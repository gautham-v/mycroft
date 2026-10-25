import Foundation
import GRDB
@testable import OpenfeedCore

enum Fixture {
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    static func db(seed: Bool = false) throws -> AppDatabase {
        try AppDatabase.inMemory(seed: seed)
    }

    @discardableResult
    static func source(_ db: AppDatabase, title: String = "Blog", url: String = "https://blog.example.com",
                       feedUrl: String? = nil, kind: SourceKind = .rss, group: String = "blogs", folderId: Int64? = nil, position: Int = 0) throws -> Source {
        try db.writer.write { d in
            var s = Source(title: title, url: url, feedUrl: feedUrl ?? "\(url)/feed-\(UUID().uuidString)", kind: kind, group: group, folderId: folderId, position: position)
            try s.insert(d)
            return s
        }
    }

    static func parsed(_ n: Int, prefix: String = "i", start: Date = Fixture.base, step: TimeInterval = -60) -> [ParsedItem] {
        (0..<n).map { i in
            ParsedItem(guid: "\(prefix)\(i)", url: "https://example.com/\(prefix)/\(i)", title: "Title \(prefix) \(i)",
                       summary: "Summary \(i)", publishedAt: start.addingTimeInterval(Double(i) * step))
        }
    }

    @discardableResult
    static func items(_ db: AppDatabase, sourceId: Int64, _ items: [ParsedItem]) throws -> [UpsertedItem] {
        try db.writer.write { d in try Queries.upsertItems(d, sourceId: sourceId, items: items) }
    }
}
