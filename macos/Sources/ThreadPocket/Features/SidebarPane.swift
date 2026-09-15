import SwiftUI

struct SidebarPane: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var overlay: OverlayCenter

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(PocketTheme.stroke)
            switch store.mode {
            case .threads:
                ThreadListView()
            case .overview:
                OverviewNavList()
            }
            Divider().overlay(PocketTheme.stroke)
            footer
        }
        .background(Color.black.opacity(0.16))
    }

    private var header: some View {
        VStack(spacing: 9) {
            PocketSegmented(
                options: [
                    PocketSegmentedOption(WorkspaceStore.Mode.threads, label: "线索", symbol: "text.alignleft"),
                    PocketSegmentedOption(WorkspaceStore.Mode.overview, label: "总览", symbol: "square.grid.2x2"),
                ],
                selection: $store.mode
            )

            if store.mode == .threads {
                HStack(spacing: 8) {
                    PocketSegmented(
                        options: WorkspaceStore.Scope.allCases.map { scope in
                            PocketSegmentedOption(scope, label: scope.label)
                        },
                        selection: $store.scope,
                        compact: true
                    )
                    .onChange(of: store.scope) { _, _ in store.refreshOverviewDebounced() }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 6) {
                    Text("总览范围")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PocketTheme.textTertiary)
                    Spacer()
                    PocketMenuButton {
                        PocketChip(
                            label: store.selectedDomainID == nil ? "全部领域" : (store.domain(store.selectedDomainID)?.name ?? "全部领域"),
                            symbol: "line.3.horizontal.decrease.circle",
                            isActive: store.selectedDomainID != nil
                        )
                    } menu: {
                        VStack(alignment: .leading, spacing: 1) {
                            ContextMenuItem(label: "全部领域", symbol: "circle.grid.2x2") {
                                store.selectedDomainID = nil
                                store.refreshOverviewDebounced()
                            }
                            ContextDivider()
                            ForEach(store.domains) { domain in
                                ContextMenuItem(
                                    label: domain.name,
                                    symbol: domain.symbol,
                                    isAccent: store.selectedDomainID == domain.id
                                ) {
                                    store.selectedDomainID = domain.id
                                    store.refreshOverviewDebounced()
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if store.mode == .threads {
                PocketMenuButton {
                    PocketChip(
                        label: store.listFilter.label,
                        symbol: filterSymbol,
                        isActive: store.listFilter != .active
                    )
                } menu: {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(WorkspaceStore.ListFilter.allCases, id: \.self) { filter in
                            ContextMenuItem(
                                label: filter.label,
                                symbol: filterSymbol(filter),
                                isAccent: store.listFilter == filter
                            ) {
                                withAnimation(PocketMotion.snappy) { store.listFilter = filter }
                            }
                        }
                    }
                }
            }
            Spacer()
            Text("\(store.visibleThreads.count) 条")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(PocketTheme.textTertiary)
            PocketButton(label: "新建线索", symbol: "plus", kind: .ghost) {
                NotificationCenter.default.post(name: AppEvent.newThread, object: nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterSymbol: String {
        filterSymbol(store.listFilter)
    }

    private func filterSymbol(_ filter: WorkspaceStore.ListFilter) -> String {
        switch filter {
        case .active: "tray.full"
        case .archived: "archivebox"
        case .trashed: "trash"
        }
    }
}

// MARK: - 线索列表

struct ThreadListView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if store.visibleThreads.isEmpty {
                    EmptyHint(
                        symbol: "tray",
                        title: "这里还没有线索",
                        message: store.listFilter == .active ? "用 ⌘N 建立一条，把持续推进的事放进来。" : "换个筛选条件看看。"
                    )
                    .padding(.top, 36)
                }
                ForEach(store.visibleThreads) { thread in
                    ThreadRow(thread: thread)
                        .reorderable(
                            id: thread.id,
                            scope: .threads,
                            order: store.draggableThreadOrder(for: thread),
                            isEnabled: !thread.isInbox
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        .reorderContainer()
    }
}

struct ThreadRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var overlay: OverlayCenter
    var thread: Thread

    @State private var isHovering = false
    @State private var isCompleting = false

    private var isSelected: Bool { store.selectedThreadID == thread.id }

    var body: some View {
        Button {
            store.requestSelection(thread.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(PocketTheme.domainColor(store.domain(thread.domainId)?.color ?? "slate"))
                        .frame(width: 7, height: 7)
                    Text(thread.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PocketTheme.textPrimary)
                        .lineLimit(1)
                    if thread.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(PocketTheme.accent)
                            .help("已置顶")
                    }
                    if thread.isInbox {
                        Image(systemName: "tray")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(PocketTheme.textTertiary)
                    }
                    Spacer(minLength: 4)
                    if thread.status != .active {
                        Image(systemName: thread.status.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(statusTint)
                    }
                    if isHovering {
                        PocketMenuButton(alignLeading: false) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PocketTheme.textSecondary)
                                .frame(width: 20, height: 18)
                                .background(RoundedRectangle(cornerRadius: 6).fill(PocketTheme.surfaceStrong))
                        } menu: {
                            menuContent
                        }
                        .transition(.opacity)
                    }
                }

                if !thread.summary.isBlank {
                    Text(thread.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PocketTheme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    let counts = thread.countsOrEmpty
                    if counts.openTasks > 0 {
                        badge("\(counts.openTasks) 待办", tint: PocketTheme.accent)
                    }
                    if counts.openEvents > 0 {
                        badge("\(counts.openEvents) 日程", tint: PocketTheme.mauve)
                    }
                    if counts.openWaits > 0 {
                        badge("\(counts.openWaits) 等待", tint: PocketTheme.warning)
                    }
                    if counts.openDirections > 0 {
                        badge("\(counts.openDirections) 方向", tint: PocketTheme.textTertiary)
                    }
                    if counts.openItems == 0 && !thread.isInbox {
                        badge("已清空", tint: PocketTheme.success)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 14)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PocketTheme.rowRadius, style: .continuous)
                    .fill(isSelected ? PocketTheme.accentSoft : (isHovering ? PocketTheme.surfaceHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PocketTheme.rowRadius, style: .continuous)
                    .strokeBorder(isSelected ? PocketTheme.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: PocketTheme.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(PocketMotion.quick) { isHovering = hovering }
        }
        .pocketContextMenu {
            menuContent
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            ContextMenuItem(label: "打开", symbol: "arrow.up.right.square", isAccent: true) {
                store.requestSelection(thread.id)
                store.mode = .threads
            }
            ContextMenuItem(label: "新建事项", symbol: "plus.circle") {
                store.requestSelection(thread.id)
                store.mode = .threads
                overlay.presentPanel {
                    ItemEditorPanel(thread: thread, item: nil, onClose: { overlay.dismissPanel() })
                        .environmentObject(store)
                        .environmentObject(overlay)
                }
            }
            if !thread.isInbox {
                ContextMenuItem(
                    label: thread.isPinned ? "取消置顶" : "置顶",
                    symbol: thread.isPinned ? "pin.slash" : "pin"
                ) {
                    Task { await store.togglePin(thread) }
                }
            }
            ContextDivider()
            Text("状态")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(PocketTheme.textTertiary)
                .padding(.horizontal, 9)
                .padding(.top, 4)
            ForEach(ThreadStatus.allCases, id: \.self) { status in
                ContextMenuItem(
                    label: status.label,
                    symbol: status.symbol,
                    isAccent: thread.status == status
                ) {
                    Task { await store.updateThread(threadId: thread.id, status: status, message: "状态已更新为\(status.label)") }
                }
            }
            ContextDivider()
            Text("归属领域")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(PocketTheme.textTertiary)
                .padding(.horizontal, 9)
                .padding(.top, 4)
            ForEach(store.domains) { domain in
                ContextMenuItem(
                    label: domain.name,
                    symbol: domain.symbol,
                    isAccent: thread.domainId == domain.id
                ) {
                    Task { await store.updateThread(threadId: thread.id, domainId: domain.id, message: "已移动到「\(domain.name)」") }
                }
            }
            ContextDivider()
            ContextMenuItem(label: "复制标题", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(thread.title, forType: .string)
                overlay.toast("已复制标题", tone: .success)
            }
            ContextMenuItem(
                label: thread.archivedAt == nil ? "归档" : "取消归档",
                symbol: "archivebox"
            ) {
                Task {
                    await store.updateThread(
                        threadId: thread.id,
                        archived: thread.archivedAt == nil,
                        message: thread.archivedAt == nil ? "已归档" : "已取消归档"
                    )
                }
            }
            ContextMenuItem(
                label: thread.isTrashed ? "恢复" : "移入回收站",
                symbol: thread.isTrashed ? "arrow.uturn.backward" : "trash",
                isDestructive: !thread.isTrashed
            ) {
                Task {
                    if thread.isTrashed {
                        await store.updateThread(threadId: thread.id, trashed: false, message: "已恢复")
                    } else {
                        await store.deleteThread(threadId: thread.id)
                    }
                }
            }
            if thread.isTrashed {
                ContextMenuItem(label: "彻底删除", symbol: "xmark.bin", isDestructive: true) {
                    overlay.confirm(
                        ConfirmState(
                            title: "彻底删除「\(thread.title)」？",
                            message: "线索内的事项、笔记与日志都会消失，且无法恢复。",
                            primaryLabel: "彻底删除",
                            secondaryLabel: "取消",
                            destructive: true,
                            onPrimary: {
                                overlay.dismissConfirm()
                                Task { await store.deleteThread(threadId: thread.id, hard: true) }
                            },
                            onSecondary: { overlay.dismissConfirm() }
                        )
                    )
                }
            }
        }
    }

    private var statusTint: Color {
        switch thread.status {
        case .active: PocketTheme.accent
        case .waiting: PocketTheme.warning
        case .paused: PocketTheme.textTertiary
        case .completed: PocketTheme.success
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.13)))
    }

}

struct EmptyHint: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(PocketTheme.textTertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PocketTheme.textSecondary)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(PocketTheme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity)
    }
}
