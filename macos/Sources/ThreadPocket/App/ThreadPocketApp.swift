import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

enum AppEvent {
    static let newThread = Notification.Name("threadpocket.event.newThread")
    static let focusSearch = Notification.Name("threadpocket.event.focusSearch")
    static let settings = Notification.Name("threadpocket.event.settings")
    static let refresh = Notification.Name("threadpocket.event.refresh")
    static let recordProgress = Notification.Name("threadpocket.event.recordProgress")
    static let newItem = Notification.Name("threadpocket.event.newItem")
}

@main
struct ThreadPocketApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var overlay: OverlayCenter
    @StateObject private var store: WorkspaceStore

    init() {
        let settings = AppSettings()
        let overlay = OverlayCenter()
        _settings = StateObject(wrappedValue: settings)
        _overlay = StateObject(wrappedValue: overlay)
        _store = StateObject(wrappedValue: WorkspaceStore(settings: settings, overlay: overlay))
    }

    var body: some Scene {
        Window("Thread Pocket", id: "main") {
            RootView()
                .environmentObject(settings)
                .environmentObject(overlay)
                .environmentObject(store)
                .frame(minWidth: 1080, minHeight: 700)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1360, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建线索") { post(AppEvent.newThread) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("新建事项") { post(AppEvent.newItem) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("搜索") { post(AppEvent.focusSearch) }
                    .keyboardShortcut("k", modifiers: .command)
                Button("记录一条进展") { post(AppEvent.recordProgress) }
                    .keyboardShortcut(.return, modifiers: .command)
                Divider()
                Button("刷新") { post(AppEvent.refresh) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("连接设置…") { post(AppEvent.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

/// 让隐藏标题栏的窗口仍然可以拖动，并把标题栏设为透明。
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.backgroundColor = .black
            window.minSize = NSSize(width: 1080, height: 700)
            window.title = "Thread Pocket"
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 顶部栏的拖动区域。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
