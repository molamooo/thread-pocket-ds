import Foundation
import Security

/// 令牌存储：优先钥匙串，钥匙串不可用时退回 0600 的本地文件。
/// （未签名的开发构建每次都会换签名，钥匙串可能拒绝旧的条目，
/// 这时降级到文件可以避免"每次重新登录"，同时在页面上标注存储位置。）
struct CredentialStore {
    enum Backend: String, Codable {
        case keychain
        case file
    }

    struct StoredCredential: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var scope: String
        var clientId: String
        var tokenEndpoint: String
        var issuer: String
        var account: String?
        var backend: Backend
    }

    private let service: String
    private let fileURL: URL

    init(service: String = "com.threadpocket.desktop") {
        self.service = service
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = support.appendingPathComponent("ThreadPocket", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("credentials.json")
    }

    private func account(for origin: String) -> String {
        "oauth:\(origin)"
    }

    func load(for origin: String) -> StoredCredential? {
        if let data = readKeychain(account: account(for: origin)),
           let credential = try? JSONDecoder().decode(StoredCredential.self, from: data) {
            return credential
        }
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? JSONDecoder().decode([String: StoredCredential].self, from: data) else {
            return nil
        }
        return all[origin]
    }

    @discardableResult
    func save(_ credential: StoredCredential, for origin: String) -> Backend {
        var next = credential
        let payload = (try? JSONEncoder().encode(credential)) ?? Data()
        if storeKeychain(payload, account: account(for: origin)) {
            next.backend = .keychain
        } else {
            next.backend = .file
        }
        var all: [String: StoredCredential] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: StoredCredential].self, from: data) {
            all = decoded
        }
        if next.backend == .keychain {
            all[origin] = nil
        } else {
            all[origin] = next
        }
        writeFile(all)
        return next.backend
    }

    func delete(for origin: String) {
        deleteKeychain(account: account(for: origin))
        guard let data = try? Data(contentsOf: fileURL),
              var all = try? JSONDecoder().decode([String: StoredCredential].self, from: data) else {
            return
        }
        all[origin] = nil
        writeFile(all)
    }

    private func writeFile(_ all: [String: StoredCredential]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /* --------------------------------- 钥匙串 --------------------------------- */

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readKeychain(account: String) -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func storeKeychain(_ data: Data, account: String) -> Bool {
        let base = query(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private func deleteKeychain(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
