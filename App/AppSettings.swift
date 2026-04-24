import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let ollamaBaseURL = "http://localhost:11434"

    @Published var defaultModel: String {
        didSet { UserDefaults.standard.set(defaultModel, forKey: "bigbro.defaultModel") }
    }

    var chatURL: URL? { URL(string: Self.ollamaBaseURL + "/api/chat") }
    var generateURL: URL? { URL(string: Self.ollamaBaseURL + "/api/generate") }

    init() {
        defaultModel = UserDefaults.standard.string(forKey: "bigbro.defaultModel") ?? "gpt-oss-20b"
    }
}
