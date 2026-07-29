import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Host of the chat backend. Every upstream URL in the app is derived from this — do
    /// not re-declare the host anywhere else.
    static let chatHost = "http://localhost:11434"

    /// OpenAI-compatible base. Ollama, LocalAI, Speaches, vLLM and llama.cpp-server all
    /// serve the same endpoints under this prefix, which is why BigBro targets it rather
    /// than any one backend's native API.
    static var chatBaseURL: String { chatHost + "/v1" }

    @Published var defaultModel: String {
        didSet { UserDefaults.standard.set(defaultModel, forKey: "bigbro.defaultModel") }
    }

    // MARK: - Derived upstream URLs

    var chatCompletionsURL: URL? { Self.url(Self.chatBaseURL, "/chat/completions") }
    var modelsURL: URL?          { Self.url(Self.chatBaseURL, "/models") }

    /// Ollama-native. Listing and installing models have no OpenAI-compatible equivalent
    /// (`/v1/models` lists but cannot pull), so these stay on the native API.
    var tagsURL: URL? { Self.url(Self.chatHost, "/api/tags") }
    var pullURL: URL? { Self.url(Self.chatHost, "/api/pull") }

    /// Host of the LocalAI backend, which serves speech and its own model gallery.
    static let localAIHost = "http://localhost:8080"

    /// LocalAI-native gallery install: apply returns a job id, which is then polled.
    var localAIApplyURL: URL? { Self.url(Self.localAIHost, "/models/apply") }
    func localAIJobURL(_ jobId: String) -> URL? { Self.url(Self.localAIHost, "/models/jobs/\(jobId)") }

    private static func url(_ base: String, _ path: String) -> URL? {
        URL(string: base + path)
    }

    init() {
        defaultModel = UserDefaults.standard.string(forKey: "bigbro.defaultModel") ?? "gpt-oss-20b"
    }
}
