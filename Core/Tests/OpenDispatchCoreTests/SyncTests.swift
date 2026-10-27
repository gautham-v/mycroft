import CloudKit
import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

/// Stands in for the CloudKit zone: push sends a device's diff, pull applies the server's records
/// the way CloudSync does (a first pull of everything, then changes).
private final class FakeServer {
    var records: [String: SyncRecord] = [:]

    /// Upload what the device's diff says, and record the agreed shadows. Returns the diff.
    @discardableResult
    func push(_ db: AppDatabase, token: String? = nil) throws -> SyncStore.Changes {
        try db.writer.write { d in
            let local = try SyncStore.localRecords(d, readwiseToken: token)
            let changes = SyncStore.diff(local: local, shadows: try SyncStore.shadows(d))
            for name in changes.saves {
                let r = local[name]!
                records[name] = r
                try SyncStore.setShadow(d, .init(name: name, type: r.type, hash: r.hash, systemFields: nil))
            }
            for name in changes.deletes {
                records[name] = nil
                try SyncStore.removeShadow(d, name: name)
            }
            return changes
        }
    }

    /// Apply every server record the device's shadow doesn't match, and deletions for shadows the server lacks.
    @discardableResult
    func pull(_ db: AppDatabase) throws -> SyncStore.ApplyResult {
        try db.writer.write { d in
            let shadows = try SyncStore.shadows(d)
            let mods = records.values.filter { shadows[$0.name]?.hash != $0.hash }.map { SyncStore.Incoming(record: $0, systemFields: nil) }
            let dels = shadows.values.filter { records[$0.name] == nil }.map { SyncStore.IncomingDeletion(name: $0.name, type: $0.type) }
            return try SyncStore.apply(d, modifications: mods, deletions: dels)
        }
    }

    /// A device's first sync: pull, prune the seed, push.
    func join(_ db: AppDatabase) throws {
        try pull(db)
        try db.writer.write { d in _ = try SyncStore.pruneSeedForJoin(d) }
        try push(db)
    }
}

private func diff(_ db: AppDatabase, token: String? = nil) throws -> SyncStore.Changes {
    try db.reader.read { d in SyncStore.diff(local: try SyncStore.localRecords(d, readwiseToken: token), shadows: try SyncStore.shadows(d)) }
}

/// (feed URL, folder title, title) for every source, sorted.
private func library(_ db: AppDatabase) async throws -> [String] {
    let (sources, folders) = try await db.sourcesAndFolders()
    let titles = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.title) })
    return sources.map { "\($0.feedUrl)|\($0.folderId.flatMap { titles[$0] } ?? "-")|\($0.title)" }.sorted()
}

@Suite("Sync")
struct SyncTests {
    @Test func newDeviceTakesTheLibrary() async throws {
        let server = FakeServer()
        let a = try Fixture.db(seed: true)
        let hn = try #require(try await a.sources().first { $0.title == "Hacker News" })
        try await a.deleteSource(id: hn.id)
        let reading = try await a.createFolder(title: "Reading")
        let mine = try Fixture.source(a, title: "Mine", url: "https://mine.example", feedUrl: "https://mine.example/feed")
        try await a.moveSource(id: mine.id, toFolder: reading.id)
        try server.join(a)

        // B is as seeded: it drops the Hacker News A removed and takes A's folder.
        let b = try Fixture.db(seed: true)
        try server.join(b)
        #expect(try await library(b) == library(a))
        #expect(try await b.folders().map(\.title) == a.folders().map(\.title))
        #expect(try diff(a).isEmpty)
        #expect(try diff(b).isEmpty)
    }

