import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Single source of truth for the Ollama host. Every upstream URL in the app is
    /// derived from this — do not re-declare the host anywhere else.
    static let ollamaBaseURL = "http://localhost:11434"

    @Published var defaultModel: String {
        didSet { UserDefaults.standard.set(defaultModel, forKey: "bigbro.defaultModel") }
    }

    // MARK: - Derived upstream URLs

    var chatURL: URL?     { Self.ollamaURL("/api/chat") }
    var generateURL: URL? { Self.ollamaURL("/api/generate") }
    var tagsURL: URL?     { Self.ollamaURL("/api/tags") }
    var pullURL: URL?     { Self.ollamaURL("/api/pull") }

    private static func ollamaURL(_ path: String) -> URL? {
        URL(string: ollamaBaseURL + path)
    }

    init() {
        defaultModel = UserDefaults.standard.string(forKey: "bigbro.defaultModel") ?? "gpt-oss-20b"
    }
}
