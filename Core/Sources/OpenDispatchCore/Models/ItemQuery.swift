import Foundation

/// Keyset cursor over (published_at desc, id desc). String form "<iso8601>|<id>" matches the web API.
public struct ItemCursor: Sendable, Hashable, Codable {
    public var publishedAt: Date
    public var id: Int64

    public init(publishedAt: Date, id: Int64) {
        self.publishedAt = publishedAt
        self.id = id
    }

    public var stringValue: String {
        "\(ISO8601.string(from: publishedAt))|\(id)"
    }

    /// Accepts "<iso>|<id>"; a bare ISO date yields id = Int64.max (everything strictly older, or same-time rows).
    public init?(string: String) {
        let parts = string.split(separator: "|", maxSplits: 1).map(String.init)
        guard let first = parts.first, let d = ISO8601.date(from: first) else { return nil }
        publishedAt = d
        id = parts.count > 1 ? (Int64(parts[1]) ?? Int64.max) : Int64.max
    }
}

/// How a list orders its items (Settings → Appearance → Feed order).
public enum FeedOrder: String, Codable, Sendable, CaseIterable, Hashable {
    /// The first page is the newest items ranked so that each further item from the same source (in a topic, the same
    /// site) counts as older than it is, so a source that posts a lot doesn't fill the top; newest first below them (`Queries.items`).
    case balanced
    /// Newest first.
    case latest
    /// Balanced, with each row counted newer or older by how often the user opens its source (`ReadingProfile`). In a topic,
    /// where the sources are other people's, it is Balanced.
    case forYou
}

/// What the item list shows: GET /api/items?view&source&folder&q&cursor&limit.
public struct ItemQuery: Sendable, Hashable {
    public var view: FeedView
    public var sourceId: Int64?
    public var folderId: Int64?
    public var filter: FeedFilter?
    /// Search text. Every whitespace-separated term (max 8, query max 200 chars) must appear,
    /// case-insensitively, in title, summary, author or cached full text.
    public var search: String
    public var cursor: ItemCursor?
    /// Clamped to 1...200. Default 50.
    public var limit: Int
    /// Only items published at or after this time (Copy as Markdown digests). nil = no lower bound.
    public var since: Date?
    /// Hide Read Items: leave out items read before this time. nil lists read items too.
    public var hideReadBefore: Date?
    /// A topic's Show filter: which kind of item the list shows (the app sets it only for a topic's list).
    public var topicFilter: TopicContentFilter
    /// Balanced and For You apply to the first page; later pages are always newest first.
    public var order: FeedOrder
    /// Videos that won't play here (`Item.embedBlocked`) leave the list, unless it's Saved, a search or a topic's
    /// (`Queries.hidesBlockedVideos`).
    public var hidesBlockedVideos: Bool
    /// Sources to leave out of the list: ones being removed, whose Undo is still up.
    public var excludedSourceIds: Set<Int64>
    /// For You's Show More (+1) and Show Less (-1), by feed URL.
    public var sourcePreferences: [String: Int]

    public static let defaultLimit = 50
    public static let maxQueryLength = 200
    public static let maxTerms = 8

    public init(
        view: FeedView = .all, sourceId: Int64? = nil, folderId: Int64? = nil, filter: FeedFilter? = nil,
        search: String = "", cursor: ItemCursor? = nil, limit: Int = ItemQuery.defaultLimit, since: Date? = nil,
        hideReadBefore: Date? = nil, topicFilter: TopicContentFilter = .all, order: FeedOrder = .latest,
        hidesBlockedVideos: Bool = false, excludedSourceIds: Set<Int64> = [], sourcePreferences: [String: Int] = [:]
    ) {
        self.view = view
        self.sourceId = sourceId
        self.folderId = folderId
        self.filter = filter
        self.search = search
        self.cursor = cursor
        self.limit = limit
        self.since = since
        self.hideReadBefore = hideReadBefore
        self.topicFilter = topicFilter
        self.order = order
        self.hidesBlockedVideos = hidesBlockedVideos
        self.excludedSourceIds = excludedSourceIds
        self.sourcePreferences = sourcePreferences
    }

    /// The search terms actually matched.
    public var searchTerms: [String] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(trimmed.prefix(Self.maxQueryLength))
        return clipped.split(whereSeparator: { $0.isWhitespace }).prefix(Self.maxTerms).map(String.init)
    }

    /// Same query, next page.
    public func after(_ cursor: ItemCursor?) -> ItemQuery {
        var q = self
        q.cursor = cursor
        return q
    }
}

/// One page of items. `nextCursor` is nil when there are no more.
public struct ItemPage: Sendable, Hashable {
    public var items: [FeedItem]
    public var nextCursor: ItemCursor?

    public init(items: [FeedItem], nextCursor: ItemCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Item counts for the sidebar (the web sidebar no longer shows counts, but they are available).
public struct ItemCounts: Sendable, Hashable {
    public var views: [FeedView: Int]
    public var sources: [Int64: Int]
    public var folders: [Int64: Int]

    public init(views: [FeedView: Int] = [:], sources: [Int64: Int] = [:], folders: [Int64: Int] = [:]) {
        self.views = views
        self.sources = sources
        self.folders = folders
    }

    public static let empty = ItemCounts()
}

/// One entry of a sources reorder: positions are assigned by array order within each folder.
public struct SourceOrderEntry: Sendable, Hashable {
    public var id: Int64
    public var folderId: Int64?

    public init(id: Int64, folderId: Int64?) {
        self.id = id
        self.folderId = folderId
    }
}
