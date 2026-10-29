import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

@Suite("Seed")
struct SeedTests {
    @Test func seedsSourcesAndFolders() async throws {
        let db = try Fixture.db(seed: true)
        let (sources, folders) = try await db.sourcesAndFolders()
        #expect(sources.count == Seed.sources.count)
        // Posts has no sources and is pruned; order is preserved.
        #expect(folders.map(\.title) == ["Labs", "Blogs", "News", "YouTube"])
        let byTitle = Dictionary(uniqueKeysWithValues: sources.map { ($0.title, $0) })
        let folderId = Dictionary(uniqueKeysWithValues: folders.map { ($0.title, $0.id) })
        #expect(byTitle["Hacker News"]?.folderId == folderId["News"])
        #expect(byTitle["OpenAI News"]?.folderId == folderId["Labs"])
        #expect(byTitle["Simon Willison"]?.folderId == folderId["Blogs"])
        #expect(byTitle["Fireship"]?.folderId == folderId["YouTube"])
        // Positions numbered by lowercase title within a folder.
        let labs = sources.filter { $0.folderId == folderId["Labs"] }.sorted { $0.position < $1.position }
        #expect(labs.map(\.title) == ["Google DeepMind Blog", "OpenAI News"])
        #expect(labs.map(\.position) == [0, 1])
    }

    @Test func seedIsIdempotentAndRemovalsStick() async throws {
        let db = try Fixture.db(seed: true)
        let hn = try #require(try await db.sources().first { $0.title == "Hacker News" })
        try await db.deleteSource(id: hn.id)
        try await db.writer.write { d in try Seed.seedIfNeeded(d) }
        let after = try await db.sources()
        #expect(after.count == Seed.sources.count - 1)
        #expect(!after.contains { $0.feedUrl == hn.feedUrl })
        #expect(try await db.folders().count == 4)
    }

    @Test func forceReseedUpsertsByFeedURL() async throws {
        let db = try Fixture.db(seed: true)
        let s = try #require(try await db.sources().first { $0.title == "Simon Willison" })
        try await db.renameSource(id: s.id, title: "Renamed")
        try await db.writer.write { d in try Seed.seedIfNeeded(d, force: true) }
        let all = try await db.sources()
        #expect(all.count == Seed.sources.count)
        #expect(all.first { $0.id == s.id }?.title == "Simon Willison")
        #expect(all.first { $0.id == s.id }?.folderId == s.folderId)
    }
}

