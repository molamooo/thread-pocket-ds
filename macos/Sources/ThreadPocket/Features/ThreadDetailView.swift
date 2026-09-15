import SwiftUI

struct DetailPane: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Group {
            switch store.mode {
            case .threads:
                ThreadDetailView()
            case .overview:
                OverviewView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ThreadDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var overlay: OverlayCenter

    @State private var isEditingSummary = false
    @State private var summaryDraft = ""
    @State private var isRenamingTitle = false
    @State private var titleDraft = ""
    @State private var progressDraft = ""
    @State private var showClosed = false
    @FocusState private var progressFocused: Bool

    var body: some View {
        if let thread = store.selectedThread {
            content(thread: thread)
        } else {
            VStack {
                EmptyHint(
                    symbol: "sidebar.left",
                    title: "选择一条线索",
                    message: "左侧列表里存放着持续推进的事情，选中后这里会显示它的现状。"
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(thread: Thread) -> some View {
        VStack(spacing: 0) {
            header(thread: thread)
            Divider().overlay(PocketTheme.stroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    currentSection(thread: thread)
                    actionsSection(thread: thread)
                    directionsSection(thread: thread)
                    waitingSection(thread: thread)
                    closedSection(thread: thread)
                    noteLogSection(thread: thread)
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 26)
                .frame(maxWidth: 940, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .reorderContainer()

            Divider().overlay(PocketTheme.stroke)
            progressBar(thread: thread)
        }
        .onChange(of: store.selectedThreadID) { _, _ in
            isEditingSummary = false
            isRenamingTitle = false
            progressDraft = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .pocketFocusProgressField)) { _ in
            progressFocused = true
        }
    }

    // MARK: - 头部

    private func header(thread: Thread) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if isRenamingTitle {
                    PocketField(
                        placeholder: "线索标题",
                        text: $titleDraft,
                        symbol: "pencil",
                        onSubmit: { commitTitle(thread: thread) }
                    )
                    .frame(maxWidth: 420)
                } else {
                    Text(thread.title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(PocketTheme.textPrimary)
                        .lineLimit(1)
                        .onTapGesture {
                            titleDraft = thread.title
                            withAnimation(PocketMotion.quick) { isRenamingTitle = true }
                        }
                }

                HStack(spacing: 7) {
                    PocketMenuButton {
                        HStack(spacing: 5) {
                            Image(systemName: store.domain(thread.domainId)?.symbol ?? "folder")
                                .font(.system(size: 10, weight: .semibold))
                            Text(store.domain(thread.domainId)?.name ?? "未归属")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(PocketTheme.domainColor(store.domain(thread.domainId)?.color ?? "slate"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(PocketTheme.domainColor(store.domain(thread.domainId)?.color ?? "slate").opacity(0.15))
                        )
                    } menu: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("归属领域")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(PocketTheme.textTertiary)
                                .padding(.horizontal, 9)
                                .padding(.top, 4)
                            ForEach(store.domains) { domain in
                                ContextMenuItem(
                                    label: domain.name,
                                    symbol: domain.symbol,
                                    isAccent: domain.id == thread.domainId
                                ) {
                                    Task { await store.updateThread(threadId: thread.id, domainId: domain.id, message: "已移动到「\(domain.name)」") }
                                }
                            }
                        }
                    }

                    PocketMenuButton {
                        HStack(spacing: 5) {
                            Image(systemName: thread.status.symbol)
                                .font(.system(size: 10, weight: .semibold))
                            Text(thread.status.label)
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(statusTint(thread.status))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(statusTint(thread.status).opacity(0.14)))
                    } menu: {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(ThreadStatus.allCases, id: \.self) { status in
                                ContextMenuItem(
                                    label: status.label,
                                    symbol: status.symbol,
                                    isAccent: status == thread.status
                                ) {
                                    Task { await store.updateThread(threadId: thread.id, status: status, message: "状态已更新") }
                                }
                            }
                        }
                    }

                    Text("更新于 \(DayKey.relativeTime(thread.updatedAt))")
                        .font(.system(size: 11))
                        .foregroundStyle(PocketTheme.textTertiary)
                }
            }

            Spacer()

            if store.hasUnsavedWork(threadId: thread.id) {
                PocketTag(label: "有未保存的修改", symbol: "pencil.circle.fill", tint: PocketTheme.warning)
                    .transition(.scale.combined(with: .opacity))
            }

            PocketMenuButton(alignLeading: false) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PocketTheme.textSecondary)
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: 9).fill(PocketTheme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PocketTheme.stroke, lineWidth: 1))
            } menu: {
                VStack(alignment: .leading, spacing: 1) {
                    ContextMenuItem(label: "新建事项", symbol: "plus.circle", shortcut: "⇧⌘N") {
                        overlay.presentPanel {
                            ItemEditorPanel(thread: thread, item: nil, onClose: { overlay.dismissPanel() })
                                .environmentObject(store)
                                .environmentObject(overlay)
                        }
                    }
                    ContextMenuItem(label: "重命名", symbol: "pencil") {
                        titleDraft = thread.title
                        isRenamingTitle = true
                    }
                    ContextMenuItem(
                        label: thread.isPinned ? "取消置顶" : "置顶",
                        symbol: thread.isPinned ? "pin.slash" : "pin"
                    ) {
                        Task { await store.togglePin(thread) }
                    }
                    ContextDivider()
                    ContextMenuItem(label: "复制当前描述", symbol: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(thread.summary, forType: .string)
                        overlay.toast("已复制当前描述", tone: .success)
                    }
                    ContextMenuItem(label: thread.archivedAt == nil ? "归档" : "取消归档", symbol: "archivebox") {
                        Task {
                            await store.updateThread(
                                threadId: thread.id,
                                archived: thread.archivedAt == nil,
                                message: thread.archivedAt == nil ? "已归档" : "已取消归档"
                            )
                        }
                    }
                    ContextMenuItem(label: "移入回收站", symbol: "trash", isDestructive: true) {
                        overlay.confirm(
                            ConfirmState(
                                title: "把「\(thread.title)」移入回收站？",
                                message: "可以随时从回收站恢复，但会先离开日常视野。",
                                primaryLabel: "移入回收站",
                                secondaryLabel: "取消",
                                destructive: true,
                                onPrimary: {
                                    overlay.dismissConfirm()
                                    Task { await store.deleteThread(threadId: thread.id) }
                                },
                                onSecondary: { overlay.dismissConfirm() }
                            )
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func statusTint(_ status: ThreadStatus) -> Color {
        switch status {
        case .active: PocketTheme.accent
        case .waiting: PocketTheme.warning
        case .paused: PocketTheme.textTertiary
        case .completed: PocketTheme.success
        }
    }

    private func commitTitle(thread: Thread) {
        let value = titleDraft.trimmed
        isRenamingTitle = false
        guard !value.isEmpty, value != thread.title else { return }
        Task { await store.updateThread(threadId: thread.id, title: value, message: "标题已更新") }
    }

    // MARK: - 当前描述

    private func currentSection(thread: Thread) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "当前", symbol: "quote.opening", tint: PocketTheme.accent)

            VStack(alignment: .leading, spacing: 10) {
                if isEditingSummary {
                    PocketTextArea(
                        text: $summaryDraft,
                        placeholder: "用一两句话交代现在到了哪里…",
                        minHeight: 76,
                        onCommit: { commitSummary(thread: thread) }
                    )
                    .onChange(of: summaryDraft) { _, newValue in
                        store.updateSummaryDraft(threadId: thread.id, text: newValue)
                    }
                    HStack(spacing: 8) {
                        Text("⌘↩ 保存 · Esc 取消")
                            .font(.system(size: 10.5))
                            .foregroundStyle(PocketTheme.textTertiary)
                        Spacer()
                        PocketButton(label: "取消", kind: .ghost) {
                            store.discardDrafts(threadId: thread.id)
                            withAnimation(PocketMotion.quick) { isEditingSummary = false }
                        }
                        PocketButton(label: "保存", symbol: "checkmark", kind: .primary) {
                            commitSummary(thread: thread)
                        }
                    }
                } else {
                    Text(thread.summary.isBlank ? "还没有写当前描述。用一句话交代现在的状态，回来时就能立刻接上。" : thread.summary)
                        .font(.system(size: 13.5))
                        .lineSpacing(3.5)
                        .foregroundStyle(thread.summary.isBlank ? PocketTheme.textTertiary : PocketTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            summaryDraft = thread.summary
                            withAnimation(PocketMotion.snappy) { isEditingSummary = true }
                        }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(radius: PocketTheme.cardRadius, fill: PocketTheme.accent.opacity(0.07))
            .pocketContextMenu {
                VStack(alignment: .leading, spacing: 1) {
                    ContextMenuItem(label: "编辑当前描述", symbol: "square.and.pencil", isAccent: true) {
                        summaryDraft = thread.summary
                        isEditingSummary = true
                    }
                    ContextMenuItem(label: "复制", symbol: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(thread.summary, forType: .string)
                        overlay.toast("已复制", tone: .success)
                    }
                    ContextMenuItem(label: "把这条描述记入日志", symbol: "text.append") {
                        Task { await store.addProgressNote(threadId: thread.id, text: thread.summary) }
                    }
                }
            }
        }
    }

    private func commitSummary(thread: Thread) {
        let value = summaryDraft.trimmed
        withAnimation(PocketMotion.quick) { isEditingSummary = false }
        Task { await store.saveSummary(threadId: thread.id, text: value) }
    }

    // MARK: - 行动

    private func actionsSection(thread: Thread) -> some View {
        // 待办与日程同属「行动」，按人工排定的顺序一起展示，也一起拖动排序。
        let open = store.openItems(for: thread.id).filter { $0.kind.isAction }
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "行动", symbol: "checklist", count: open.count, tint: PocketTheme.accent) {
                presentEditor(thread: thread, kind: .task)
            }
            if open.isEmpty {
                InlineHint(text: "还没有未结束的行动。明确的下一步就写成待办，固定时间的事写成日程。")
            }
            ForEach(open) { item in
                ItemRow(item: item, thread: thread, dragScope: .items(threadId: thread.id), dragOrder: open.map(\.id))
            }
        }
    }

    // MARK: - 探索方向

    private func directionsSection(thread: Thread) -> some View {
        let directions = store.openItems(for: thread.id).filter { $0.kind == .direction }
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(
                title: "探索方向",
                symbol: "sparkle.magnifyingglass",
                count: directions.count,
                tint: PocketTheme.mauve,
                actionLabel: "记一个"
            ) {
                presentEditor(thread: thread, kind: .direction)
            }
            if directions.isEmpty {
                InlineHint(text: "值得继续看、但还没成为承诺的想法放在这里；它们不计入待办数量。")
            }
            ForEach(directions) { item in
                ItemRow(
                    item: item,
                    thread: thread,
                    dragScope: .items(threadId: thread.id),
                    dragOrder: directions.map(\.id)
                )
            }
        }
    }

