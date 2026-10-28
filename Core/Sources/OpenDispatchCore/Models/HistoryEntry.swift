import Foundation
import GRDB

/// What the app knows about having read an article: when it was last opened, whether it's read, and for
/// a video or episode how far playback got. It carries the article's title, source and links, so History
/// can list and reopen it after the item is pruned (and on a device that never had it), like Highlight.
///
/// An article is identified by (sourceFeedUrl, itemGuid), the same key highlights and saved items use.
/// A row with no `openedAt` was marked read from a list without being opened; History leaves it out.
public struct HistoryEntry: Sendable, Hashable, Identifiable {
    public var sourceFeedUrl: String
    public var itemGuid: String
    public var itemUrl: String
    public var itemTitle: String
    public var sourceTitle: String
    public var sourceKind: SourceKind
    public var itemAuthor: String?
    public var itemPublishedAt: Date?
    public var thumbnailUrl: String?
    public var videoId: String?
    public var audioUrl: String?
    /// The last time it was opened; nil when it was only marked read.
    public var openedAt: Date?
    /// When it became read; nil = unread (or a video or episode still in progress).
    public var readAt: Date?
    /// Seconds into a video or episode.
    public var positionSec: Double?
    /// Its length as the player reported it (feeds don't always say).
    public var durationSec: Double?

    /// Played this far (of the length) counts as watched or listened to.
    public static let finishedFraction = 0.9

    public init(
        sourceFeedUrl: String, itemGuid: String, itemUrl: String, itemTitle: String, sourceTitle: String,
        sourceKind: SourceKind = .rss, itemAuthor: String? = nil, itemPublishedAt: Date? = nil,
        thumbnailUrl: String? = nil, videoId: String? = nil, audioUrl: String? = nil, openedAt: Date? = nil,
        readAt: Date? = nil, positionSec: Double? = nil, durationSec: Double? = nil
    ) {
        self.sourceFeedUrl = sourceFeedUrl
        self.itemGuid = itemGuid
        self.itemUrl = itemUrl
        self.itemTitle = itemTitle
        self.sourceTitle = sourceTitle
        self.sourceKind = sourceKind
        self.itemAuthor = itemAuthor
        self.itemPublishedAt = itemPublishedAt
        self.thumbnailUrl = thumbnailUrl
        self.videoId = videoId
        self.audioUrl = audioUrl
        self.openedAt = openedAt
        self.readAt = readAt
        self.positionSec = positionSec
        self.durationSec = durationSec
    }

    /// A snapshot of a list item, neither opened nor read yet.
    public init(item: FeedItem) {
        let it = item.item
        self.init(
            sourceFeedUrl: item.source.feedUrl, itemGuid: it.guid, itemUrl: it.url, itemTitle: it.title,
            sourceTitle: item.source.title, sourceKind: item.source.kind, itemAuthor: it.author,
            itemPublishedAt: it.publishedAt, thumbnailUrl: it.thumbnailUrl, videoId: it.videoId, audioUrl: it.audioUrl,
            durationSec: it.durationSec.map(Double.init))
    }

    public var id: String { key }
    /// Highlight.articleKey of the article.
    public var key: String { Highlight.articleKey(sourceFeedUrl: sourceFeedUrl, itemGuid: itemGuid) }

    public var isRead: Bool { readAt != nil }

    /// What clearing History by time looks at: the last time it was opened or marked read.
    public var activityAt: Date? { openedAt ?? readAt }

    /// How far into a video or episode, 0...1, while it's in progress (started, not finished, not read).
    public var progress: Double? {
        guard readAt == nil, let p = positionSec, let d = durationSec, d > 0, p > 0 else { return nil }
        return min(p / d, 1)
    }

    /// A video or podcast episode: read once played to the end, not when opened.
    public static func isMedia(_ item: FeedItem) -> Bool {
        item.item.videoId != nil || item.item.audioUrl != nil
    }
}

extension HistoryEntry: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "history"

    public init(row: Row) throws {
        sourceFeedUrl = row["source_feed_url"]
        itemGuid = row["item_guid"]
        itemUrl = row["item_url"]
        itemTitle = row["item_title"]
        sourceTitle = row["source_title"]
        sourceKind = (row["source_kind"] as String?).flatMap(SourceKind.init(rawValue:)) ?? .rss
        itemAuthor = row["item_author"]
        itemPublishedAt = row["item_published_at"]
        thumbnailUrl = row["thumbnail_url"]
        videoId = row["video_id"]
        audioUrl = row["audio_url"]
        openedAt = row["opened_at"]
        readAt = row["read_at"]
        positionSec = row["position_sec"]
        durationSec = row["duration_sec"]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["source_feed_url"] = sourceFeedUrl
        container["item_guid"] = itemGuid
        container["item_url"] = itemUrl
        container["item_title"] = itemTitle
        container["source_title"] = sourceTitle
        container["source_kind"] = sourceKind.rawValue
        container["item_author"] = itemAuthor
        container["item_published_at"] = itemPublishedAt
        container["thumbnail_url"] = thumbnailUrl
        container["video_id"] = videoId
        container["audio_url"] = audioUrl
        container["opened_at"] = openedAt
        container["read_at"] = readAt
        container["position_sec"] = positionSec
        container["duration_sec"] = durationSec
    }
}
