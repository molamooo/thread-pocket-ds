import Foundation

enum APIError: LocalizedError {
    case badURL(String)
    case transport(String)
    case server(status: Int, code: String, message: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let value):
            "服务器地址无效：\(value)"
        case .transport(let message):
            message
        case .server(_, _, let message):
            message
        case .decoding(let message):
            "返回数据无法解析：\(message)"
        }
    }

    var isConnectivityIssue: Bool {
        if case .transport = self { return true }
        if case .badURL = self { return true }
        return false
    }
}

enum QueryValue {
    case string(String)
    case int(Int)

    var encoded: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        }
    }
}

final class APIClient {
    var baseURL: URL
    var token: String?

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: configuration)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    static func normalize(urlString: String) -> URL? {
        let trimmed = urlString.trimmed
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    func get<T: Decodable>(_ path: String, query: [String: QueryValue] = [:]) async throws -> T {
        try await request(path, method: "GET", query: query, body: nil)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any] = [:]) async throws -> T {
        try await request(path, method: "POST", query: [:], body: body)
    }

    func patch<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        try await request(path, method: "PATCH", query: [:], body: body)
    }

    func put<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        try await request(path, method: "PUT", query: [:], body: body)
    }

    @discardableResult
    func delete<T: Decodable>(_ path: String, query: [String: QueryValue] = [:]) async throws -> T {
        try await request(path, method: "DELETE", query: query, body: nil)
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String,
        query: [String: QueryValue],
        body: [String: Any]?
    ) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false) else {
            throw APIError.badURL(baseURL.absoluteString)
        }
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value.encoded) }
        }
        guard let url = components.url else { throw APIError.badURL(baseURL.absoluteString) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token, !token.trimmed.isEmpty {
            request.setValue("Bearer \(token.trimmed)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(Self.friendlyTransport(error, url: url))
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("服务器没有返回有效响应")
        }

        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? decoder.decode(ServerErrorEnvelope.self, from: data) {
                throw APIError.server(status: http.statusCode, code: envelope.error.code, message: envelope.error.message)
            }
            throw APIError.server(status: http.statusCode, code: "http_\(http.statusCode)", message: "请求失败（HTTP \(http.statusCode)）")
        }

        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private static func friendlyTransport(_ error: Error, url: URL) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost:
            return "无法连接到 \(url.host ?? "服务器")，请确认后端已启动。"
        case NSURLErrorTimedOut:
            return "连接 \(url.host ?? "服务器") 超时。"
        case NSURLErrorNotConnectedToInternet:
            return "当前网络不可用。"
        default:
            return "连接失败：\(nsError.localizedDescription)"
        }
    }
}

struct EmptyResponse: Decodable {}

extension Dictionary where Key == String, Value == Any {
    /// 移除空值，避免把可选字段覆盖成 null。
    func compacted() -> [String: Any] {
        filter { _, value in !(value is NSNull) }
    }
}
