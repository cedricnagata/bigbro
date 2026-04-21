import Foundation

enum InferenceError: Error {
    case invalidConfiguration
    case upstreamFailure(statusCode: Int)
    case invalidResponse
}

struct InferenceProxy {
    func forward(messages: [[String: String]], model: String? = nil) async throws -> String {
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