    // MARK: - 等待

    private func waitingSection(thread: Thread) -> some View {
        let waits = store.openItems(for: thread.id).filter { $0.kind == .wait || $0.blocked }
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "等待与阻塞", symbol: "hourglass", count: waits.count, tint: PocketTheme.warning, actionLabel: "记一个") {
                presentEditor(thread: thread, kind: .wait)
            }
            if waits.isEmpty {
                InlineHint(text: "需要等外部结果，或自己被卡住的行动放在这里，可以设置跟进时间。")
            }
            ForEach(waits) { item in
                ItemRow(item: item, thread: thread, dragScope: .items(threadId: thread.id), dragOrder: waits.map(\.id))
            }
        }
    }

    // MARK: - 已结束

    private func closedSection(thread: Thread) -> some View {
        let closed = store.items[thread.id]?.filter { !$0.isOpen } ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(PocketMotion.snappy) { showClosed.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: showClosed ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(PocketTheme.textTertiary)
                    Text("已完成 / 已解除 / 已取消")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(PocketTheme.textSecondary)
                    Text("\(closed.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PocketTheme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showClosed {
                if closed.isEmpty {
                    InlineHint(text: "还没有结束的事项。")
                }
                ForEach(closed) { item in
                    ItemRow(item: item, thread: thread)
                }
            }
        }
    }

    // MARK: - 笔记 / 日志

    private func noteLogSection(thread: Thread) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PocketSegmented(
                    options: [
                        PocketSegmentedOption(WorkspaceStore.DetailTab.note, label: "笔记", symbol: "note.text"),
                        PocketSegmentedOption(
                            WorkspaceStore.DetailTab.log,
                            label: "日志",
                            symbol: "clock.arrow.circlepath",
                            badge: store.logs(for: thread.id).count
                        ),
                    ],
                    selection: $store.detailTab,
                    compact: true
                )
                Spacer()
                if store.detailTab == .note {
                    noteStatus(thread: thread)
                }
            }

            if store.detailTab == .note {
                noteEditor(thread: thread)
            } else {
                LogTimeline(thread: thread)
            }
        }
    }

    private func noteStatus(thread: Thread) -> some View {
        let dirty = store.hasUnsavedWork(threadId: thread.id) && store.noteText(for: thread.id) != store.note(for: thread.id).content
        let updated = store.note(for: thread.id).updatedAt
        return HStack(spacing: 6) {
            if dirty {
                PocketTag(label: "未保存", symbol: "circle.fill", tint: PocketTheme.warning)
                PocketButton(label: "保存", symbol: "checkmark", kind: .secondary) {
                    Task { await store.saveNote(threadId: thread.id, content: store.noteText(for: thread.id)) }
                }
            } else if let updated {
                Text("已保存 · \(DayKey.relativeTime(updated))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PocketTheme.textTertiary)
            }
        }
        .transition(.opacity)
    }

    private func noteEditor(thread: Thread) -> some View {
        let binding = Binding<String>(
            get: { store.noteText(for: thread.id) },
            set: { store.updateNoteDraft(threadId: thread.id, text: $0) }
        )
        return PocketTextArea(
            text: binding,
            placeholder: "随手写点东西：尺寸、链接、还没想清楚的问题…",
            minHeight: 150,
            onCommit: {
                Task { await store.saveNote(threadId: thread.id, content: store.noteText(for: thread.id)) }
            }
        )
        .onChange(of: store.noteText(for: thread.id)) { _, _ in
            scheduleNoteAutosave(thread: thread)
        }
    }

    @State private var noteAutosaveTask: Task<Void, Never>?

    private func scheduleNoteAutosave(thread: Thread) {
        noteAutosaveTask?.cancel()
        noteAutosaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            let content = store.noteText(for: thread.id)
            guard content != store.note(for: thread.id).content else { return }
            await store.saveNote(threadId: thread.id, content: content, silent: true)
        }
    }

    // MARK: - 快速记录进展

    private func progressBar(thread: Thread) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(progressDraft.isBlank ? PocketTheme.textTertiary : PocketTheme.accent)
            TextField("记录一条进展：发生了什么、判断怎么变了…", text: $progressDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(PocketTheme.textPrimary)
                .focused($progressFocused)
                .onSubmit { record(thread: thread) }
            if !progressDraft.isBlank {
                PocketButton(label: "记录", symbol: "arrow.turn.down.left", kind: .primary) {
                    record(thread: thread)
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                Text("⌘⏎")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PocketTheme.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color.black.opacity(0.18))
        .animation(PocketMotion.quick, value: progressDraft.isBlank)
        .onChange(of: thread.id) { _, _ in progressDraft = "" }
    }

    private func record(thread: Thread) {
        let text = progressDraft.trimmed
        guard !text.isEmpty else { return }
        progressDraft = ""
        store.detailTab = .log
        Task { await store.addProgressNote(threadId: thread.id, text: text) }
    }

    private func presentEditor(thread: Thread, kind: ItemKind) {
        overlay.presentPanel {
            ItemEditorPanel(thread: thread, item: nil, initialKind: kind, onClose: { overlay.dismissPanel() })
                .environmentObject(store)
                .environmentObject(overlay)
        }
    }
}

