import SwiftUI

enum PocketTheme {
    static let canvasTop = Color(red: 0.075, green: 0.082, blue: 0.11)
    static let canvasBottom = Color(red: 0.043, green: 0.047, blue: 0.066)

    static let surface = Color.white.opacity(0.048)
    static let surfaceStrong = Color.white.opacity(0.085)
    static let surfaceHover = Color.white.opacity(0.07)
    static let stroke = Color.white.opacity(0.1)
    static let strokeStrong = Color.white.opacity(0.18)

    static let textPrimary = Color(red: 0.93, green: 0.94, blue: 0.97)
    static let textSecondary = Color(red: 0.62, green: 0.65, blue: 0.72)
    static let textTertiary = Color(red: 0.45, green: 0.48, blue: 0.56)

    static let accent = Color(red: 0.52, green: 0.58, blue: 1.0)
    static let accentSoft = Color(red: 0.52, green: 0.58, blue: 1.0).opacity(0.16)
    static let success = Color(red: 0.38, green: 0.83, blue: 0.6)
    static let warning = Color(red: 0.98, green: 0.75, blue: 0.35)
    static let danger = Color(red: 0.98, green: 0.45, blue: 0.48)
    static let mauve = Color(red: 0.78, green: 0.55, blue: 1.0)

    static let panelRadius: CGFloat = 18
    static let cardRadius: CGFloat = 14
    static let rowRadius: CGFloat = 11

    static var canvas: LinearGradient {
        LinearGradient(colors: [canvasTop, canvasBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func domainColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "indigo": Color(red: 0.47, green: 0.53, blue: 0.98)
        case "blue": Color(red: 0.35, green: 0.62, blue: 0.98)
        case "teal": Color(red: 0.24, green: 0.78, blue: 0.74)
        case "green": Color(red: 0.38, green: 0.83, blue: 0.6)
        case "amber": Color(red: 0.97, green: 0.72, blue: 0.32)
        case "orange": Color(red: 0.98, green: 0.6, blue: 0.32)
        case "rose": Color(red: 0.98, green: 0.5, blue: 0.6)
        case "pink": Color(red: 0.96, green: 0.53, blue: 0.82)
        case "violet": Color(red: 0.72, green: 0.52, blue: 1.0)
        case "slate": Color(red: 0.6, green: 0.66, blue: 0.78)
        default: accent
        }
    }

    static let domainColorNames = [
        "indigo", "blue", "teal", "green", "amber", "orange", "rose", "pink", "violet", "slate",
    ]
}

/// 统一的玻璃质感面板。
struct GlassPanel: ViewModifier {
    var radius: CGFloat = PocketTheme.panelRadius
    var borderOpacity: Double = 1
    var fill: Color = PocketTheme.surface

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(PocketTheme.stroke.opacity(borderOpacity), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func glassPanel(
        radius: CGFloat = PocketTheme.panelRadius,
        borderOpacity: Double = 1,
        fill: Color = PocketTheme.surface
    ) -> some View {
        modifier(GlassPanel(radius: radius, borderOpacity: borderOpacity, fill: fill))
    }
}
