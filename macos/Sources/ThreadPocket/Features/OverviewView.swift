import SwiftUI

/// 总览模式下左侧的入口列表。
struct OverviewNavList: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(WorkspaceStore.OverviewTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(PocketMotion.snappy) { store.overviewTab = tab }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(store.overviewTab == tab ? PocketTheme.accent : PocketTheme.textSecondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tab.label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(PocketTheme.textPrimary)
                                Text(subtitle(tab))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(PocketTheme.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if let count = count(tab), count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(PocketTheme.textSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(PocketTheme.surfaceStrong))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: PocketTheme.rowRadius, style: .continuous)
                                .fill(store.overviewTab == tab ? PocketTheme.accentSoft : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: PocketTheme.rowRadius, style: .continuous)
                                .strokeBorder(store.overviewTab == tab ? PocketTheme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: PocketTheme.rowRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Divider().overlay(PocketTheme.stroke).padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text("视线范围")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PocketTheme.textTertiary)
                    ForEach(store.domains) { domain in
                        Button {
                            store.selectedDomainID = store.selectedDomainID == domain.id ? nil : domain.id
                            store.refreshOverviewDebounced()
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(PocketTheme.domainColor(domain.color))
                                    .frame(width: 7, height: 7)
                                Text(domain.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(PocketTheme.textSecondary)
                                Spacer()
                                if store.selectedDomainID == domain.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(PocketTheme.accent)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
    }

    private func subtitle(_ tab: WorkspaceStore.OverviewTab) -> String {
        switch tab {
        case .today: "现在需要处理什么"
        case .actions: "还有什么可以安排"
        case .inbox: "收下的内容放在哪里"
        }
    }

    private func count(_ tab: WorkspaceStore.OverviewTab) -> Int? {
        switch tab {
        case .today: store.todayView?.groups.reduce(0) { $0 + $1.count }
        case .actions: store.actionsView?.total
        case .inbox: store.inboxView?.total
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(PocketTheme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch store.overviewTab {
                    case .today: todayContent
                    case .actions: actionsContent
                    case .inbox: inboxContent
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: 940, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .onAppear { store.refreshOverviewDebounced() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(PocketTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PocketTheme.textTertiary)
                }
                Spacer()
                Text(dateLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(PocketTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(PocketTheme.surface))
                    .overlay(Capsule().strokeBorder(PocketTheme.stroke, lineWidth: 1))
            }

            if store.overviewTab == .actions {
                HStack(spacing: 8) {
                    PocketSegmented(
                        options: WorkspaceStore.DateFilter.allCases.map { filter in
                            PocketSegmentedOption(filter, label: filter.label)
                        },
                        selection: $store.dateFilter,
                        compact: true
                    )
                    .onChange(of: store.dateFilter) { _, _ in store.refreshOverviewDebounced() }

                    PocketSegmented(
                        options: WorkspaceStore.RangeFilter.allCases.map { filter in
                            PocketSegmentedOption(filter, label: filter.label)
                        },
                        selection: $store.rangeFilter,
                        compact: true
                    )
                    .onChange(of: store.rangeFilter) { _, _ in store.refreshOverviewDebounced() }
                    Spacer()
                }
                .opacity(store.dateFilter == .without ? 0.45 : 1)
                .disabled(store.dateFilter == .without)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var title: String {
        switch store.overviewTab {
        case .today: "今天"
        case .actions: "行动"
        case .inbox: "收件箱"
        }
    }

    private var subtitle: String {
        switch store.overviewTab {
        case .today: "跨线索看今天安排、逾期与需要确认结果的日程"
        case .actions: "未结束的待办与固定日程，按线索分组"
        case .inbox: "各领域收集箱里的未结束事项，整理它们的归属"
        }
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: Date())
    }

    // MARK: - 今天

    @ViewBuilder
    private var todayContent: some View {
        if let view = store.todayView, !view.groups.isEmpty {
            ForEach(view.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(
                        title: group.title,
                        symbol: symbol(group.key),
                        count: group.count,
                        tint: tint(group.key)
                    )
                    ForEach(group.entries, id: \.item.id) { entry in
                        if let thread = store.thread(entry.item.threadId) {
                            ItemRow(item: entry.item, thread: thread, compact: true, showThreadLabel: true)
                        } else if let ref = entry.thread {
                            Text("\(ref.title) · \(entry.item.title)")
                                .font(.system(size: 12))
                                .foregroundStyle(PocketTheme.textSecondary)
                        }
                    }
                }
            }
        } else {
            EmptyHint(symbol: "sun.max", title: "今天没有需要处理的行动", message: "可以进入具体线索，处理上下文较重的工作。")
                .padding(.top, 60)
        }
    }

    private func symbol(_ key: String) -> String {
        switch key {
        case "today": "sun.max"
        case "overdue": "exclamationmark.circle"
        case "to_reschedule": "arrow.triangle.2.circlepath"
        case "past_events": "calendar.badge.exclamationmark"
        case "follow_ups": "bell.badge"
        default: "circle"
        }
    }

    private func tint(_ key: String) -> Color {
        switch key {
        case "today": PocketTheme.accent
        case "overdue": PocketTheme.danger
        case "to_reschedule": PocketTheme.warning
        case "past_events": PocketTheme.mauve
        case "follow_ups": PocketTheme.warning
        default: PocketTheme.textSecondary
        }
    }

    // MARK: - 行动

    @ViewBuilder
    private var actionsContent: some View {
        if let view = store.actionsView, !view.groups.isEmpty {
            ForEach(view.groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        if let domain = store.domain(group.thread.domainId) {
                            Circle()
                                .fill(PocketTheme.domainColor(domain.color))
                                .frame(width: 7, height: 7)
                        }
                        Text(group.thread.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(PocketTheme.textPrimary)
                        if group.thread.isInboxOrFalse {
                            PocketTag(label: "收集箱", symbol: "tray", tint: PocketTheme.textTertiary)
                        }
                        Text("\(group.items.count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(PocketTheme.textTertiary)
                        Spacer()
                        PocketIconButton(symbol: "arrow.up.forward.app", help: "定位到这条线索", size: 20) {
                            store.mode = .threads
                            store.requestSelection(group.thread.id)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 8)

                    ForEach(group.items) { item in
                        if let thread = store.thread(item.threadId) {
                            ItemRow(item: item, thread: thread, compact: true)
                        }
                    }
                }
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(PocketTheme.stroke.opacity(0.6)).frame(height: 1)
                }
            }
        } else {
            EmptyHint(symbol: "checklist", title: "没有符合条件的行动", message: "换个筛选看看，或进入线索添加新的待办。")
                .padding(.top, 60)
        }
    }

    // MARK: - 收件箱

    @ViewBuilder
    private var inboxContent: some View {
        if let view = store.inboxView, !view.groups.isEmpty {
            ForEach(view.groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        if let domain = group.domain {
                            Circle()
                                .fill(PocketTheme.domainColor(domain.color))
                                .frame(width: 7, height: 7)
                            Text(domain.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(PocketTheme.textPrimary)
                        } else {
                            Text(group.thread.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(PocketTheme.textPrimary)
                        }
                        PocketTag(label: "收集箱", symbol: "tray", tint: PocketTheme.textTertiary)
                        Spacer()
                        Text("\(group.items.count) 项待整理")
                            .font(.system(size: 10.5))
                            .foregroundStyle(PocketTheme.textTertiary)
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 8)

                    ForEach(group.items) { item in
                        if let thread = store.thread(item.threadId) {
                            ItemRow(item: item, thread: thread, compact: true)
                        }
                    }
                }
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(PocketTheme.stroke.opacity(0.6)).frame(height: 1)
                }
            }
        } else {
            EmptyHint(symbol: "tray", title: "收件箱是空的", message: "收集箱不需要清空，未整理也不等于紧急。")
                .padding(.top, 60)
        }
    }
}
