import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

@Suite("Highlights")
struct HighlightTests {
    static func highlight(_ feed: String, _ guid: String, text: String = "a quote", at offset: TimeInterval = 0, color: HighlightColor = .yellow) -> Highlight {
        Highlight(sourceFeedUrl: feed, itemGuid: guid, itemUrl: "https://example.com/\(guid)", itemTitle: "Title \(guid)",
                  sourceTitle: "Blog", itemAuthor: "Ada", text: text, prefix: "before ", suffix: " after", color: color,
                  createdAt: Fixture.base.addingTimeInterval(offset))
    }

    @Test func roundTripsEveryField() async throws {
        let db = try Fixture.db()
        var h = Self.highlight("https://b.example/feed", "g1", color: .underline)
        h.note = "worth rereading"
        h.itemPublishedAt = Fixture.base
        try await db.insertHighlight(h)
        let back = try #require(try await db.highlights(sourceFeedUrl: h.sourceFeedUrl, itemGuid: "g1").first)
        #expect(back == h)
        #expect(try await db.highlightCount() == 1)
    }

    @Test func updateChangesColorAndNoteOnly() async throws {
        let db = try Fixture.db()
        let h = Self.highlight("https://b.example/feed", "g1")
        try await db.insertHighlight(h)
        let later = h.createdAt.addingTimeInterval(60)
        let edited = try #require(try await db.writer.write { d in
            try Queries.updateHighlight(d, id: h.id, color: .blue, note: "  hello \n", forReadwise: true, now: later)
        })
        #expect(edited.color == .blue)
        #expect(edited.note == "hello")
        #expect(edited.text == h.text)
        #expect(edited.updatedAt == later)
        #expect(edited.readwisePending)
        // No change, no bump.
        let same = try #require(try await db.updateHighlight(id: h.id, color: .blue, note: "hello"))
        #expect(same.updatedAt == later)
        #expect(try await db.updateHighlight(id: "missing", color: .pink) == nil)
        // Clearing the note.
        #expect(try await db.updateHighlight(id: h.id, note: "")?.note == "")
    }

    @Test func groupsByArticleNewestActivityFirst() async throws {
        let db = try Fixture.db()
        let a1 = Self.highlight("https://b.example/feed", "a", text: "one", at: 0)
        let a2 = Self.highlight("https://b.example/feed", "a", text: "two", at: 10)
        let b1 = Self.highlight("https://b.example/feed", "b", text: "three", at: 5)
        let c1 = Self.highlight("https://c.example/feed", "a", text: "four", at: 1)
        for h in [a1, b1, c1, a2] { try await db.insertHighlight(h) }
        var groups = try await db.highlightGroups()
        #expect(groups.map(\.id) == [a1.articleKey, b1.articleKey, c1.articleKey])
        #expect(groups[0].highlights.map(\.text) == ["one", "two"])
        #expect(groups[0].count == 2)
        // Editing an old highlight moves its article to the top.
        try await db.writer.write { d in _ = try Queries.updateHighlight(d, id: c1.id, note: "n", now: Fixture.base.addingTimeInterval(100)) }
        groups = try await db.highlightGroups()
        #expect(groups.first?.id == c1.articleKey)
        #expect(groups.first?.latest.note == "n")
        #expect(try await db.deleteHighlight(id: c1.id))
        #expect(try await db.highlightGroups().count == 2)
    }

    @Test func pruneKeepsItemsWithHighlights() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db, feedUrl: "https://b.example/feed")
        let old = Fixture.base.addingTimeInterval(-20 * 86400)
        try Fixture.items(db, sourceId: s.id, [
            ParsedItem(guid: "plain", url: "https://e.com/1", title: "plain", publishedAt: old),
            ParsedItem(guid: "marked", url: "https://e.com/2", title: "marked", publishedAt: old),
        ])
        try await db.insertHighlight(Self.highlight("https://b.example/feed", "marked"))
        // The same guid under another source is a different article.
        try await db.insertHighlight(Self.highlight("https://other.example/feed", "plain"))
        let pruned = try await db.pruneOldItems(before: Retention.cutoff(now: Fixture.base))
        #expect(pruned == 1)
        #expect(try await db.items(ItemQuery()).items.map(\.item.guid) == ["marked"])
        // Removing the highlight makes the item prunable again.
        let h = try #require(try await db.highlights(sourceFeedUrl: "https://b.example/feed", itemGuid: "marked").first)
        try await db.deleteHighlight(id: h.id)
        #expect(try await db.pruneOldItems(before: Retention.cutoff(now: Fixture.base)) == 1)
    }

    @Test func highlightsOutliveTheirSource() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db, feedUrl: "https://b.example/feed")
        try Fixture.items(db, sourceId: s.id, Fixture.parsed(1))
        try await db.insertHighlight(Self.highlight("https://b.example/feed", "i0"))
        try await db.deleteSource(id: s.id)
        #expect(try await db.highlightCount() == 1)
        #expect(try await db.itemForHighlights(sourceFeedUrl: "https://b.example/feed", itemGuid: "i0") == nil)
    }

    @Test func itemForHighlightsAddsTheMissingItem() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db, feedUrl: "https://b.example/feed")
        var h = Self.highlight("https://b.example/feed", "gone")
        h.itemPublishedAt = Fixture.base.addingTimeInterval(-86400)
        try await db.insertHighlight(h)
        let item = try #require(try await db.itemForHighlights(sourceFeedUrl: h.sourceFeedUrl, itemGuid: "gone"))
        #expect(item.source.id == s.id)
        #expect(item.item.title == "Title gone")
        #expect(item.item.url == "https://example.com/gone")
        #expect(item.item.author == "Ada")
        #expect(item.item.publishedAt == h.itemPublishedAt)
        // Asking again finds the same row.
        let again = try #require(try await db.itemForHighlights(sourceFeedUrl: h.sourceFeedUrl, itemGuid: "gone"))
        #expect(again.id == item.id)
    }

    @Test func readwiseBookkeeping() async throws {
        let db = try Fixture.db()
        let h = Self.highlight("https://b.example/feed", "g")
        try await db.insertHighlight(h, forReadwise: true)
        #expect(try await db.reader.read { d in try Queries.pendingReadwiseHighlights(d) }.map(\.id) == [h.id])

        // An edit made while the request was in flight keeps the highlight pending.
        let sent = try #require(try await db.reader.read { d in try Queries.highlight(d, id: h.id) })
        try await db.writer.write { d in _ = try Queries.updateHighlight(d, id: h.id, note: "later", forReadwise: true, now: sent.updatedAt.addingTimeInterval(5)) }
        try await db.writer.write { d in try Queries.markReadwiseSent(d, sent: sent, readwiseId: 77) }
        let edited = try #require(try await db.reader.read { d in try Queries.highlight(d, id: h.id) })
        #expect(edited.readwiseId == 77)
        #expect(edited.readwisePending)
        try await db.writer.write { d in try Queries.markReadwiseSent(d, sent: edited, readwiseId: 77) }
        let settled = try #require(try await db.reader.read { d in try Queries.highlight(d, id: h.id) })
        #expect(!settled.readwisePending)

        // Deleting a sent highlight queues its Readwise deletion; one never sent queues nothing.
        try await db.deleteHighlight(id: h.id, forReadwise: true)
        #expect(try await db.reader.read { d in try Queries.pendingReadwiseDeletes(d) } == [77])
        let unsent = Self.highlight("https://b.example/feed", "u")
        try await db.insertHighlight(unsent)
        try await db.deleteHighlight(id: unsent.id, forReadwise: true)
        #expect(try await db.reader.read { d in try Queries.pendingReadwiseDeletes(d) } == [77])
    }
}
