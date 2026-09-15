import AppKit
import SwiftUI

// MARK: - 对勾图形

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.75))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.26))
        return path
    }
}

/// 替代系统 toggle box 的自定义完成框。
struct PocketCheck: View {
    var isOn: Bool
    var isBusy: Bool = false
    var tint: Color = PocketTheme.success
    var size: CGFloat = 20
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isOn ? tint.opacity(0.92) : (isHovering ? PocketTheme.surfaceStrong : Color.clear))
                Circle()
                    .strokeBorder(isOn ? tint : PocketTheme.strokeStrong, lineWidth: isOn ? 1 : 1.5)
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                } else if isOn {
                    CheckmarkShape()
                        .stroke(
                            PocketTheme.canvasBottom.opacity(0.9),
                            style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round, lineJoin: .round)
                        )
                        .padding(size * 0.22)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(isHovering ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(PocketMotion.quick) { isHovering = hovering }
        }
        .animation(PocketMotion.snappy, value: isOn)
        .help(isOn ? "标记为未完成" : "标记为已完成")
    }
}

// MARK: - 分段控件

struct PocketSegmentedOption<Value: Hashable>: Identifiable {
    var value: Value
    var label: String
    var symbol: String?
    var badge: Int?

    var id: Value { value }

    init(_ value: Value, label: String, symbol: String? = nil, badge: Int? = nil) {
        self.value = value
        self.label = label
        self.symbol = symbol
        self.badge = badge
    }
}

/// 带滑动高亮的分段控件。
struct PocketSegmented<Value: Hashable>: View {
    var options: [PocketSegmentedOption<Value>]
    @Binding var selection: Value
    var compact: Bool = false
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isActive = option.value == selection
                Button {
                    guard !isActive else { return }
                    withAnimation(PocketMotion.snappy) { selection = option.value }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                        }
                        Text(option.label)
                            .font(.system(size: compact ? 11.5 : 12.5, weight: isActive ? .semibold : .medium))
                        if let badge = option.badge, badge > 0 {
                            Text("\(badge)")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(isActive ? PocketTheme.accentSoft : PocketTheme.surfaceStrong)
                                )
                                .foregroundStyle(isActive ? PocketTheme.textPrimary : PocketTheme.textSecondary)
                        }
                    }
                    .foregroundStyle(isActive ? PocketTheme.textPrimary : PocketTheme.textSecondary)
                    .padding(.horizontal, compact ? 9 : 12)
                    .padding(.vertical, compact ? 5 : 6.5)
                    .background {
                        if isActive {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(PocketTheme.surfaceStrong)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(PocketTheme.strokeStrong, lineWidth: 1)
                                }
                                .matchedGeometryEffect(id: "segmented.active", in: namespace)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PocketTheme.stroke, lineWidth: 1)
        )
    }
}

// MARK: - 按钮

enum PocketButtonStyleKind {
    case primary
    case secondary
    case ghost
    case danger
}

struct PocketButton: View {
    var label: String
    var symbol: String?
    var kind: PocketButtonStyleKind = .secondary
    var isEnabled: Bool = true
    var action: () -> Void

    @State private var isHovering = false

    private var foreground: Color {
        switch kind {
        case .primary: PocketTheme.canvasBottom.opacity(0.95)
        case .secondary: PocketTheme.textPrimary
        case .ghost: PocketTheme.textSecondary
        case .danger: PocketTheme.danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary: isHovering ? PocketTheme.accent.opacity(0.92) : PocketTheme.accent
        case .secondary: isHovering ? PocketTheme.surfaceStrong : PocketTheme.surface
        case .ghost: isHovering ? PocketTheme.surface : Color.clear
        case .danger: isHovering ? PocketTheme.danger.opacity(0.16) : Color.clear
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                }
                Text(label).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(isEnabled ? foreground : PocketTheme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isEnabled ? background : PocketTheme.surface.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(kind == .primary ? Color.clear : PocketTheme.stroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .scaleEffect(isHovering && isEnabled ? 1.015 : 1)
        .onHover { hovering in
            withAnimation(PocketMotion.quick) { isHovering = hovering }
        }
    }
}

struct PocketIconButton: View {
    var symbol: String
    var help: String
    var tint: Color = PocketTheme.textSecondary
    var size: CGFloat = 26
    var isActive: Bool = false
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isActive ? PocketTheme.textPrimary : (isHovering ? PocketTheme.textPrimary : tint))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? PocketTheme.surfaceStrong : (isHovering ? PocketTheme.surface : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(PocketMotion.quick) { isHovering = hovering }
        }
        .help(help)
    }
}

