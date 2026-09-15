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
                    label("访问令牌（可选）", hint: "后端设置了 THREADPOCKET_API_KEY 时才需要填写")
                    PocketField(placeholder: "留空表示不需要鉴权", text: $token, symbol: "key")
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
                    PocketButton(label: "连接并开始", symbol: "arrow.right", kind: .primary, isEnabled: state != .testing) {
                        Task { await connect() }
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
            settings.hasOnboarded = true
            overlay.toast("已连接到 \(store.serverLabel)", tone: .success)
            onFinish()
        } else {
            state = .failure(store.connection.label)
        }
    }
}
