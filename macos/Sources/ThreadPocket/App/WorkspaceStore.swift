import Combine
import Foundation
import SwiftUI

@MainActor
final class WorkspaceStore: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case online(Date)
        case offline(String)

        var isOnline: Bool { if case .online = self { return true } else { return false } }
        var isConnecting: Bool { self == .connecting }

        var label: String {
            switch self {
            case .idle: "未连接"
            case .connecting: "连接中"
            case .online(let date):
                "已连接 · \(Self.timeFormatter.string(from: date))"
            case .offline: "未连接"
            }
        }

        var detail: String? {
            if case .offline(let reason) = self { return reason }
            return nil
        }

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()
    }

    enum Mode: String, CaseIterable, Hashable {
        case threads
        case overview

        var label: String {
            switch self {
            case .threads: "线索"
            case .overview: "总览"
            }
        }

        var symbol: String {
            switch self {
            case .threads: "text.alignleft"
            case .overview: "square.grid.2x2"
            }
        }
    }

    enum Scope: String, CaseIterable, Hashable {
        case all
        case today
        case upcoming
        case waiting

        var label: String {
            switch self {
            case .all: "全部"
            case .today: "今天"
            case .upcoming: "近期"
            case .waiting: "等待"
            }
        }
    }

    enum OverviewTab: String, CaseIterable, Hashable {
        case today
        case actions
        case inbox

        var label: String {
            switch self {
            case .today: "今天"
            case .actions: "行动"
            case .inbox: "收件箱"
            }
        }

        var symbol: String {
            switch self {
            case .today: "sun.max"
            case .actions: "checklist"
            case .inbox: "tray"
            }
        }
    }

    enum DateFilter: String, CaseIterable, Hashable {
        case all
        case with
        case without

        var label: String {
            switch self {
            case .all: "全部"
            case .with: "有时间"
            case .without: "无时间"
            }
        }
    }

    enum RangeFilter: String, CaseIterable, Hashable {
        case any
        case upcoming7

        var label: String { self == .any ? "不限时间" : "近 7 天" }
    }

    enum ListFilter: String, CaseIterable, Hashable {
        case active
        case archived
        case trashed

        var label: String {
            switch self {
            case .active: "日常视野"
            case .archived: "归档"
            case .trashed: "回收站"
            }
        }
    }

    // 数据
    @Published private(set) var domains: [Domain] = []
    @Published private(set) var threads: [Thread] = []
    @Published private(set) var items: [String: [Item]] = [:]
    @Published private(set) var notes: [String: Note] = [:]
    @Published private(set) var logs: [String: [LogEntry]] = [:]
    @Published private(set) var connection: ConnectionState = .idle
    @Published private(set) var inFlight = 0
    @Published private(set) var unavailableReason: String?

    // 视图状态
    @Published var selectedThreadID: String?
    @Published var selectedDomainID: String?
    @Published var mode: Mode = .threads
    @Published var scope: Scope = .all
    @Published var overviewTab: OverviewTab = .today
    @Published var dateFilter: DateFilter = .all
    @Published var rangeFilter: RangeFilter = .any
    @Published var listFilter: ListFilter = .active
    @Published var detailTab: DetailTab = .note
    @Published var searchText: String = ""
    @Published private(set) var searchResults: SearchResponse?

    // 概览数据
    @Published private(set) var todayView: TodayView?
    @Published private(set) var actionsView: ActionsView?
    @Published private(set) var inboxView: InboxView?

    // 草稿
    @Published private(set) var summaryDraft: [String: String] = [:]
    @Published private(set) var noteDraft: [String: String] = [:]

    enum DetailTab: String, CaseIterable, Hashable {
        case note
        case log

        var label: String {
            switch self {
            case .note: "笔记"
            case .log: "日志"
            }
        }
    }

    let settings: AppSettings
    let overlay: OverlayCenter
    private(set) var client: APIClient?
    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(settings: AppSettings, overlay: OverlayCenter) {
        self.settings = settings
        self.overlay = overlay
        rebuildClient()
    }

    // MARK: - 连接

    func rebuildClient() {
        guard let url = settings.normalizedURL else {
            client = nil
            return
        }
        client = APIClient(baseURL: url, token: settings.token)
    }

    var serverLabel: String {
        settings.normalizedURL?.absoluteString ?? settings.serverURL
    }

    func connect(showToast: Bool = false) async {
        rebuildClient()
        guard let client else {
            connection = .offline("服务器地址无效")
            return
        }
        connection = .connecting
        do {
            let health: HealthResponse = try await client.get("/health")
            _ = health
            let snapshot: Snapshot = try await client.get("/api/v1/snapshot")
            apply(snapshot: snapshot)
            connection = .online(Date())
            unavailableReason = nil
            if selectedThreadID == nil || !threads.contains(where: { $0.id == selectedThreadID }) {
                selectedThreadID = preferredInitialThread()?.id
            }
            await refreshOverview()
            startAutoRefresh()
            if showToast {
                overlay.toast("已连接到 \(serverLabel)", tone: .success)
            }
        } catch let error as APIError {
            connection = .offline(error.errorDescription ?? "连接失败")
            unavailableReason = error.errorDescription
            if showToast {
                overlay.toast(
                    "连接失败",
                    tone: .failure,
                    detail: error.errorDescription,
                    actionLabel: "重试",
                    action: { [weak self] in Task { await self?.connect(showToast: true) } }
                )
            }
        } catch {
            connection = .offline("连接失败")
        }
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        guard settings.autoRefreshSeconds > 0 else { return }
        let seconds = settings.autoRefreshSeconds
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.softRefresh()
            }
        }
    }

    /// 后台轻量刷新：不改变当前选择，失败时保留现有内容。
    func softRefresh() async {
        guard let client, connection.isOnline, inFlight == 0 else { return }
        do {
            let snapshot: Snapshot = try await client.get("/api/v1/snapshot")
            apply(snapshot: snapshot, preservingSelection: true)
            connection = .online(Date())
            await refreshOverview()
        } catch {
            // 静默失败，等待下一次刷新或用户手动重连
        }
    }

    func disconnect() {
        refreshTask?.cancel()
        connection = .idle
    }

    private func preferredInitialThread() -> Thread? {
        let candidates = threads.filter { !$0.isInbox && !$0.isTrashed && $0.archivedAt == nil }
        if let waiting = candidates.first(where: { $0.status == .active && $0.countsOrEmpty.openItems > 0 }) {
            return waiting
        }
        return candidates.first ?? threads.first
    }

    private func apply(snapshot: Snapshot, preservingSelection: Bool = false) {
        domains = snapshot.domains.sorted { $0.position < $1.position }
        threads = snapshot.threads
        var itemMap: [String: [Item]] = [:]
        for item in snapshot.items {
            itemMap[item.threadId, default: []].append(item)
        }
        for key in itemMap.keys {
            itemMap[key]?.sort { $0.position < $1.position }
        }
        items = itemMap

        var noteMap: [String: Note] = [:]
        for note in snapshot.notes {
            if let threadId = note.threadId { noteMap[threadId] = note }
        }
        for thread in snapshot.threads where noteMap[thread.id] == nil {
            noteMap[thread.id] = .empty
        }
        notes = noteMap

        var logMap: [String: [LogEntry]] = [:]
        for log in snapshot.logs {
            logMap[log.threadId, default: []].append(log)
        }
        for key in logMap.keys {
            logMap[key]?.sort { $0.createdAt > $1.createdAt }
        }
        logs = logMap

        if !preservingSelection {
            if selectedThreadID == nil || !snapshot.threads.contains(where: { $0.id == selectedThreadID }) {
                selectedThreadID = preferredInitialThread()?.id
            }
        }
    }

    // MARK: - 派生数据

    var selectedThread: Thread? {
        threads.first { $0.id == selectedThreadID }
    }

    func thread(_ id: String?) -> Thread? {
        guard let id else { return nil }
        return threads.first { $0.id == id }
    }

    func domain(_ id: String?) -> Domain? {
        guard let id else { return nil }
        return domains.first { $0.id == id }
    }

    func openItems(for threadId: String, includeClosed: Bool = false) -> [Item] {
        let all = items[threadId] ?? []
        return includeClosed ? all : all.filter { $0.isOpen }
    }

    func note(for threadId: String) -> Note {
        notes[threadId] ?? .empty
    }

    func logs(for threadId: String) -> [LogEntry] {
        logs[threadId] ?? []
    }

    var visibleThreads: [Thread] {
        let needle = searchText.trimmed.lowercased()
        return threads
            .filter { thread in
                switch listFilter {
                case .active: !thread.isTrashed && thread.archivedAt == nil
                case .archived: !thread.isTrashed && thread.archivedAt != nil
                case .trashed: thread.isTrashed
                }
            }
            .filter { selectedDomainID == nil || $0.domainId == selectedDomainID }
            .filter { matchesScope($0) }
            .filter { thread in
                guard !needle.isEmpty else { return true }
                if thread.title.lowercased().contains(needle) { return true }
                if thread.summary.lowercased().contains(needle) { return true }
                return (items[thread.id] ?? []).contains { $0.title.lowercased().contains(needle) }
            }
            .sorted { lhs, rhs in
                if lhs.isInbox != rhs.isInbox { return !lhs.isInbox }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private func matchesScope(_ thread: Thread) -> Bool {
        guard scope != .all else { return true }
        let open = openItems(for: thread.id)
        let today = DayKey.today
        switch scope {
        case .all:
            return true
        case .today:
            return open.contains { item in
                switch item.kind {
                case .task:
                    if item.dueDate == today || item.planDate == today { return true }
                    if let due = item.dueDate, due < today { return true }
                    if let plan = item.planDate, plan < today { return true }
                    return false
                case .event:
                    guard let start = item.startAt else { return false }
                    let day = DayKey.fromIso(start)
                    let end = item.endAt.map { DayKey.fromIso($0) } ?? day
                    return day <= today && end >= today
                case .wait:
                    if let follow = item.followUpDate { return follow <= today }
                    return false
                case .direction:
                    return false
                }
            }
        case .upcoming:
            let horizon = DayKey.add(days: 6)
            return open.contains { item in
                let candidates = [item.planDate, item.dueDate, item.followUpDate, item.startAt.map { DayKey.fromIso($0) }]
                return candidates.compactMap { $0 }.contains { $0 >= today && $0 <= horizon }
            }
        case .waiting:
            return open.contains { $0.kind == .wait || $0.blocked }
        }
    }

    func hasUnsavedWork(threadId: String?) -> Bool {
        guard let threadId else { return false }
        if let draft = summaryDraft[threadId], draft != (thread(threadId)?.summary ?? "") { return true }
        if let draft = noteDraft[threadId], draft != note(for: threadId).content { return true }
        return false
    }

    var hasAnyDraft: Bool {
        threads.contains { hasUnsavedWork(threadId: $0.id) }
    }

    // MARK: - 选择线程（带草稿保护）

    func requestSelection(_ threadId: String?) {
        guard threadId != selectedThreadID else { return }
        if let current = selectedThreadID, hasUnsavedWork(threadId: current) {
            let targetTitle = thread(threadId)?.title ?? "其他线索"
            let currentTitle = thread(current)?.title ?? "当前线索"
            overlay.confirm(
                ConfirmState(
                    title: "还有未保存的内容",
                    message: "「\(currentTitle)」的修改尚未保存。切换后这些内容会丢失。",
                    primaryLabel: "保存并切换到「\(targetTitle)」",
                    secondaryLabel: "放弃修改",
                    tertiaryLabel: "留在原处",
                    onPrimary: { [weak self] in
                        guard let self else { return }
                        Task {
                            await self.commitDrafts(threadId: current)
                            self.overlay.dismissConfirm()
                            self.selectedThreadID = threadId
                        }
                    },
                    onSecondary: { [weak self] in
                        guard let self else { return }
                        self.discardDrafts(threadId: current)
                        self.overlay.dismissConfirm()
                        self.selectedThreadID = threadId
                    },
                    onTertiary: { [weak self] in
                        self?.overlay.dismissConfirm()
                    }
                )
            )
            return
        }
        selectedThreadID = threadId
    }

    func discardDrafts(threadId: String) {
        summaryDraft[threadId] = nil
        noteDraft[threadId] = nil
    }

    func commitDrafts(threadId: String) async {
        if let draft = summaryDraft[threadId], draft != (thread(threadId)?.summary ?? "") {
            await saveSummary(threadId: threadId, text: draft, silent: true)
        }
        if let draft = noteDraft[threadId], draft != note(for: threadId).content {
            await saveNote(threadId: threadId, content: draft, silent: true)
        }
    }

    // MARK: - 草稿

    func updateSummaryDraft(threadId: String, text: String) {
        summaryDraft[threadId] = text
    }

    func updateNoteDraft(threadId: String, text: String) {
        noteDraft[threadId] = text
    }

    func summaryText(for threadId: String) -> String {
        summaryDraft[threadId] ?? thread(threadId)?.summary ?? ""
    }

    func noteText(for threadId: String) -> String {
        noteDraft[threadId] ?? note(for: threadId).content
    }

    // MARK: - 请求封装

    private func perform(
        _ label: String,
        successMessage: String? = nil,
        operation: (APIClient) async throws -> Void
    ) async {
        guard let client else {
            overlay.toast("还没有可用的服务器地址", tone: .failure, detail: "在设置里填写后端 URL 后重试。")
            return
        }
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            try await operation(client)
            if let successMessage {
                overlay.toast(successMessage, tone: .success)
            }
            if !connection.isOnline { connection = .online(Date()) }
        } catch let error as APIError {
            if error.isConnectivityIssue { connection = .offline(error.errorDescription ?? "连接中断") }
            overlay.toast(
                "\(label)失败",
                tone: .failure,
                detail: error.errorDescription,
                actionLabel: "重新连接",
                action: { [weak self] in Task { await self?.connect(showToast: false) } }
            )
        } catch {
            overlay.toast("\(label)失败", tone: .failure, detail: "\(error)")
        }
    }

    private func apply(bundle: ThreadBundle?) {
        guard let bundle else { return }
        upsert(thread: bundle.thread)
        items[bundle.thread.id] = (bundle.items.open + bundle.items.closed).sorted { $0.position < $1.position }
        notes[bundle.thread.id] = bundle.note
        logs[bundle.thread.id] = bundle.logs
    }

    private func upsert(thread: Thread) {
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[index] = thread
        } else {
            threads.append(thread)
        }
    }

    private func upsert(item: Item) {
        var list = items[item.threadId] ?? []
        if let index = list.firstIndex(where: { $0.id == item.id }) {
            list[index] = item
        } else {
            list.append(item)
        }
        items[item.threadId] = list.sorted { $0.position < $1.position }
    }

    private func remove(item: Item) {
        items[item.threadId] = (items[item.threadId] ?? []).filter { $0.id != item.id }
    }

    // MARK: - Thread 操作

    @discardableResult
    func createThread(title: String, domainId: String, summary: String = "") async -> Thread? {
        var created: Thread?
        await perform("新建线索") { client in
            let response: ThreadMutationResponse = try await client.post(
                "/api/v1/threads",
                body: ["domain_id": domainId, "title": title, "summary": summary]
            )
            created = response.thread
            upsert(thread: response.thread)
            items[response.thread.id] = items[response.thread.id] ?? []
            notes[response.thread.id] = .empty
            logs[response.thread.id] = logs[response.thread.id] ?? []
        }
        if let created {
            selectedThreadID = created.id
            selectedDomainID = created.domainId
            mode = .threads
            overlay.toast("已建立「\(created.title)」", tone: .success)
        }
        return created
    }

    func updateThread(
        threadId: String,
        title: String? = nil,
        summary: String? = nil,
        status: ThreadStatus? = nil,
        domainId: String? = nil,
        archived: Bool? = nil,
        trashed: Bool? = nil,
        message: String? = nil
    ) async {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let summary { body["summary"] = summary }
        if let status { body["status"] = status.rawValue }
        if let domainId { body["domain_id"] = domainId }
        if let archived { body["archived"] = archived }
        if let trashed { body["trashed"] = trashed }
        guard !body.isEmpty else { return }

        await perform("更新线索", successMessage: message) { client in
            let response: ThreadMutationResponse = try await client.patch("/api/v1/threads/\(threadId)", body: body)
            upsert(thread: response.thread)
            apply(bundle: response.bundle)
        }
        if trashed == true, selectedThreadID == threadId {
            selectedThreadID = preferredInitialThread()?.id
        }
        if archived == true, selectedThreadID == threadId {
            selectedThreadID = preferredInitialThread()?.id
        }
        await refreshOverview()
    }

    func saveSummary(threadId: String, text: String, silent: Bool = false) async {
        guard text != (thread(threadId)?.summary ?? "") else {
            summaryDraft[threadId] = nil
            return
        }
        await perform("保存当前描述", successMessage: silent ? nil : "当前描述已更新") { client in
            let response: ThreadMutationResponse = try await client.patch(
                "/api/v1/threads/\(threadId)",
                body: ["summary": text]
            )
            upsert(thread: response.thread)
            apply(bundle: response.bundle)
        }
    }

    func saveNote(threadId: String, content: String, silent: Bool = false) async {
        await perform("保存笔记", successMessage: silent ? nil : "笔记已保存") { client in
            let response: NoteResponse = try await client.put("/api/v1/threads/\(threadId)/note", body: ["content": content])
            notes[threadId] = response.note
            noteDraft[threadId] = nil
        }
    }

    func addProgressNote(threadId: String, text: String) async {
        await perform("记录进展") { client in
            let response: LogsResponse = try await client.post("/api/v1/threads/\(threadId)/logs", body: ["text": text])
            logs[threadId] = response.logs
        }
    }

    func deleteThread(threadId: String, hard: Bool = false) async {
        await perform(hard ? "彻底删除" : "移入回收站", successMessage: hard ? "已彻底删除" : "已移入回收站") { client in
            let _: EmptyResponse = try await client.delete("/api/v1/threads/\(threadId)", query: hard ? ["hard": .string("1")] : [:])
            if hard {
                threads.removeAll { $0.id == threadId }
                items[threadId] = nil
            } else if let index = threads.firstIndex(where: { $0.id == threadId }) {
                threads[index].trashedAt = ISO8601DateFormatter.pocketFormatter.string(from: Date())
            }
        }
        if selectedThreadID == threadId { selectedThreadID = preferredInitialThread()?.id }
        await refreshOverview()
    }

    // MARK: - 事项操作

    func createItem(
        threadId: String,
        kind: ItemKind,
        title: String,
        detail: String? = nil,
        planDate: String? = nil,
        dueDate: String? = nil,
        startAt: String? = nil,
        endAt: String? = nil,
        followUpDate: String? = nil,
        blocked: Bool = false,
        blockerReason: String? = nil
    ) async {
        var body: [String: Any] = ["kind": kind.rawValue, "title": title]
        if let detail, !detail.isBlank { body["detail"] = detail }
        if let planDate { body["plan_date"] = planDate }
        if let dueDate { body["due_date"] = dueDate }
        if let startAt { body["start_at"] = startAt }
        if let endAt { body["end_at"] = endAt }
        if let followUpDate { body["follow_up_date"] = followUpDate }
        if blocked { body["blocked"] = true }
        if let blockerReason, !blockerReason.isBlank { body["blocker_reason"] = blockerReason }

        await perform("新增\(kind.label)", successMessage: "已记录：\(title)") { client in
            let response: ItemMutationResponse = try await client.post("/api/v1/threads/\(threadId)/items", body: body)
            upsert(item: response.item)
            apply(bundle: response.bundle)
        }
        await refreshOverview()
    }

    func updateItem(
        _ item: Item,
        patch: [String: Any],
        message: String? = nil,
        toast: Bool = true
    ) async {
        guard !patch.isEmpty else { return }
        await perform("更新事项", successMessage: toast ? message : nil) { client in
            let response: ItemMutationResponse = try await client.patch("/api/v1/items/\(item.id)", body: patch)
            upsert(item: response.item)
            apply(bundle: response.bundle)
        }
        await refreshOverview()
    }

    func toggle(_ item: Item) async {
        switch item.kind {
        case .task, .event:
            let next: ItemStatus = item.isOpen ? .done : .open
            await updateItem(
                item,
                patch: ["status": next.rawValue],
                message: next == .done ? "已完成：\(item.title)" : "已重新打开：\(item.title)",
                toast: next == .done
            )
        case .wait:
            let next: ItemStatus = item.isOpen ? .resolved : .open
            await updateItem(item, patch: ["status": next.rawValue], message: next == .resolved ? "等待已解除：\(item.title)" : "已重新打开")
        case .direction:
            break
        }
    }

    func cancel(_ item: Item) async {
        await updateItem(item, patch: ["status": "cancelled"], message: "已取消：\(item.title)")
    }

    func reopen(_ item: Item) async {
        await updateItem(item, patch: ["status": "open"], message: "已重新打开")
    }

    func deleteItem(_ item: Item) async {
        await perform("删除事项", successMessage: "已删除：\(item.title)") { client in
            let response: ItemMutationResponse = try await client.delete("/api/v1/items/\(item.id)")
            remove(item: item)
            apply(bundle: response.bundle)
        }
        await refreshOverview()
    }

    func convertDirection(_ item: Item, planDate: String? = nil, dueDate: String? = nil) async {
        var body: [String: Any] = [:]
        if let planDate { body["plan_date"] = planDate }
        if let dueDate { body["due_date"] = dueDate }
        await perform("转为待办", successMessage: "已转成待办：\(item.title)") { client in
            let response: ConvertResponse = try await client.post("/api/v1/items/\(item.id)/convert", body: body)
            upsert(item: response.direction)
            upsert(item: response.task)
            apply(bundle: response.bundle)
        }
        await refreshOverview()
    }

    func abandonDirection(_ item: Item) async {
        await updateItem(item, patch: ["status": "abandoned"], message: "已放弃：\(item.title)")
    }

    func moveItem(_ item: Item, toThread threadId: String) async {
        guard threadId != item.threadId else { return }
        let targetTitle = thread(threadId)?.title ?? "目标线索"
        await perform("移动事项", successMessage: "已移动到「\(targetTitle)」") { client in
            let response: MoveResponse = try await client.post("/api/v1/items/\(item.id)/move", body: ["thread_id": threadId])
            items[response.previousThreadId ?? item.threadId] = (response.from?.items.open ?? []) + (response.from?.items.closed ?? [])
            upsert(item: response.item)
            apply(bundle: response.bundle)
        }
        await refreshOverview()
    }

    // MARK: - 总览

    func refreshOverview() async {
        guard let client, connection.isOnline || unavailableReason == nil else { return }
        var base: [String: QueryValue] = [:]
        if let domainId = selectedDomainID { base["domain_id"] = .string(domainId) }
        let query = base
        var actionQuery = base
        actionQuery["dates"] = .string(dateFilter.rawValue)
        actionQuery["range"] = .string(rangeFilter.rawValue)
        let actionsQuery = actionQuery
        do {
            async let today: TodayView = client.get("/api/v1/views/today", query: query)
            async let actions: ActionsView = client.get("/api/v1/views/actions", query: actionsQuery)
            async let inbox: InboxView = client.get("/api/v1/views/inbox", query: query)
            todayView = try await today
            actionsView = try await actions
            inboxView = try await inbox
        } catch {
            // 总览失败不影响主流程
        }
    }

    func refreshOverviewDebounced() {
        Task { await refreshOverview() }
    }

    // MARK: - 搜索

    func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmed
        guard query.count >= 1 else {
            searchResults = nil
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, let self, let client = self.client else { return }
            do {
                let results: SearchResponse = try await client.get("/api/v1/search", query: ["q": .string(query)])
                guard !Task.isCancelled else { return }
                self.searchResults = results
            } catch {
                // 搜索失败保持静默
            }
        }
    }

    func clearSearch() {
        searchText = ""
        searchResults = nil
    }

    // MARK: - 键盘动作

    func quickCapture(_ title: String, kind: ItemKind = .task) async {
        let domainId = selectedDomainID ?? domains.first?.id
        guard let domainId else {
            overlay.toast("请先建立一个 Domain", tone: .warning)
            return
        }
        let inbox = threads.first { $0.domainId == domainId && $0.isInbox && !$0.isTrashed }
        if let threadId = selectedThread?.id, selectedThread?.isInbox == false {
            await createItem(threadId: threadId, kind: kind, title: title)
        } else if let inbox {
            await createItem(threadId: inbox.id, kind: kind, title: title)
        } else {
            overlay.toast("找不到可用的收集箱", tone: .failure)
        }
    }

    func isThreadInToday(_ thread: Thread) -> Bool {
        matchesScope(thread)
    }
}
