import Foundation

// MARK: - 类型

enum ItemKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case task
    case event
    case direction
    case wait

    var id: String { rawValue }

    var label: String {
        switch self {
        case .task: "待办"
        case .event: "固定日程"
        case .direction: "探索方向"
        case .wait: "等待"
        }
    }

    var shortLabel: String {
        switch self {
        case .task: "待办"
        case .event: "日程"
        case .direction: "方向"
        case .wait: "等待"
        }
    }

    var symbol: String {
        switch self {
        case .task: "checkmark.circle"
        case .event: "calendar"
        case .direction: "sparkle.magnifyingglass"
        case .wait: "hourglass"
        }
    }

    /// 可以逐项完成、并进入今天与行动视图的类型。
    var isAction: Bool { self == .task || self == .event }
}

enum ItemStatus: String, Codable, Hashable {
    case open
    case done
    case cancelled
    case resolved
    case abandoned
    case converted

    var isClosed: Bool { self != .open }

    var label: String {
        switch self {
        case .open: "未结束"
        case .done: "已完成"
        case .cancelled: "已取消"
        case .resolved: "已解除"
        case .abandoned: "已放弃"
        case .converted: "已转为待办"
        }
    }
}

enum ThreadStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case active
    case waiting
    case paused
    case completed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .active: "进行中"
        case .waiting: "等待中"
        case .paused: "暂停"
        case .completed: "完成"
        }
    }

    var symbol: String {
        switch self {
        case .active: "circle.dashed"
        case .waiting: "hourglass"
        case .paused: "pause.circle"
        case .completed: "checkmark.seal"
        }
    }
}

// MARK: - 实体

struct Domain: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var color: String
    var icon: String?
    var position: Int
    var archived: Bool

    var symbol: String { icon ?? "square.grid.2x2" }
}

struct ThreadCounts: Codable, Hashable {
    var openTasks: Int
    var openEvents: Int
    var openDirections: Int
    var openWaits: Int
    var openBlocked: Int
    var doneItems: Int

    static let empty = ThreadCounts(
        openTasks: 0, openEvents: 0, openDirections: 0, openWaits: 0, openBlocked: 0, doneItems: 0
    )

    var openItems: Int { openTasks + openEvents + openDirections + openWaits }
}

struct Thread: Identifiable, Codable, Hashable {
    var id: String
    var domainId: String
    var title: String
    var summary: String
    var status: ThreadStatus
    var isInbox: Bool
    var position: Int
    var archived: Bool
    var archivedAt: String?
    var trashedAt: String?
    var pinnedAt: String?
    var createdAt: String
    var updatedAt: String
    var counts: ThreadCounts?

    var countsOrEmpty: ThreadCounts { counts ?? .empty }
    var isTrashed: Bool { trashedAt != nil }
    var isPinned: Bool { pinnedAt != nil }
}

struct Item: Identifiable, Codable, Hashable {
    var id: String
    var threadId: String
    var kind: ItemKind
    var title: String
    var status: ItemStatus
    var detail: String?
    var planDate: String?
    var dueDate: String?
    var startAt: String?
    var endAt: String?
    var followUpDate: String?
    var blocked: Bool
    var blockerReason: String?
    var sourceId: String?
    var position: Int
    var createdAt: String
    var updatedAt: String
    var closedAt: String?

    var isOpen: Bool { status == .open }

    /// 用于列表展示的时间标签。
    func timeBadge(today: String = DayKey.today) -> (text: String, tone: TimeTone)? {
        switch kind {
        case .task:
            if let due = dueDate {
                let tone: TimeTone = due < today ? .overdue : (due == today ? .today : .neutral)
                return (due == today ? "今天到期" : "截止 \(DayKey.humanize(due))", tone)
            }
            if let plan = planDate {
                let tone: TimeTone = plan < today ? .reschedule : (plan == today ? .today : .neutral)
                return (plan == today ? "今天计划" : "计划 \(DayKey.humanize(plan))", tone)
            }
            return ("无时间", .muted)
        case .event:
            guard let start = startAt else { return (planDate.map { "计划 \(DayKey.humanize($0))" } ?? "无时间", .muted) }
            let day = DayKey.fromIso(start)
            let tone: TimeTone = day < today ? .overdue : (day == today ? .today : .neutral)
            return ("\(DayKey.humanize(day)) \(DayKey.clock(start))", tone)
        case .wait:
            guard let follow = followUpDate else { return ("未设跟进", .muted) }
            let tone: TimeTone = follow <= today ? .today : .neutral
            return (follow <= today ? "待跟进" : "跟进 \(DayKey.humanize(follow))", tone)
        case .direction:
            return nil
        }
    }
}

enum TimeTone {
    case muted
    case neutral
    case today
    case overdue
    case reschedule
}

struct Note: Codable, Hashable {
    var threadId: String?
    var content: String
    var updatedAt: String?

    static let empty = Note(threadId: nil, content: "", updatedAt: nil)
}

struct LogEntry: Identifiable, Codable, Hashable {
    var id: String
    var threadId: String
    var kind: String
    var action: String
    var text: String
    var meta: [String: JSONValue]?
    var actor: String
    var createdAt: String

    var isProgress: Bool { kind == "progress" }
}

enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

// MARK: - 组合结构

struct Snapshot: Codable {
    var domains: [Domain]
    var threads: [Thread]
    var items: [Item]
    var notes: [Note]
    var logs: [LogEntry]
    var serverTime: String
}

