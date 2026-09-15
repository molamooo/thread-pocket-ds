import AppKit
import CryptoKit
import Foundation
import Security

/// 桌面端的 OAuth 登录：发现授权服务器 → 动态注册 → PKCE 授权码 + 本机回环回调 → 令牌。
/// 桌面端复用与 MCP 完全相同的授权服务器与 scope，只是它申请的是 threads:* 而不是 mcp:tools。
@MainActor
final class OAuthClient {
    struct ServerMetadata: Decodable {
        var issuer: String
        var authorizationEndpoint: String
        var tokenEndpoint: String
        var registrationEndpoint: String?
        var scopesSupported: [String]?
    }

    struct ResourceMetadata: Decodable {
        var resource: String
        var authorizationServers: [String]
        var scopesSupported: [String]?
    }

    struct RegistrationResponse: Decodable {
        var clientId: String
        var clientName: String?
    }

    struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Double?
        var scope: String?
        var tokenType: String?
    }

    enum LoginError: LocalizedError {
        case discovery(String)
        case registration(String)
        case denied(String)
        case exchange(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .discovery(let message): "无法发现授权服务器：\(message)"
            case .registration(let message): "客户端注册失败：\(message)"
            case .denied(let message): "授权被拒绝或失败：\(message)"
            case .exchange(let message): "换取令牌失败：\(message)"
            case .malformed(let message): message
            }
        }
    }

    /// 桌面端需要的权限：读写线索 + 刷新令牌。绝不申请 mcp:tools。
    static let requestedScopes = "threads:read threads:write offline_access"
    /// 回环回调固定用不带端口的形式注册；服务端对 127.0.0.1 的回调忽略端口差异。
    static let registeredRedirect = "http://127.0.0.1/callback"

    private let session: URLSession
    private let credentials = CredentialStore()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - 缓存

    func cached(for origin: String) -> CredentialStore.StoredCredential? {
        credentials.load(for: origin)
    }

    func signOut(for origin: String) {
        credentials.delete(for: origin)
    }

    // MARK: - 登录

    @discardableResult
    func signIn(baseURL: URL, present: Bool = true) async throws -> CredentialStore.StoredCredential {
        let origin = Self.origin(of: baseURL)
        let metadata = try await discover(baseURL: baseURL)
        let clientId = try await clientIdentifier(metadata: metadata, origin: origin)

        let verifier = Self.randomVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomVerifier()

        let server = LoopbackCallbackServer()
        let port = try await server.start()
        let redirectUri = "http://127.0.0.1:\(port)/callback"

        guard var components = URLComponents(string: metadata.authorizationEndpoint) else {
            throw LoginError.discovery("授权端点地址无效")
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: Self.requestedScopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizeURL = components.url else {
            throw LoginError.discovery("无法构造授权链接")
        }

        if present {
            NSWorkspace.shared.open(authorizeURL)
        }

        let callback: [String: String]
        do {
            callback = try await server.waitForCallback()
        } catch {
            server.stop()
            throw error
        }
        server.stop()

        if let error = callback["error"] {
            throw LoginError.denied(callback["error_description"] ?? error)
        }
        guard let code = callback["code"], !code.isEmpty else {
            throw LoginError.denied("回调里没有授权码")
        }
        guard callback["state"] == state else {
            throw LoginError.denied("state 校验失败，请重试")
        }

        let tokens = try await exchange(
            tokenEndpoint: metadata.tokenEndpoint,
            body: [
                "grant_type": "authorization_code",
                "client_id": clientId,
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": redirectUri,
            ]
        )

        let credential = CredentialStore.StoredCredential(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: Date().addingTimeInterval(tokens.expiresIn ?? 3600),
            scope: tokens.scope ?? Self.requestedScopes,
            clientId: clientId,
            tokenEndpoint: metadata.tokenEndpoint,
            issuer: metadata.issuer,
            account: try? await fetchAccount(tokenEndpoint: metadata.tokenEndpoint, accessToken: tokens.accessToken),
            backend: .keychain
        )
        let backend = credentials.save(credential, for: origin)
        var stored = credential
        stored.backend = backend
        return stored
    }

    /// 用刷新令牌换新的访问令牌；服务端会轮换刷新令牌。
    func refresh(_ credential: CredentialStore.StoredCredential, origin: String) async throws -> CredentialStore.StoredCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw LoginError.exchange("没有可用的刷新令牌，请重新登录")
        }
        let tokens = try await exchange(
            tokenEndpoint: credential.tokenEndpoint,
            body: [
                "grant_type": "refresh_token",
                "client_id": credential.clientId,
                "refresh_token": refreshToken,
            ]
        )
        var next = credential
        next.accessToken = tokens.accessToken
        next.refreshToken = tokens.refreshToken ?? refreshToken
        next.expiresAt = Date().addingTimeInterval(tokens.expiresIn ?? 3600)
        next.scope = tokens.scope ?? credential.scope
        let backend = credentials.save(next, for: origin)
        next.backend = backend
        return next
    }

    // MARK: - 协议细节

    func discover(baseURL: URL) async throws -> ServerMetadata {
        let origin = Self.origin(of: baseURL)
        var issuer = origin

        // RFC 9728：先看资源元信息，拿到授权服务器地址
        if let resourceURL = URL(string: "\(origin)/.well-known/oauth-protected-resource"),
           let resource: ResourceMetadata = try? await get(resourceURL),
           let first = resource.authorizationServers.first {
            issuer = first
        }

        guard let metadataURL = URL(string: "\(issuer)/.well-known/oauth-authorization-server") else {
            throw LoginError.discovery("地址无效")
        }
        do {
            return try await get(metadataURL)
        } catch {
            throw LoginError.discovery("\(issuer) 没有提供授权服务器元信息（OAuth 未启用？）")
        }
    }

    private func clientIdentifier(metadata: ServerMetadata, origin: String) async throws -> String {
        if let cached = credentials.load(for: origin)?.clientId, !cached.isEmpty {
            return cached
        }
        if let stored = UserDefaults.standard.string(forKey: "threadpocket.oauthClient.\(origin)"), !stored.isEmpty {
            return stored
        }
        guard let endpoint = metadata.registrationEndpoint, let url = URL(string: endpoint) else {
            throw LoginError.registration("服务端没有提供注册端点，且本机还没有注册记录")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Thread Pocket for macOS",
            "redirect_uris": [Self.registeredRedirect],
            "scope": Self.requestedScopes,
            "token_endpoint_auth_method": "none",
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw LoginError.registration("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(text.prefix(200))")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let registration = try decoder.decode(RegistrationResponse.self, from: data)
        UserDefaults.standard.set(registration.clientId, forKey: "threadpocket.oauthClient.\(origin)")
        return registration.clientId
    }

    private func exchange(tokenEndpoint: String, body: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: tokenEndpoint) else {
            throw LoginError.exchange("令牌端点地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            body.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").utf8
        )
        let (data, response) = try await session.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let http = response as? HTTPURLResponse else {
            throw LoginError.exchange("没有收到有效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? decoder.decode(OAuthErrorEnvelope.self, from: data) {
                throw LoginError.exchange(envelope.errorDescription ?? envelope.error)
            }
            throw LoginError.exchange("HTTP \(http.statusCode)")
        }
        return try decoder.decode(TokenResponse.self, from: data)
    }

    private func fetchAccount(tokenEndpoint: String, accessToken: String) async throws -> String? {
        guard let tokenURL = URL(string: tokenEndpoint),
              let originURL = URL(string: Self.origin(of: tokenURL)) else { return nil }
        var request = URLRequest(url: originURL.appendingPathComponent("auth/whoami"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        struct WhoAmI: Decodable { var email: String? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(WhoAmI.self, from: data))?.email
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LoginError.discovery("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - 工具

    static func origin(of url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme ?? "http"
        components.host = url.host
        components.port = url.port
        return components.string ?? url.absoluteString
    }

    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

struct OAuthErrorEnvelope: Decodable {
    var error: String
    var errorDescription: String?
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
