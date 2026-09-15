import AppKit
import SwiftUI

/// 菜单层级：基础菜单是 0，逐级子菜单依次 +1。用于决定悬停时该收起哪一层。
private struct ContextMenuLevelKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var contextMenuLevel: Int {
        get { self[ContextMenuLevelKey.self] }
        set { self[ContextMenuLevelKey.self] = newValue }
    }
}

// MARK: - 右键事件捕获

/// 捕获右键（含 Control + 左键），把点击位置换算到窗口左上角坐标系。
struct RightClickCatcher: NSViewRepresentable {
    var onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handler = onRightClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.handler = onRightClick
    }

    final class CatcherView: NSView {
        var handler: ((CGPoint) -> Void)?

        override var isFlipped: Bool { true }

        /// 只有右键才参与命中测试，左键继续交给下方的 SwiftUI 内容。
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            case .leftMouseDown where event.modifierFlags.contains(.control):
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let window else { return }
            let inWindow = event.locationInWindow
            let height = window.contentView?.bounds.height ?? window.frame.height
            handler?(CGPoint(x: inWindow.x, y: height - inWindow.y))
        }
    }
}

extension View {
    /// 自定义右键菜单：完全由应用绘制，不使用系统菜单。
    func pocketContextMenu<MenuContent: View>(
        onOpen: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> MenuContent
    ) -> some View {
        modifier(PocketContextMenuModifier(onOpen: onOpen, menu: content))
    }
}

struct PocketContextMenuModifier<MenuContent: View>: ViewModifier {
    @EnvironmentObject private var overlay: OverlayCenter
    var onOpen: (() -> Void)?
    var menu: () -> MenuContent

    func body(content: Content) -> some View {
        content.overlay(
            RightClickCatcher { point in
                onOpen?()
                overlay.showContextMenu(at: point) { menu() }
            }
        )
    }
}

// MARK: - 菜单内容

struct ContextMenuItem: View {
    var label: String
    var symbol: String?
    var shortcut: String?
    var tint: Color = PocketTheme.textPrimary
    var isAccent: Bool = false
    var isDestructive: Bool = false
    var isDisabled: Bool = false
    var hasSubmenu: Bool = false
    var action: () -> Void

    @EnvironmentObject private var overlay: OverlayCenter
    @Environment(\.contextMenuLevel) private var level
    @State private var isHovering = false

    var body: some View {
        Button {
            guard !isDisabled else { return }
            overlay.dismissContextMenu()
            action()
        } label: {
            HStack(spacing: 9) {
                Group {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16)

                Text(label)
                    .font(.system(size: 12.5, weight: isAccent ? .semibold : .regular))
                Spacer(minLength: 18)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(PocketTheme.textTertiary)
                }
                if hasSubmenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(PocketTheme.textTertiary)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 6.5)
            .frame(minWidth: 168, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering && !isDisabled ? PocketTheme.surfaceStrong : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            withAnimation(PocketMotion.quick) { isHovering = hovering }
            // 移到普通项上时，收起它右边已经展开的子菜单
            if hovering { overlay.clearSubmenus(from: level + 1) }
        }
    }

    private var foreground: Color {
        if isDisabled { return PocketTheme.textTertiary.opacity(0.6) }
        if isDestructive { return PocketTheme.danger }
        if isAccent { return PocketTheme.accent }
        return tint
    }
}

struct ContextDivider: View {
    var body: some View {
        Rectangle()
            .fill(PocketTheme.stroke)
            .frame(height: 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }
}

/// 带下一级菜单的项：悬停时在右侧展开。
struct ContextMenuSubmenuRow<Content: View>: View {
    var label: String
    var symbol: String?
    var detail: String?
    var isDisabled: Bool = false
    @ViewBuilder var submenu: () -> Content

