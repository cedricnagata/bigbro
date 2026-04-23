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

    func forwardStream(messages: [[String: Any]],
                       model: String? = nil,
                       tools: [[String: Any]] = []) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let settings = AppSettings.shared
                    guard let url = settings.chatURL else {
                        continuation.finish(throwing: InferenceError.invalidConfiguration)
                        return
                    }
                    let resolvedModel = model?.isEmpty == false ? model! : settings.defaultModel
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var body: [String: Any] = [
                        "model": resolvedModel,
                        "messages": messages,
                        "stream": true
                    ]
                    if !tools.isEmpty { body["tools"] = tools }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

    func forward(messages: [[String: Any]], model: String? = nil) async throws -> String {
        let settings = AppSettings.shared
        guard let url = settings.chatURL else { throw InferenceError.invalidConfiguration }

        let resolvedModel = model?.isEmpty == false ? model! : settings.defaultModel

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["model": resolvedModel, "messages": messages, "stream": false]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
}
