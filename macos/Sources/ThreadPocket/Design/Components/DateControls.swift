import SwiftUI

/// 自定义日历面板：替代系统日期选择器，保持统一的质感与动画。
struct CalendarPanel: View {
    var selected: String?
    var allowsClear: Bool = true
    var onPick: (String?) -> Void

    @EnvironmentObject private var overlay: OverlayCenter
    @State private var month: Date = Date()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private let weekdaySymbols = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            monthLabel
            grid
            Divider().overlay(PocketTheme.stroke)
            quickActions
        }
        .padding(12)
        .frame(width: 268)
        .onAppear {
            if let selected, let date = DayKey.date(from: selected) {
                month = date
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            PocketIconButton(symbol: "chevron.left", help: "上个月", size: 22) {
                shift(months: -1)
            }
            Text(monthTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PocketTheme.textPrimary)
                .frame(minWidth: 92)
            PocketIconButton(symbol: "chevron.right", help: "下个月", size: 22) {
                shift(months: 1)
            }
            Spacer()
            PocketIconButton(symbol: "arrow.uturn.backward", help: "回到本月", size: 22) {
                withAnimation(PocketMotion.snappy) { month = Date() }
            }
        }
    }

    private var monthLabel: some View {
        HStack(spacing: 2) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PocketTheme.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 28)
                }
            }
        }
    }

    private func dayCell(_ key: String) -> some View {
        let isSelected = key == selected
        let isToday = key == DayKey.today
        let number = Int(key.suffix(2)) ?? 0
        return Button {
            onPick(key)
            overlay.dismissContextMenu()
        } label: {
            Text("\(number)")
                .font(.system(size: 12, weight: isSelected ? .bold : (isToday ? .semibold : .regular)))
                .foregroundStyle(isSelected ? PocketTheme.canvasBottom : (isToday ? PocketTheme.accent : PocketTheme.textPrimary))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? PocketTheme.accent : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isToday && !isSelected ? PocketTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(SoftHoverButtonStyle())
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 1) {
            ContextMenuItem(label: "今天", symbol: "sun.max") { pick(DayKey.today) }
            ContextMenuItem(label: "明天", symbol: "sunrise") { pick(DayKey.add(days: 1)) }
            ContextMenuItem(label: "下周同一天", symbol: "calendar.badge.plus") { pick(DayKey.add(days: 7)) }
            ContextMenuItem(label: "周末", symbol: "beach.umbrella") { pick(nextWeekend()) }
            if allowsClear {
                ContextDivider()
                ContextMenuItem(label: "清除日期", symbol: "xmark.circle", isDestructive: true) {
                    onPick(nil)
                    overlay.dismissContextMenu()
                }
            }
        }
    }

    private func pick(_ key: String) {
        onPick(key)
        overlay.dismissContextMenu()
    }

    private func nextWeekend() -> String {
        var candidate = DayKey.today
        for _ in 0..<14 {
            if let date = DayKey.date(from: candidate) {
                let weekday = DayKey.calendar.component(.weekday, from: date)
                if weekday == 7 { return candidate }
            }
            candidate = DayKey.add(days: 1, to: candidate)
        }
        return DayKey.add(days: 6)
    }

    private func shift(months: Int) {
        withAnimation(PocketMotion.snappy) {
            month = DayKey.calendar.date(byAdding: .month, value: months, to: month) ?? month
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: month)
    }

    private var days: [String?] {
        let calendar = DayKey.calendar
        let components = calendar.dateComponents([.year, .month], from: month)
        guard let first = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)) else {
            return []
        }
        let range = calendar.range(of: .day, in: .month, for: first) ?? 1..<29
        // 周一为一周起点
        let weekday = calendar.component(.weekday, from: first) // 1 = Sunday
        let leading = (weekday + 5) % 7
        var cells: [String?] = Array(repeating: nil, count: leading)
        for day in range {
            cells.append(String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, day))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
}

struct SoftHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? PocketTheme.surfaceStrong : Color.clear)
            )
    }
}

/// 时间选择面板：以 30 分钟为刻度。
struct TimePanel: View {
    var hour: Int
    var minute: Int
    var onPick: (Int, Int) -> Void

    @EnvironmentObject private var overlay: OverlayCenter
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择时间")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PocketTheme.textSecondary)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(0..<48, id: \.self) { slot in
                        let slotHour = slot / 2
                        let slotMinute = (slot % 2) * 30
                        let isActive = slotHour == hour && slotMinute == minute
                        Button {
                            onPick(slotHour, slotMinute)
                            overlay.dismissContextMenu()
                        } label: {
                            Text(String(format: "%02d:%02d", slotHour, slotMinute))
                                .font(.system(size: 12, weight: isActive ? .bold : .medium))
                                .foregroundStyle(isActive ? PocketTheme.canvasBottom : PocketTheme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isActive ? PocketTheme.accent : PocketTheme.surface)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 210)
        }
        .padding(12)
        .frame(width: 230)
    }
}

/// 日期字段：以 chip 呈现，点开自定义日历。
struct PocketDateField: View {
    var label: String
    var symbol: String
    var value: String?
    var tint: Color = PocketTheme.textSecondary
    var allowsClear: Bool = true
    var onPick: (String?) -> Void

    var body: some View {
        PocketMenuButton {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(value.map { "\(label) \(DayKey.humanize($0))" } ?? label)
                    .font(.system(size: 12, weight: value == nil ? .medium : .semibold))
            }
            .foregroundStyle(value == nil ? PocketTheme.textTertiary : PocketTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(value == nil ? PocketTheme.surface : tint.opacity(0.18))
            )
            .overlay(
                Capsule().strokeBorder(value == nil ? PocketTheme.stroke : tint.opacity(0.4), lineWidth: 1)
            )
            .contentShape(Capsule())
        } menu: {
            CalendarPanel(selected: value, allowsClear: allowsClear, onPick: onPick)
        }
    }
}

/// 时间字段：以 chip 呈现，点开自定义时间列表。
struct PocketTimeField: View {
    var label: String
    var iso: String?
    var fallbackHour: Int = 9
    var onPick: (Int, Int) -> Void

    var body: some View {
        let current = DayKey.hourMinute(fromIso: iso)
        let hour = iso == nil ? fallbackHour : current.hour
        let minute = iso == nil ? 0 : current.minute
        PocketMenuButton {
            HStack(spacing: 5) {
                Image(systemName: "clock").font(.system(size: 10.5, weight: .semibold))
                Text(iso == nil ? label : String(format: "%@ %02d:%02d", label, hour, minute))
                    .font(.system(size: 12, weight: iso == nil ? .medium : .semibold))
            }
            .foregroundStyle(iso == nil ? PocketTheme.textTertiary : PocketTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(iso == nil ? PocketTheme.surface : PocketTheme.mauve.opacity(0.18)))
            .overlay(
                Capsule().strokeBorder(iso == nil ? PocketTheme.stroke : PocketTheme.mauve.opacity(0.4), lineWidth: 1)
            )
            .contentShape(Capsule())
        } menu: {
            TimePanel(hour: hour, minute: minute, onPick: onPick)
        }
    }
}
