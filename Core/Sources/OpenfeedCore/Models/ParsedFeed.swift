import Foundation

/// Normalized item ready for upsert (minus source_id). Port of `ParsedItem` in src/lib/parse.ts.
/// Produced by FeedParser (feeds) and PageScraper (scraped pages); consumed by Queries.upsertItems.
public struct ParsedItem: Sendable, Hashable {
    public var guid: String
    public var url: String
    public var title: String
    public var summary: String?
    public var author: String?
    public var publishedAt: Date
    public var thumbnailUrl: String?
    public var videoId: String?
    public var durationSec: Int?
    /// The episode's audio enclosure (podcasts; set for any feed item that carries one).
    public var audioUrl: String?
    public var hnPoints: Int?
    public var hnComments: Int?
    public var hnCommentsUrl: String?

    public init(
        guid: String, url: String, title: String, summary: String? = nil, author: String? = nil, publishedAt: Date,
        thumbnailUrl: String? = nil, videoId: String? = nil, durationSec: Int? = nil, audioUrl: String? = nil,
        hnPoints: Int? = nil, hnComments: Int? = nil, hnCommentsUrl: String? = nil
    ) {
        self.guid = guid
        self.url = url
        self.title = title
        self.summary = summary
        self.author = author
        self.publishedAt = publishedAt
        self.thumbnailUrl = thumbnailUrl
        self.videoId = videoId
        self.durationSec = durationSec
        self.audioUrl = audioUrl
        self.hnPoints = hnPoints
        self.hnComments = hnComments
        self.hnCommentsUrl = hnCommentsUrl
    }
}

/// Port of `ParsedFeed` in src/lib/parse.ts.
public struct ParsedFeed: Sendable, Hashable {
    public var title: String?
    public var link: String?
    /// Most items carry an audio enclosure (feedLooksLikePodcast).
    public var isPodcast: Bool
    /// Show/channel art (itunes:image, then the RSS channel image), absolute.
    public var imageUrl: String?
    public var items: [ParsedItem]

    public init(title: String? = nil, link: String? = nil, isPodcast: Bool = false, imageUrl: String? = nil, items: [ParsedItem] = []) {
        self.title = title
        self.link = link
        self.isPodcast = isPodcast
        self.imageUrl = imageUrl
        self.items = items
    }
}

/// A feed found by FeedDetector, shaped like the source row to insert. Port of `DetectedFeed` (feed-detect.ts).
public struct DetectedFeed: Sendable, Hashable {
    public var title: String
    public var url: String
    public var feedUrl: String
    public var kind: SourceKind
    public var group: String
    /// Podcasts: the show art, stored as the source icon.
    public var iconUrl: String?

    public init(title: String, url: String, feedUrl: String, kind: SourceKind, group: String, iconUrl: String? = nil) {
        self.title = title
        self.url = url
        self.feedUrl = feedUrl
        self.kind = kind
        self.group = group
        self.iconUrl = iconUrl
    }
}

/// Source columns a refresh may change (fetcher.ts `SourceUpdate`): podcast promotion on first fetch, seen URLs for pages.
public struct SourceFetchUpdate: Sendable, Hashable {
    public var kind: SourceKind?
    public var group: String?
    public var iconUrl: String?
    public var seenUrls: [String]?

    public init(kind: SourceKind? = nil, group: String? = nil, iconUrl: String? = nil, seenUrls: [String]? = nil) {
        self.kind = kind
        self.group = group
        self.iconUrl = iconUrl
        self.seenUrls = seenUrls
    }
}

/// (guid, url, title) of an item already stored for a source; input to dedupe and scraping.
public struct StoredItemKey: Sendable, Hashable {
    public var guid: String
    public var url: String
    public var title: String

    public init(guid: String, url: String, title: String) {
        self.guid = guid
        self.url = url
        self.title = title
    }
}

/// A row written by Queries.upsertItems. `inserted` is false when an existing (source_id, guid) row was updated.
public struct UpsertedItem: Sendable, Hashable {
    public var id: Int64
    public var url: String
    public var thumbnailUrl: String?
    public var publishedAt: Date
    public var inserted: Bool

    public init(id: Int64, url: String, thumbnailUrl: String?, publishedAt: Date, inserted: Bool) {
        self.id = id
        self.url = url
        self.thumbnailUrl = thumbnailUrl
        self.publishedAt = publishedAt
        self.inserted = inserted
    }
}

/// Extracted article content. Port of `ExtractResult` (extract.ts).
public struct ExtractResult: Sendable, Hashable {
    public var contentHtml: String?
    public var leadImage: String?
    /// contentHtml came from the Jina Reader rendered-page fallback.
    public var rendered: Bool

    public init(contentHtml: String?, leadImage: String?, rendered: Bool = false) {
        self.contentHtml = contentHtml
        self.leadImage = leadImage
        self.rendered = rendered
    }
}

/// Where an item came from, so an unfetchable page can fall back to the feed's own HTML (extract.ts `FeedRef`).
public struct FeedRef: Sendable, Hashable {
    public var feedUrl: String
    public var guid: String

    public init(feedUrl: String, guid: String) {
        self.feedUrl = feedUrl
        self.guid = guid
    }
}
