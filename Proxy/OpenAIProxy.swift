import Foundation

enum InferenceError: Error, LocalizedError {
    case invalidConfiguration
    case upstreamFailure(statusCode: Int, body: String?)
    case invalidResponse
    case unsupportedOption(String)
    case modelNotSelected(capability: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Backend URL is not configured."
        case .upstreamFailure(let statusCode, let body):
            if let body, !body.isEmpty {
                return "Backend returned HTTP \(statusCode): \(body)"
            }
            return "Backend returned HTTP \(statusCode)."
        case .invalidResponse:
            return "Unexpected response from the backend."
        case .unsupportedOption(let name):
            return "'\(name)' is not supported on an OpenAI-compatible backend."
        case .modelNotSelected(let capability):
            return "No \(capability) model is selected. Pick one in BigBro Settings → Speech."
        }
    }
}

/// One event from an inference response. This replaces the old in-band sentinel string, so
/// tool calls and reasoning traces can never be mistaken for assistant text — which matters
/// now that assistant text is piped to text-to-speech.
enum InferenceEvent {
    case delta(String)
    case reasoning(String)
    case toolCalls([[String: Any]])
}

/// Proxies inference to an OpenAI-compatible backend (`/v1/chat/completions`).
///
/// BigBro targets the OpenAI surface rather than any backend's native API because Ollama,
/// LocalAI, Speaches, vLLM, LM Studio and llama.cpp-server all speak it, so switching
/// backends is a base-URL change rather than a new adapter.
struct OpenAIProxy {

    // MARK: - Helpers

    private func resolvedModel(_ model: String?) -> String {
        model?.isEmpty == false ? model! : AppSettings.shared.defaultModel
    }

    private func jsonPOSTRequest(url: URL, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300  // 5 min cap for very slow models
        return request
    }

    /// Cap on how much of an upstream error body is quoted back in the thrown error.
    private static let maxErrorBodyLength = 2000

