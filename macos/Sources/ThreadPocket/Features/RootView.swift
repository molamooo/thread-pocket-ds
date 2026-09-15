import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var overlay: OverlayCenter
    @EnvironmentObject private var settings: AppSettings

    @State private var searchAnchor: CGRect = .zero
    @State private var showSettings = false
    @State private var showOnboarding = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            background

            VStack(spacing: 0) {
                TopBar(searchAnchor: $searchAnchor)
                    .zIndex(2)

                if case .offline(let reason) = store.connection {
                    OfflineBanner(reason: reason)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                HStack(spacing: 0) {
                    SidebarPane()
                        .frame(width: 320)
                    Divider().overlay(PocketTheme.stroke)
                    DetailPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                StatusBar()
            }

            if let results = store.searchResults, !store.searchText.isBlank {
                SearchResultsPanel(results: results, anchor: searchAnchor)
                    .zIndex(5)
            }

            if let state = overlay.contextMenu {
                ContextMenuLayer(state: state)
                    .environmentObject(overlay)
                    .zIndex(20)
            }

            if let confirm = overlay.confirmState {
                ConfirmLayer(state: confirm)
                    .environmentObject(overlay)
                    .zIndex(22)
            }

            if let panel = overlay.panel {
                PanelLayer(state: panel)
                    .environmentObject(overlay)
                    .zIndex(12)
            }

            if showSettings {
                PanelLayer(
                    state: PanelState(
                        content: AnyView(
                            SettingsPanel(onClose: { withAnimation(PocketMotion.panel) { showSettings = false } })
                                .environmentObject(store)
                                .environmentObject(settings)
                                .environmentObject(overlay)
                        )
                    ),
                    wrapInPanel: true,
                    dismissible: false
                )
                .environmentObject(overlay)
                .zIndex(13)
            }

            if showOnboarding {
                OnboardingCard(
                    onFinish: { withAnimation(PocketMotion.panel) { showOnboarding = false } },
                    onSkip: { withAnimation(PocketMotion.panel) { showOnboarding = false } }
                )
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(overlay)
                .zIndex(14)
            }

            ToastStack()
                .zIndex(30)
        }
        .animation(PocketMotion.gentle, value: store.connection)
        .task {
            await store.connect()
            if !settings.hasOnboarded { showOnboarding = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppEvent.newThread)) { _ in presentNewThread() }
        .onReceive(NotificationCenter.default.publisher(for: AppEvent.newItem)) { _ in presentNewItem() }
        .onReceive(NotificationCenter.default.publisher(for: AppEvent.focusSearch)) { _ in
            NotificationCenter.default.post(name: .pocketFocusSearchField, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppEvent.settings)) { _ in showSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: AppEvent.refresh)) { _ in
            Task { await store.connect() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppEvent.recordProgress)) { _ in
            NotificationCenter.default.post(name: .pocketFocusProgressField, object: nil)
        }
    }

    private var background: some View {
        ZStack {
            PocketTheme.canvas
            Circle()
                .fill(PocketTheme.accent.opacity(0.22))
                .frame(width: 620, height: 620)
                .blur(radius: 160)
                .offset(x: -380, y: -320)
            Circle()
                .fill(PocketTheme.mauve.opacity(0.14))
                .frame(width: 560, height: 560)
                .blur(radius: 170)
                .offset(x: 420, y: -260)
        }
        .ignoresSafeArea()
    }

    private func presentNewThread() {
        guard let domainId = store.selectedDomainID ?? store.domains.first?.id else {
            overlay.toast("请先建立一个 Domain", tone: .warning)
            return
        }
        overlay.presentPanel {
            NewThreadPanel(domainId: domainId, onClose: { overlay.dismissPanel() })
                .environmentObject(store)
                .environmentObject(overlay)
        }
    }

    private func presentNewItem() {
        guard let thread = store.selectedThread else {
            overlay.toast("先选择一条线索", tone: .warning)
            return
        }
        overlay.presentPanel {
            ItemEditorPanel(
                thread: thread,
                item: nil,
                onClose: { overlay.dismissPanel() }
            )
            .environmentObject(store)
            .environmentObject(overlay)
        }
    }
}

