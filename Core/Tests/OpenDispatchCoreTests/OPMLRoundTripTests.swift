import Foundation
import Testing
@testable import OpenDispatchCore

/// Settings > Sources OPML flow end to end through OpenDispatchServices on the seeded database:
/// export, remove some sources (and a whole folder), import the export back, then import a file
/// with a broken feed URL. Set OPENDISPATCH_OPML_DUMP=<dir> to keep the exported file for inspection.
@Suite("OPML round trip")
struct OPMLRoundTripTests {
    @Test func exportDeleteReimport() async throws {
        let db = try AppDatabase.inMemory(seed: true)
        let services = OpenDispatchServices.live(database: db)
        let (seeded, seededFolders) = try await db.sourcesAndFolders()
        #expect(!seeded.isEmpty)
        #expect(!seededFolders.isEmpty)

        let xml = try await services.exportOPML()
        if let dir = ProcessInfo.processInfo.environment["OPENDISPATCH_OPML_DUMP"] {
            try xml.write(toFile: (dir as NSString).appendingPathComponent("seeded-export.opml"), atomically: true, encoding: .utf8)
        }
        // Well-formed XML, one nested outline per non-empty folder holding exactly its sources.
        let parsedXML = try XMLDocument(xmlString: xml)
        let body = try #require(try parsedXML.nodes(forXPath: "/opml/body").first as? XMLElement)
        let top = (body.children ?? []).compactMap { $0 as? XMLElement }
        for f in seededFolders {
            let members = seeded.filter { $0.folderId == f.id }
            let outline = top.first { $0.attribute(forName: "title")?.stringValue == f.title && $0.attribute(forName: "xmlUrl") == nil }
            if members.isEmpty { #expect(outline == nil); continue }
            let kids = try #require(outline?.children?.compactMap { $0 as? XMLElement })
            #expect(Set(kids.compactMap { $0.attribute(forName: "xmlUrl")?.stringValue }) == Set(members.map(\.feedUrl)))
        }
        let unfiled = top.compactMap { $0.attribute(forName: "xmlUrl")?.stringValue }
        #expect(Set(unfiled) == Set(seeded.filter { $0.folderId == nil }.map(\.feedUrl)))

        // Re-importing over the full list skips everything.
        let noop = try await services.importOPML(xml: xml)
        #expect(noop == OPMLImportResult(added: 0, skipped: seeded.count, foldersCreated: 0, errors: []))

        // Remove a whole folder (its sources go unfiled), then two sources from other folders.
        let gone = try #require(seededFolders.first { f in seeded.contains { $0.folderId == f.id } })
        _ = try await db.deleteFolder(id: gone.id)
        let goneMembers = try await db.sources().filter { s in seeded.first { $0.id == s.id }?.folderId == gone.id }
        let others = seeded.filter { $0.folderId != gone.id && $0.folderId != nil }.prefix(2)
        let removed = Array(goneMembers) + Array(others)
        for s in removed { _ = try await db.deleteSource(id: s.id) }

        let result = try await services.importOPML(xml: xml)
        #expect(result.added == removed.count)
        #expect(result.skipped == seeded.count - removed.count)
        #expect(result.foldersCreated == 1)
        #expect(result.errors.isEmpty)

        let (after, afterFolders) = try await db.sourcesAndFolders()
        #expect(Set(after.map(\.feedUrl)) == Set(seeded.map(\.feedUrl)))
        let recreated = try #require(afterFolders.first { $0.title == gone.title })
        for s in seeded {
            let now = try #require(after.first { $0.feedUrl == s.feedUrl })
            let wantFolder = seededFolders.first { $0.id == s.folderId }?.title
            #expect(afterFolders.first { $0.id == now.folderId }?.title == wantFolder, "\(s.title) folder")
            #expect(now.kind == s.kind)
            #expect(now.title == s.title)
        }
        #expect(after.filter { $0.folderId == recreated.id }.count == goneMembers.count)
    }

    @Test func brokenFeedURLIsReported() async throws {
        let db = try AppDatabase.inMemory(seed: false)
        let services = OpenDispatchServices.live(database: db)
        let xml = """
        <?xml version="1.0"?><opml version="2.0"><body>
          <outline text="Good" xmlUrl="https://good.example/feed.xml"/>
          <outline text="Bad host" xmlUrl="https://not a host/feed"/>
          <outline text="Bad scheme" xmlUrl="ftp://files.example/feed"/>
        </body></opml>
        """
        let r = try await services.importOPML(xml: xml)
        #expect(r.added == 1)
        #expect(r.errors.count == 2)
        #expect(r.errors.allSatisfy { $0.hasPrefix("Bad ") })

        await #expect(throws: OPMLError.notOPML) { try await services.importOPML(xml: "<html><body>nope</body></html>") }
    }

    @Test func controlCharactersAreDroppedFromExport() throws {
        let s = Source(title: "Bell\u{07}\u{0B}Title\u{FFFF}", url: "https://x.example", feedUrl: "https://x.example/rss", kind: .rss, group: "blogs")
        let xml = DefaultOPMLCoder().serialize(folders: [Folder(id: 1, title: "F\u{01}older")], sources: [s, Source(title: "In folder", url: "https://y.example", feedUrl: "https://y.example/rss", kind: .rss, group: "blogs", folderId: 1)], now: Date())
        #expect(xml.contains(#"text="BellTitle""#))
        #expect(xml.contains(#"title="Folder""#))
        _ = try XMLDocument(xmlString: xml)
    }
}
