import SwiftUI

/// 居中浮层：新建/编辑面板等。
struct PanelLayer: View {
    var state: PanelState
    var wrapInPanel: Bool = true
    var dismissible: Bool = true

    @EnvironmentObject private var overlay: OverlayCenter
    @State private var appeared = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.55)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.28))
                .onTapGesture {
                    if dismissible { overlay.dismissPanel() }
                }

            Group {
                if wrapInPanel {
                    state.content
                        .glassPanel(radius: 20, fill: Color.black.opacity(0.42))
                } else {
                    state.content
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)

            if dismissible {
                Button("") { overlay.dismissPanel() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
        }
        .onAppear {
            withAnimation(PocketMotion.panel) { appeared = true }
        }
    }
}

/// 自定义确认框（替代系统 alert）。
struct ConfirmLayer: View {
    var state: ConfirmState
    @EnvironmentObject private var overlay: OverlayCenter
    @State private var appeared = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.4)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.2))
                .onTapGesture { overlay.dismissConfirm() }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: state.destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(state.destructive ? PocketTheme.danger : PocketTheme.accent)
                    Text(state.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PocketTheme.textPrimary)
                }
                Text(state.message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(PocketTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Spacer()
                    if let tertiary = state.tertiaryLabel {
                        PocketButton(label: tertiary, kind: .ghost) { state.onTertiary?() }
                    }
                    if let secondary = state.secondaryLabel {
                        PocketButton(label: secondary, kind: .secondary) { state.onSecondary?() }
                    }
                    PocketButton(
                        label: state.primaryLabel,
                        symbol: state.destructive ? "trash" : "checkmark",
                        kind: state.destructive ? .danger : .primary
                    ) {
                        state.onPrimary()
                    }
                }
            }
            .padding(18)
            .frame(width: 400)
            .glassPanel(radius: 18, fill: Color.black.opacity(0.45))
            .shadow(color: .black.opacity(0.5), radius: 36, y: 18)
            .scaleEffect(appeared ? 1 : 0.95)
            .opacity(appeared ? 1 : 0)

            Button("") { overlay.dismissConfirm() }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .onAppear {
            withAnimation(PocketMotion.pop) { appeared = true }
        }
    }
}

/// 搜索结果显示面板（悬浮在搜索框下方）。
struct SearchResultsPanel: View {
    @EnvironmentObject private var store: WorkspaceStore
    var results: SearchResponse
    var anchor: CGRect

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if results.threads.isEmpty && results.items.isEmpty {
                Text("没有匹配的内容")
                    .font(.system(size: 12))
                    .foregroundStyle(PocketTheme.textSecondary)
                    .padding(.vertical, 6)
            }

            if !results.threads.isEmpty {
                sectionTitle("线索")
                ForEach(results.threads.prefix(5)) { thread in
                    Button {
                        store.requestSelection(thread.id)
                        store.mode = .threads
                        store.listFilter = .active
                        store.clearSearch()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(PocketTheme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(thread.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(PocketTheme.textPrimary)
                                Text(thread.summary)
                                    .font(.system(size: 11))
                                    .foregroundStyle(PocketTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(HoverRowButtonStyle())
                }
            }

            if !results.items.isEmpty {
                sectionTitle("事项")
                ForEach(results.items.prefix(6)) { item in
                    Button {
                        store.requestSelection(item.threadId)
                        store.mode = .threads
                        store.listFilter = .active
                        store.clearSearch()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.kind.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(PocketTheme.textSecondary)
                            Text(item.title)
                                .font(.system(size: 12.5))
                                .foregroundStyle(PocketTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(store.thread(item.threadId)?.title ?? "")
                                .font(.system(size: 10.5))
                                .foregroundStyle(PocketTheme.textTertiary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(HoverRowButtonStyle())
                }
            }
        }
        .padding(10)
        .frame(width: 330)
        .glassPanel(radius: 14, fill: Color.black.opacity(0.4))
        .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
        .offset(x: max(12, anchor.minX - 150), y: anchor.maxY + 8)
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(PocketTheme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }
}

struct HoverRowButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed || isHovering ? PocketTheme.surfaceStrong : Color.clear)
            )
            .onHover { hovering in
                withAnimation(PocketMotion.quick) { isHovering = hovering }
            }
    }
}
