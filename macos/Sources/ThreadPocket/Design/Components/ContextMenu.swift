import AppKit
import SwiftUI

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

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RightClickCatcher { _ in overlay.dismissContextMenu() }
                    .overlay(
                        Color.black.opacity(0.0001)
                            .onTapGesture { overlay.dismissContextMenu() }
                    )

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
}