@Suite("Items")
struct ItemTests {
    @Test func pagesWithKeysetCursor() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db)
        try Fixture.items(db, sourceId: s.id, Fixture.parsed(120))
        let p1 = try await db.items(ItemQuery())
        #expect(p1.items.count == 50)
        #expect(p1.items.first?.item.guid == "i0")
        #expect(p1.items.first?.source.id == s.id)
        #expect(p1.items.first?.hasContent == false)
        #expect(p1.items.first?.item.contentHtml == nil)
        let c1 = try #require(p1.nextCursor)
        let p2 = try await db.items(ItemQuery(cursor: c1))
        #expect(p2.items.first?.item.guid == "i50")
        let p3 = try await db.items(ItemQuery(cursor: try #require(p2.nextCursor)))
        #expect(p3.items.count == 20)
        #expect(p3.nextCursor == nil)
        let all = Set((p1.items + p2.items + p3.items).map(\.id))
        #expect(all.count == 120)
    }

    @Test func cursorBreaksPublishedAtTiesById() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db)
        try Fixture.items(db, sourceId: s.id, Fixture.parsed(5, step: 0))
        let p1 = try await db.items(ItemQuery(limit: 2))
        let p2 = try await db.items(ItemQuery(cursor: p1.nextCursor, limit: 2))
        let p3 = try await db.items(ItemQuery(cursor: p2.nextCursor, limit: 2))
        let ids = (p1.items + p2.items + p3.items).map(\.id)
        #expect(ids.count == 5)
        #expect(ids == ids.sorted(by: >))
        #expect(p3.nextCursor == nil)
    }

    @Test func balancedOrderLetsAQuietSourceRise() async throws {
        let db = try Fixture.db()
        let busy = try Fixture.source(db, title: "Busy")
        let quiet = try Fixture.source(db, title: "Quiet", url: "https://quiet.example.com")
        try Fixture.items(db, sourceId: busy.id, Fixture.parsed(6, prefix: "b", step: -600))
        try Fixture.items(db, sourceId: quiet.id, Fixture.parsed(1, prefix: "q", start: Fixture.base.addingTimeInterval(-3600)))
        let latest = try await db.items(ItemQuery()).items.map(\.item.guid)
        #expect(latest == ["b0", "b1", "b2", "b3", "b4", "b5", "q0"])
        let balanced = try await db.items(ItemQuery(order: .balanced)).items.map(\.item.guid)
        #expect(balanced == ["b0", "q0", "b1", "b2", "b3", "b4", "b5"])
        // A source's list is never ranked.
        #expect(try await db.items(ItemQuery(sourceId: busy.id, order: .balanced)).items.map(\.item.guid) == ["b0", "b1", "b2", "b3", "b4", "b5"])
    }

    @Test func balancedOrderPagesNewestFirstBelowItsWindow() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db)
        // Ten in the last 48 hours of the list, then five a day apart before them.
        try Fixture.items(db, sourceId: s.id, Fixture.parsed(10, prefix: "n", step: -3600))
        try Fixture.items(db, sourceId: s.id, Fixture.parsed(5, prefix: "o", start: Fixture.base.addingTimeInterval(-3 * 86_400), step: -86_400))
        let p1 = try await db.items(ItemQuery(limit: 3, order: .balanced))
        #expect(p1.items.map(\.item.guid) == (0..<10).map { "n\($0)" })
        let p2 = try await db.items(ItemQuery(cursor: try #require(p1.nextCursor), limit: 3, order: .balanced))
        #expect(p2.items.map(\.item.guid) == ["o0", "o1", "o2"])
        let p3 = try await db.items(ItemQuery(cursor: try #require(p2.nextCursor), limit: 3, order: .balanced))
        #expect(p3.items.map(\.item.guid) == ["o3", "o4"])
        #expect(p3.nextCursor == nil)
        // Everything inside the window: one page, no cursor.
        let small = try Fixture.db()
        let t = try Fixture.source(small)
        try Fixture.items(small, sourceId: t.id, Fixture.parsed(4))
        #expect(try await small.items(ItemQuery(limit: 2, order: .balanced)).nextCursor == nil)
    }

    @Test func cursorStringRoundTrips() throws {
        let c = ItemCursor(publishedAt: Date(timeIntervalSince1970: 1_790_000_000.123), id: 42)
        let parsed = try #require(ItemCursor(string: c.stringValue))
        #expect(parsed.id == 42)
        #expect(abs(parsed.publishedAt.timeIntervalSince(c.publishedAt)) < 0.001)
        #expect(c.stringValue.hasSuffix("Z|42"))
        #expect(ItemCursor(string: "nope") == nil)
    }

    @Test func viewsFilterByKindAndPostURL() async throws {
        let db = try Fixture.db()
        let blog = try Fixture.source(db, title: "Blog", url: "https://blog.example.com")
        let yt = try Fixture.source(db, title: "YT", url: "https://www.youtube.com/channel/UC1", kind: .youtube, group: "youtube")
        let pod = try Fixture.source(db, title: "Pod", url: "https://pod.example.com", kind: .podcast, group: "podcast")
        let post = try Fixture.source(db, title: "X", url: "https://x.com/someone", kind: .page, group: "blogs")
        try Fixture.items(db, sourceId: blog.id, Fixture.parsed(3, prefix: "b"))
        try Fixture.items(db, sourceId: yt.id, Fixture.parsed(2, prefix: "y"))
        try Fixture.items(db, sourceId: pod.id, Fixture.parsed(4, prefix: "p"))
        try Fixture.items(db, sourceId: post.id, Fixture.parsed(1, prefix: "x"))
        func count(_ v: FeedView) async throws -> Int { try await db.items(ItemQuery(view: v)).items.count }
        #expect(try await count(.all) == 10)
        #expect(try await count(.video) == 2)
        #expect(try await count(.podcasts) == 4)
        #expect(try await count(.posts) == 1)
        #expect(try await count(.articles) == 3)
        #expect(try await count(.saved) == 0)
        #expect(try await db.items(ItemQuery(sourceId: yt.id)).items.allSatisfy { $0.source.kind == .youtube })
        let counts = try await db.counts()
        #expect(counts.views[.all] == 10)
        #expect(counts.views[.articles] == 3)
        #expect(counts.sources[pod.id] == 4)
    }

    @Test func folderFilterAndCounts() async throws {
        let db = try Fixture.db()
        let f = try await db.createFolder(title: "News")
        let a = try Fixture.source(db, title: "A", folderId: f.id)
        let b = try Fixture.source(db, title: "B")
        try Fixture.items(db, sourceId: a.id, Fixture.parsed(3, prefix: "a"))
        try Fixture.items(db, sourceId: b.id, Fixture.parsed(2, prefix: "b"))
        #expect(try await db.items(ItemQuery(folderId: f.id)).items.count == 3)
        #expect(try await db.counts().folders[f.id] == 3)
    }

    @Test func savedToggle() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db)
        let rows = try Fixture.items(db, sourceId: s.id, Fixture.parsed(3))
        let updated = try await db.setSaved(itemId: rows[1].id, saved: true)
        #expect(updated?.isSaved == true)
        let saved = try await db.items(ItemQuery(view: .saved)).items
        #expect(saved.map(\.id) == [rows[1].id])
        try await db.setSaved(itemId: rows[1].id, saved: false)
        #expect(try await db.items(ItemQuery(view: .saved)).items.isEmpty)
        #expect(try await db.setSaved(itemId: 9999, saved: true) == nil)
    }

    @Test func searchMatchesAllTermsAndEscapesWildcards() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db)
        try Fixture.items(db, sourceId: s.id, [
            ParsedItem(guid: "1", url: "https://e.com/1", title: "Claude ships agents", summary: "big news", publishedAt: Fixture.base),
            ParsedItem(guid: "2", url: "https://e.com/2", title: "Agents everywhere", author: "Simon", publishedAt: Fixture.base),
            ParsedItem(guid: "3", url: "https://e.com/3", title: "100% uptime", publishedAt: Fixture.base),
            ParsedItem(guid: "4", url: "https://e.com/4", title: "1000 users", publishedAt: Fixture.base),
        ])
        func titles(_ q: String) async throws -> Set<String> {
            Set(try await db.items(ItemQuery(search: q)).items.map(\.item.title))
        }
        #expect(try await titles("agents") == ["Claude ships agents", "Agents everywhere"])
        #expect(try await titles("  AGENTS   claude ") == ["Claude ships agents"])
        #expect(try await titles("simon") == ["Agents everywhere"])
        #expect(try await titles("100%") == ["100% uptime"])
        #expect(try await titles("nothing-here").isEmpty)
        // Cached full text is searched too.
        let id = try #require(try await db.items(ItemQuery(search: "1000")).items.first?.id)
        try await db.cacheContent(itemId: id, result: ExtractResult(contentHtml: "<p>zebra</p>", leadImage: nil))
        #expect(try await titles("zebra") == ["1000 users"])
    }

    @Test func upsertConflictRules() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db)
        var first = ParsedItem(guid: "g", url: "https://e.com/a", title: "Old", summary: "keep me", publishedAt: Fixture.base, thumbnailUrl: "https://e.com/t.jpg", hnPoints: 100)
        let r1 = try Fixture.items(db, sourceId: s.id, [first])
        #expect(r1.first?.inserted == true)
        try await db.setSaved(itemId: r1[0].id, saved: true)
        first.title = "New"
        first.summary = nil
        first.thumbnailUrl = nil
        first.hnPoints = 250
        first.publishedAt = Fixture.base.addingTimeInterval(999)
        let r2 = try Fixture.items(db, sourceId: s.id, [first, ParsedItem(guid: "h", url: "https://e.com/b", title: "B", publishedAt: Fixture.base)])
        #expect(r2.map(\.inserted) == [false, true])
        #expect(r2[0].id == r1[0].id)
        let row = try #require(try await db.itemRecord(id: r1[0].id))
        #expect(row.title == "New")
        #expect(row.summary == "keep me")
        #expect(row.thumbnailUrl == "https://e.com/t.jpg")
        #expect(row.hnPoints == 250)
        #expect(row.isSaved)
        #expect(abs(row.publishedAt.timeIntervalSince(Fixture.base)) < 0.001)
    }

    @Test func cacheContentKeepsStoredThumbnail() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db)
        let rows = try Fixture.items(db, sourceId: s.id, [
            ParsedItem(guid: "a", url: "https://e.com/a", title: "A", publishedAt: Fixture.base, thumbnailUrl: "https://e.com/keep.jpg"),
            ParsedItem(guid: "b", url: "https://e.com/b", title: "B", publishedAt: Fixture.base),
        ])
        try await db.cacheContent(itemId: rows[0].id, result: ExtractResult(contentHtml: "<p>a</p>", leadImage: "https://e.com/lead.jpg", rendered: true))
        try await db.cacheContent(itemId: rows[1].id, result: ExtractResult(contentHtml: "<p>b</p>", leadImage: "https://e.com/lead.jpg"))
        let a = try #require(try await db.itemRecord(id: rows[0].id))
        let b = try #require(try await db.itemRecord(id: rows[1].id))
        #expect(a.thumbnailUrl == "https://e.com/keep.jpg")
        #expect(a.contentRendered)
        #expect(b.thumbnailUrl == "https://e.com/lead.jpg")
        #expect(try await db.feedItem(id: rows[1].id)?.hasContent == true)
    }

    @Test func pruneRemovesOldUnsavedOnly() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db)
        let now = Fixture.base
        let rows = try Fixture.items(db, sourceId: s.id, [
            ParsedItem(guid: "new", url: "https://e.com/1", title: "new", publishedAt: now),
            ParsedItem(guid: "old", url: "https://e.com/2", title: "old", publishedAt: now.addingTimeInterval(-20 * 86400)),
            ParsedItem(guid: "oldsaved", url: "https://e.com/3", title: "oldsaved", publishedAt: now.addingTimeInterval(-20 * 86400)),
        ])
        try await db.setSaved(itemId: rows[2].id, saved: true)
        let pruned = try await db.pruneOldItems(before: Retention.cutoff(now: now))
        #expect(pruned == 1)
        #expect(Set(try await db.items(ItemQuery()).items.map(\.item.guid)) == ["new", "oldsaved"])
    }

    @Test func thumbnailBackfillHelpers() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db)
        let rows = try Fixture.items(db, sourceId: s.id, Fixture.parsed(4))
        let candidates = try await db.reader.read { d in try Queries.thumbnailCandidates(d, sourceId: s.id, excluding: [rows[0].id], limit: 2) }
        #expect(candidates.map(\.id) == [rows[1].id, rows[2].id])
        try await db.writer.write { d in
            try Queries.setThumbnailFound(d, itemId: rows[1].id, url: "https://e.com/og.jpg")
            try Queries.markThumbnailChecked(d, itemIds: [rows[2].id])
        }
        let next = try await db.reader.read { d in try Queries.thumbnailCandidates(d, sourceId: s.id, excluding: [], limit: 10) }
        #expect(next.map(\.id) == [rows[0].id, rows[3].id])
    }
}

