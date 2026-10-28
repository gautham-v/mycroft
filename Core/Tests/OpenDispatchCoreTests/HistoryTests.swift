import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

@Suite("History")
struct HistoryTests {
    /// A source with `n` items, newest first, as list rows.
    static func feed(_ db: AppDatabase, _ n: Int, kind: SourceKind = .rss, prefix: String = "i") async throws -> [FeedItem] {
        let s = try Fixture.source(db, kind: kind)
        try Fixture.items(db, sourceId: s.id, Fixture.parsed(n, prefix: prefix))
        return try await db.items(ItemQuery(sourceId: s.id)).items
    }

    static func entry(_ db: AppDatabase, _ item: FeedItem) async throws -> HistoryEntry? {
        try await db.reader.read { d in try Queries.historyEntry(d, sourceFeedUrl: item.source.feedUrl, itemGuid: item.item.guid) }
    }

    @Test func openingAnArticleMakesItRead() async throws {
        let db = try Fixture.db()
        let items = try await Self.feed(db, 2)
        let t0 = Fixture.base
        try await db.writer.write { d in _ = try Queries.recordOpen(d, HistoryEntry(item: items[0]), isMedia: false, now: t0) }
        let e = try #require(try await Self.entry(db, items[0]))
        #expect(e.openedAt == t0)
        #expect(e.readAt == t0)
        #expect(e.itemTitle == items[0].item.title)
        // Opening again moves it up History without changing when it was read.
        let t1 = t0.addingTimeInterval(60)
        try await db.writer.write { d in _ = try Queries.recordOpen(d, HistoryEntry(item: items[0]), isMedia: false, now: t1) }
        let again = try #require(try await Self.entry(db, items[0]))
        #expect(again.openedAt == t1)
        #expect(again.readAt == t0)
    }

    @Test func videosAreReadPastNinetyPercent() async throws {
        let db = try Fixture.db()
        let item = try #require(try await Self.feed(db, 1, kind: .youtube).first)
        try await db.recordOpen(HistoryEntry(item: item), isMedia: true)
        var e = try #require(try await Self.entry(db, item))
        #expect(e.readAt == nil)
        #expect(e.openedAt != nil)
        try await db.recordProgress(HistoryEntry(item: item), position: 300, duration: 600)
        e = try #require(try await Self.entry(db, item))
        #expect(e.progress == 0.5)
        #expect(!e.isRead)
        try await db.recordProgress(HistoryEntry(item: item), position: 545, duration: 600)
        e = try #require(try await Self.entry(db, item))
        #expect(e.isRead)
        #expect(e.progress == nil)
    }

    @Test func markingReadAndUnread() async throws {
        let db = try Fixture.db()
        let items = try await Self.feed(db, 2)
        // Read without opening: a row History doesn't list as opened; unread takes it away again.
        try await db.setRead(HistoryEntry(item: items[0]), read: true)
        var e = try #require(try await Self.entry(db, items[0]))
        #expect(e.isRead && e.openedAt == nil)
        try await db.setRead(HistoryEntry(item: items[0]), read: false)
        #expect(try await Self.entry(db, items[0]) == nil)
        // An opened one keeps its History entry, unread.
        try await db.recordOpen(HistoryEntry(item: items[1]), isMedia: false)
        try await db.setRead(HistoryEntry(item: items[1]), read: false)
        e = try #require(try await Self.entry(db, items[1]))
        #expect(!e.isRead && e.openedAt != nil)
    }

