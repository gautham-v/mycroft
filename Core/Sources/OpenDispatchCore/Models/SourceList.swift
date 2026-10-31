import Foundation

/// How the desktop sidebar groups and orders sources (pure; the app's AppModel calls these).
/// A source is in exactly one place: Pinned, Hidden, or its folder (nil = No Folder). Topics are in none of them
/// (they have their own sidebar group, `topics`), so they are left out of every list here.
public enum SourceList {
    /// Topics in sidebar order: creation order (position), then keyword.
    public static func topics(_ sources: [Source]) -> [Source] {
        sources.filter(\.isTopic).sorted(by: byPositionThenTitle)
    }

    /// Visible sources of a folder in sidebar order: position, then title. Pinned and hidden sources are excluded.
    public static func inFolder(_ sources: [Source], _ folderId: Int64?) -> [Source] {
        sources.filter { $0.folderId == folderId && !$0.isPinned && !$0.isHidden && !$0.isTopic }.sorted(by: byPositionThenTitle)
    }

    /// Every source of a folder in the same order, pinned and hidden ones included (the iPhone Sources tab,
    /// which has no Pinned or Hidden groups).
    public static func allInFolder(_ sources: [Source], _ folderId: Int64?) -> [Source] {
        sources.filter { $0.folderId == folderId && !$0.isTopic }.sorted(by: byPositionThenTitle)
    }

    /// Pinned sources in the order they were pinned.
    public static func pinned(_ sources: [Source]) -> [Source] {
        sources.filter { $0.isPinned && !$0.isHidden && !$0.isTopic }.sorted {
            let (a, b) = ($0.pinnedAt ?? .distantPast, $1.pinnedAt ?? .distantPast)
            return a != b ? a < b : $0.id < $1.id
        }
    }

    /// Hidden sources by title.
    public static func hidden(_ sources: [Source]) -> [Source] {
        sources.filter { $0.isHidden && !$0.isTopic }.sorted(by: byTitle)
    }

    /// Sources whose title contains `query`, ignoring case and diacritics, across every folder, pinned and
    /// hidden sources included, by title. A blank query matches nothing (the caller shows the tree instead).
    public static func matching(_ sources: [Source], query: String) -> [Source] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return sources.filter { !$0.isTopic && $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.sorted(by: byTitle)
    }

    private static func byPositionThenTitle(_ a: Source, _ b: Source) -> Bool {
        a.position != b.position ? a.position < b.position : byTitle(a, b)
    }

    private static func byTitle(_ a: Source, _ b: Source) -> Bool {
        a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}