extension Notification.Name {
    static let pocketFocusSearchField = Notification.Name("threadpocket.focusSearchField")
    static let pocketFocusProgressField = Notification.Name("threadpocket.focusProgressField")
}

// MARK: - 顶部栏

struct TopBar: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var overlay: OverlayCenter
    @Binding var searchAnchor: CGRect

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [PocketTheme.accent, PocketTheme.mauve, PocketTheme.danger.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(PocketTheme.canvasBottom)
                    )
                    .shadow(color: PocketTheme.accent.opacity(0.4), radius: 10, y: 4)
                Text("Thread Pocket")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PocketTheme.textPrimary)
            }
            .padding(.leading, 74)

            Divider().frame(height: 20).overlay(PocketTheme.stroke)

            DomainChips()

            Spacer(minLength: 12)

            SearchField(anchor: $searchAnchor)

            ConnectionPill()

            PocketIconButton(symbol: "plus", help: "新建线索  ⌘N", size: 28) {
                NotificationCenter.default.post(name: AppEvent.newThread, object: nil)
            }
            PocketIconButton(symbol: "gearshape", help: "连接设置  ⌘,", size: 28) {
                NotificationCenter.default.post(name: AppEvent.settings, object: nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            ZStack {
                WindowDragArea()
                LinearGradient(
                    colors: [Color.white.opacity(0.05), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(PocketTheme.stroke).frame(height: 1)
        }
    }
}

struct DomainChips: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var overlay: OverlayCenter

    var body: some View {
        HStack(spacing: 6) {
            PocketChip(
                label: "全部",
                symbol: "circle.grid.2x2",
                tint: PocketTheme.accent,
                isActive: store.selectedDomainID == nil
            ) {
                withAnimation(PocketMotion.snappy) { store.selectedDomainID = nil }
                store.refreshOverviewDebounced()
            }

            ForEach(store.domains) { domain in
                PocketChip(
                    label: domain.name,
                    symbol: domain.symbol,
                    tint: PocketTheme.domainColor(domain.color),
                    isActive: store.selectedDomainID == domain.id
                ) {
                    withAnimation(PocketMotion.snappy) { store.selectedDomainID = domain.id }
                    store.refreshOverviewDebounced()
                }
                .pocketContextMenu {
                    VStack(alignment: .leading, spacing: 1) {
                        ContextMenuItem(label: "只看这个领域", symbol: "line.3.horizontal.decrease.circle") {
                            store.selectedDomainID = domain.id
                            store.refreshOverviewDebounced()
                        }
                        ContextMenuItem(label: "新建线索", symbol: "plus.circle") {
                            store.selectedDomainID = domain.id
                            NotificationCenter.default.post(name: AppEvent.newThread, object: nil)
                        }
                        ContextDivider()
                        ContextMenuItem(label: "调整颜色与名称", symbol: "paintpalette") {
                            presentDomainEditor(domain)
                        }
                        ContextMenuItem(label: "删除领域", symbol: "trash", isDestructive: true) {
                            overlay.confirm(
                                ConfirmState(
                                    title: "删除「\(domain.name)」？",
                                    message: "该领域下的线索与事项会一并删除，这个操作不可恢复。",
                                    primaryLabel: "删除",
                                    secondaryLabel: "取消",
                                    destructive: true,
                                    onPrimary: {
                                        overlay.dismissConfirm()
                                        Task { await deleteDomain(domain) }
                                    },
                                    onSecondary: { overlay.dismissConfirm() }
                                )
                            )
                        }
                    }
                }
            }

            PocketIconButton(symbol: "plus", help: "新建领域", size: 24) {
                presentDomainEditor(nil)
            }
        }
    }

    private func presentDomainEditor(_ domain: Domain?) {
        overlay.presentPanel {
            DomainEditorPanel(domain: domain, onClose: { overlay.dismissPanel() })
                .environmentObject(store)
                .environmentObject(overlay)
        }
    }

    private func deleteDomain(_ domain: Domain) async {
        guard let client = store.client else { return }
        do {
            let _: EmptyResponse = try await client.delete("/api/v1/domains/\(domain.id)")
            if store.selectedDomainID == domain.id { store.selectedDomainID = nil }
            await store.connect()
            overlay.toast("已删除「\(domain.name)」", tone: .success)
        } catch let error as APIError {
            overlay.toast("删除失败", tone: .failure, detail: error.errorDescription)
        } catch {
            overlay.toast("删除失败", tone: .failure)
        }
    }
}

struct ConnectionPill: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(tint.opacity(0.4), lineWidth: 3).scaleEffect(store.connection.isConnecting ? 2.2 : 1))
                .animation(
                    store.connection.isConnecting
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : PocketMotion.quick,
                    value: store.connection.isConnecting
                )
            Text(store.connection.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PocketTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(PocketTheme.surface))
        .overlay(Capsule().strokeBorder(PocketTheme.stroke, lineWidth: 1))
        .help(store.connection.detail ?? store.serverLabel)
    }

    private var tint: Color {
        switch store.connection {
        case .online: PocketTheme.success
        case .connecting: PocketTheme.warning
        case .offline: PocketTheme.danger
        case .idle: PocketTheme.textTertiary
        }
    }
}