@Suite("Sources and folders")
struct SourceFolderTests {
    @Test func insertSourceLandsInUnfiledAndDedupesByFeedURL() async throws {
        let db = try Fixture.db()
        try Fixture.source(db, title: "Existing", position: 0)
        let found = DetectedFeed(title: "New", url: "https://n.com", feedUrl: "https://n.com/feed", kind: .rss, group: "blogs")
        let (s, existed) = try await db.insertSource(found)
        #expect(!existed)
        #expect(s.folderId == nil)
        #expect(s.position == 1)
        let again = try await db.insertSource(found)
        #expect(again.existed)
        #expect(again.source.id == s.id)
        let custom = try await db.insertSource(DetectedFeed(title: "C", url: "https://c.com", feedUrl: "https://c.com/f", kind: .rss, group: "blogs"), group: "labs")
        #expect(custom.source.group == "labs")
    }

    @Test func folderCRUDAndReorder() async throws {
        let db = try Fixture.db()
        let a = try await db.createFolder(title: "  A  ")
        let b = try await db.createFolder(title: "B")
        #expect(a.title == "A")
        #expect((a.position, b.position) == (0, 1))
        await #expect(throws: QueryError.emptyTitle) { try await db.createFolder(title: "   ") }
        try await db.renameFolder(id: a.id, title: "Alpha")
        try await db.reorderFolders([b.id, a.id])
        #expect(try await db.folders().map(\.title) == ["B", "Alpha"])
        let s = try Fixture.source(db, folderId: b.id)
        #expect(try await db.deleteFolder(id: b.id))
        #expect(try await db.source(id: s.id)?.folderId == nil)
        #expect(try await db.deleteFolder(id: 999) == false)
        await #expect(throws: QueryError.notFound("Folder")) { try await db.renameFolder(id: 999, title: "x") }
    }