    @EnvironmentObject private var overlay: OverlayCenter
    @Environment(\.contextMenuLevel) private var level
    @State private var isHovering = false
    @State private var anchor: CGRect = .zero

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                } else {
                    Color.clear
                }
            }
            .frame(width: 16)

            Text(label)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 18)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(PocketTheme.textTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(PocketTheme.textTertiary)
        }
        .foregroundStyle(isDisabled ? PocketTheme.textTertiary.opacity(0.6) : PocketTheme.textPrimary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6.5)
        .frame(minWidth: 168, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering && !isDisabled ? PocketTheme.surfaceStrong : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: FramePreferenceKey.self, value: proxy.frame(in: .global))
            }
        )
        .onPreferenceChange(FramePreferenceKey.self) { value in
            if value != .zero { anchor = value }
        }
        .onHover { hovering in
            withAnimation(PocketMotion.quick) { isHovering = hovering }
            guard hovering else { return }
            if isDisabled || anchor == .zero {
                overlay.clearSubmenus(from: level + 1)
            } else {
                overlay.showSubmenu(level: level + 1, anchor: anchor) { submenu() }
            }
        }
        .onTapGesture {
            guard !isDisabled, anchor != .zero else { return }
            if overlay.submenus.contains(where: { $0.level == level + 1 && $0.anchor.equalTo(anchor) }) {
                overlay.clearSubmenus(from: level + 1)
            } else {
                overlay.showSubmenu(level: level + 1, anchor: anchor) { submenu() }
            }
        }
    }
}

/// 每级子菜单的浮层：贴住触发它的那一行的右侧，空间不够时翻到左边。
struct ContextSubmenuPanel: View {
    var state: SubmenuState
    /// 浮层原点在窗口坐标系里的位置：用来把锚点换算到浮层坐标系。
    var layerOrigin: CGPoint
    var bounds: CGSize

    @State private var size: CGSize = .zero

    var body: some View {
        state.content
            .padding(5)
            .fixedSize()
            .background(
                GeometryReader { inner in
                    Color.clear.onAppear { size = inner.size }
                        .onChange(of: inner.size) { _, newValue in size = newValue }
                }
            )
            .glassPanel(radius: 14, fill: Color.black.opacity(0.35))
            .shadow(color: .black.opacity(0.45), radius: 26, y: 14)
            .scaleEffect(size == .zero ? 0.96 : 1, anchor: .topLeading)
            .opacity(size == .zero ? 0 : 1)
            .offset(x: origin.x, y: origin.y)
            .environment(\.contextMenuLevel, state.level)
    }

    private var origin: CGPoint {
        let gap: CGFloat = 5
        let edge: CGFloat = 12
        let anchorMinX = state.anchor.minX - layerOrigin.x
        let anchorMaxX = state.anchor.maxX - layerOrigin.x
        let anchorY = state.anchor.minY - layerOrigin.y
        var x = anchorMaxX + gap
        if size != .zero, x + size.width > bounds.width - edge {
            x = max(edge, anchorMinX - size.width - gap)
        }
        let maxY = max(edge, bounds.height - size.height - edge)
        let y = min(max(anchorY - 6, edge), maxY)
        return CGPoint(x: x, y: y)
    }
}

/// 右键菜单顶部的横向快捷时间：今天 / 明天 / 周末 / 清空。
struct ContextQuickTimes: View {
    var current: String?
    var clearLabel: String = "清空"
    var onPick: (String?) -> Void

    @EnvironmentObject private var overlay: OverlayCenter

