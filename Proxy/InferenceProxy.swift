import Foundation

enum InferenceError: Error {
    case invalidConfiguration
    case upstreamFailure(statusCode: Int)
    case invalidResponse
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
        return request
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

                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw InferenceError.upstreamFailure(statusCode: code)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
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

                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw InferenceError.upstreamFailure(statusCode: code)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["response"] as? String else {
            throw InferenceError.invalidResponse
        }
        return result
    }
}