    @Test func createFolderWithSource() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db)
        let f = try await db.createFolder(title: "Mine", withSource: s.id)
        #expect(try await db.source(id: s.id)?.folderId == f.id)
    }

    @Test func moveRenameReorderDeleteSources() async throws {
        let db = try Fixture.db()
        let f = try await db.createFolder(title: "F")
        let s1 = try Fixture.source(db, title: "One", folderId: f.id, position: 0)
        let s2 = try Fixture.source(db, title: "Two", position: 0)
        let s3 = try Fixture.source(db, title: "Three", position: 1)
        let moved = try await db.moveSource(id: s2.id, toFolder: f.id)
        #expect(moved.folderId == f.id)
        #expect(moved.position == 1)
        await #expect(throws: QueryError.notFound("Folder")) { try await db.moveSource(id: s2.id, toFolder: 999) }
        try await db.renameSource(id: s3.id, title: " Tres ")
        #expect(try await db.source(id: s3.id)?.title == "Tres")
        try await db.reorderSources([
            SourceOrderEntry(id: s3.id, folderId: f.id), SourceOrderEntry(id: s1.id, folderId: f.id), SourceOrderEntry(id: s2.id, folderId: nil),
        ])
        let all = try await db.sources()
        let pos = Dictionary(uniqueKeysWithValues: all.map { ($0.id, ($0.folderId, $0.position)) })
        #expect(pos[s3.id]! == (f.id, 0))
        #expect(pos[s1.id]! == (f.id, 1))
        #expect(pos[s2.id]! == (nil, 0))
        try Fixture.items(db, sourceId: s1.id, Fixture.parsed(3))
        #expect(try await db.deleteSource(id: s1.id))
        #expect(try await db.items(ItemQuery()).items.isEmpty)
    }

    @Test func sourceDerivedFields() throws {
        let s = Source(title: "T", url: "https://www.Example.com/x", feedUrl: "f", kind: .rss, group: "blogs", seenUrls: ["a"])
        #expect(s.host == "example.com")
        #expect(s.type == .article)
        #expect(Source(title: "", url: "https://bsky.app/profile/a", feedUrl: "", kind: .page, group: "").type == .post)
        #expect(Source(title: "", url: "https://x.com", feedUrl: "", kind: .page, group: "").type == .article)
        #expect(Source(title: "", url: "", feedUrl: "", kind: .youtube, group: "").type == .video)
        #expect(Source(title: "", url: "", feedUrl: "", kind: .podcast, group: "").type == .podcast)
    }

    @Test func seenUrlsRoundTripAndMarkFetched() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db, kind: .page)
        try await db.writer.write { d in
            try Queries.markSourceFetched(d, sourceId: s.id, error: nil, update: SourceFetchUpdate(seenUrls: ["https://a", "https://b"]))
        }
        var row = try #require(try await db.source(id: s.id))
        #expect(row.seenUrls == ["https://a", "https://b"])
        #expect(row.lastFetchedAt != nil)
        try await db.writer.write { d in
            try Queries.markSourceFetched(d, sourceId: s.id, error: String(repeating: "e", count: 600), update: SourceFetchUpdate(kind: .podcast))
        }
        row = try #require(try await db.source(id: s.id))
        #expect(row.lastError?.count == 500)
        #expect(row.kind == .page)
        #expect(row.seenUrls == ["https://a", "https://b"])
    }
}

