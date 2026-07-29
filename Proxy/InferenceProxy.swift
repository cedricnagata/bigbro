import Foundation

enum InferenceError: Error, LocalizedError {
    case invalidConfiguration
    case upstreamFailure(statusCode: Int, body: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Ollama URL is not configured."
        case .upstreamFailure(let statusCode, let body):
            if let body, !body.isEmpty {
                return "Ollama returned HTTP \(statusCode): \(body)"
            }
            return "Ollama returned HTTP \(statusCode)."
        case .invalidResponse:
            return "Unexpected response from Ollama."
        }
    }
}

// Sentinel prefix yielded when Ollama returns tool_calls in a streaming response.
// AppRouter detects this prefix (12 chars: 1 SOH + "TOOL_CALLS:") and converts
// it to a toolCall peer message.
let toolCallsSentinel = "\u{0001}TOOL_CALLS:"

struct InferenceProxy {

    // MARK: - Helpers

    private func resolvedModel(_ model: String?) -> String {
        let s = AppSettings.shared
        return model?.isEmpty == false ? model! : s.defaultModel
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
    /// successful caller can still stream it. Without this, Ollama's non-200 JSON error
    /// bodies get parsed as NDJSON, yield no deltas, and reach the client as a successful
    /// empty stream.
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

    // MARK: - /api/chat (streaming)

    func forwardStream(
        messages: [[String: Any]],
        model: String? = nil,
        tools: [[String: Any]] = [],
        format: Any? = nil,
        options: [String: Any]? = nil,
        think: Bool? = nil,
        keepAlive: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let url = AppSettings.shared.chatURL else {
                        continuation.finish(throwing: InferenceError.invalidConfiguration)
                        return
                    }
                    var body: [String: Any] = [
                        "model": resolvedModel(model),
                        "messages": messages,
                        "stream": true
                    ]
                    if !tools.isEmpty            { body["tools"] = tools }
                    if let format                { body["format"] = format }
                    if let options, !options.isEmpty { body["options"] = options }
                    if let think                 { body["think"] = think }
                    if let keepAlive             { body["keep_alive"] = keepAlive }
                    let request = try jsonPOSTRequest(url: url, body: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try await validate(response, bytes: bytes)
                    for try await line in bytes.lines {
                        guard !line.isEmpty,
                              let lineData = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                        else { continue }

                        if let message = json["message"] as? [String: Any] {
                            if let content = message["content"] as? String, !content.isEmpty {
                                continuation.yield(content)
                            }
                            if let toolCalls = message["tool_calls"] {
                                if let data = try? JSONSerialization.data(withJSONObject: toolCalls),
                                   let jsonStr = String(data: data, encoding: .utf8) {
                                    continuation.yield(toolCallsSentinel + jsonStr)
                                }
                            }
                        }
                        if let done = json["done"] as? Bool, done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - /api/chat (non-streaming)

    func forward(
        messages: [[String: Any]],
        model: String? = nil,
        tools: [[String: Any]] = [],
        format: Any? = nil,
        options: [String: Any]? = nil,
        think: Bool? = nil,
        keepAlive: String? = nil
    ) async throws -> String {
        guard let url = AppSettings.shared.chatURL else { throw InferenceError.invalidConfiguration }

        var body: [String: Any] = ["model": resolvedModel(model), "messages": messages, "stream": false]
        if !tools.isEmpty            { body["tools"] = tools }
        if let format                { body["format"] = format }
        if let options, !options.isEmpty { body["options"] = options }
        if let think                 { body["think"] = think }
        if let keepAlive             { body["keep_alive"] = keepAlive }
        let request = try jsonPOSTRequest(url: url, body: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            throw InferenceError.invalidResponse
        }
        if let toolCalls = message["tool_calls"],
           let tcData = try? JSONSerialization.data(withJSONObject: toolCalls),
           let tcStr = String(data: tcData, encoding: .utf8) {
            return toolCallsSentinel + tcStr
        }
        guard let content = message["content"] as? String else {
            throw InferenceError.invalidResponse
        }
        return content
    }

    // MARK: - /api/generate (streaming)

    func forwardGenerateStream(
        prompt: String,
        images: [String] = [],
        suffix: String? = nil,
        system: String? = nil,
        template: String? = nil,
        model: String? = nil,
        format: Any? = nil,
        options: [String: Any]? = nil,
        raw: Bool? = nil,
        think: Bool? = nil,
        keepAlive: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let url = AppSettings.shared.generateURL else {
                        continuation.finish(throwing: InferenceError.invalidConfiguration)
                        return
                    }
                    var body: [String: Any] = [
                        "model": resolvedModel(model),
                        "prompt": prompt,
                        "stream": true
                    ]
                    if !images.isEmpty           { body["images"] = images }
                    if let suffix                { body["suffix"] = suffix }
                    if let system                { body["system"] = system }
                    if let template              { body["template"] = template }
                    if let format                { body["format"] = format }
                    if let options, !options.isEmpty { body["options"] = options }
                    if let raw                   { body["raw"] = raw }
                    if let think                 { body["think"] = think }
                    if let keepAlive             { body["keep_alive"] = keepAlive }
                    let request = try jsonPOSTRequest(url: url, body: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try await validate(response, bytes: bytes)
                    for try await line in bytes.lines {
                        guard !line.isEmpty,
                              let lineData = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                        else { continue }

                        if let response = json["response"] as? String, !response.isEmpty {
                            continuation.yield(response)
                        }
                        if let done = json["done"] as? Bool, done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - /api/generate (non-streaming)

    func forwardGenerate(
        prompt: String,
        images: [String] = [],
        suffix: String? = nil,
        system: String? = nil,
        template: String? = nil,
        model: String? = nil,
        format: Any? = nil,
        options: [String: Any]? = nil,
        raw: Bool? = nil,
        think: Bool? = nil,
        keepAlive: String? = nil
    ) async throws -> String {
        guard let url = AppSettings.shared.generateURL else { throw InferenceError.invalidConfiguration }

        var body: [String: Any] = ["model": resolvedModel(model), "prompt": prompt, "stream": false]
        if !images.isEmpty           { body["images"] = images }
        if let suffix                { body["suffix"] = suffix }
        if let system                { body["system"] = system }
        if let template              { body["template"] = template }
        if let format                { body["format"] = format }
        if let options, !options.isEmpty { body["options"] = options }
        if let raw                   { body["raw"] = raw }
        if let think                 { body["think"] = think }
        if let keepAlive             { body["keep_alive"] = keepAlive }
        let request = try jsonPOSTRequest(url: url, body: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["response"] as? String else {
            throw InferenceError.invalidResponse
        }
        return result
    }
}
