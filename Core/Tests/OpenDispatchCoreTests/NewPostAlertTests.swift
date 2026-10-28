import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

@Suite("New post alerts")
struct NewPostAlertTests {
    /// Stores items with `created_at` = `at`, as a refresh at that time would.
    private func store(_ db: AppDatabase, sourceId: Int64, _ items: [ParsedItem], at: Date) throws {
        try db.writer.write { d in _ = try Queries.upsertItems(d, sourceId: sourceId, items: items, now: at) }
    }

    @Test func onlyFollowedSourcesPostsStoredAfterTurningOn() async throws {
        let db = try Fixture.db()
        let now = Fixture.base
        let followed = try Fixture.source(db, title: "Followed")
        let other = try Fixture.source(db, title: "Other")
        try store(db, sourceId: followed.id, Fixture.parsed(2, prefix: "old", start: now), at: now.addingTimeInterval(-600))
        try await db.writer.write { d in _ = try Queries.setSourceNotify(d, id: followed.id, on: true, now: now.addingTimeInterval(-300)) }
        try store(db, sourceId: followed.id, Fixture.parsed(2, prefix: "new", start: now), at: now)
        try store(db, sourceId: other.id, Fixture.parsed(3, prefix: "x", start: now), at: now)

        let alerts = try await db.writer.write { d in try Queries.takeNewPostAlerts(d, now: now) }
        // Oldest first.
        #expect(alerts.map(\.title) == ["Title new 1", "Title new 0"])
        #expect(alerts.allSatisfy { $0.sourceId == followed.id && $0.sourceTitle == "Followed" })
        // Each item is handed out once.
        #expect(try await db.writer.write { d in try Queries.takeNewPostAlerts(d, now: now) }.isEmpty)

        try store(db, sourceId: followed.id, Fixture.parsed(1, prefix: "later", start: now), at: now.addingTimeInterval(60))
        let later = try await db.writer.write { d in try Queries.takeNewPostAlerts(d, now: now) }
        #expect(later.map(\.title) == ["Title later 0"])
    }

    @Test func skipsOldPostsAndTurningOffStops() async throws {
        let db = try Fixture.db()
        let now = Fixture.base
        let s = try Fixture.source(db)
        _ = try await db.setSourceNotify(id: s.id, on: true)
        #expect(try await db.source(id: s.id)?.notifies == true)
        // A feed adding a week-old post now doesn't notify.
        let stale = Fixture.parsed(1, prefix: "stale", start: now.addingTimeInterval(-7 * 24 * 3600))
        try store(db, sourceId: s.id, stale, at: Date())
        #expect(try await db.writer.write { d in try Queries.takeNewPostAlerts(d, now: now) }.isEmpty)

        _ = try await db.setSourceNotify(id: s.id, on: false)
        #expect(try await db.source(id: s.id)?.notifySince == nil)
        try store(db, sourceId: s.id, Fixture.parsed(1, prefix: "off", start: now), at: Date())
        #expect(try await db.writer.write { d in try Queries.takeNewPostAlerts(d, now: now) }.isEmpty)
    }
}