    /// Throws unless the response is HTTP 200. `bytes` is consumed only on failure, so a
    /// successful caller can still stream it.
    private func validate(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { throw InferenceError.invalidResponse }
        guard http.statusCode != 200 else { return }

        var body = ""
        for try await line in bytes.lines {
            body += line
            if body.count >= Self.maxErrorBodyLength { break }
        }
        throw InferenceError.upstreamFailure(statusCode: http.statusCode, body: body.isEmpty ? nil : body)
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw InferenceError.invalidResponse }
        guard http.statusCode != 200 else { return }
        throw InferenceError.upstreamFailure(
            statusCode: http.statusCode,
            body: String(data: data.prefix(Self.maxErrorBodyLength), encoding: .utf8)
        )
    }

    // MARK: - Request translation

    /// Translates the Ollama-shaped messages BigBroKit sends into OpenAI chat messages.
    ///
    /// This lives on the Mac rather than in the client so existing BigBroKit builds keep
    /// working against an OpenAI-compatible backend. Three shapes differ:
    ///   - images are a base64 array in Ollama, content parts with data URIs in OpenAI
    ///   - tool call arguments are an object in Ollama, a JSON string in OpenAI
    ///   - tool results are addressed by `tool_name` in Ollama, `tool_call_id` in OpenAI
    private func openAIMessages(from raw: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        // function name -> tool_call id, carried from the most recent assistant turn so a
        // following tool result can be addressed the way OpenAI requires.
        var callIds: [String: String] = [:]

        for (i, msg) in raw.enumerated() {
            let role = msg["role"] as? String ?? "user"
            let content = msg["content"] as? String ?? ""
            var m: [String: Any] = ["role": role]

            if let images = msg["images"] as? [String], !images.isEmpty {
                var parts: [[String: Any]] = []
                if !content.isEmpty {
                    parts.append(["type": "text", "text": content])
                }
                for base64 in images {
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(base64)"],
                    ])
                }
                m["content"] = parts
            } else {
                m["content"] = content
            }

            if role == "assistant", let rawCalls = msg["tool_calls"] as? [[String: Any]] {
                var calls: [[String: Any]] = []
                callIds.removeAll()
                for (j, call) in rawCalls.enumerated() {
                    guard let fn = call["function"] as? [String: Any],
                          let name = fn["name"] as? String else { continue }
                    // Ollama's tool calls carry no id. Synthesize a stable one when the
                    // client echoed back a call that originated there.
                    let id = call["id"] as? String ?? "call_\(i)_\(j)"
                    callIds[name] = id
                    calls.append([
                        "id": id,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": Self.argumentsString(fn["arguments"]),
                        ],
                    ])
                }
                if !calls.isEmpty { m["tool_calls"] = calls }
            }

            if role == "tool" {
                let name = msg["tool_name"] as? String
                if let id = msg["tool_call_id"] as? String {
                    m["tool_call_id"] = id
                } else if let name, let id = callIds[name] {
                    m["tool_call_id"] = id
                }
                if let name { m["name"] = name }
            }

            out.append(m)
        }
        return out
    }

    /// OpenAI takes tool call arguments as a JSON string; Ollama uses an object.
    private static func argumentsString(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let value,
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{}"
    }

    /// Maps Ollama `options` onto OpenAI request fields.
    ///
    /// Six map directly and `num_predict` is a rename. The rest (`top_k`, `repeat_penalty`,
    /// `num_ctx`, `num_thread`) have no OpenAI equivalent and are forwarded verbatim:
    /// Ollama and LocalAI accept them as extensions, stricter servers ignore them.
    private func applyOptions(_ options: [String: Any]?, to body: inout [String: Any]) {
        guard let options else { return }
        for (key, value) in options {
            switch key {
            case "num_predict":
                body["max_tokens"] = value
            default:
                body[key] = value
            }
        }
    }

    /// Ollama's native `format` becomes OpenAI's `response_format`.
    private func responseFormat(from format: Any?) -> [String: Any]? {
        guard let format else { return nil }
        if let string = format as? String {
            return string == "json" ? ["type": "json_object"] : nil
        }
        if let schema = format as? [String: Any] {
            return ["type": "json_schema", "json_schema": ["name": "response", "schema": schema]]
        }
        return nil
    }

    /// Ollama's native `think` flag is *not* honoured on `/v1/chat/completions` — the
    /// OpenAI-compatible surface uses `reasoning_effort`, where "none" disables thinking.
    private func reasoningEffort(from think: Bool?) -> String? {
        guard let think else { return nil }
        return think ? "medium" : "none"
    }

    private func chatBody(
        messages: [[String: Any]],
        model: String?,
        tools: [[String: Any]],
        format: Any?,
        options: [String: Any]?,
        think: Bool?,
        keepAlive: String?,
        stream: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": resolvedModel(model),
            "messages": openAIMessages(from: messages),
            "stream": stream,
        ]
        if !tools.isEmpty                        { body["tools"] = tools }
        if let rf = responseFormat(from: format) { body["response_format"] = rf }
        if let effort = reasoningEffort(from: think) { body["reasoning_effort"] = effort }
        // No OpenAI equivalent. Forwarded verbatim so backends that understand it (Ollama)
        // still honour it; the rest ignore an unknown field.
        if let keepAlive                         { body["keep_alive"] = keepAlive }
        applyOptions(options, to: &body)
        return body
    }

    // MARK: - Response translation

    /// OpenAI streams tool calls in fragments: the first carries `id` and `function.name`,
    /// later ones append a few characters of `function.arguments` at a time.
    private static func accumulate(_ fragments: [[String: Any]], into calls: inout [Int: [String: Any]]) {
        for fragment in fragments {
            let index = fragment["index"] as? Int ?? 0
            var call = calls[index] ?? ["type": "function"]

            if let id = fragment["id"] as? String { call["id"] = id }

            var fn = call["function"] as? [String: Any] ?? ["name": "", "arguments": ""]
            if let f = fragment["function"] as? [String: Any] {
                if let name = f["name"] as? String, !name.isEmpty { fn["name"] = name }
                if let args = f["arguments"] as? String {
                    fn["arguments"] = (fn["arguments"] as? String ?? "") + args
                }
            }
            call["function"] = fn
            calls[index] = call
        }
    }

    /// BigBroKit reads `function.arguments` as an object, which is what Ollama's native API
    /// produced. Decode OpenAI's JSON-string form back to an object so existing clients keep
    /// working. `id` is preserved so the echoed assistant turn can address tool results.
    private static func clientShape(_ calls: [[String: Any]]) -> [[String: Any]] {
        calls.map { call in
            var out = call
            if var fn = call["function"] as? [String: Any] {
                if let string = fn["arguments"] as? String {
                    let parsed = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]
                    fn["arguments"] = parsed ?? [:]
                }
                out["function"] = fn
            }
            return out
        }
    }

    /// Backends disagree on where reasoning traces live; check both known spellings.
    private static func reasoningText(in object: [String: Any]) -> String? {
        let value = object["reasoning"] ?? object["reasoning_content"]
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Streaming

    private func streamEvents(_ request: URLRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try await validate(response, bytes: bytes)

                    var toolCalls: [Int: [String: Any]] = [:]

                    for try await line in bytes.lines {
                        // Server-sent events: `data: {...}` payload lines, blank separators,
                        // and a literal [DONE] terminator.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choice = (json["choices"] as? [[String: Any]])?.first
                        else { continue }

                        let delta = choice["delta"] as? [String: Any] ?? [:]

                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(.delta(content))
                        }
                        if let reasoning = Self.reasoningText(in: delta) {
                            continuation.yield(.reasoning(reasoning))
                        }
                        if let fragments = delta["tool_calls"] as? [[String: Any]] {
                            Self.accumulate(fragments, into: &toolCalls)
                        }
                    }

                    // Tool calls are only complete once the stream ends, since arguments
                    // arrive in fragments.
                    if !toolCalls.isEmpty {
                        let ordered = toolCalls.keys.sorted().compactMap { toolCalls[$0] }
                        continuation.yield(.toolCalls(Self.clientShape(ordered)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func sendOnce(_ request: URLRequest) async throws -> [InferenceEvent] {
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw InferenceError.invalidResponse
        }

        var events: [InferenceEvent] = []
        if let reasoning = Self.reasoningText(in: message) {
            events.append(.reasoning(reasoning))
        }
        if let content = message["content"] as? String, !content.isEmpty {
            events.append(.delta(content))
        }
        if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            events.append(.toolCalls(Self.clientShape(calls)))
        }
        return events
    }

    // MARK: - Chat

    func chatStream(
        messages: [[String: Any]],
        model: String? = nil,
        tools: [[String: Any]] = [],
        format: Any? = nil,
        options: [String: Any]? = nil,
        think: Bool? = nil,
        keepAlive: String? = nil
    ) -> AsyncThrowingStream<InferenceEvent, Error> {
        guard let url = AppSettings.shared.chatCompletionsURL else {
            return AsyncThrowingStream { $0.finish(throwing: InferenceError.invalidConfiguration) }
        }
        let body = chatBody(messages: messages, model: model, tools: tools, format: format,
                            options: options, think: think, keepAlive: keepAlive, stream: true)
        do {
            return streamEvents(try jsonPOSTRequest(url: url, body: body))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func chat(
        messages: [[String: Any]],
        model: String? = nil,
        tools: [[String: Any]] = [],
        format: Any? = nil,
        options: [String: Any]? = nil,
        think: Bool? = nil,
        keepAlive: String? = nil
    ) async throws -> [InferenceEvent] {
        guard let url = AppSettings.shared.chatCompletionsURL else {
            throw InferenceError.invalidConfiguration
        }
        let body = chatBody(messages: messages, model: model, tools: tools, format: format,
                            options: options, think: think, keepAlive: keepAlive, stream: false)
        return try await sendOnce(jsonPOSTRequest(url: url, body: body))
    }

    // MARK: - Speech synthesis

    /// Bytes are buffered to roughly this size before being yielded, so the caller sends a
    /// reasonable number of frames rather than one per network read.
    private static let audioChunkBytes = 8 * 1024

    /// ...and flushed at least this often regardless, so a backend that pauses between
    /// sentences does not leave a partial buffer stranded.
    private static let audioFlushInterval: TimeInterval = 0.25

    /// Streams synthesized audio from `/v1/audio/speech`.
    ///
    /// `stream_format: "audio"` asks for raw chunked bytes. Backends that do not know the
    /// flag ignore it and return the whole body instead, which this same reader handles with
    /// no branching. `stream_format: "sse"` is deliberately not used: most local servers do
    /// not implement it, and it would base64-encode audio that the peer protocol then
    /// base64-encodes again.
    func synthesize(
        input: String,
        voice: String? = nil,
        model: String? = nil,
        responseFormat: String? = nil,
        speed: Double? = nil
    ) -> AsyncThrowingStream<Data, Error> {
        let settings = AppSettings.shared
        guard let url = settings.speechURL else {
            return AsyncThrowingStream { $0.finish(throwing: InferenceError.invalidConfiguration) }
        }

        // Sending an empty model name produces an opaque 404 from the backend; naming the
        // real problem is far more useful.
        let resolvedModel = model?.isEmpty == false ? model! : settings.ttsModel
        guard !resolvedModel.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: InferenceError.modelNotSelected(capability: "speech")) }
        }

        let format = responseFormat ?? settings.ttsFormat
        var body: [String: Any] = [
            "model": resolvedModel,
            "input": input,
            "voice": voice?.isEmpty == false ? voice! : settings.ttsVoice,
            "response_format": format,
        ]
        if let speed { body["speed"] = speed }

        // Streaming is only defined for pcm/wav at normal speed; asking for it otherwise
        // makes stricter servers reject the request outright.
        if ["pcm", "wav"].contains(format), speed == nil || speed == 1.0 {
            body["stream_format"] = "audio"
        }

        let request: URLRequest
        do {
            request = try jsonPOSTRequest(url: url, body: body)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try await validate(response, bytes: bytes)

                    var buffer = Data()
                    var lastFlush = Date()
                    var sinceTimeCheck = 0

                    for try await byte in bytes {
                        buffer.append(byte)

                        if buffer.count >= Self.audioChunkBytes {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                            lastFlush = Date()
                            sinceTimeCheck = 0
                            continue
                        }

                        // Checking the clock per byte would dominate the loop; sample it.
                        sinceTimeCheck += 1
                        if sinceTimeCheck >= 1024 {
                            sinceTimeCheck = 0
                            if !buffer.isEmpty, Date().timeIntervalSince(lastFlush) >= Self.audioFlushInterval {
                                continuation.yield(buffer)
                                buffer.removeAll(keepingCapacity: true)
                                lastFlush = Date()
                            }
                        }
                    }

                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Collects a whole utterance into one buffer. Used by the Settings preview, where the
    /// audio is handed to AVAudioPlayer rather than streamed.
    func synthesizeAll(
        input: String,
        voice: String? = nil,
        model: String? = nil,
        responseFormat: String? = nil,
        speed: Double? = nil
    ) async throws -> Data {
        var audio = Data()
        for try await chunk in synthesize(input: input, voice: voice, model: model,
                                          responseFormat: responseFormat, speed: speed) {
            audio.append(chunk)
        }
        return audio
    }

    // MARK: - Transcription

    /// Transcribes a complete utterance via `/v1/audio/transcriptions`.
    ///
    /// Batch rather than streaming: real-time transcription needs the Realtime API and a
    /// persistent bidirectional session, which is a much larger change and unnecessary for
    /// push-to-talk or voice-activity-delimited turns.
    ///
    /// This is the only request in the proxy that is not JSON — the endpoint takes
    /// multipart/form-data.
    func transcribe(
        audio: Data,
        format: String = "wav",
        model: String? = nil,
        language: String? = nil,
        prompt: String? = nil,
        temperature: Double? = nil
    ) async throws -> (text: String, language: String?) {
        let settings = AppSettings.shared
        guard let url = settings.transcriptionsURL else {
            throw InferenceError.invalidConfiguration
        }

        let resolvedModel = model?.isEmpty == false ? model! : settings.sttModel
        guard !resolvedModel.isEmpty else {
            throw InferenceError.modelNotSelected(capability: "transcription")
        }

        var body = MultipartBody()
        body.addFile(
            "file",
            filename: "audio.\(format)",
            contentType: MultipartBody.audioContentType(for: format),
            fileData: audio
        )
        body.addField("model", resolvedModel)
        body.addField("response_format", "json")
        if let language    { body.addField("language", language) }
        if let prompt      { body.addField("prompt", prompt) }
        if let temperature { body.addField("temperature", String(temperature)) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.finalize()
        request.timeoutInterval = 300  // first request may lazily download the model

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return (text, json["language"] as? String)
        }
        // Some servers answer with a bare string even when asked for json.
        guard let text = String(data: data, encoding: .utf8) else {
            throw InferenceError.invalidResponse
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    // MARK: - Generate

    /// Ollama's `/api/generate` has no OpenAI equivalent that preserves images or a system
    /// prompt — `/v1/completions` is plain text in, text out — so a generate request is
    /// expressed as a one-turn chat.
    ///
    /// `template` and `raw` are Ollama prompt-templating knobs, and `suffix` is
    /// fill-in-the-middle. None has a chat-completions analogue, so they are rejected rather
    /// than silently dropped — a wrong answer is worse than a clear error.
    private func generateMessages(
        prompt: String,
        images: [String],
        system: String?,
        template: String?,
        suffix: String?,
        raw: Bool?
    ) throws -> [[String: Any]] {
        if template != nil { throw InferenceError.unsupportedOption("template") }
        if suffix != nil   { throw InferenceError.unsupportedOption("suffix") }
        if raw == true     { throw InferenceError.unsupportedOption("raw") }

        var messages: [[String: Any]] = []
        if let system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        var user: [String: Any] = ["role": "user", "content": prompt]
        if !images.isEmpty { user["images"] = images }
        messages.append(user)
        return messages
    }

    func generateStream(
        prompt: String,
        images: [String] = [],
        system: String? = nil,
        template: String? = nil,
        suffix: String? = nil,
        model: String? = nil,
        format: Any? = nil,
        options: [String: Any]? = nil,
        raw: Bool? = nil,
        think: Bool? = nil,
        keepAlive: String? = nil
    ) -> AsyncThrowingStream<InferenceEvent, Error> {
        do {
            let messages = try generateMessages(prompt: prompt, images: images, system: system,
                                                template: template, suffix: suffix, raw: raw)
            return chatStream(messages: messages, model: model, format: format,
                              options: options, think: think, keepAlive: keepAlive)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func generate(
        prompt: String,
        images: [String] = [],
        system: String? = nil,
        template: String? = nil,
        suffix: String? = nil,
        model: String? = nil,
        format: Any? = nil,
        options: [String: Any]? = nil,
        raw: Bool? = nil,
        think: Bool? = nil,
        keepAlive: String? = nil
    ) async throws -> [InferenceEvent] {
        let messages = try generateMessages(prompt: prompt, images: images, system: system,
                                            template: template, suffix: suffix, raw: raw)
        return try await chat(messages: messages, model: model, format: format,
                              options: options, think: think, keepAlive: keepAlive)
    }
}
