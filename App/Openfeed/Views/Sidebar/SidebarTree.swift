import OpenfeedCore
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
/// (nil = Unfiled), or on a folder header (first in that folder for sources; before it for folders).
enum SidebarDrop: Equatable {
    case row(Int64)
    case end(Int64?)
    case folder(Int64)
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
        }
        list.insert(Entry(id: id, folderId: folderId), at: at)
        return list == original ? nil : list
    }

    /// New folder order after dropping folder `id` on folder header `target` (it lands before the target),
    /// or nil when nothing changes. Folders only drop on folder headers.
    static func dropFolder(id: Int64, at target: SidebarDrop, order: [Int64]) -> [Int64]? {
        guard case .folder(let targetId) = target, targetId != id, order.contains(id) else { return nil }
        var ids = order.filter { $0 != id }
        guard let i = ids.firstIndex(of: targetId) else { return nil }
        ids.insert(id, at: i)
        return ids == order ? nil : ids
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
        guard let dragging else { return false }
        if case .folder = dragging, case .folder = target { return true }
        if case .folder = dragging { return false }
        return true
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

    func performDrop(info: DropInfo) -> Bool {
        over = nil
        guard accepts, let dragging else { return false }
        perform(dragging, target)
        return true
    }
}