@Suite("Pinned and hidden sources")
struct PinHideTests {
    @Test func pinKeepsFolderAndPositionAndUnpinRestoresPlace() async throws {
        let db = try Fixture.db()
        let f = try await db.createFolder(title: "F")
        let a = try Fixture.source(db, title: "A", folderId: f.id, position: 0)
        let b = try Fixture.source(db, title: "B", folderId: f.id, position: 1)
        let pinned = try await db.setSourcePinned(id: b.id, pinned: true)
        #expect(pinned.isPinned)
        #expect(pinned.folderId == f.id)
        #expect(pinned.position == 1)
        var all = try await db.sources()
        #expect(SourceList.inFolder(all, f.id).map(\.id) == [a.id])
        #expect(SourceList.pinned(all).map(\.id) == [b.id])
        // The iPhone list has no Pinned group and still shows it in its folder.
        #expect(SourceList.allInFolder(all, f.id).map(\.id) == [a.id, b.id])
        try await db.setSourcePinned(id: b.id, pinned: false)
        all = try await db.sources()
        #expect(SourceList.inFolder(all, f.id).map(\.id) == [a.id, b.id])
        #expect(SourceList.pinned(all).isEmpty)
    }

    @Test func pinsListInPinOrder() async throws {
        let db = try Fixture.db()
        let a = try Fixture.source(db, title: "A")
        let b = try Fixture.source(db, title: "B")
        let c = try Fixture.source(db, title: "C")
        let t = Date(timeIntervalSince1970: 1_000)
        try await db.writer.write { d in
            try Queries.setSourcePinned(d, id: c.id, pinned: true, now: t)
            try Queries.setSourcePinned(d, id: a.id, pinned: true, now: t.addingTimeInterval(1))
            try Queries.setSourcePinned(d, id: b.id, pinned: true, now: t.addingTimeInterval(2))
        }
        #expect(SourceList.pinned(try await db.sources()).map(\.title) == ["C", "A", "B"])
    }

