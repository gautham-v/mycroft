import Foundation
import GRDB

/// User-named sidebar section. Sources with no folder show under "Unfiled".
public struct Folder: Sendable, Hashable, Identifiable {
    /// 0 until inserted.
    public var id: Int64
    public var title: String
    public var position: Int
    public var createdAt: Date

    public init(id: Int64 = 0, title: String, position: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.position = position
        self.createdAt = createdAt
    }
}

extension Folder: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "folders"

    public enum Columns {
        public static let id = Column("id")
        public static let title = Column("title")
        public static let position = Column("position")
        public static let createdAt = Column("created_at")
    }

    public init(row: Row) throws {
        id = row["id"]
        title = row["title"]
        position = row["position"]
        createdAt = row["created_at"]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        if id != 0 { container["id"] = id }
        container["title"] = title
        container["position"] = position
        container["created_at"] = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let sources = hasMany(Source.self, using: ForeignKey(["folder_id"]))
}
