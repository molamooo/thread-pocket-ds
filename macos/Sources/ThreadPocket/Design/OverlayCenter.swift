import SwiftUI

enum ToastTone {
    case neutral
    case success
    case warning
    case failure

    var symbol: String {
        switch self {
        case .neutral: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .failure: "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .neutral: PocketTheme.textSecondary
        case .success: PocketTheme.success
        case .warning: PocketTheme.warning
        case .failure: PocketTheme.danger
        }
    }
}

struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var tone: ToastTone = .neutral
    var detail: String?
    var actionLabel: String?
    var action: (() -> Void)?
}

struct ContextMenuState: Identifiable {
    let id = UUID()
    var point: CGPoint
    var content: AnyView
}

struct PanelState: Identifiable {
    let id = UUID()
    var content: AnyView
}

struct ConfirmState: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var primaryLabel: String
    var secondaryLabel: String?
    var tertiaryLabel: String?
    var destructive: Bool = false
    var onPrimary: () -> Void
    var onSecondary: (() -> Void)?
    var onTertiary: (() -> Void)?
}

/// 承载自定义浮层：右键菜单、弹窗、确认框与提示。
@MainActor
final class OverlayCenter: ObservableObject {
    @Published var toasts: [Toast] = []
    @Published var contextMenu: ContextMenuState?
    @Published var panel: PanelState?
    @Published var confirmState: ConfirmState?
    @Published var isPalettePresented = false

    func toast(_ message: String, tone: ToastTone = .neutral, detail: String? = nil, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        let toast = Toast(message: message, tone: tone, detail: detail, actionLabel: actionLabel, action: action)
        withAnimation(PocketMotion.snappy) {
            toasts.append(toast)
        }
        let delay = tone == .failure ? 6.0 : 2.6
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            dismiss(toast)
        }
    }

    func dismiss(_ toast: Toast) {
        withAnimation(PocketMotion.gentle) {
            toasts.removeAll { $0.id == toast.id }
        }
    }

    func showContextMenu(at point: CGPoint, @ViewBuilder content: () -> some View) {
        withAnimation(PocketMotion.pop) {
            contextMenu = ContextMenuState(point: point, content: AnyView(content()))
        }
    }

    func dismissContextMenu() {
        guard contextMenu != nil else { return }
        withAnimation(PocketMotion.quick) {
            contextMenu = nil
        }
    }

    func presentPanel<Content: View>(@ViewBuilder content: () -> Content) {
        withAnimation(PocketMotion.panel) {
            panel = PanelState(content: AnyView(content()))
        }
    }

    func dismissPanel() {
        withAnimation(PocketMotion.panel) {
            panel = nil
        }
    }

    func confirm(_ state: ConfirmState) {
        withAnimation(PocketMotion.pop) {
            confirmState = state
        }
    }

    func dismissConfirm() {
        withAnimation(PocketMotion.quick) {
            confirmState = nil
        }
    }
}

enum PocketMotion {
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.78)
    static let gentle = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let pop = Animation.spring(response: 0.24, dampingFraction: 0.72)
    static let quick = Animation.spring(response: 0.18, dampingFraction: 0.9)
    static let panel = Animation.spring(response: 0.34, dampingFraction: 0.82)
}
