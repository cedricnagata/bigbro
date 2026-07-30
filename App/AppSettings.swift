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

    init() {
        let defaults = UserDefaults.standard
        textModelID   = defaults.string(forKey: "bigbro.textModelID") ?? ModelCatalog.defaultTextModelID
        visionModelID = defaults.string(forKey: "bigbro.visionModelID") ?? ModelCatalog.defaultVisionModelID
    }
}
