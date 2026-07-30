import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Models

    /// Catalog id of the model used when a request names none. Stored as an id rather than a
    /// `BigBroModel` so a catalog entry that disappears in a later build degrades to the
    /// default instead of failing to decode.
    @Published var textModelID: String {
        didSet { UserDefaults.standard.set(textModelID, forKey: "bigbro.textModelID") }
    }

    /// Used whenever a request carries images, including when the request asked for a
    /// language model that cannot see.
    @Published var visionModelID: String {
        didSet { UserDefaults.standard.set(visionModelID, forKey: "bigbro.visionModelID") }
    }

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
        textModelID   = defaults.string(forKey: "bigbro.textModelID") ?? ModelCatalog.defaultTextModelID
        visionModelID = defaults.string(forKey: "bigbro.visionModelID") ?? ModelCatalog.defaultVisionModelID
        speechEnabled = defaults.bool(forKey: "bigbro.speechEnabled")
        ttsVoice      = defaults.string(forKey: "bigbro.ttsVoice") ?? "af_heart"
    }
}
