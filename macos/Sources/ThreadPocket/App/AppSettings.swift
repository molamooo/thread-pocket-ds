import Foundation

/// 连接配置：服务器地址与令牌都可随时修改，应用只依赖这个 URL。
final class AppSettings: ObservableObject {
    private enum Key {
        static let serverURL = "threadpocket.serverURL"
        static let token = "threadpocket.token"
        static let autoRefresh = "threadpocket.autoRefreshSeconds"
        static let onboarded = "threadpocket.onboarded"
    }

    static let defaultServerURL = "http://127.0.0.1:8787"

    private let defaults: UserDefaults

    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Key.serverURL) }
    }

    @Published var token: String {
        didSet { defaults.set(token, forKey: Key.token) }
    }

    @Published var autoRefreshSeconds: Int {
        didSet { defaults.set(autoRefreshSeconds, forKey: Key.autoRefresh) }
    }

    @Published var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Key.onboarded) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serverURL = defaults.string(forKey: Key.serverURL) ?? Self.defaultServerURL
        self.token = defaults.string(forKey: Key.token) ?? ""
        let stored = defaults.object(forKey: Key.autoRefresh) as? Int
        self.autoRefreshSeconds = stored ?? 0
        self.hasOnboarded = defaults.bool(forKey: Key.onboarded)
    }

    var normalizedURL: URL? {
        APIClient.normalize(urlString: serverURL)
    }
}
