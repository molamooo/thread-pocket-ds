import SwiftUI

struct SettingsPanel: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var overlay: OverlayCenter

    var onClose: () -> Void

    @State private var url = ""
    @State private var token = ""
    @State private var autoRefresh = 0
    @State private var probeState: ProbeState = .idle

    enum ProbeState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PocketTheme.accent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(PocketTheme.accent.opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("连接设置")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PocketTheme.textPrimary)
                    Text("应用只依赖这个地址，后端可以独立部署与迭代")
                        .font(.system(size: 11))
                        .foregroundStyle(PocketTheme.textTertiary)
                }
                Spacer()
                PocketIconButton(symbol: "xmark", help: "关闭", size: 24, action: onClose)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(PocketTheme.stroke)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    label("后端地址", hint: "例如 http://127.0.0.1:8787 或 https://api.example.com")
                    PocketField(placeholder: "http://127.0.0.1:8787", text: $url, symbol: "link")
                    HStack(spacing: 8) {
                        PocketButton(label: "测试连接", symbol: "antenna.radiowaves.left.and.right", kind: .secondary) {
                            Task { await probe() }
                        }
                        if AppSettings.defaultServerURL != url.trimmed {
                            PocketButton(label: "恢复默认", kind: .ghost) {
                                url = AppSettings.defaultServerURL
                            }
                        }
                        probeBadge
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    label("账号", hint: "用浏览器登录后即可读写这个部署里的线索；令牌只保存在本机")
                    HStack(spacing: 8) {
                        accountBadge
                        Spacer()
                        if store.authState.isSignedIn {
                            PocketButton(label: "退出登录", symbol: "rectangle.portrait.and.arrow.right", kind: .ghost) {
                                store.signOut()
                            }
                        } else {
                            PocketButton(
                                label: store.isSigningIn ? "等待浏览器…" : "使用浏览器登录",
                                symbol: "safari",
                                kind: .primary,
                                isEnabled: !store.isSigningIn
                            ) {
                                Task { await store.signIn() }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    label("访问令牌（可选）", hint: "给脚本或自动化使用；后端设置了 THREADPOCKET_API_KEY 时填这里")
                    PocketField(placeholder: "留空表示用上面的登录状态", text: $token, symbol: "key")
                }

                VStack(alignment: .leading, spacing: 6) {
                    label("自动刷新", hint: "长时间开着时保持与后端一致")
                    PocketSegmented(
                        options: [
                            PocketSegmentedOption(0, label: "关闭"),
                            PocketSegmentedOption(30, label: "30 秒"),
                            PocketSegmentedOption(120, label: "2 分钟"),
                        ],
                        selection: $autoRefresh,
                        compact: true
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    label("其他", hint: nil)
                    VStack(alignment: .leading, spacing: 5) {
                        shortcutRow("⌘N", "新建线索")
                        shortcutRow("⇧⌘N", "新建事项")
                        shortcutRow("⌘K", "搜索")
                        shortcutRow("⌘⏎", "记录一条进展")
                        shortcutRow("⌘R", "重新加载")
                    }
                }
            }
            .padding(16)

            Divider().overlay(PocketTheme.stroke)

            HStack(spacing: 8) {
                Text(store.serverLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(PocketTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                PocketButton(label: "取消", kind: .ghost, action: onClose)
                PocketButton(label: "保存并重连", symbol: "arrow.clockwise", kind: .primary) {
                    settings.serverURL = url.trimmed
                    settings.token = token.trimmed
                    settings.autoRefreshSeconds = autoRefresh
                    onClose()
                    Task { await store.connect(showToast: true) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 520)
        .onAppear {
            url = settings.serverURL
            token = settings.token
            autoRefresh = settings.autoRefreshSeconds
        }
    }

    @ViewBuilder
    private var accountBadge: some View {
        switch store.authState {
        case .signedIn(let account, let backend):
            VStack(alignment: .leading, spacing: 2) {
                PocketTag(label: account ?? "已登录", symbol: "checkmark.seal.fill", tint: PocketTheme.success)
                Text(backend == .keychain ? "令牌存放在钥匙串" : "钥匙串不可用，令牌保存在本机 0600 文件")
                    .font(.system(size: 10))
                    .foregroundStyle(PocketTheme.textTertiary)
            }
        case .expired(let reason):
            VStack(alignment: .leading, spacing: 2) {
                PocketTag(label: "登录已失效", symbol: "exclamationmark.triangle.fill", tint: PocketTheme.warning)
                Text(reason).font(.system(size: 10)).foregroundStyle(PocketTheme.textTertiary)
            }
        case .signedOut:
            PocketTag(label: "未登录", symbol: "person.crop.circle", tint: PocketTheme.textTertiary)
        case .open:
            PocketTag(label: "该部署未启用鉴权", symbol: "lock.open", tint: PocketTheme.textSecondary)
        case .unknown:
            PocketTag(label: "未检测", symbol: "questionmark.circle", tint: PocketTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var probeBadge: some View {
        switch probeState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在连接…")
                    .font(.system(size: 11))
                    .foregroundStyle(PocketTheme.textSecondary)
            }
        case .success(let message):
            PocketTag(label: message, symbol: "checkmark.circle.fill", tint: PocketTheme.success)
        case .failure(let message):
            PocketTag(label: message, symbol: "exclamationmark.circle.fill", tint: PocketTheme.danger)
        }
    }

    private func label(_ text: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(PocketTheme.textSecondary)
            if let hint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(PocketTheme.textTertiary)
            }
        }
    }

    private func shortcutRow(_ key: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(PocketTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(PocketTheme.surfaceStrong))
            Text(action)
                .font(.system(size: 11.5))
                .foregroundStyle(PocketTheme.textTertiary)
        }
    }

    private func probe() async {
        guard let url = APIClient.normalize(urlString: url) else {
            probeState = .failure("地址无效")
            return
        }
        probeState = .testing
        let client = APIClient(baseURL: url, token: token.trimmed.isEmpty ? nil : token.trimmed)
        do {
            let health: HealthResponse = try await client.get("/health")
            let snapshot: Snapshot = try await client.get("/api/v1/snapshot")
            probeState = .success("连接正常 · \(snapshot.threads.count) 条线索")
            _ = health
        } catch let error as APIError {
            probeState = .failure(error.errorDescription ?? "连接失败")
        } catch {
            probeState = .failure("连接失败")
        }
    }
}

/// 首次启动的引导卡片：先连上后端，再开始使用。
struct OnboardingCard: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var overlay: OverlayCenter

    var onFinish: () -> Void
    var onSkip: () -> Void

    @State private var url = AppSettings.defaultServerURL
    @State private var token = ""
    @State private var state: ProbeState = .idle

    enum ProbeState: Equatable {
        case idle
        case testing
        /// 地址是通的，但这个部署要求登录：引导卡片直接给出登录入口，而不是把用户卡在这里
        case needsLogin
        case failure(String)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.35))
                .onTapGesture {}

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [PocketTheme.accent, PocketTheme.mauve, PocketTheme.danger.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)
                        .overlay(
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(PocketTheme.canvasBottom)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Thread Pocket")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(PocketTheme.textPrimary)
                        Text("让持续推进的事情，每一次回来都能接得上。")
                            .font(.system(size: 12))
                            .foregroundStyle(PocketTheme.textSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    step(number: 1, text: "在 server 目录执行 npm start 启动后端（默认 8787 端口）。")
                    step(number: 2, text: "填写后端地址并连接。Web 与移动端以后可以复用同一份部署。")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("后端地址")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PocketTheme.textSecondary)
                    PocketField(placeholder: AppSettings.defaultServerURL, text: $url, symbol: "link")
                    PocketField(placeholder: "访问令牌（可选）", text: $token, symbol: "key")
                }

                if case .failure(let message) = state {
                    PocketTag(label: message, symbol: "exclamationmark.circle.fill", tint: PocketTheme.danger)
                        .transition(.opacity)
                }

                if case .needsLogin = state {
                    VStack(alignment: .leading, spacing: 4) {
                        PocketTag(label: "这个部署需要登录", symbol: "person.badge.key.fill", tint: PocketTheme.warning)
                        Text("地址已经记下了。点「使用浏览器登录」完成授权，之后不用再登。")
                            .font(.system(size: 11))
                            .foregroundStyle(PocketTheme.textTertiary)
                    }
                    .transition(.opacity)
                }

                HStack(spacing: 8) {
                    PocketButton(label: "先看看演示界面", kind: .ghost, action: onSkip)
                    Spacer()
                    if case .testing = state {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("连接中…")
                                .font(.system(size: 11))
                                .foregroundStyle(PocketTheme.textSecondary)
                        }
                    }
                    if case .needsLogin = state {
                        PocketButton(
                            label: store.isSigningIn ? "等待浏览器…" : "使用浏览器登录",
                            symbol: "safari",
                            kind: .primary,
                            isEnabled: !store.isSigningIn
                        ) {
                            Task { await signIn() }
                        }
                    } else {
                        PocketButton(label: "连接并开始", symbol: "arrow.right", kind: .primary, isEnabled: state != .testing) {
                            Task { await connect() }
                        }
                    }
                }
            }
            .padding(22)
            .frame(width: 520)
            .glassPanel(radius: 20, fill: Color.black.opacity(0.42))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        }
        .onAppear {
            url = settings.serverURL
            token = settings.token
        }
    }

    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(PocketTheme.canvasBottom)
                .frame(width: 17, height: 17)
                .background(Circle().fill(PocketTheme.accent))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(PocketTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() async {
        guard APIClient.normalize(urlString: url) != nil else {
            state = .failure("地址无效")
            return
        }
        state = .testing
        settings.serverURL = url.trimmed
        settings.token = token.trimmed
        await store.connect()
        if store.connection.isOnline {
            finish()
            return
        }
        // 服务端要求登录时不要把用户卡在引导页：地址已经存下了，这里直接给出登录入口
        if store.authState == .signedOut || isExpired {
            state = .needsLogin
            return
        }
        state = .failure(store.connection.label)
    }

    private func signIn() async {
        await store.signIn()
        if store.connection.isOnline {
            finish()
        } else if case .expired(let reason) = store.authState {
            state = .failure(reason)
        }
    }

    private func finish() {
        settings.hasOnboarded = true
        overlay.toast("已连接到 \(store.serverLabel)", tone: .success)
        onFinish()
    }

    private var isExpired: Bool {
        if case .expired = store.authState { return true }
        return false
    }
}
