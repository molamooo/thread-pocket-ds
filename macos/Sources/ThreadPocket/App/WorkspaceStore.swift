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
    @Published private(set) var authState: AuthState = .unknown
    @Published private(set) var isSigningIn = false

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

    enum AuthState: Equatable {
        case unknown
        case open
        case signedIn(account: String?, backend: CredentialStore.Backend)
        case signedOut
        case expired(String)

        var label: String {
            switch self {
            case .unknown: "未检测"
            case .open: "无需登录"
            case .signedIn(let account, _): account ?? "已登录"
            case .signedOut: "未登录"
            case .expired: "登录已失效"
            }
        }

        var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    let settings: AppSettings
    let overlay: OverlayCenter
    let oauth = OAuthClient()
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

    var serverOrigin: String? {
        settings.normalizedURL.map { OAuthClient.origin(of: $0) }
    }

    // MARK: - 登录状态

    /// 桌面端优先使用 OAuth 令牌；没有登录时退回手动填写的静态密钥。
    private var credential: CredentialStore.StoredCredential? {
        guard let origin = serverOrigin else { return nil }
        return oauth.cached(for: origin)
    }

    private var effectiveToken: String? {
        if let credential { return credential.accessToken }
        let manual = settings.token.trimmed
        return manual.isEmpty ? nil : manual
    }

    func refreshAuthState() {
        if credential != nil {
            authState = .signedIn(account: credential?.account, backend: credential?.backend ?? .file)
        } else if !settings.token.trimmed.isEmpty {
            authState = .signedIn(account: "静态令牌", backend: .file)
        }
    }

    func signIn() async {
        guard let url = settings.normalizedURL else {
            overlay.toast("请先填写有效的服务器地址", tone: .warning)
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let credential = try await oauth.signIn(baseURL: url)
            authState = .signedIn(account: credential.account, backend: credential.backend)
            overlay.toast(
                "已登录\(credential.account.map { "：\($0)" } ?? "")",
                tone: .success,
                detail: credential.backend == .keychain ? "令牌存放在钥匙串" : "钥匙串不可用，令牌暂存在本机加密文件"
            )
            await connect()
        } catch {
            authState = .signedOut
            overlay.toast("登录失败", tone: .failure, detail: error.localizedDescription)
        }
    }

    func signOut() {
        if let origin = serverOrigin { oauth.signOut(for: origin) }
        authState = .signedOut
        overlay.toast("已退出登录", tone: .neutral)
        Task { await connect() }
    }

    /// 令牌快过期就先刷新；服务端返回 invalid_token 时刷新并重试一次。
    private func refreshCredentialIfNeeded(force: Bool = false) async throws {
        guard let origin = serverOrigin, var current = credential else { return }
        let expiring = current.expiresAt.timeIntervalSinceNow < 90
        guard force || expiring else { return }
        current = try await oauth.refresh(current, origin: origin)
        authState = .signedIn(account: current.account, backend: current.backend)
    }

    private func withAuthorizedClient<T>(_ operation: (APIClient) async throws -> T) async throws -> T {
        guard let client else { throw APIError.badURL(settings.serverURL) }
        try? await refreshCredentialIfNeeded()
        client.token = effectiveToken
        do {
            return try await operation(client)
        } catch let error as APIError {
            guard case .server(let status, _, _) = error, status == 401 else { throw error }
            guard credential != nil else { throw error }
            do {
                try await refreshCredentialIfNeeded(force: true)
            } catch {
                authState = .expired("登录已失效，请重新登录")
                throw error
            }
            client.token = effectiveToken
            return try await operation(client)
        }
    }

    func connect(showToast: Bool = false) async {
        rebuildClient()
        guard let client else {
            connection = .offline("服务器地址无效")
            return
        }
        connection = .connecting
        refreshAuthState()
        do {
            let health: HealthResponse = try await client.get("/health")
            _ = health
            let snapshot: Snapshot = try await withAuthorizedClient { client in
                try await client.get("/api/v1/snapshot")
            }
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
            if case .server(let status, _, _) = error, status == 401 {
                authState = credential == nil ? .signedOut : .expired("登录已失效，请重新登录")
                connection = .offline("需要登录")
                unavailableReason = "需要登录后才能读取你的线索。"
                if showToast {
                    overlay.toast(
                        "需要登录",
                        tone: .warning,
                        detail: "这个部署开启了鉴权。点右侧按钮用浏览器登录，或在连接设置里填写访问令牌。",
                        actionLabel: "登录",
                        action: { [weak self] in Task { await self?.signIn() } }
                    )
                }
                return
            }
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
        guard client != nil, connection.isOnline, inFlight == 0 else { return }
        do {
            let snapshot: Snapshot = try await withAuthorizedClient { client in
                try await client.get("/api/v1/snapshot")
            }
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
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                if lhs.isInbox != rhs.isInbox { return !lhs.isInbox }
                if lhs.position != rhs.position { return lhs.position < rhs.position }
                return lhs.createdAt < rhs.createdAt
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
        guard client != nil else {
            overlay.toast("还没有可用的服务器地址", tone: .failure, detail: "在设置里填写后端 URL 后重试。")
            return
        }
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            try await withAuthorizedClient { client in try await operation(client) }
            if let successMessage {
                overlay.toast(successMessage, tone: .success)
            }
            if !connection.isOnline { connection = .online(Date()) }
        } catch let error as APIError {
            if case .server(let status, _, _) = error, status == 401 {
                authState = credential == nil ? .signedOut : .expired("登录已失效，请重新登录")
                overlay.toast(
                    "需要登录",
                    tone: .warning,
                    detail: "访问令牌无效或已过期。",
                    actionLabel: "登录",
                    action: { [weak self] in Task { await self?.signIn() } }
                )
                return
            }
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

    func togglePin(_ thread: Thread) async {
        let next = !thread.isPinned
        await perform(next ? "置顶线索" : "取消置顶", successMessage: next ? "已置顶「\(thread.title)」" : "已取消置顶") { client in
            let response: ThreadMutationResponse = try await client.patch(
                "/api/v1/threads/\(thread.id)",
                body: ["pinned": next]
            )
            upsert(thread: response.thread)
        }
    }

    // MARK: - 拖动排序

    /// 拖动的范围：线索列表或某条线索内的条目。
    enum DragScope: Equatable {
        case threads
        case items(threadId: String)
    }

    private struct DragState {
        var scope: DragScope
        var id: String
        var order: [String]
        var original: [String]
    }

    @Published private(set) var draggingId: String?
    private var dragState: DragState?

    /// 线索列表里可以和这条线索互相换位的那一段（同一条置顶分组、都不在收件箱）。
    func draggableThreadOrder(for thread: Thread) -> [String] {
        visibleThreads
            .filter { !$0.isInbox && $0.isPinned == thread.isPinned }
            .map(\.id)
    }

    func beginDrag(id: String, scope: DragScope, order: [String]) {
        guard order.count > 1, order.contains(id) else { return }
        dragState = DragState(scope: scope, id: id, order: order, original: order)
        draggingId = id
    }

    /// 拖过某个条目时先在本地换位；松手时才写回服务端。
    func dragOver(_ targetId: String) {
        guard var state = dragState, targetId != state.id else { return }
        guard let from = state.order.firstIndex(of: state.id),
              let to = state.order.firstIndex(of: targetId) else { return }
        var order = state.order
        let moving = order.remove(at: from)
        order.insert(moving, at: to)
        guard order != state.order else { return }
        state.order = order
        dragState = state
        withAnimation(PocketMotion.quick) { applyOrder(order, scope: state.scope) }
    }

    func endDrag() async {
        guard let state = dragState else { return }
        dragState = nil
        draggingId = nil
        guard state.order != state.original else { return }
        switch state.scope {
        case .threads:
            await perform("调整顺序") { client in
                let response: ThreadOrderResponse = try await client.post(
                    "/api/v1/threads/reorder",
                    body: ["ids": state.order]
                )
                for thread in response.threads { upsert(thread: thread) }
            }
        case .items(let threadId):
            await perform("调整顺序") { client in
                let response: ItemReorderResponse = try await client.post(
                    "/api/v1/items/reorder",
                    body: ["thread_id": threadId, "ids": state.order]
                )
                for item in response.items { upsert(item: item) }
                apply(bundle: response.bundle)
            }
        }
    }

    func cancelDrag() {
        guard let state = dragState else { return }
        applyOrder(state.original, scope: state.scope)
        dragState = nil
        draggingId = nil
    }

    /**
     把 order 里的条目按这个顺序放回它们原先占据的位置槽，其他内容不受影响。
     服务端用同一套规则，因此本地预览和落库结果一致。
     */
    private func applyOrder(_ order: [String], scope: DragScope) {
        switch scope {
        case .threads:
            let slots = order.compactMap { id in threads.first { $0.id == id }?.position }.sorted()
            guard slots.count == order.count else { return }
            for (index, id) in order.enumerated() {
                guard let i = threads.firstIndex(where: { $0.id == id }) else { continue }
                threads[i].position = slots[index]
            }
        case .items(let threadId):
            guard var list = items[threadId] else { return }
            let slots = order.compactMap { id in list.first { $0.id == id }?.position }.sorted()
            guard slots.count == order.count else { return }
            for (index, id) in order.enumerated() {
                guard let i = list.firstIndex(where: { $0.id == id }) else { continue }
                list[i].position = slots[index]
            }
            items[threadId] = list.sorted { $0.position < $1.position }
        }
    }

    // MARK: - Domain 操作

    func deleteDomain(_ domain: Domain) async {
        await perform("删除领域", successMessage: "已删除「\(domain.name)」") { client in
            let _: EmptyResponse = try await client.delete("/api/v1/domains/\(domain.id)")
            if self.selectedDomainID == domain.id { self.selectedDomainID = nil }
        }
        await connect()
    }

    func saveDomain(_ domain: Domain?, name: String, color: String) async {
        await perform(domain == nil ? "新建领域" : "更新领域", successMessage: domain == nil ? "已建立「\(name)」" : "已更新「\(name)」") { client in
            if let domain {
                let _: DomainMutationResponse = try await client.patch(
                    "/api/v1/domains/\(domain.id)",
                    body: ["name": name, "color": color]
                )
            } else {
                let _: DomainMutationResponse = try await client.post(
                    "/api/v1/domains",
                    body: ["name": name, "color": color]
                )
            }
        }
        await connect()
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
        guard client != nil, connection.isOnline || unavailableReason == nil else { return }
        var base: [String: QueryValue] = [:]
        if let domainId = selectedDomainID { base["domain_id"] = .string(domainId) }
        let query = base
        var actionQuery = base
        actionQuery["dates"] = .string(dateFilter.rawValue)
        actionQuery["range"] = .string(rangeFilter.rawValue)
        let actionsQuery = actionQuery
        do {
            async let today: TodayView = withAuthorizedClient { try await $0.get("/api/v1/views/today", query: query) }
            async let actions: ActionsView = withAuthorizedClient { try await $0.get("/api/v1/views/actions", query: actionsQuery) }
            async let inbox: InboxView = withAuthorizedClient { try await $0.get("/api/v1/views/inbox", query: query) }
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
            guard !Task.isCancelled, let self, self.client != nil else { return }
            do {
                let results: SearchResponse = try await self.withAuthorizedClient { client in
                    try await client.get("/api/v1/search", query: ["q": .string(query)])
                }
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
