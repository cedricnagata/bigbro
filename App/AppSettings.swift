import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Speech backend

    /// Gates text-to-speech *and* speech-to-text. Off by default: loading Kokoro + Parakeet
    /// is not free, so an unconfigured optional capability should read as off rather than
    /// eagerly downloading two more models nobody asked for yet.
    @Published var speechEnabled: Bool {
        didSet { UserDefaults.standard.set(speechEnabled, forKey: "bigbro.speechEnabled") }
    }

    /// Kokoro voice id, e.g. `af_heart`. Free-form rather than a closed list: FluidAudio does
    /// not expose a canonical enumerable voice list the way it does for models.
    @Published var ttsVoice: String {
        didSet { UserDefaults.standard.set(ttsVoice, forKey: "bigbro.ttsVoice") }
    }

    init() {
        let defaults = UserDefaults.standard
        speechEnabled = defaults.bool(forKey: "bigbro.speechEnabled")
        ttsVoice      = defaults.string(forKey: "bigbro.ttsVoice") ?? "af_heart"
    }
}
