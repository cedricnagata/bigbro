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

    /// Host of the speech backend. Defaults to LocalAI, which serves both text-to-speech
    /// and speech-to-text; Speaches is a drop-in alternative on port 8000, and
    /// Kokoro-FastAPI on 8880. There is no canonical port the way 11434 is canonical for
    /// Ollama, which is why this is configurable at all.
    static let localAIHost = "http://localhost:8080"
    static var speechBaseURL: String { localAIHost + "/v1" }

    @Published var defaultModel: String {
        didSet { UserDefaults.standard.set(defaultModel, forKey: "bigbro.defaultModel") }
    }

    // MARK: - Speech backend

    /// Gates text-to-speech *and* speech-to-text. Off by default: an unconfigured optional
    /// backend should read as off rather than broken, and should not be polled at all.
    @Published var speechEnabled: Bool {
        didSet { UserDefaults.standard.set(speechEnabled, forKey: "bigbro.speechEnabled") }
    }
    @Published var ttsModel: String {
        didSet { UserDefaults.standard.set(ttsModel, forKey: "bigbro.ttsModel") }
    }
    @Published var ttsVoice: String {
        didSet { UserDefaults.standard.set(ttsVoice, forKey: "bigbro.ttsVoice") }
    }
    /// Wire format for synthesized audio. `pcm` is the default because it is the only
    /// format safe to split at arbitrary byte boundaries and feed straight to playback.
    @Published var ttsFormat: String {
        didSet { UserDefaults.standard.set(ttsFormat, forKey: "bigbro.ttsFormat") }
    }
    @Published var sttModel: String {
        didSet { UserDefaults.standard.set(sttModel, forKey: "bigbro.sttModel") }
    }

    // MARK: - Derived upstream URLs

    var chatCompletionsURL: URL? { Self.url(Self.chatBaseURL, "/chat/completions") }
    var modelsURL: URL?          { Self.url(Self.chatBaseURL, "/models") }

    var speechURL: URL?         { Self.url(Self.speechBaseURL, "/audio/speech") }
    var transcriptionsURL: URL? { Self.url(Self.speechBaseURL, "/audio/transcriptions") }
    var speechModelsURL: URL?   { Self.url(Self.speechBaseURL, "/models") }
    var voicesURL: URL?         { Self.url(Self.speechBaseURL, "/audio/voices") }

    /// Ollama-native. Listing and installing models have no OpenAI-compatible equivalent
    /// (`/v1/models` lists but cannot pull), so these stay on the native API.
    var tagsURL: URL? { Self.url(Self.chatHost, "/api/tags") }
    var pullURL: URL? { Self.url(Self.chatHost, "/api/pull") }

    /// LocalAI-native gallery install: apply returns a job id, which is then polled.
    var localAIApplyURL: URL? { Self.url(Self.localAIHost, "/models/apply") }
    func localAIJobURL(_ jobId: String) -> URL? { Self.url(Self.localAIHost, "/models/jobs/\(jobId)") }

    private static func url(_ base: String, _ path: String) -> URL? {
        URL(string: base + path)
    }

    init() {
        let defaults = UserDefaults.standard
        defaultModel   = defaults.string(forKey: "bigbro.defaultModel") ?? "gpt-oss-20b"
        speechEnabled  = defaults.bool(forKey: "bigbro.speechEnabled")
        ttsModel       = defaults.string(forKey: "bigbro.ttsModel") ?? "tts-1"
        ttsVoice       = defaults.string(forKey: "bigbro.ttsVoice") ?? "af_heart"
        ttsFormat      = defaults.string(forKey: "bigbro.ttsFormat") ?? "pcm"
        sttModel       = defaults.string(forKey: "bigbro.sttModel") ?? "whisper-1"
    }
}