    var body: some View {
        HStack(spacing: 5) {
            chip("今天", key: DayKey.today, symbol: "sun.max")
            chip("明天", key: DayKey.add(days: 1), symbol: "sunrise")
            chip("周末", key: DayKey.weekend, symbol: "beach.umbrella")
            clearChip
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    private func chip(_ label: String, key: String, symbol: String) -> some View {
        let isActive = current == key
        return Button {
            overlay.dismissContextMenu()
            onPick(key)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .bold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isActive ? PocketTheme.canvasBottom : PocketTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(isActive ? PocketTheme.accent : PocketTheme.surfaceStrong))
            .overlay(Capsule().strokeBorder(isActive ? Color.clear : PocketTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("设为\(label)")
    }

    private var clearChip: some View {
        let enabled = current != nil
        return Button {
            guard enabled else { return }
            overlay.dismissContextMenu()
            onPick(nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 9.5, weight: .bold))
                Text(clearLabel)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(enabled ? PocketTheme.textSecondary : PocketTheme.textTertiary.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(enabled ? PocketTheme.surface : Color.clear))
            .overlay(Capsule().strokeBorder(enabled ? PocketTheme.stroke : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("清除日期")
    }
}

// MARK: - 浮层

final class FramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 左键触发的自定义弹出菜单。
struct PocketMenuButton<Label: View, MenuContent: View>: View {
    @ViewBuilder var label: () -> Label
    @ViewBuilder var menu: () -> MenuContent
    var alignLeading: Bool = true
    var gap: CGFloat = 6

    init(
        alignLeading: Bool = true,
        gap: CGFloat = 6,
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.alignLeading = alignLeading
        self.gap = gap
        self.label = label
        self.menu = menu
    }

    @EnvironmentObject private var overlay: OverlayCenter
    @State private var anchor: CGRect = .zero

    var body: some View {
        label()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: FramePreferenceKey.self, value: proxy.frame(in: .global))
                }
            )
            .onPreferenceChange(FramePreferenceKey.self) { value in
                if value != .zero { anchor = value }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                let point = CGPoint(
                    x: alignLeading ? anchor.minX : anchor.maxX,
                    y: anchor.maxY + gap
                )
                overlay.showContextMenu(at: point) { menu() }
            }
    }
}

struct ContextMenuLayer: View {
    var state: ContextMenuState
    @EnvironmentObject private var overlay: OverlayCenter
    @State private var size: CGSize = .zero
    @State private var layerOrigin: CGPoint = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RightClickCatcher { _ in overlay.dismissContextMenu() }
                    .overlay(
                        Color.black.opacity(0.0001)
                            .onTapGesture { overlay.dismissContextMenu() }
                    )
                    .background(originReader)

                state.content
                    .padding(5)
                    .fixedSize()
                    .background(
                        GeometryReader { inner in
                            Color.clear.onAppear { size = inner.size }
                                .onChange(of: inner.size) { _, newValue in size = newValue }
                        }
                    )
                    .glassPanel(radius: 14, fill: Color.black.opacity(0.35))
                    .shadow(color: .black.opacity(0.45), radius: 26, y: 14)
                    .scaleEffect(size == .zero ? 0.94 : 1, anchor: .topLeading)
                    .opacity(size == .zero ? 0 : 1)
                    .offset(x: resolvedX(in: proxy.size), y: resolvedY(in: proxy.size))

                ForEach(overlay.submenus) { submenu in
                    ContextSubmenuPanel(
                        state: submenu,
                        layerOrigin: layerOrigin,
                        bounds: proxy.size
                    )
                }

                Button("") { overlay.dismissContextMenu() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
        }
    }

    private func resolvedX(in bounds: CGSize) -> CGFloat {
        let desired = state.point.x
        let limit = bounds.width - size.width - 12
        return max(12, min(desired, max(12, limit)))
    }

    private func resolvedY(in bounds: CGSize) -> CGFloat {
        let desired = state.point.y
        let limit = bounds.height - size.height - 12
        if desired <= limit { return max(12, desired) }
        // 空间不足时向上翻转
        return max(12, min(desired - size.height - 8, limit))
    }

    /// 记录这一层在窗口坐标里的原点，用来把各种锚点换算进来。
    private var originReader: some View {
        GeometryReader { inner in
            Color.clear
                .onAppear { layerOrigin = inner.frame(in: .global).origin }
                .onChange(of: inner.frame(in: .global).origin) { _, newValue in layerOrigin = newValue }
        }
    }
}
