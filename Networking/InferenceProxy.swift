import Foundation

enum InferenceError: Error {
    case upstreamFailure(statusCode: Int)
    case invalidResponse
}

struct InferenceProxy {
    static let ollamaURL = URL(string: "http://localhost:11434/api/chat")!
    var model: String = "llama3"

    func forward(messages: [[String: String]]) async throws -> String {
        var request = URLRequest(url: Self.ollamaURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["model": model, "messages": messages, "stream": false]
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
