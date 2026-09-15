import Foundation
import Network

/// 桌面端的 OAuth 回调服务器：监听 127.0.0.1 的随机端口，接收一次浏览器跳转。
/// 这是 RFC 8252 推荐的原生应用做法，不需要自定义 URL scheme。
final class LoopbackCallbackServer {
    enum CallbackError: LocalizedError {
        case startFailed(String)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .startFailed(let message): "无法启动本地回调端口：\(message)"
            case .timedOut: "等待浏览器授权超时，请重试。"
            case .cancelled: "登录已取消。"
            }
        }
    }

    private let queue = DispatchQueue(label: "com.threadpocket.oauth.callback")
    private var listener: NWListener?
    private var pending: CheckedContinuation<[String: String], Error>?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var didResolve = false

    private(set) var port: UInt16 = 0

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener = listener

        let value: UInt16 = try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                self?.resolveStart(state)
            }
            listener.start(queue: queue)
        }
        self.port = value
        return value
    }

    /// 只在 queue 上被回调，保证 continuation 只 resume 一次。
    private func resolveStart(_ state: NWListener.State) {
        guard let continuation = startContinuation else { return }
        switch state {
        case .ready:
            startContinuation = nil
            continuation.resume(returning: listener?.port?.rawValue ?? 0)
        case .failed(let error):
            startContinuation = nil
            continuation.resume(throwing: CallbackError.startFailed(error.localizedDescription))
        default:
            break
        }
    }

    /// 等待浏览器回调，返回查询参数。
    func waitForCallback(timeout: TimeInterval = 300) async throws -> [String: String] {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(CallbackError.timedOut))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            if didResolve {
                continuation.resume(throwing: CallbackError.cancelled)
                return
            }
            pending = continuation
        }
    }

    func stop() {
        finish(.failure(CallbackError.cancelled))
        listener?.cancel()
        listener = nil
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !didResolve else { return }
        didResolve = true
        if let pending {
            self.pending = nil
            pending.resume(with: result)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let query = Self.parseQuery(fromRequestLine: request)
            let success = query["code"] != nil || query["error"] != nil
            self.respond(connection, ok: success, query: query)
            if success {
                self.finish(.success(query))
                self.listener?.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, ok: Bool, query: [String: String]) {
        let title = ok ? "已授权，可以关闭这个窗口" : "没有收到授权码"
        let detail = query["error_description"] ?? query["error"] ?? ""
        let html = """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Thread Pocket</title><style>
        :root{color-scheme:dark}
        body{margin:0;min-height:100vh;display:grid;place-items:center;
        background:radial-gradient(900px 500px at 15% -10%,rgba(124,140,255,.25),transparent 60%),#090b12;
        color:#eef1f8;font:15px/1.6 -apple-system,"PingFang SC",system-ui,sans-serif}
        .card{background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.1);border-radius:20px;
        padding:28px 30px;max-width:420px;text-align:center;backdrop-filter:blur(20px)}
        .mark{width:44px;height:44px;border-radius:13px;margin:0 auto 14px;display:grid;place-items:center;font-size:21px;
        background:linear-gradient(150deg,#7c8cff,#b98cff 60%,#ff8abe)}
        p{color:#8d94a8;font-size:13px;margin:6px 0 0}
        </style></head><body><div class="card"><div class="mark">🧵</div>
        <strong>\(title)</strong><p>\(detail)</p></div></body></html>
        """
        let body = Data(html.utf8)
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r
        """
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// 从 "GET /callback?code=... HTTP/1.1" 里取出查询参数。
    private static func parseQuery(fromRequestLine request: String) -> [String: String] {
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else { return [:] }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return [:] }
        guard let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }
}