    @Test func usedDeviceMergesInsteadOfPruning() async throws {
        let server = FakeServer()
        let a = try Fixture.db(seed: true)
        let hn = try #require(try await a.sources().first { $0.title == "Hacker News" })
        try await a.deleteSource(id: hn.id)
        try server.join(a)

        let b = try Fixture.db(seed: true)
        let theirs = try Fixture.source(b, title: "Theirs", url: "https://theirs.example", feedUrl: "https://theirs.example/feed")
        try server.join(b)
        // B has been used, so nothing of it is dropped: the union ends up on both.
        let libB = try await library(b)
        #expect(libB.contains { $0.hasPrefix(hn.feedUrl + "|") })
        #expect(libB.contains("\(theirs.feedUrl)|-|Theirs"))
        try server.pull(a)
        #expect(try await library(a) == libB)
        #expect(try diff(a).isEmpty)
        #expect(try diff(b).isEmpty)
    }

    @Test func savedItemWaitsForItsSource() async throws {
        let a = try Fixture.db()
        let src = try Fixture.source(a, feedUrl: "https://late.example/feed")
        let rows = try Fixture.items(a, sourceId: src.id, Fixture.parsed(1))
        try await a.setSaved(itemId: rows[0].id, saved: true)
        let local = try await a.reader.read { d in try SyncStore.localRecords(d, readwiseToken: nil) }
        let saved = try #require(local.values.first { $0.type == .savedItem })
        let source = try #require(local.values.first { $0.type == .source })

        // CloudKit delivers the saved item in an earlier batch than its source.
        let b = try Fixture.db()
        let first = try await b.writer.write { d in
            try SyncStore.apply(d, modifications: [.init(record: saved, systemFields: nil)], deletions: [])
        }
        #expect(!first.libraryChanged)
        try await b.writer.write { d in
            _ = try SyncStore.apply(d, modifications: [.init(record: source, systemFields: nil)], deletions: [])
        }
        #expect(try await b.items(ItemQuery(view: .saved)).items.map(\.item.guid) == ["i0"])
        #expect(try diff(b).isEmpty)
        #expect(try await b.reader.read { d in try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM sync_parked") } == 0)
    }

    @Test func undecryptedTokenIsLeftAlone() throws {
        let b = try Fixture.db()
        let r = SyncRecord(type: .integrations, name: SyncRecord.integrationsName, fields: ["hasReadwiseToken": .bool(true)])
        let result = try b.writer.write { d in try SyncStore.apply(d, modifications: [.init(record: r, systemFields: nil)], deletions: []) }
        #expect(result.readwiseToken == nil)
        var cleared = r
        cleared.fields["hasReadwiseToken"] = .bool(false)
        let again = try b.writer.write { d in try SyncStore.apply(d, modifications: [.init(record: cleared, systemFields: nil)], deletions: []) }
        #expect(again.readwiseToken == .some(nil))
    }

    @Test func joiningKeepsSeededSourcesWithSavedItems() async throws {
        let server = FakeServer()
        let a = try Fixture.db(seed: true)
        let fireship = try #require(try await a.sources().first { $0.title == "Fireship" })
        try await a.deleteSource(id: fireship.id)
        try server.join(a)

        let b = try Fixture.db(seed: true)
        let onB = try #require(try await b.sources().first { $0.title == "Fireship" })
        let rows = try Fixture.items(b, sourceId: onB.id, Fixture.parsed(1))
        try await b.setSaved(itemId: rows[0].id, saved: true)
        try server.join(b)
        #expect(try await b.sources().contains { $0.title == "Fireship" })
        #expect(server.records[SyncRecord.sourceName(feedUrl: onB.feedUrl)] != nil)
    }

    @Test func firstDeviceKeepsItsSeed() async throws {
        let server = FakeServer()
        let a = try Fixture.db(seed: true)
        try server.join(a)
        #expect(try await a.sources().count == Seed.sources.count)
        #expect(server.records.values.filter { $0.type == .source }.count == Seed.sources.count)
    }

