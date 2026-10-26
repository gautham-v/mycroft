import Foundation
import GRDB

/// One feed entry. Mirrors `items` in src/db/schema.ts (all columns). Unique (source_id, guid).
public struct Item: Sendable, Hashable, Identifiable {
    /// 0 until inserted.
    public var id: Int64
    public var sourceId: Int64
    public var guid: String
    public var url: String
    public var title: String
    public var summary: String?
    /// Extracted full text (sanitized HTML), cached. nil in list queries (see FeedItem.hasContent).
    public var contentHtml: String?
    /// content_html came from the rendered-page (Jina Reader) fallback.
    public var contentRendered: Bool
    public var author: String?
    public var publishedAt: Date
    public var thumbnailUrl: String?
    /// The article page was already tried for an og:image at refresh time.
    public var thumbnailChecked: Bool
    public var videoId: String?
    public var durationSec: Int?
    /// kind 'podcast': the episode's audio enclosure URL.
    public var audioUrl: String?
    public var hnPoints: Int?
    public var hnComments: Int?
    public var hnCommentsUrl: String?
    /// A post on X that quotes another: the quoted account's avatar (the summary names the account).
    public var quoteAvatarUrl: String?
    public var isSaved: Bool
    public var createdAt: Date

    public init(
        id: Int64 = 0, sourceId: Int64, guid: String, url: String, title: String, summary: String? = nil,
        contentHtml: String? = nil, contentRendered: Bool = false, author: String? = nil, publishedAt: Date,
        thumbnailUrl: String? = nil, thumbnailChecked: Bool = false, videoId: String? = nil, durationSec: Int? = nil,
        audioUrl: String? = nil, hnPoints: Int? = nil, hnComments: Int? = nil, hnCommentsUrl: String? = nil,
        quoteAvatarUrl: String? = nil, isSaved: Bool = false, createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceId = sourceId
        self.guid = guid
        self.url = url
        self.title = title
        self.summary = summary
        self.contentHtml = contentHtml
        self.contentRendered = contentRendered
        self.author = author
        self.publishedAt = publishedAt
        self.thumbnailUrl = thumbnailUrl
        self.thumbnailChecked = thumbnailChecked
        self.videoId = videoId
        self.durationSec = durationSec
        self.audioUrl = audioUrl
        self.hnPoints = hnPoints
        self.hnComments = hnComments
        self.hnCommentsUrl = hnCommentsUrl
        self.quoteAvatarUrl = quoteAvatarUrl
        self.isSaved = isSaved
        self.createdAt = createdAt
    }
}

extension Item: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "items"

    public enum Columns {
        public static let id = Column("id")
        public static let sourceId = Column("source_id")
        public static let guid = Column("guid")
        public static let url = Column("url")
        public static let title = Column("title")
        public static let summary = Column("summary")
        public static let contentHtml = Column("content_html")
        public static let contentRendered = Column("content_rendered")
        public static let author = Column("author")
        public static let publishedAt = Column("published_at")
        public static let thumbnailUrl = Column("thumbnail_url")
        public static let thumbnailChecked = Column("thumbnail_checked")
        public static let videoId = Column("video_id")
        public static let durationSec = Column("duration_sec")
        public static let audioUrl = Column("audio_url")
        public static let hnPoints = Column("hn_points")
        public static let hnComments = Column("hn_comments")
        public static let hnCommentsUrl = Column("hn_comments_url")
        public static let quoteAvatarUrl = Column("quote_avatar_url")
        public static let isSaved = Column("is_saved")
        public static let createdAt = Column("created_at")
    }

    public init(row: Row) throws {
        id = row["id"]
        sourceId = row["source_id"]
        guid = row["guid"]
        url = row["url"]
        title = row["title"]
        summary = row["summary"]
        // Absent from list selections: decodes as nil.
        contentHtml = row["content_html"]
        contentRendered = row["content_rendered"] ?? false
        author = row["author"]
        publishedAt = row["published_at"]
        thumbnailUrl = row["thumbnail_url"]
        thumbnailChecked = row["thumbnail_checked"] ?? false
        videoId = row["video_id"]
        durationSec = row["duration_sec"]
        audioUrl = row["audio_url"]
        hnPoints = row["hn_points"]
        hnComments = row["hn_comments"]
        hnCommentsUrl = row["hn_comments_url"]
        quoteAvatarUrl = row["quote_avatar_url"]
        isSaved = row["is_saved"] ?? false
        createdAt = row["created_at"]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        if id != 0 { container["id"] = id }
        container["source_id"] = sourceId
        container["guid"] = guid
        container["url"] = url
        container["title"] = title
        container["summary"] = summary
        container["content_html"] = contentHtml
        container["content_rendered"] = contentRendered
        container["author"] = author
        container["published_at"] = publishedAt
        container["thumbnail_url"] = thumbnailUrl
        container["thumbnail_checked"] = thumbnailChecked
        container["video_id"] = videoId
        container["duration_sec"] = durationSec
        container["audio_url"] = audioUrl
        container["hn_points"] = hnPoints
        container["hn_comments"] = hnComments
        container["hn_comments_url"] = hnCommentsUrl
        container["quote_avatar_url"] = quoteAvatarUrl
        container["is_saved"] = isSaved
        container["created_at"] = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let source = belongsTo(Source.self, key: "source", using: ForeignKey(["source_id"]))

    /// Every column except content_html, plus `has_content` (content_html IS NOT NULL). Used by list queries.
    static var listSelection: [any SQLSelectable] {
        [
            Columns.id, Columns.sourceId, Columns.guid, Columns.url, Columns.title, Columns.summary,
            Columns.contentRendered, Columns.author, Columns.publishedAt, Columns.thumbnailUrl,
            Columns.thumbnailChecked, Columns.videoId, Columns.durationSec, Columns.audioUrl, Columns.hnPoints,
            Columns.hnComments, Columns.hnCommentsUrl, Columns.quoteAvatarUrl, Columns.isSaved, Columns.createdAt,
            (Columns.contentHtml != nil).forKey("has_content"),
        ]
    }
}

/// A list row: the item joined with its source (the web app's wire `Item` with `source {…}` and `has_content`).
/// `item.contentHtml` is nil here; load the full item with `AppDatabase.itemRecord(id:)` or ContentService.
public struct FeedItem: Sendable, Hashable, Identifiable {
    public var item: Item
    public var source: Source
    /// Full text has already been extracted and cached.
    public var hasContent: Bool

    public init(item: Item, source: Source, hasContent: Bool? = nil) {
        self.item = item
        self.source = source
        self.hasContent = hasContent ?? (item.contentHtml != nil)
    }

    public var id: Int64 { item.id }
    public var isSaved: Bool { item.isSaved }
    public var cursor: ItemCursor { ItemCursor(publishedAt: item.publishedAt, id: item.id) }
}

extension FeedItem: FetchableRecord {
    public init(row: Row) throws {
        item = try Item(row: row)
        guard let s = row.scopes["source"] else {
            throw DatabaseError(message: "FeedItem row is missing its source")
        }
        source = try Source(row: s)
        let flag: Bool? = row["has_content"]
        hasContent = flag ?? (item.contentHtml != nil)
    }
}