    @Test func hiddenSourcesLeaveTheTreeButStaySubscribed() async throws {
        let db = try Fixture.db()
        let a = try Fixture.source(db, title: "A")
        let b = try Fixture.source(db, title: "B")
        try Fixture.items(db, sourceId: b.id, Fixture.parsed(2))
        try await db.setSourceHidden(id: b.id, hidden: true)
        let all = try await db.sources()
        #expect(all.count == 2)
        #expect(SourceList.inFolder(all, nil).map(\.id) == [a.id])
        #expect(SourceList.hidden(all).map(\.id) == [b.id])
        // Items of a hidden source still show in the views.
        #expect(try await db.items(ItemQuery()).items.count == 2)
        try await db.setSourceHidden(id: b.id, hidden: false)
        #expect(SourceList.inFolder(try await db.sources(), nil).map(\.id) == [a.id, b.id])
    }

    @Test func pinningUnhidesAndHidingUnpins() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db)
        try await db.setSourceHidden(id: s.id, hidden: true)
        var row = try await db.setSourcePinned(id: s.id, pinned: true)
        #expect(row.isPinned && !row.isHidden)
        row = try await db.setSourceHidden(id: s.id, hidden: true)
        #expect(row.isHidden && !row.isPinned)
        await #expect(throws: QueryError.notFound("Source")) { try await db.setSourcePinned(id: 999, pinned: true) }
        await #expect(throws: QueryError.notFound("Source")) { try await db.setSourceHidden(id: 999, hidden: true) }
    }

    @Test func pinAndHideSurviveReorderAndFolderDelete() async throws {
        let db = try Fixture.db()
        let f = try await db.createFolder(title: "F")
        let a = try Fixture.source(db, title: "A", folderId: f.id, position: 0)
        let b = try Fixture.source(db, title: "B", folderId: f.id, position: 1)
        try await db.setSourcePinned(id: a.id, pinned: true)
        try await db.reorderSources([SourceOrderEntry(id: b.id, folderId: nil)])
        #expect(try await db.source(id: a.id)?.isPinned == true)
        try await db.deleteFolder(id: f.id)
        let row = try #require(try await db.source(id: a.id))
        #expect(row.isPinned)
        #expect(row.folderId == nil)
    }

    @Test func searchIgnoresCaseAndDiacriticsAcrossPinnedAndHidden() async throws {
        let db = try Fixture.db()
        let f = try await db.createFolder(title: "F")
        let cafe = try Fixture.source(db, title: "Café Notes", folderId: f.id)
        let pinned = try Fixture.source(db, title: "The CAFETERIA")
        let hidden = try Fixture.source(db, title: "cafe society")
        try Fixture.source(db, title: "Unrelated")
        try await db.setSourcePinned(id: pinned.id, pinned: true)
        try await db.setSourceHidden(id: hidden.id, hidden: true)
        let all = try await db.sources()
        #expect(SourceList.matching(all, query: "cafe").map(\.id) == [cafe.id, hidden.id, pinned.id].sorted { a, b in
            let t = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.title) })
            return t[a]!.localizedStandardCompare(t[b]!) == .orderedAscending
        })
        #expect(SourceList.matching(all, query: "  CAFÉ ").count == 3)
        #expect(SourceList.matching(all, query: "").isEmpty)
        #expect(SourceList.matching(all, query: "zzz").isEmpty)
    }

    @Test func opmlExportIncludesPinnedAndHiddenSources() async throws {
        let db = try Fixture.db()
        let a = try Fixture.source(db, title: "Pinned One", feedUrl: "https://a.example/feed")
        let b = try Fixture.source(db, title: "Hidden One", feedUrl: "https://b.example/feed")
        try await db.setSourcePinned(id: a.id, pinned: true)
        try await db.setSourceHidden(id: b.id, hidden: true)
        let services = OpenDispatchServices.live(database: db)
        let xml = try await services.exportOPML()
        #expect(xml.contains("https://a.example/feed"))
        #expect(xml.contains("https://b.example/feed"))
    }

    @Test func migrationAddsColumnsToExistingRows() async throws {
        let db = try Fixture.db()
        let s = try Fixture.source(db)
        let row = try #require(try await db.source(id: s.id))
        #expect(row.pinnedAt == nil)
        #expect(row.isHidden == false)
    }
}