struct InlineHint: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(PocketTheme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PocketTheme.rowRadius, style: .continuous)
                    .fill(Color.white.opacity(0.02))
            )
    }
}

struct LogTimeline: View {
    @EnvironmentObject private var store: WorkspaceStore
    var thread: Thread

    var body: some View {
        let entries = store.logs(for: thread.id)
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                InlineHint(text: "还没有日志。记录一次进展后，这里会按时间顺序保留结果与判断。")
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(entry.isProgress ? PocketTheme.accent : PocketTheme.textTertiary.opacity(0.6))
                            .frame(width: entry.isProgress ? 8 : 6, height: entry.isProgress ? 8 : 6)
                            .padding(.top, entry.isProgress ? 5 : 6)
                        if index != entries.count - 1 {
                            Rectangle()
                                .fill(PocketTheme.stroke)
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.text)
                            .font(.system(size: entry.isProgress ? 13 : 11.5, weight: entry.isProgress ? .medium : .regular))
                            .foregroundStyle(entry.isProgress ? PocketTheme.textPrimary : PocketTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Text(DayKey.relativeTime(entry.createdAt))
                            .font(.system(size: 10))
                            .foregroundStyle(PocketTheme.textTertiary.opacity(0.8))
                    }
                    .padding(.bottom, entry.isProgress ? 13 : 9)

                    Spacer(minLength: 0)
                }
                .pocketContextMenu {
                    VStack(alignment: .leading, spacing: 1) {
                        ContextMenuItem(label: "复制这条记录", symbol: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.text, forType: .string)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }
}