struct SearchField: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Binding var anchor: CGRect
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isFocused ? PocketTheme.accent : PocketTheme.textTertiary)
            TextField("搜索线索与事项", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(PocketTheme.textPrimary)
                .focused($isFocused)
                .frame(width: 168)
                .onChange(of: store.searchText) { _, _ in store.scheduleSearch() }
            if !store.searchText.isEmpty {
                PocketIconButton(symbol: "xmark.circle.fill", help: "清除", size: 18) {
                    store.clearSearch()
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                Text("⌘K")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PocketTheme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(PocketTheme.surfaceStrong))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(isFocused ? PocketTheme.surfaceStrong : PocketTheme.surface)
        )
        .overlay(
            Capsule().strokeBorder(isFocused ? PocketTheme.accent.opacity(0.6) : PocketTheme.stroke, lineWidth: 1)
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: FramePreferenceKey.self, value: proxy.frame(in: .global))
            }
        )
        .onPreferenceChange(FramePreferenceKey.self) { value in
            if value != .zero { anchor = value }
        }
        .animation(PocketMotion.quick, value: isFocused)
        .onReceive(NotificationCenter.default.publisher(for: .pocketFocusSearchField)) { _ in
            isFocused = true
        }
    }
}

// MARK: - 状态栏

struct StatusBar: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 14) {
            Label("⌘N 新建线索", systemImage: "command")
            Label("⌘K 搜索", systemImage: "magnifyingglass")
            Label("⌘⏎ 记录进展", systemImage: "square.and.pencil")
            Spacer()
            if store.inFlight > 0 {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("同步中")
                }
                .transition(.opacity)
            }
            Text("\(store.threads.filter { !$0.isTrashed }.count) 条线索 · \(openItemCount) 项未结束")
            Text(store.serverLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(PocketTheme.textTertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .top) {
            Rectangle().fill(PocketTheme.stroke).frame(height: 1)
        }
    }

    private var openItemCount: Int {
        store.items.values.flatMap { $0 }.filter { $0.isOpen }.count
    }
}

struct OfflineBanner: View {
    @EnvironmentObject private var store: WorkspaceStore
    var reason: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(PocketTheme.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("未连接到后端")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PocketTheme.textPrimary)
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(PocketTheme.textSecondary)
                    .lineLimit(1)
            }
            PocketButton(label: "重试", symbol: "arrow.clockwise", kind: .secondary) {
                Task { await store.connect(showToast: true) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassPanel(radius: 14, fill: PocketTheme.warning.opacity(0.1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
    }
}

// MARK: - Toast

struct ToastStack: View {
    @EnvironmentObject private var overlay: OverlayCenter

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            ForEach(overlay.toasts) { toast in
                HStack(spacing: 9) {
                    Image(systemName: toast.tone.symbol)
                        .foregroundStyle(toast.tone.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(toast.message)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(PocketTheme.textPrimary)
                        if let detail = toast.detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(PocketTheme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    if let actionLabel = toast.actionLabel, let action = toast.action {
                        PocketButton(label: actionLabel, kind: .secondary, action: action)
                    }
                    PocketIconButton(symbol: "xmark", help: "关闭", size: 20) {
                        overlay.dismiss(toast)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassPanel(radius: 13, fill: Color.black.opacity(0.4))
                .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 20)
        .allowsHitTesting(true)
        .animation(PocketMotion.snappy, value: overlay.toasts.count)
    }
}