    @Test func appliedChangesAreNotSentBack() async throws {
        let server = FakeServer()
        let a = try Fixture.db(seed: true)
        let b = try Fixture.db(seed: true)
        try server.join(a)
        try server.join(b)
        let s = try #require(try await a.sources().first)
        try await a.renameSource(id: s.id, title: "Renamed")
        try await a.setSourcePinned(id: s.id, pinned: true)
        #expect(try server.push(a).saves == [SyncRecord.sourceName(feedUrl: s.feedUrl)])
        let result = try server.pull(b)
        #expect(result.libraryChanged)
        let onB = try #require(try await b.sources().first { $0.feedUrl == s.feedUrl })
        #expect(onB.title == "Renamed")
        #expect(onB.isPinned)
        #expect(try diff(b).isEmpty)
    }

    @Test func renamedFolderMovesItsSources() async throws {
        let server = FakeServer()
        let a = try Fixture.db(seed: true)
        let b = try Fixture.db(seed: true)
        try server.join(a)
        try server.join(b)
        let news = try #require(try await a.folders().first { $0.title == "News" })
        try await a.renameFolder(id: news.id, title: "Headlines")
        let pushed = try server.push(a)
        #expect(pushed.deletes == [SyncRecord.folderName(title: "News")])
        try server.pull(b)
        #expect(try await b.folders().map(\.title).sorted() == ["Blogs", "Headlines", "Labs", "YouTube"])
        #expect(try await library(b) == library(a))
        #expect(try diff(b).isEmpty)
    }

    @Test func savedItemsTravelAsSnapshots() async throws {
        let server = FakeServer()
        let a = try Fixture.db()
        let b = try Fixture.db()
        let src = try Fixture.source(a, feedUrl: "https://blog.example.com/feed")
        let rows = try Fixture.items(a, sourceId: src.id, Fixture.parsed(3))
        try server.join(a)
        try server.join(b)
        try await a.setSaved(itemId: rows[1].id, saved: true)
        try server.push(a)
        try server.pull(b)
        // B never fetched the feed: the saved item is inserted from the snapshot.
        let saved = try await b.items(ItemQuery(view: .saved)).items
        #expect(saved.map(\.item.guid) == ["i1"])
        #expect(saved.first?.item.title == "Title i 1")
        #expect(try diff(b).isEmpty)

        // A refresh changing the item's title is not a sync change.
        try await a.writer.write { d in try d.execute(sql: "UPDATE items SET title = 'Changed', thumbnail_url = 'x' WHERE id = ?", arguments: [rows[1].id]) }
        #expect(try diff(a).isEmpty)

        // Unsaving on B unsaves on A.
        try await b.setSaved(itemId: saved[0].id, saved: false)
        #expect(try server.push(b).deletes.count == 1)
        try server.pull(a)
        #expect(try await a.items(ItemQuery(view: .saved)).items.isEmpty)
    }

    @Test func savedItemOfAnUnknownSourceIsLeftAlone() throws {
        let server = FakeServer()
        let b = try Fixture.db()
        let r = SyncRecord(type: .savedItem, name: SyncRecord.savedItemName(sourceFeedUrl: "https://gone.example/feed", guid: "g"), fields: [
            "sourceFeedUrl": .string("https://gone.example/feed"), "guid": .string("g"), "url": .string("https://gone.example/1"),
            "title": .string("Gone"), "publishedAt": .date(Fixture.base),
        ])
        server.records[r.name] = r
        try server.join(b)
        // Not applied, so not shadowed, so not deleted from the server.
        #expect(server.records[r.name] != nil)
        #expect(try diff(b).isEmpty)
    }

    @Test func deletedSourceIsDeletedElsewhere() async throws {
        let server = FakeServer()
        let a = try Fixture.db(seed: true)
        let b = try Fixture.db(seed: true)
        try server.join(a)
        try server.join(b)
        let s = try #require(try await a.sources().first)
        try await a.deleteSource(id: s.id)
        try server.push(a)
        try server.pull(b)
        #expect(try await b.sources().count == Seed.sources.count - 1)
        #expect(try diff(b).isEmpty)
    }