@Suite("Meta and OPML")
struct MetaOPMLTests {
    @Test func metaRoundTrip() async throws {
        let db = try Fixture.db()
        #expect(try await db.lastRefreshAt() == nil)
        try await db.setLastRefreshAt(Fixture.base)
        #expect(try await db.lastRefreshAt() == Fixture.base)
        try await db.setMeta("k", "v")
        #expect(try await db.meta("k") == "v")
        try await db.setMeta("k", nil)
        #expect(try await db.meta("k") == nil)
    }

    @Test func importOPMLMatchesFoldersAndSkipsKnown() async throws {
        let db = try Fixture.db()
        let news = try await db.createFolder(title: "News")
        try Fixture.source(db, title: "Known", url: "https://known.com", feedUrl: "https://known.com/feed/")
        let doc = OPMLDocument(
            folders: [
                OPMLFolder(title: "news", sources: [OPMLSource(title: "N1", feedUrl: "https://n1.com/rss", htmlUrl: "https://n1.com")]),
                OPMLFolder(title: "Video", sources: [OPMLSource(title: "", feedUrl: "https://www.youtube.com/feeds/videos.xml?channel_id=UCabc")]),
                OPMLFolder(title: "Dupes", sources: [OPMLSource(title: "K", feedUrl: "http://www.KNOWN.com/feed")]),
            ],
            unfiled: [
                OPMLSource(title: "Bad", feedUrl: "ftp://nope"),
                OPMLSource(title: "Page", feedUrl: "https://p.com/news", kind: .page),
                OPMLSource(title: "Pod", feedUrl: "https://pod.com/rss", kind: .podcast),
            ])
        let r = try await db.importOPML(doc)
        #expect(r.added == 4)
        #expect(r.skipped == 1)
        #expect(r.foldersCreated == 1)
        #expect(r.errors.count == 1)
        let (sources, folders) = try await db.sourcesAndFolders()
        #expect(folders.map(\.title) == ["News", "Video"])
        let n1 = try #require(sources.first { $0.title == "N1" })
        #expect(n1.folderId == news.id)
        #expect(n1.url == "https://n1.com/")
        let yt = try #require(sources.first { $0.kind == .youtube })
        #expect(yt.title == "YouTube channel")
        #expect(yt.url == "https://www.youtube.com/channel/UCabc")
        let page = try #require(sources.first { $0.title == "Page" })
        #expect(page.kind == .page)
        #expect(page.url == "https://p.com/news")
        #expect(sources.first { $0.title == "Pod" }?.group == "podcast")
    }

    @Test func feedKeyNormalizes() {
        #expect(Queries.feedKey("https://www.Example.COM/Feed/") == "example.com/Feed")
        #expect(Queries.feedKey("http://example.com") == "example.com")
    }
}
