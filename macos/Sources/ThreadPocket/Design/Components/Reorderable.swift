import SwiftUI
import UniformTypeIdentifiers

/// 拖动排序：拖过某一行时先在本地换位，松手后才写回服务端。
///
/// 排序只在一段「同类内容」之间发生（线索受置顶分组限制，条目受所在分区限制），
/// 因此这里不接收来自别处的拖放，也不会把内容拖出自己所在的那一段。
struct ReorderDropDelegate: DropDelegate {
    let id: String
    let store: WorkspaceStore

    func validateDrop(info: DropInfo) -> Bool {
        store.draggingId != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        store.draggingId == nil ? nil : DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        store.dragOver(id)
    }

    func performDrop(info: DropInfo) -> Bool {
        Task { await store.endDrag() }
        return true
    }
}

/// 列表容器的拖放兜底：在空白处松手或拖出列表时，撤掉未提交的本地预览。
struct ReorderContainerDelegate: DropDelegate {
    let store: WorkspaceStore

    func validateDrop(info: DropInfo) -> Bool {
        store.draggingId != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        store.draggingId == nil ? nil : DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        store.cancelDrag()
    }

    func performDrop(info: DropInfo) -> Bool {
        store.cancelDrag()
        return true
    }
}

struct ReorderableModifier: ViewModifier {
    @EnvironmentObject private var store: WorkspaceStore
    let id: String
    let scope: WorkspaceStore.DragScope
    let order: [String]
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled && order.count > 1 {
            content
                .opacity(store.draggingId == id ? 0.45 : 1)
                .onDrag {
                    store.beginDrag(id: id, scope: scope, order: order)
                    return NSItemProvider(object: id as NSString)
                }
                .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(id: id, store: store))
        } else {
            content
        }
    }
}

extension View {
    /// 让这一行参与拖动排序。`order` 是同一条可排序序列的 id（按当前显示顺序）。
    func reorderable(
        id: String,
        scope: WorkspaceStore.DragScope,
        order: [String],
        isEnabled: Bool = true
    ) -> some View {
        modifier(ReorderableModifier(id: id, scope: scope, order: order, isEnabled: isEnabled))
    }

    /// 列表容器的拖放兜底，见 `ReorderContainerDelegate`。
    func reorderContainer() -> some View {
        modifier(ReorderContainerModifier())
    }
}

struct ReorderContainerModifier: ViewModifier {
    @EnvironmentObject private var store: WorkspaceStore

    func body(content: Content) -> some View {
        content.onDrop(of: [UTType.text], delegate: ReorderContainerDelegate(store: store))
    }
}
