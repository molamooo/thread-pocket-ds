import SwiftUI

struct SectionHeader: View {
    var title: String
    var symbol: String
    var count: Int?
    var tint: Color = PocketTheme.textSecondary
    var actionLabel: String = "添加"
    var onAction: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(PocketTheme.textSecondary)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(PocketTheme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(PocketTheme.surfaceStrong))
            }
            Spacer()
            if let onAction {
                Button(action: onAction) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(actionLabel)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(isHovering ? PocketTheme.textPrimary : PocketTheme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isHovering ? PocketTheme.surfaceStrong : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in withAnimation(PocketMotion.quick) { isHovering = hovering } }
            }
        }
        .padding(.horizontal, 2)
    }
}

/// 事项行：类型决定它的完成方式与可用的动作。
struct ItemRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var overlay: OverlayCenter

    var item: Item
    var thread: Thread
    var compact: Bool = false
    var showThreadLabel: Bool = false
    /// 参与拖动排序时的上下文；为 nil 表示这一行不参与排序。
    var dragScope: WorkspaceStore.DragScope?
    var dragOrder: [String] = []

    @State private var isHovering = false
    @State private var isBusy = false

    private var isClosed: Bool { !item.isOpen }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leading

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: compact ? 12.5 : 13, weight: .medium))
                        .foregroundStyle(isClosed ? PocketTheme.textTertiary : PocketTheme.textPrimary)
                        .strikethrough(isClosed && item.kind != .wait, color: PocketTheme.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if item.blocked {
                        PocketTag(label: "受阻", symbol: "exclamationmark.triangle.fill", tint: PocketTheme.warning)
                    }
                    if item.kind == .direction {
                        PocketTag(label: "探索", symbol: "sparkle", tint: PocketTheme.mauve)
                    }
                    Spacer(minLength: 4)
                    if isHovering {
                        hoverActions
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }

                if let detail = item.detail, !detail.isBlank, !compact {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PocketTheme.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    timeBadge
                    if showThreadLabel, let threadName = store.thread(item.threadId)?.title {
                        PocketTag(label: threadName, symbol: "text.alignleft", tint: PocketTheme.textTertiary)
                    }
                    if isClosed {
                        PocketTag(label: item.status.label, symbol: "checkmark", tint: PocketTheme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: PocketTheme.rowRadius, style: .continuous)
                .fill(isHovering ? PocketTheme.surfaceHover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: PocketTheme.rowRadius, style: .continuous))
        .onHover { hovering in
            withAnimation(PocketMotion.quick) { isHovering = hovering }
        }
        .animation(PocketMotion.quick, value: isClosed)
        .pocketContextMenu { menuContent }
        .reorderable(
            id: item.id,
            scope: dragScope ?? .items(threadId: item.threadId),
            order: dragOrder,
            isEnabled: dragScope != nil
        )
    }

    @ViewBuilder
    private var leading: some View {
        switch item.kind {
        case .task, .event, .wait:
            PocketCheck(
                isOn: isClosed,
                isBusy: isBusy,
                tint: item.kind == .wait ? PocketTheme.warning : PocketTheme.success
            ) {
                run { await store.toggle(item) }
            }
            .padding(.top, 1)
        case .direction:
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(PocketTheme.mauve)
                .frame(width: 20, height: 20)
                .background(Circle().fill(PocketTheme.mauve.opacity(0.14)))
                .padding(.top, 1)
        }
    }

    @ViewBuilder
    private var timeBadge: some View {
        if let badge = item.timeBadge() {
            let tint: Color = {
                switch badge.tone {
                case .overdue: PocketTheme.danger
                case .today: PocketTheme.accent
                case .reschedule: PocketTheme.warning
                case .neutral: PocketTheme.textSecondary
                case .muted: PocketTheme.textTertiary
                }
            }()
            if item.kind == .task {
                PocketMenuButton {
                    PocketTag(label: badge.text, symbol: badgeSymbol(badge.tone), tint: tint)
                } menu: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("计划日")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(PocketTheme.textTertiary)
                            .padding(.horizontal, 9)
                            .padding(.top, 4)
                        quickDateItems(target: "plan_date", current: item.planDate)
                        ContextDivider()
                        Text("截止日")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(PocketTheme.textTertiary)
                            .padding(.horizontal, 9)
                            .padding(.top, 4)
                        quickDateItems(target: "due_date", current: item.dueDate)
                    }
                }
            } else {
                PocketTag(label: badge.text, symbol: badgeSymbol(badge.tone), tint: tint)
            }
        }
    }

    private func badgeSymbol(_ tone: TimeTone) -> String {
        switch tone {
        case .overdue: "exclamationmark.circle"
        case .today: "sun.max"
        case .reschedule: "arrow.triangle.2.circlepath"
        case .neutral: "calendar"
        case .muted: "minus"
        }
    }

    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 4) {
            if item.kind == .task {
                PocketMenuButton(alignLeading: false) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(PocketTheme.textSecondary)
                        .frame(width: 20, height: 18)
                        .background(RoundedRectangle(cornerRadius: 6).fill(PocketTheme.surfaceStrong))
                } menu: {
                    CalendarPanel(selected: item.planDate ?? item.dueDate) { picked in
                        let body: [String: Any] = item.planDate != nil || item.dueDate == nil
                            ? ["plan_date": picked ?? NSNull()]
                            : ["due_date": picked ?? NSNull()]
                        Task { await store.updateItem(item, patch: body, message: "已改期") }
                    }
                }
            }
            PocketMenuButton(alignLeading: false) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(PocketTheme.textSecondary)
                    .frame(width: 20, height: 18)
                    .background(RoundedRectangle(cornerRadius: 6).fill(PocketTheme.surfaceStrong))
            } menu: {
                menuContent
            }
        }
    }

    @ViewBuilder
    private func quickDateItems(target: String, current: String?) -> some View {
        let options: [(String, String)] = [
            ("今天", DayKey.today),
            ("明天", DayKey.add(days: 1)),
            ("本周末", DayKey.add(days: 6)),
        ]
        ForEach(options, id: \.1) { label, key in
            ContextMenuItem(label: label, symbol: "calendar", isAccent: current == key) {
                Task { await store.updateItem(item, patch: [target: key], message: "已改到\(label)") }
            }
        }
        if current != nil {
            ContextMenuItem(label: "清除日期", symbol: "xmark.circle") {
                Task { await store.updateItem(item, patch: [target: NSNull()], message: "已清除日期") }
            }
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            // 第一行：横排的快捷时间
            if let field = quickTimeField {
                ContextQuickTimes(current: quickTimeKey, clearLabel: "清空") { key in
                    Task {
                        await store.updateItem(
                            item,
                            patch: quickTimePatch(key),
                            message: key == nil ? "已清除\(field.label)" : "已改到\(DayKey.humanize(key ?? ""))"
                        )
                    }
                }
                ContextDivider()
            }

            switch item.kind {
            case .task, .event:
                ContextMenuItem(
                    label: isClosed ? "重新打开" : "标记完成",
                    symbol: isClosed ? "arrow.uturn.backward" : "checkmark.circle",
                    shortcut: "⌘↩"
                ) {
                    run { await store.toggle(item) }
                }
                ContextMenuItem(
                    label: item.blocked ? "取消受阻标记" : "标记为受阻",
                    symbol: "exclamationmark.triangle"
                ) {
                    Task { await store.updateItem(item, patch: ["blocked": !item.blocked], message: item.blocked ? "已取消受阻" : "已标记受阻") }
                }
            case .wait:
                ContextMenuItem(label: item.isOpen ? "解除等待" : "重新打开", symbol: "checkmark.circle", isAccent: item.isOpen) {
                    run { await store.toggle(item) }
                }
                ContextMenuItem(label: "转换为待办", symbol: "arrow.right.circle") {
                    Task {
                        await store.createItem(threadId: item.threadId, kind: .task, title: item.title, detail: item.detail)
                        await store.updateItem(item, patch: ["status": "cancelled"], toast: false)
                    }
                }
            case .direction:
                ContextMenuItem(label: "转为待办", symbol: "arrow.right.circle", isAccent: true) {
                    Task { await store.convertDirection(item) }
                }
                ContextMenuItem(label: "放弃这个方向", symbol: "hand.thumbsdown") {
                    Task { await store.abandonDirection(item) }
                }
            }

            ContextDivider()
            ContextMenuItem(label: "编辑…", symbol: "square.and.pencil") {
                overlay.presentPanel {
                    ItemEditorPanel(thread: thread, item: item, onClose: { overlay.dismissPanel() })
                        .environmentObject(store)
                        .environmentObject(overlay)
                }
            }
            moveRow
            ContextDivider()
            ContextMenuItem(label: "复制标题", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.title, forType: .string)
                overlay.toast("已复制", tone: .success)
            }
            if item.kind == .task || item.kind == .event {
                ContextMenuItem(label: "取消这件事", symbol: "xmark.circle") {
                    Task { await store.cancel(item) }
                }
            }
            ContextMenuItem(label: "删除", symbol: "trash", isDestructive: true) {
                Task { await store.deleteItem(item) }
            }
        }
    }

    /// 分级移动：一级「移动到」→ 二级 Domain → 三级 Thread。
    @ViewBuilder
    private var moveRow: some View {
        ContextMenuSubmenuRow(label: "移动到", symbol: "arrow.turn.up.right") {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(store.domains) { domain in
                    let targets = moveTargets(in: domain)
                    ContextMenuSubmenuRow(
                        label: domain.name,
                        symbol: domain.symbol,
                        detail: targets.isEmpty ? "没有其他线索" : "\(targets.count) 条",
                        isDisabled: targets.isEmpty
                    ) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(targets) { target in
                                ContextMenuItem(
                                    label: target.title,
                                    symbol: target.isInbox ? "tray" : "text.alignleft"
                                ) {
                                    Task { await store.moveItem(item, toThread: target.id) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func moveTargets(in domain: Domain) -> [Thread] {
        store.threads
            .filter { $0.domainId == domain.id && $0.id != item.threadId && !$0.isTrashed && $0.archivedAt == nil }
            .sorted { lhs, rhs in
                if lhs.isInbox != rhs.isInbox { return !lhs.isInbox }
                if lhs.position != rhs.position { return lhs.position < rhs.position }
                return lhs.createdAt < rhs.createdAt
            }
    }

    // MARK: - 快捷时间

    /// 快捷时间作用在哪个日期字段：待办用计划日（没有计划日才算截止日）、日程用开始时间、等待用跟进日。
    private var quickTimeField: (field: String, label: String)? {
        switch item.kind {
        case .task:
            return item.planDate != nil || item.dueDate == nil ? ("plan_date", "计划日") : ("due_date", "截止日")
        case .event:
            return ("start_at", "开始时间")
        case .wait:
            return ("follow_up_date", "跟进日")
        case .direction:
            return nil
        }
    }

    private var quickTimeKey: String? {
        switch item.kind {
        case .task:
            return item.planDate ?? item.dueDate
        case .event:
            return item.startAt.map { DayKey.fromIso($0) } ?? item.planDate
        case .wait:
            return item.followUpDate
        case .direction:
            return nil
        }
    }

    /// 日程改期保留原来的时刻与跨度，只挪日期；其余类型直接写日期字段。
    private func quickTimePatch(_ key: String?) -> [String: Any] {
        if item.kind == .event {
            guard let key else { return ["start_at": NSNull(), "end_at": NSNull()] }
            let (hour, minute) = DayKey.hourMinute(fromIso: item.startAt)
            let hadTime = item.startAt != nil
            var patch: [String: Any] = [
                "start_at": DayKey.iso(key: key, hour: hadTime ? hour : 9, minute: hadTime ? minute : 0),
            ]
            if let end = item.endAt, let start = item.startAt {
                let span = DayKey.dayOffset(DayKey.fromIso(end), from: DayKey.fromIso(start)) ?? 0
                let (endHour, endMinute) = DayKey.hourMinute(fromIso: end)
                patch["end_at"] = DayKey.iso(key: DayKey.add(days: span, to: key), hour: endHour, minute: endMinute)
            }
            return patch
        }
        guard let field = quickTimeField?.field else { return [:] }
        if let key { return [field: key] }
        return [field: NSNull()]
    }

    private func run(_ operation: @escaping () async -> Void) {
        isBusy = true
        Task {
            await operation()
            isBusy = false
        }
    }
}
