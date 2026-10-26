import OpenDispatchCore
import SwiftUI
import UniformTypeIdentifiers

/// What is being dragged in the sidebar (sidebar.tsx `Drag`).
enum SidebarDrag: Equatable {
    case source(Int64)
    case folder(Int64)

    /// Plain-text payload for the drag item provider ("source:12" / "folder:3"), like the web dataTransfer.
    var payload: String {
        switch self {
        case .source(let id): "source:\(id)"
        case .folder(let id): "folder:\(id)"
        }
    }
}

/// Where a drop would land (sidebar.tsx `Over`): before a source row, at the end of a folder
/// (nil = Unfiled; for a folder drag, after that folder), on a folder header (first in that folder for
/// sources; before it for folders), or in the gap between the last folder and the unfiled list (last
/// for folders; first unfiled for sources).
enum SidebarDrop: Equatable {
    case row(Int64)
    case end(Int64?)
    case folder(Int64)
    case afterFolders
}

/// Pure reorder rules ported from sidebar.tsx `dropSource` / `dropFolder`. No state, no UI.
enum SidebarTree {
    /// One source's place in the flattened sidebar order.
    struct Entry: Equatable {
        var id: Int64
        var folderId: Int64?
    }

    /// New full order of every source after dropping `id` at `target`, or nil when nothing changes
    /// (or the target is invalid). `folderOrder` is the folders top to bottom; `contents` maps a folder id
    /// (nil = Unfiled) to its source ids in display order.
    static func dropSource(id: Int64, at target: SidebarDrop, folderOrder: [Int64], contents: [Int64?: [Int64]]) -> [Entry]? {
        let lanes: [Int64?] = folderOrder.map { Optional($0) } + [nil]
        let original = lanes.flatMap { fid in (contents[fid] ?? []).map { Entry(id: $0, folderId: fid) } }
        guard original.contains(where: { $0.id == id }) else { return nil }
        var list = original.filter { $0.id != id }

        func lane(_ e: Entry) -> Int { lanes.firstIndex(of: e.folderId) ?? lanes.count }
        /// After the last source in that folder (or where the folder would start, if empty);
        /// a header drop puts it first in that folder.
        func laneEnd(_ fid: Int64?, header: Bool) -> Int? {
            guard let laneIdx = lanes.firstIndex(of: fid) else { return nil }
            if header, let first = list.firstIndex(where: { $0.folderId == fid }) { return first }
            return list.firstIndex { lane($0) > laneIdx } ?? list.count
        }

        let at: Int
        let folderId: Int64?
        switch target {
        case .row(let rowId):
            guard let i = list.firstIndex(where: { $0.id == rowId }) else { return nil }
            at = i
            folderId = list[i].folderId
        case .end(let fid):
            guard let i = laneEnd(fid, header: false) else { return nil }
            at = i
            folderId = fid
        case .folder(let fid):
            guard let i = laneEnd(fid, header: true) else { return nil }
            at = i
            folderId = fid
        case .afterFolders:
            guard let i = laneEnd(nil, header: true) else { return nil }
            at = i
            folderId = nil
        }
        list.insert(Entry(id: id, folderId: folderId), at: at)
        return list == original ? nil : list
    }

    /// New folder order after dropping folder `id` at `target`, or nil when nothing changes (or the target
    /// is invalid). A folder header puts it before that folder, a folder's end strip after it, and the gap
    /// above the unfiled list last. Source rows and the unfiled end don't take folders.
    static func dropFolder(id: Int64, at target: SidebarDrop, order: [Int64]) -> [Int64]? {
        guard order.contains(id) else { return nil }
        var ids = order.filter { $0 != id }
        let at: Int
        switch target {
        case .folder(let targetId):
            guard targetId != id, let i = ids.firstIndex(of: targetId) else { return nil }
            at = i
        case .end(let targetId?):
            guard targetId != id, let i = ids.firstIndex(of: targetId) else { return nil }
            at = i + 1
        case .afterFolders:
            at = ids.count
        case .row, .end(nil):
            return nil
        }
        ids.insert(id, at: at)
        return ids == order ? nil : ids
    }

    /// Whether a drag can drop on a target at all (drives hover feedback and validation).
    static func accepts(_ drag: SidebarDrag, at target: SidebarDrop) -> Bool {
        switch (drag, target) {
        case (.source, _): true
        case (.folder, .folder), (.folder, .end(.some(_))), (.folder, .afterFolders): true
        case (.folder, .row), (.folder, .end(.none)): false
        }
    }
}

/// Drop target for one sidebar spot. The current drag is tracked by the sidebar itself (set when the drag
/// starts), so validation and hover feedback don't need to decode the item provider.
struct SidebarDropDelegate: DropDelegate {
    let target: SidebarDrop
    let dragging: SidebarDrag?
    @Binding var over: SidebarDrop?
    let perform: (SidebarDrag, SidebarDrop) -> Void

    private var accepts: Bool {
        dragging.map { SidebarTree.accepts($0, at: target) } ?? false
    }

    func validateDrop(info: DropInfo) -> Bool {
        accepts && info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropEntered(info: DropInfo) {
        if accepts { over = target }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        accepts ? DropProposal(operation: .move) : DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) {
        if over == target { over = nil }
    }

    /// Applies the drop only when the dropped text is the payload of the drag this sidebar started.
    /// SwiftUI has no drag-ended callback, so `dragging` outlives a drag cancelled outside the sidebar;
    /// without this check a later drop of unrelated text (a link from another app) would move that stale source.
    func performDrop(info: DropInfo) -> Bool {
        over = nil
        guard accepts, let dragging,
              let provider = info.itemProviders(for: [UTType.plainText]).first
        else { return false }
        let expected = dragging.payload
        let target = target
        // The completion runs off the main actor; the action is only ever called back on it.
        let action = MainActorAction(perform)
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, text as String == expected else { return }
            Task { @MainActor in action.run(dragging, target) }
        }
        return true
    }
}

/// Carries the drop action across the item provider's background completion back to the main actor.
private struct MainActorAction: @unchecked Sendable {
    let perform: (SidebarDrag, SidebarDrop) -> Void
    init(_ perform: @escaping (SidebarDrag, SidebarDrop) -> Void) { self.perform = perform }
    @MainActor func run(_ drag: SidebarDrag, _ target: SidebarDrop) { perform(drag, target) }
}
