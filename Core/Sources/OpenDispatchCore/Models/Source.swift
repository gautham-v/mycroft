import Foundation
import GRDB

/// A subscribed feed, channel, podcast or scraped page. Mirrors `sources` in src/db/schema.ts.
public struct Source: Sendable, Hashable, Identifiable {
    /// 0 until inserted.
    public var id: Int64
    public var title: String
    /// Site / channel URL.
    public var url: String
    /// Unique. For kind `.page` this is the listing URL.
    public var feedUrl: String
    public var kind: SourceKind
    /// Legacy group: labs | blogs | news | aggregator | youtube | podcast (free text).
    public var group: String
    public var iconUrl: String?
    public var lastFetchedAt: Date?
    public var lastError: String?
    /// kind `.page`: article URLs already handled, so refreshes skip them. Stored as JSON text.
    public var seenUrls: [String]?
    /// Sidebar folder; nil = Unfiled.
    public var folderId: Int64?
    /// Order within its folder (or within Unfiled).
    public var position: Int
    public var createdAt: Date
    /// When the source was pinned to the sidebar's Pinned group; nil = not pinned. Pins list in this order.
    /// `folderId` and `position` are kept while pinned, so unpinning puts the source back.
    public var pinnedAt: Date?
    /// Left out of the sidebar tree (still subscribed; its items still show in All and the other views).
    public var isHidden: Bool
    /// Left out of All, Articles, Posts, Video and Podcasts (still in the sidebar, its folder's list and its own).
    /// A muted folder (`Folder.isMuted`) does the same for every source in it. The opposite of `isHidden`.
    public var isMuted: Bool
    /// When notifications for new posts were turned on; nil = off. Only items stored after this notify.
    /// Per device: not synced.
    public var notifySince: Date?
    /// kind `.topic`: what the topic follows (nil for every other kind). Synced with the source.
    public var topicOptions: TopicOptions?

    public init(
        id: Int64 = 0, title: String, url: String, feedUrl: String, kind: SourceKind, group: String,
        iconUrl: String? = nil, lastFetchedAt: Date? = nil, lastError: String? = nil, seenUrls: [String]? = nil,
        folderId: Int64? = nil, position: Int = 0, createdAt: Date = Date(),
        pinnedAt: Date? = nil, isHidden: Bool = false, isMuted: Bool = false, notifySince: Date? = nil, topicOptions: TopicOptions? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.feedUrl = feedUrl
        self.kind = kind
        self.group = group
        self.iconUrl = iconUrl
        self.lastFetchedAt = lastFetchedAt
        self.lastError = lastError
        self.seenUrls = seenUrls
        self.folderId = folderId
        self.position = position
        self.createdAt = createdAt
        self.pinnedAt = pinnedAt
        self.isHidden = isHidden
        self.isMuted = isMuted
        self.notifySince = notifySince
        self.topicOptions = topicOptions
    }

    public var isPinned: Bool { pinnedAt != nil }
    public var notifies: Bool { notifySince != nil }

    /// The title without an X profile's "(@handle) on X" ending, for menus and messages that name the source.
    public var shortTitle: String {
        let name = TextFormat.splitHandle(title.hasSuffix(" on X") ? String(title.dropLast(5)) : title).name
        return name.isEmpty ? title : name
    }

    /// A followed keyword search (`Topic`). Tells by the reserved feed URL, not `kind`: in a list row `kind`
    /// is rewritten per item (`shown(for:)`).
    public var isTopic: Bool { Topic.isTopicFeedURL(feedUrl) }
    /// The keyword of a topic, as typed.
    public var topicKeyword: String? { isTopic ? (topicOptions?.keyword ?? title) : nil }

    /// article / post / video / podcast.
    public var type: SourceType { SourceType(kind: kind, url: url) }
    /// Hostname of `url` without a leading "www." ("" when unparseable).
    public var host: String { URLHost.host(of: url) }
}

extension Source: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "sources"

    public enum Columns {
        public static let id = Column("id")
        public static let title = Column("title")
        public static let url = Column("url")
        public static let feedUrl = Column("feed_url")
        public static let kind = Column("kind")
        public static let group = Column("group")
        public static let iconUrl = Column("icon_url")
        public static let lastFetchedAt = Column("last_fetched_at")
        public static let lastError = Column("last_error")
        public static let seenUrls = Column("seen_urls")
        public static let folderId = Column("folder_id")
        public static let position = Column("position")
        public static let createdAt = Column("created_at")
        public static let pinnedAt = Column("pinned_at")
        public static let isHidden = Column("is_hidden")
        public static let isMuted = Column("is_muted")
        public static let notifySince = Column("notify_since")
        public static let topicOptions = Column("topic_options")
    }

    public init(row: Row) throws {
        id = row["id"]
        title = row["title"]
        url = row["url"]
        feedUrl = row["feed_url"]
        kind = row["kind"]
        group = row["group"]
        iconUrl = row["icon_url"]
        lastFetchedAt = row["last_fetched_at"]
        lastError = row["last_error"]
        let seen: String? = row["seen_urls"]
        seenUrls = seen.flatMap { s in
            s.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        }
        folderId = row["folder_id"]
        position = row["position"]
        createdAt = row["created_at"]
        pinnedAt = row["pinned_at"]
        isHidden = row["is_hidden"]
        isMuted = row["is_muted"]
        notifySince = row["notify_since"]
        topicOptions = TopicOptions(json: row["topic_options"])
    }

    public func encode(to container: inout PersistenceContainer) throws {
        if id != 0 { container["id"] = id }
        container["title"] = title
        container["url"] = url
        container["feed_url"] = feedUrl
        container["kind"] = kind
        container["group"] = group
        container["icon_url"] = iconUrl
        container["last_fetched_at"] = lastFetchedAt
        container["last_error"] = lastError
        container["seen_urls"] = Source.encodeSeen(seenUrls)
        container["folder_id"] = folderId
        container["position"] = position
        container["created_at"] = createdAt
        container["pinned_at"] = pinnedAt
        container["is_hidden"] = isHidden
        container["is_muted"] = isMuted
        container["notify_since"] = notifySince
        container["topic_options"] = topicOptions?.json
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static func encodeSeen(_ urls: [String]?) -> String? {
        guard let urls, let data = try? JSONEncoder().encode(urls) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static let items = hasMany(Item.self, using: ForeignKey(["source_id"]))
    public static let folder = belongsTo(Folder.self, key: "folder", using: ForeignKey(["folder_id"]))
}