    @Test func clearingByTime() async throws {
        let db = try Fixture.db()
        let items = try await Self.feed(db, 3)
        let now = Fixture.base
        try await db.writer.write { d in
            _ = try Queries.recordOpen(d, HistoryEntry(item: items[0]), isMedia: false, now: now.addingTimeInterval(-30 * 60))
            _ = try Queries.recordOpen(d, HistoryEntry(item: items[1]), isMedia: false, now: now.addingTimeInterval(-3 * 3600))
            _ = try Queries.setRead(d, HistoryEntry(item: items[2]), read: true, now: now.addingTimeInterval(-10 * 60))
        }
        #expect(try await db.history().map(\.itemGuid) == [items[2].item.guid, items[0].item.guid, items[1].item.guid])
        #expect(try await db.clearHistory(since: now.addingTimeInterval(-3600)) == 2)
        #expect(try await db.history().map(\.itemGuid) == [items[1].item.guid])
        #expect(try await db.clearHistory(since: nil) == 1)
        #expect(try await db.history().isEmpty)
    }

    @Test func hideReadItemsKeepsWhatWasReadSinceTheListLoaded() async throws {
        let db = try Fixture.db()
        let items = try await Self.feed(db, 3)
        let sourceId = items[0].source.id
        let loaded = Date()
        try await db.writer.write { d in
            _ = try Queries.setRead(d, HistoryEntry(item: items[0]), read: true, now: loaded.addingTimeInterval(-60))
            _ = try Queries.setRead(d, HistoryEntry(item: items[1]), read: true, now: loaded.addingTimeInterval(60))
        }
        let shown = try await db.items(ItemQuery(sourceId: sourceId, hideReadBefore: loaded)).items.map(\.id)
        #expect(shown == [items[1].id, items[2].id])
        #expect(try await db.items(ItemQuery(sourceId: sourceId)).items.count == 3)
    }

    @Test func markAllReadCoversEveryPage() async throws {
        let db = try Fixture.db()
        let items = try await Self.feed(db, 5)
        try await db.setRead(HistoryEntry(item: items[0]), read: true)
        #expect(try await db.markAllRead(ItemQuery(sourceId: items[0].source.id, limit: 2)) == 4)
        #expect(try await db.history().allSatisfy(\.isRead))
        #expect(try await db.history().count == 5)
    }

    @Test func readMarksGoWithTheirItemButOpenedOnesStay() async throws {
        let db = try Fixture.db()
        let items = try await Self.feed(db, 2)
        try await db.setRead(HistoryEntry(item: items[0]), read: true)
        try await db.recordOpen(HistoryEntry(item: items[1]), isMedia: false)
        _ = try await db.pruneOldItems(before: Date.distantFuture)
        #expect(try await db.history().map(\.itemGuid) == [items[1].item.guid])
    }

    @Test func reopeningAfterThePruneAddsTheItemBack() async throws {
        let db = try Fixture.db()
        let item = try #require(try await Self.feed(db, 1).first)
        let e = try await db.recordOpen(HistoryEntry(item: item), isMedia: false)
        _ = try await db.pruneOldItems(before: Date.distantFuture)
        #expect(try await db.feedItem(id: item.id) == nil)
        let back = try #require(try await db.itemForHistory(e))
        #expect(back.item.guid == item.item.guid)
        #expect(back.item.title == item.item.title)
        #expect(back.source.feedUrl == item.source.feedUrl)
    }
}

@Suite("Sync engine state")
struct SyncEngineStateTests {
    @Test func newRecordTypesRefetchTheZone() async throws {
        let db = try Fixture.db()
        // State saved by a build that didn't record its types (or knew fewer): fetch everything again.
        try await db.writer.write { d in try SyncStore.setSyncMeta(d, SyncStore.Key.engineState, "{}") }
        #expect(try await db.writer.write { d in try SyncStore.engineStateToRestore(d) } == nil)
        // From then on the saved state is kept.
        #expect(try await db.writer.write { d in try SyncStore.engineStateToRestore(d) } == "{}")
        try await db.writer.write { d in try SyncStore.setSyncMeta(d, SyncStore.Key.knownTypes, "Folder,Source") }
        #expect(try await db.writer.write { d in try SyncStore.engineStateToRestore(d) } == nil)
    }
}
