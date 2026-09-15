import SwiftUI

/// 新建 / 编辑事项的面板。类型决定需要填写的字段。
struct ItemEditorPanel: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var overlay: OverlayCenter

    var thread: Thread
    var item: Item?
    var initialKind: ItemKind = .task
    var onClose: () -> Void

    @State private var kind: ItemKind = .task
    @State private var title = ""
    @State private var detail = ""
    @State private var planDate: String?
    @State private var dueDate: String?
    @State private var followUpDate: String?
    @State private var eventDay: String?
    @State private var startHour = 9
    @State private var startMinute = 0
    @State private var durationMinutes = 60
    @State private var blocked = false
    @State private var blockerReason = ""
    @State private var isSaving = false
    @FocusState private var titleFocused: Bool

    private var isEditing: Bool { item != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(PocketTheme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    kindPicker
                    titleField
                    fieldsForKind
                    detailField
                }
                .padding(18)
            }
            .frame(maxHeight: 460)
            Divider().overlay(PocketTheme.stroke)
            footer
        }
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(isEditing ? "编辑\(kind.label)" : "新建\(kind.label)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PocketTheme.textPrimary)
                Text("在「\(thread.title)」中")
                    .font(.system(size: 11))
                    .foregroundStyle(PocketTheme.textTertiary)
            }
            Spacer()
            PocketIconButton(symbol: "xmark", help: "关闭", size: 24, action: onClose)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("类型", hint: "待办和日程进入今天与行动；方向与等待单独呈现")
            PocketSegmented(
                options: ItemKind.allCases.map { kind in
                    PocketSegmentedOption(kind, label: kind.shortLabel, symbol: kind.symbol)
                },
                selection: $kind
            )
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("标题", hint: "写得独立可懂，不必依赖上下文")
            PocketField(placeholder: "例如：核对报价中的增项", text: $title, symbol: "text.cursor")
                .focused($titleFocused)
        }
    }

    @ViewBuilder
    private var fieldsForKind: some View {
        switch kind {
        case .task:
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("时间", hint: "计划日是准备做的时间，截止日是最迟完成的时间")
                HStack(spacing: 8) {
                    PocketDateField(label: "计划", symbol: "calendar.badge.clock", value: planDate, tint: PocketTheme.accent) { picked in
                        planDate = picked
                    }
                    PocketDateField(label: "截止", symbol: "flag", value: dueDate, tint: PocketTheme.danger) { picked in
                        dueDate = picked
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    PocketButton(label: blocked ? "已标记受阻" : "标记为受阻", symbol: "exclamationmark.triangle", kind: blocked ? .primary : .ghost) {
                        blocked.toggle()
                    }
                    if blocked {
                        PocketField(placeholder: "卡在哪里？", text: $blockerReason, symbol: "text.bubble")
                            .frame(maxWidth: 240)
                    }
                }
            }
        case .event:
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("固定时间", hint: "活动在什么时候发生")
                HStack(spacing: 8) {
                    PocketDateField(label: "日期", symbol: "calendar", value: eventDay, tint: PocketTheme.mauve, allowsClear: false) { picked in
                        eventDay = picked ?? eventDay
                    }
                    PocketTimeField(label: "开始", iso: eventDay.map { DayKey.iso(key: $0, hour: startHour, minute: startMinute) }) { hour, minute in
                        startHour = hour
                        startMinute = minute
                    }
                    PocketMenuButton {
                        PocketTag(label: "时长 \(durationText)", symbol: "timer", tint: PocketTheme.mauve)
                            .padding(.vertical, 3)
                    } menu: {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach([30, 45, 60, 90, 120, 180], id: \.self) { minutes in
                                ContextMenuItem(label: "\(minutes) 分钟", symbol: "timer", isAccent: durationMinutes == minutes) {
                                    durationMinutes = minutes
                                }
                            }
                        }
                    }
                    Spacer()
                }
            }
        case .direction:
            InlineHint(text: "探索方向保留意向，不计入待办数量。明确后可以随时转成待办。")
        case .wait:
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("跟进", hint: "外部结果还没到位时，约定一个再检查的时间")
                HStack(spacing: 8) {
                    PocketDateField(label: "跟进", symbol: "bell.badge", value: followUpDate, tint: PocketTheme.warning) { picked in
                        followUpDate = picked
                    }
                    Spacer()
                }
            }
        }
    }

    private var detailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("说明", hint: "可选，写下判断依据或需要补充的信息")
            PocketTextArea(text: $detail, placeholder: "补充说明…", minHeight: 70)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isEditing {
                PocketButton(label: "删除", symbol: "trash", kind: .danger) {
                    if let item {
                        onClose()
                        Task { await store.deleteItem(item) }
                    }
                }
            }
            Spacer()
            PocketButton(label: "取消", kind: .ghost, action: onClose)
            PocketButton(
                label: isSaving ? "保存中…" : (isEditing ? "保存修改" : "添加"),
                symbol: "checkmark",
                kind: .primary,
                isEnabled: !title.trimmed.isEmpty && !isSaving
            ) {
                submit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func fieldLabel(_ text: String, hint: String? = nil) -> some View {
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

    private var accent: Color {
        switch kind {
        case .task: PocketTheme.accent
        case .event: PocketTheme.mauve
        case .direction: PocketTheme.mauve
        case .wait: PocketTheme.warning
        }
    }

    private var durationText: String {
        if durationMinutes % 60 == 0 { return "\(durationMinutes / 60) 小时" }
        return "\(durationMinutes) 分钟"
    }

    private func load() {
        guard let item else {
            kind = initialKind
            eventDay = DayKey.today
            titleFocused = true
            return
        }
        kind = item.kind
        title = item.title
        detail = item.detail ?? ""
        planDate = item.planDate
        dueDate = item.dueDate
        followUpDate = item.followUpDate
        blocked = item.blocked
        blockerReason = item.blockerReason ?? ""
        if let start = item.startAt {
            eventDay = DayKey.fromIso(start)
            let parts = DayKey.hourMinute(fromIso: item.startAt)
            startHour = parts.hour
            startMinute = parts.minute
            if let end = item.endAt, let startDate = ISO8601DateFormatter.parse(start), let endDate = ISO8601DateFormatter.parse(end) {
                durationMinutes = max(15, Int(endDate.timeIntervalSince(startDate) / 60))
            }
        } else {
            eventDay = DayKey.today
        }
    }

    private func submit() {
        let value = title.trimmed
        guard !value.isEmpty else { return }
        isSaving = true

        if let item {
            var patch: [String: Any] = ["title": value, "kind": kind.rawValue]
            patch["detail"] = detail.isBlank ? NSNull() : detail
            patch["plan_date"] = planDate ?? NSNull()
            patch["due_date"] = dueDate ?? NSNull()
            patch["follow_up_date"] = followUpDate ?? NSNull()
            patch["blocked"] = blocked
            patch["blocker_reason"] = blockerReason.isBlank ? NSNull() : blockerReason
            if kind == .event, let day = eventDay {
                patch["start_at"] = DayKey.iso(key: day, hour: startHour, minute: startMinute)
                patch["end_at"] = DayKey.iso(
                    key: day,
                    hour: startHour + (durationMinutes / 60),
                    minute: startMinute + (durationMinutes % 60)
                )
            } else {
                patch["start_at"] = NSNull()
                patch["end_at"] = NSNull()
            }
            Task {
                await store.updateItem(item, patch: patch, message: "已保存修改")
                onClose()
            }
        } else {
            let startAt = kind == .event ? eventDay.map { DayKey.iso(key: $0, hour: startHour, minute: startMinute) } : nil
            let endAt = kind == .event
                ? eventDay.map {
                    DayKey.iso(
                        key: $0,
                        hour: startHour + (durationMinutes / 60),
                        minute: startMinute + (durationMinutes % 60)
                    )
                }
                : nil
            Task {
                await store.createItem(
                    threadId: thread.id,
                    kind: kind,
                    title: value,
                    detail: detail.isBlank ? nil : detail,
                    planDate: kind == .task ? planDate : nil,
                    dueDate: kind == .task ? dueDate : nil,
                    startAt: startAt,
                    endAt: endAt,
                    followUpDate: kind == .wait ? followUpDate : nil,
                    blocked: blocked,
                    blockerReason: blockerReason.isBlank ? nil : blockerReason
                )
                onClose()
            }
        }
    }
}

/// 新建线索。
struct NewThreadPanel: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var overlay: OverlayCenter

    var domainId: String
    var onClose: () -> Void

    @State private var title = ""
    @State private var summary = ""
    @State private var selectedDomain: String = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PocketTheme.accent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(PocketTheme.accent.opacity(0.16)))
                Text("新建线索")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PocketTheme.textPrimary)
                Spacer()
                PocketIconButton(symbol: "xmark", help: "关闭", size: 24, action: onClose)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(PocketTheme.stroke)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("标题")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PocketTheme.textSecondary)
                    PocketField(placeholder: "例如：厨房方案", text: $title, symbol: "text.cursor")
                        .focused($titleFocused)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("归属领域")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PocketTheme.textSecondary)
                    HStack(spacing: 6) {
                        ForEach(store.domains) { domain in
                            PocketChip(
                                label: domain.name,
                                symbol: domain.symbol,
                                tint: PocketTheme.domainColor(domain.color),
                                isActive: selectedDomain == domain.id
                            ) {
                                selectedDomain = domain.id
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("当前描述（可选）")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PocketTheme.textSecondary)
                    PocketTextArea(text: $summary, placeholder: "现在到了哪里？一句话就够。", minHeight: 70)
                }
            }
            .padding(16)

            Divider().overlay(PocketTheme.stroke)

            HStack {
                Text("建立后可以继续补充行动、方向与等待")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PocketTheme.textTertiary)
                Spacer()
                PocketButton(label: "取消", kind: .ghost, action: onClose)
                PocketButton(
                    label: "建立",
                    symbol: "checkmark",
                    kind: .primary,
                    isEnabled: !title.trimmed.isEmpty
                ) {
                    let draftTitle = title.trimmed
                    let draftSummary = summary.trimmed
                    let domain = selectedDomain.isEmpty ? domainId : selectedDomain
                    onClose()
                    Task { await store.createThread(title: draftTitle, domainId: domain, summary: draftSummary) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 470)
        .onAppear {
            selectedDomain = domainId
            titleFocused = true
        }
    }
}

