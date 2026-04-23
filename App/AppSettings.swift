import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Keys.baseURL) }
    }
    @Published var defaultModel: String {
        didSet { UserDefaults.standard.set(defaultModel, forKey: Keys.defaultModel) }
    }

    var chatURL: URL? {
        URL(string: baseURL + "/api/chat")
    }

    var generateURL: URL? {
        URL(string: baseURL + "/api/generate")
    }

    private enum Keys {
        static let baseURL = "bigbro.baseURL"
        static let defaultModel = "bigbro.defaultModel"
    }

    init() {
        baseURL = UserDefaults.standard.string(forKey: Keys.baseURL) ?? "http://localhost:11434"
        defaultModel = UserDefaults.standard.string(forKey: Keys.defaultModel) ?? "gpt-oss-20b"
    }
}