    @Test func refreshBookkeepingIsNotAChange() async throws {
        let server = FakeServer()
        let a = try Fixture.db(seed: true)
        try server.join(a)
        let s = try #require(try await a.sources().first)
        try await a.writer.write { d in
            try Queries.markSourceFetched(d, sourceId: s.id, error: nil, update: SourceFetchUpdate(iconUrl: "https://icon.example/x.png"))
            try Queries.setLastRefreshAt(d, Date())
        }
        #expect(try diff(a).isEmpty)
    }

    @Test func settingsAndIntegrationsSync() async throws {
        let server = FakeServer()
        let a = try Fixture.db()
        let b = try Fixture.db()
        try await a.setMeta(MetaKey.syncedSettings, #"{"theme":"dark"}"#)
        try await a.setMeta(MetaKey.webhookURL, "https://hook.example/x")
        try server.join(a)
        #expect(try server.push(a, token: "tok-1").saves == [SyncRecord.integrationsName])
        let first = try server.pull(b)
        #expect(first.readwiseToken == .some("tok-1"))
        #expect(first.settingsJSON == #"{"theme":"dark"}"#)
        #expect(first.integrationsChanged)
        #expect(try await b.meta(MetaKey.syncedSettings) == #"{"theme":"dark"}"#)
        #expect(try await b.meta(MetaKey.webhookURL) == "https://hook.example/x")
        // With the token written to B's Keychain (CloudSync does that), B has nothing to send.
        #expect(try diff(b, token: "tok-1").isEmpty)
        #expect(try server.pull(b) == SyncStore.ApplyResult())
    }

    @Test func ckRecordRoundTrip() throws {
        let r = SyncRecord(type: .source, name: SyncRecord.sourceName(feedUrl: "https://a.example/feed"), fields: [
            "feedUrl": .string("https://a.example/feed"), "title": .string("A"), "url": .string("https://a.example"),
            "kind": .string("rss"), "group": .string("blogs"), "position": .int(3), "isHidden": .bool(true),
            "pinnedAt": .date(Date(timeIntervalSince1970: 1_790_000_000.123)), "createdAt": .date(Fixture.base),
        ])
        let ck = CloudSync.ckRecord(r, systemFields: nil)
        #expect(ck.recordType == "Source")
        #expect(ck.recordID.zoneID == CloudSync.zoneID)
        #expect(CloudSync.syncRecord(from: ck) == r)

        // Writing on top of system fields keeps the record ID and clears dropped values.
        var unpinned = r
        unpinned.fields["pinnedAt"] = nil
        let again = CloudSync.ckRecord(unpinned, systemFields: CloudSync.systemFields(ck))
        #expect(again.recordID == ck.recordID)
        #expect(again["pinnedAt"] == nil)
        #expect(CloudSync.syncRecord(from: again) == unpinned)

        let secret = SyncRecord(type: .integrations, name: SyncRecord.integrationsName, fields: ["readwiseToken": .secret("t")])
        let sck = CloudSync.ckRecord(secret, systemFields: nil)
        #expect(sck["readwiseToken"] == nil)
        #expect(CloudSync.syncRecord(from: sck) == secret)
    }

    @Test func highlightsSyncWithoutTheItem() async throws {
        let server = FakeServer()
        let a = try Fixture.db()
        let b = try Fixture.db()
        try server.join(a)
        try server.join(b)
        var h = HighlightTests.highlight("https://b.example/feed", "g1", text: "the quote", color: .green)
        h.note = "a note"
        h.itemPublishedAt = Fixture.base
        // The user makes it on A with Readwise on; B has neither the item nor the source.
        try await a.insertHighlight(h, forReadwise: true)
        #expect(try server.push(a).saves == [SyncRecord.highlightName(id: h.id)])
        let result = try server.pull(b)
        #expect(result.highlightsChanged)
        var onB = try #require(try await b.highlights(sourceFeedUrl: h.sourceFeedUrl, itemGuid: "g1").first)
        #expect(onB.text == "the quote")
        #expect(onB.note == "a note")
        #expect(onB.color == .green)
        #expect(onB.itemTitle == "Title g1")
        #expect(onB.itemPublishedAt == h.itemPublishedAt)
        // Applied from iCloud, so B doesn't send it to Readwise.
        #expect(!onB.readwisePending)
        #expect(try diff(b).isEmpty)
        #expect(try server.pull(b) == SyncStore.ApplyResult())

        // An edit, then the Readwise id A gets back, both reach B; neither is queued there.
        let id = h.id
        try await a.updateHighlight(id: id, color: .pink, note: "changed", forReadwise: true)
        try await a.writer.write { d in
            let sent = try #require(try Queries.highlight(d, id: id))
            try Queries.markReadwiseSent(d, sent: sent, readwiseId: 4242)
        }
        try server.push(a)
        try server.pull(b)
        onB = try #require(try await b.highlights(sourceFeedUrl: h.sourceFeedUrl, itemGuid: "g1").first)
        #expect(onB.color == .pink)
        #expect(onB.note == "changed")
        #expect(onB.readwiseId == 4242)
        #expect(!onB.readwisePending)
        #expect(try diff(b).isEmpty)

        // Deleted on B: gone on A, and A queues no Readwise deletion for a change it didn't make.
        try await b.deleteHighlight(id: h.id)
        #expect(try server.push(b).deletes == [SyncRecord.highlightName(id: h.id)])
        try server.pull(a)
        #expect(try await a.highlightCount() == 0)
        #expect(try await a.reader.read { d in try Queries.pendingReadwiseDeletes(d) }.isEmpty)
        #expect(try diff(a).isEmpty)
    }

    @Test func highlightsKeepTheirOwnArticleKey() async throws {
        // Two articles with the same guid under different sources stay apart.
        let server = FakeServer()
        let a = try Fixture.db()
        try await a.insertHighlight(HighlightTests.highlight("https://one.example/feed", "same", text: "x"))
        try await a.insertHighlight(HighlightTests.highlight("https://two.example/feed", "same", text: "x"))
        try server.join(a)
        #expect(server.records.values.filter { $0.type == .highlight }.count == 2)
    }

    @Test func highlightRecordRoundTripsThroughCloudKit() throws {
        var h = HighlightTests.highlight("https://b.example/feed", "g1", text: "quote", color: .underline)
        h.note = "n"
        h.readwiseId = 9
        let r = SyncStore.highlightRecord(h)
        #expect(r.name == "highlight-" + h.id)
        let ck = CloudSync.ckRecord(r, systemFields: nil)
        #expect(ck.recordType == "Highlight")
        #expect(CloudSync.syncRecord(from: ck) == r)
        // A bare highlight leaves the optional fields out entirely.
        let bare = SyncStore.highlightRecord(HighlightTests.highlight("f", "g", text: "q"))
        #expect(bare["note"] == nil && bare["readwiseId"] == nil && bare["itemPublishedAt"] == nil)
        #expect(CloudSync.syncRecord(from: CloudSync.ckRecord(bare, systemFields: nil)) == bare)
    }

    @Test func highlightHashIgnoresTheArticleSnapshot() {
        var h = HighlightTests.highlight("f", "g")
        let before = SyncStore.highlightRecord(h).hash
        h.itemTitle = "Renamed article"
        #expect(SyncStore.highlightRecord(h).hash == before)
        h.note = "now with a note"
        #expect(SyncStore.highlightRecord(h).hash != before)
    }

    @Test func recordNamesFollowNaturalKeys() {
        #expect(SyncRecord.folderName(title: " News ") == SyncRecord.folderName(title: "news"))
        #expect(SyncRecord.sourceName(feedUrl: "https://a/feed") != SyncRecord.sourceName(feedUrl: "https://b/feed"))
        #expect(SyncRecord.sourceName(feedUrl: "https://a/feed").count < 255)
    }
}