/// 新建 / 编辑 Domain。
struct DomainEditorPanel: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var overlay: OverlayCenter

    var domain: Domain?
    var onClose: () -> Void

    @State private var name = ""
    @State private var color = "indigo"
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PocketTheme.accent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(PocketTheme.accent.opacity(0.16)))
                Text(domain == nil ? "新建领域" : "编辑领域")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PocketTheme.textPrimary)
                Spacer()
                PocketIconButton(symbol: "xmark", help: "关闭", size: 24, action: onClose)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(PocketTheme.stroke)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("名称")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PocketTheme.textSecondary)
                    PocketField(placeholder: "例如：装修", text: $name, symbol: "tag")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("颜色")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PocketTheme.textSecondary)
                    HStack(spacing: 8) {
                        ForEach(PocketTheme.domainColorNames, id: \.self) { candidate in
                            Button {
                                withAnimation(PocketMotion.snappy) { color = candidate }
                            } label: {
                                Circle()
                                    .fill(PocketTheme.domainColor(candidate))
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle().strokeBorder(PocketTheme.textPrimary, lineWidth: color == candidate ? 2 : 0)
                                    )
                                    .scaleEffect(color == candidate ? 1.12 : 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)

            Divider().overlay(PocketTheme.stroke)

            HStack {
                Spacer()
                PocketButton(label: "取消", kind: .ghost, action: onClose)
                PocketButton(
                    label: domain == nil ? "建立" : "保存",
                    symbol: "checkmark",
                    kind: .primary,
                    isEnabled: !name.trimmed.isEmpty && !isSaving
                ) {
                    submit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .onAppear {
            if let domain {
                name = domain.name
                color = domain.color
            }
        }
    }

    private func submit() {
        let value = name.trimmed
        isSaving = true
        onClose()
        Task { await store.saveDomain(domain, name: value, color: color) }
    }
}

struct DomainMutationResponse: Codable {
    var domain: Domain
}