// MARK: - 标签

struct PocketChip: View {
    var label: String
    var symbol: String?
    var tint: Color = PocketTheme.accent
    var isActive: Bool = false
    var interactive: Bool = true
    var action: (() -> Void)?

    @State private var isHovering = false

    private var foreground: Color {
        isActive ? PocketTheme.textPrimary : (isHovering && interactive ? PocketTheme.textPrimary : PocketTheme.textSecondary)
    }

    var body: some View {
        let content = HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            }
            Text(label).font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(isActive ? tint.opacity(0.22) : (isHovering && interactive ? PocketTheme.surfaceStrong : PocketTheme.surface))
        )
        .overlay(
            Capsule().strokeBorder(isActive ? tint.opacity(0.55) : PocketTheme.stroke, lineWidth: 1)
        )
        .contentShape(Capsule())

        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .onHover { hovering in withAnimation(PocketMotion.quick) { isHovering = hovering } }
            } else {
                content
            }
        }
    }
}

/// 只用于展示的弱提示标签（时间、状态等）。
struct PocketTag: View {
    var label: String
    var symbol: String?
    var tint: Color = PocketTheme.textTertiary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            }
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

// MARK: - 文本输入

struct PocketField: View {
    var placeholder: String
    @Binding var text: String
    var symbol: String?
    var onSubmit: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(PocketTheme.textTertiary)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(PocketTheme.textPrimary)
                .focused($isFocused)
                .onSubmit { onSubmit?() }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7.5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFocused ? PocketTheme.surfaceStrong : PocketTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocused ? PocketTheme.accent.opacity(0.6) : PocketTheme.stroke, lineWidth: 1)
        )
        .animation(PocketMotion.quick, value: isFocused)
    }
}

/// 带占位与自定义右键菜单的多行编辑器。
struct PocketTextArea: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat = 90
    var onCommit: (() -> Void)?

    @FocusState private var isFocused: Bool
    @EnvironmentObject private var overlay: OverlayCenter

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(PocketTheme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .foregroundStyle(PocketTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .focused($isFocused)
        }
        .frame(minHeight: minHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? PocketTheme.surfaceStrong : PocketTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? PocketTheme.accent.opacity(0.6) : PocketTheme.stroke, lineWidth: 1)
        )
        .animation(PocketMotion.quick, value: isFocused)
        .pocketContextMenu(onOpen: { isFocused = true }) {
            VStack(alignment: .leading, spacing: 1) {
                ContextMenuItem(label: "剪切", symbol: "scissors") { TextEditing.cut() }
                ContextMenuItem(label: "复制", symbol: "doc.on.doc") { TextEditing.copy() }
                ContextMenuItem(label: "粘贴", symbol: "doc.on.clipboard") { TextEditing.paste() }
                ContextDivider()
                ContextMenuItem(label: "全选", symbol: "selection.pin.in.out") { TextEditing.selectAll() }
                ContextMenuItem(label: "插入当前时间", symbol: "clock") {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "zh_Hans_CN")
                    formatter.dateFormat = "M月d日 HH:mm"
                    text += (text.isEmpty ? "" : "\n") + "—— \(formatter.string(from: Date()))\n"
                }
                if let onCommit {
                    ContextDivider()
                    ContextMenuItem(label: "保存并收起", symbol: "checkmark", isAccent: true) { onCommit() }
                }
            }
        }
    }
}

enum TextEditing {
    static func cut() { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
    static func copy() { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
    static func paste() { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
    static func selectAll() { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
}
