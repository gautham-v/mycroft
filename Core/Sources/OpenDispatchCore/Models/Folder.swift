import Foundation
import GRDB

/// User-named sidebar section. Sources with no folder show under "No Folder".
public struct Folder: Sendable, Hashable, Identifiable {
    /// 0 until inserted.
    public var id: Int64
    public var title: String
    public var position: Int
    public var createdAt: Date
    /// Every source filed here stays out of All, Articles, Posts, Video and Podcasts (see `Source.isMuted`), new ones too.
    public var isMuted: Bool

    public init(id: Int64 = 0, title: String, position: Int = 0, createdAt: Date = Date(), isMuted: Bool = false) {
        self.id = id
        self.title = title
        self.position = position
        self.createdAt = createdAt
        self.isMuted = isMuted
    }
}

extension Folder: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "folders"

    public enum Columns {
        public static let id = Column("id")
        public static let title = Column("title")
        public static let position = Column("position")
        public static let createdAt = Column("created_at")
        public static let isMuted = Column("is_muted")
    }

    public init(row: Row) throws {
        id = row["id"]
        title = row["title"]
        position = row["position"]
        createdAt = row["created_at"]
        isMuted = row["is_muted"]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        if id != 0 { container["id"] = id }
        container["title"] = title
        container["position"] = position
        container["created_at"] = createdAt
        container["is_muted"] = isMuted
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let sources = hasMany(Source.self, using: ForeignKey(["folder_id"]))
}