struct ThreadItemGroups: Codable {
    var open: [Item]
    var closed: [Item]
}

struct ThreadBundle: Codable {
    var thread: Thread
    var items: ThreadItemGroups
    var note: Note
    var logs: [LogEntry]
}

struct ThreadRef: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var domainId: String
    var status: ThreadStatus?
    var isInbox: Bool?

    var isInboxOrFalse: Bool { isInbox ?? false }
}

struct TodayEntry: Codable, Hashable {
    var item: Item
    var thread: ThreadRef?
}

struct TodayGroup: Codable, Identifiable, Hashable {
    var key: String
    var title: String
    var count: Int
    var entries: [TodayEntry]

    var id: String { key }
}

struct TodayView: Codable {
    var today: String
    var groups: [TodayGroup]
    var totals: [String: Int]
}

struct ThreadActionsGroup: Codable, Identifiable, Hashable {
    var thread: ThreadRef
    var items: [Item]

    var id: String { thread.id }
}

struct ActionsView: Codable {
    var today: String
    var horizonEnd: String
    var groups: [ThreadActionsGroup]
    var total: Int
}

struct InboxGroup: Codable, Identifiable, Hashable {
    var thread: ThreadRef
    var domain: Domain?
    var items: [Item]

    var id: String { thread.id }
}

struct InboxView: Codable {
    var groups: [InboxGroup]
    var total: Int
}

struct SearchResponse: Codable {
    var q: String
    var threads: [Thread]
    var items: [Item]
}

struct ItemMutationResponse: Codable {
    var item: Item
    var bundle: ThreadBundle?
    var previousThreadId: String?
}

struct ThreadMutationResponse: Codable {
    var thread: Thread
    var bundle: ThreadBundle?
}

struct ConvertResponse: Codable {
    var direction: Item
    var task: Item
    var threadId: String
    var bundle: ThreadBundle?
}

struct MoveResponse: Codable {
    var item: Item
    var from: ThreadBundle?
    var bundle: ThreadBundle?
    var previousThreadId: String?
}

struct ThreadOrderResponse: Codable {
    var threads: [Thread]
}

struct ItemReorderResponse: Codable {
    var items: [Item]
    var bundle: ThreadBundle?
}

struct LogsResponse: Codable {
    var logs: [LogEntry]
}

struct NoteResponse: Codable {
    var note: Note
}

struct HealthResponse: Codable {
    var status: String
    var service: String
    var serverTime: String
}

struct ServerErrorEnvelope: Codable {
    struct Payload: Codable {
        var code: String
        var message: String
    }
    var error: Payload
}

// MARK: - 日期工具

enum DayKey {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hans_CN")
        calendar.firstWeekday = 1
        return calendar
    }

    static var today: String { key(from: Date()) }

    static func key(from date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func date(from key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func fromIso(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter.parse(iso) else { return String(iso.prefix(10)) }
        return key(from: date)
    }

    static func clock(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter.parse(iso) else { return "" }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    static func add(days: Int, to key: String? = nil) -> String {
        let base = date(from: key ?? today) ?? Date()
        let shifted = calendar.date(byAdding: .day, value: days, to: base) ?? base
        return self.key(from: shifted)
    }

    /// 周末：最近的那个周六；今天就是周六时返回今天。
    static var weekend: String {
        var candidate = today
        for _ in 0..<8 {
            if let date = date(from: candidate), calendar.component(.weekday, from: date) == 7 {
                return candidate
            }
            candidate = add(days: 1, to: candidate)
        }
        return add(days: 6)
    }

    static func iso(key: String, hour: Int = 9, minute: Int = 0) -> String {
        guard let day = date(from: key) else { return "" }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let combined = calendar.date(
            from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: hour, minute: minute)
        ) ?? day
        return ISO8601DateFormatter.pocketFormatter.string(from: combined)
    }

    static func hourMinute(fromIso iso: String?) -> (hour: Int, minute: Int) {
        guard let iso, let date = ISO8601DateFormatter.parse(iso) else { return (9, 0) }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 9, parts.minute ?? 0)
    }

    static func dayOffset(_ key: String, from reference: String = today) -> Int? {
        guard let a = date(from: key), let b = date(from: reference) else { return nil }
        return calendar.dateComponents([.day], from: b, to: a).day
    }

    static func humanize(_ key: String) -> String {
        guard let offset = dayOffset(key) else { return key }
        switch offset {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case -1: return "昨天"
        default: break
        }
        guard let date = date(from: key) else { return key }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = calendar
        if abs(offset) < 350 {
            formatter.dateFormat = "M月d日"
            let weekday = DateFormatter()
            weekday.locale = Locale(identifier: "zh_Hans_CN")
            weekday.calendar = calendar
            weekday.dateFormat = "EEE"
            return "\(formatter.string(from: date)) \(weekday.string(from: date))"
        }
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    static func relativeTime(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter.parse(iso) else { return iso }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        let absolute = DateFormatter()
        absolute.locale = Locale(identifier: "zh_Hans_CN")
        absolute.dateFormat = "M月d日 HH:mm"
        return absolute.string(from: date)
    }
}

extension ISO8601DateFormatter {
    static let pocketFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let pocketFallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        pocketFormatter.date(from: value) ?? pocketFallback.date(from: value)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
}
