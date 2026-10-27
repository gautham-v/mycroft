import Foundation
import GRDB

/// Highlight colors. `underline` draws a line under the text instead of a background.
public enum HighlightColor: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case yellow, green, blue, pink, purple, underline

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }

    /// Readwise's color tag for this color; nil for underline, which Readwise has no equivalent of.
    public var readwiseColor: String? { self == .underline ? nil : rawValue }
}

/// A passage the user marked in an article, with an optional note. It carries what is needed to show it
/// on its own (the article's title, source and URL), so it outlives the item (pruning keeps items that
/// have highlights, but a deleted source or another device never had the item) and travels through iCloud.
///
/// An article is identified by (sourceFeedUrl, itemGuid), the same key saved items sync by, not by the
/// local integer ids. `prefix`/`suffix` are the text just before and after `text` in the article, used by
/// the reader to find the quote again when it appears more than once.
public struct Highlight: Sendable, Hashable, Identifiable {
    /// UUID string, lowercase. The CloudKit record name derives from it.
    public var id: String
    public var sourceFeedUrl: String
    public var itemGuid: String
    public var itemUrl: String
    public var itemTitle: String
    public var sourceTitle: String
    public var itemAuthor: String?
    /// When the article was published, if known; a device that never had the item uses it to add it.
    public var itemPublishedAt: Date?
    /// The exact quote.
    public var text: String
    public var prefix: String
    public var suffix: String
    /// Empty = no note.
    public var note: String
    public var color: HighlightColor
    public var createdAt: Date
    public var updatedAt: Date
    /// Readwise's id for this highlight once it has been sent there; synced so any device can delete it.
    public var readwiseId: Int64?
    /// Changed on this device and not yet sent to Readwise. Local to the device: never synced.
    public var readwisePending: Bool

    public static let contextLength = 32

    public init(
        id: String = UUID().uuidString.lowercased(), sourceFeedUrl: String, itemGuid: String, itemUrl: String,
        itemTitle: String, sourceTitle: String, itemAuthor: String? = nil, itemPublishedAt: Date? = nil,
        text: String, prefix: String = "", suffix: String = "", note: String = "", color: HighlightColor = .yellow, createdAt: Date = Date(),
        updatedAt: Date? = nil, readwiseId: Int64? = nil, readwisePending: Bool = false
    ) {
        self.id = id
        self.sourceFeedUrl = sourceFeedUrl
        self.itemGuid = itemGuid
        self.itemUrl = itemUrl
        self.itemTitle = itemTitle
        self.sourceTitle = sourceTitle
        self.itemAuthor = itemAuthor
        self.itemPublishedAt = itemPublishedAt
        self.text = text
        self.prefix = prefix
        self.suffix = suffix
        self.note = note
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.readwiseId = readwiseId
        self.readwisePending = readwisePending
    }

    /// (sourceFeedUrl, itemGuid) joined, for grouping and lookups.
    public var articleKey: String { Highlight.articleKey(sourceFeedUrl: sourceFeedUrl, itemGuid: itemGuid) }

    public static func articleKey(sourceFeedUrl: String, itemGuid: String) -> String {
        sourceFeedUrl + "\n" + itemGuid
    }
}

extension Highlight: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "highlights"

    public enum Columns {
        public static let id = Column("id")
        public static let sourceFeedUrl = Column("source_feed_url")
        public static let itemGuid = Column("item_guid")
        public static let createdAt = Column("created_at")
        public static let updatedAt = Column("updated_at")
        public static let readwiseId = Column("readwise_id")
        public static let readwisePending = Column("readwise_pending")
    }

    public init(row: Row) throws {
        id = row["id"]
        sourceFeedUrl = row["source_feed_url"]
        itemGuid = row["item_guid"]
        itemUrl = row["item_url"]
        itemTitle = row["item_title"]
        sourceTitle = row["source_title"]
        itemAuthor = row["item_author"]
        itemPublishedAt = row["item_published_at"]
        text = row["text"]
        prefix = row["prefix"] ?? ""
        suffix = row["suffix"] ?? ""
        note = row["note"] ?? ""
        color = HighlightColor(rawValue: row["color"]) ?? .yellow
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
        readwiseId = row["readwise_id"]
        readwisePending = row["readwise_pending"] ?? false
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["source_feed_url"] = sourceFeedUrl
        container["item_guid"] = itemGuid
        container["item_url"] = itemUrl
        container["item_title"] = itemTitle
        container["source_title"] = sourceTitle
        container["item_author"] = itemAuthor
        container["item_published_at"] = itemPublishedAt
        container["text"] = text
        container["prefix"] = prefix
        container["suffix"] = suffix
        container["note"] = note.isEmpty ? nil : note
        container["color"] = color.rawValue
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        container["readwise_id"] = readwiseId
        container["readwise_pending"] = readwisePending
    }
}

/// One article's highlights, for the Highlights view. Built from the highlights table alone, so it
/// exists whether or not the item (or its source) is on this device.
public struct HighlightGroup: Sendable, Hashable, Identifiable {
    public var sourceFeedUrl: String
    public var itemGuid: String
    /// In the order they were made.
    public var highlights: [Highlight]

    public var id: String { Highlight.articleKey(sourceFeedUrl: sourceFeedUrl, itemGuid: itemGuid) }
    public var count: Int { highlights.count }
    /// The most recently made or edited highlight; the article's details come from it.
    public var latest: Highlight { highlights.max { $0.updatedAt < $1.updatedAt } ?? highlights[0] }
    public var title: String { latest.itemTitle }
    public var sourceTitle: String { latest.sourceTitle }
    public var itemUrl: String { latest.itemUrl }
    /// When the newest highlight was made or edited: lists order by it.
    public var activityAt: Date { latest.updatedAt }
}
