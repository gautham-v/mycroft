import Foundation
import Testing
@testable import OpenfeedCore

/// Port of scripts/opml-check.ts.
@Suite("DefaultOPMLCoder")
struct OPMLCoderTests {
    let coder = DefaultOPMLCoder()

    private func roundTripInput() -> ([Folder], [Source]) {
        let folders = [
            Folder(id: 1, title: "Labs & Research"),
            Folder(id: 2, title: "Empty"),
            Folder(id: 3, title: "Video"),
        ]
        let sources = [
            Source(title: "Anthropic News", url: "https://www.anthropic.com", feedUrl: "https://www.anthropic.com/news/rss.xml", kind: .rss, group: "labs", folderId: 1),
            Source(title: #"Quotes "and" <tags>"#, url: "https://example.com", feedUrl: "https://example.com/feed?a=1&b=2", kind: .rss, group: "blogs", folderId: 1),
            Source(title: "Fireship", url: "https://www.youtube.com/channel/UCsBjURrPoezykLs9EqgamOA",
                   feedUrl: "https://www.youtube.com/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA", kind: .youtube, group: "youtube", folderId: 3),
            Source(title: "A scraped page", url: "https://lab.example/news", feedUrl: "https://lab.example/news", kind: .page, group: "blogs"),
            Source(title: "Orphan (folder not exported)", url: "https://o.example", feedUrl: "https://o.example/rss", kind: .rss, group: "blogs", folderId: 99),
        ]
        return (folders, sources)
    }

    @Test func serializeAndRoundTrip() throws {
        let (folders, sources) = roundTripInput()
        let now = try #require(ISO8601.date(from: "2026-10-24T12:00:00.000Z"))
        let xml = coder.serialize(folders: folders, sources: sources, now: now)
        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\""))
        #expect(xml.contains("xmlns:openfeed=\"https://github.com/gautham-v/openfeed\""))
        #expect(xml.contains("<dateCreated>Sat, 24 Oct 2026 12:00:00 GMT</dateCreated>"))
        #expect(!xml.contains(#"title="Empty""#), "empty folders are left out")
        #expect(xml.contains(#"xmlUrl="https://example.com/feed?a=1&amp;b=2""#), "attribute values are escaped")
        #expect(xml.contains(#"title="Quotes &quot;and&quot; &lt;tags&gt;""#))
        #expect(xml.contains(#"openfeed:kind="page""#))
        #expect(xml.hasSuffix("</opml>\n"))

        let back = try coder.parse(xml)
        #expect(back.folders.map { [$0.title] + $0.sources.map(\.title) } == [
            ["Labs & Research", "Anthropic News", #"Quotes "and" <tags>"#],
            ["Video", "Fireship"],
        ])
        #expect(back.unfiled.map(\.title) == ["A scraped page", "Orphan (folder not exported)"])
        #expect(back.unfiled.map(\.kind) == [.page, .rss])
        let quoted = back.folders[0].sources[1]
        #expect(quoted.feedUrl == "https://example.com/feed?a=1&b=2")
        #expect(quoted.htmlUrl == "https://example.com")
        #expect(back.folders[1].sources[0].kind == .youtube)
    }

    @Test func newlinesInTitlesBecomeSpaces() {
        let s = Source(title: "Line\r\none\ttwo", url: "https://x.example", feedUrl: "https://x.example/rss", kind: .rss, group: "blogs")
        let xml = coder.serialize(folders: [], sources: [s], now: Date())
        #expect(xml.contains(#"text="Line one two""#))
    }

    static let messy = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- exported by some reader -->
        <opml version="1.0">
          <head><title>Feedly &amp; friends</title></head>
          <body>
            <outline text="Tech" title="Tech">
              <outline type="rss" text="Ars Technica" title="Ars Technica" xmlUrl="https://feeds.arstechnica.com/arstechnica/index" htmlUrl="https://arstechnica.com"/>
              <outline text="AT&amp;amp;T &#8211; Blog" xmlurl="https://att.example/feed"></outline>
              <outline text='Single quoted' XMLURL='https://sq.example/rss'/>
              <!-- <outline text="Commented out" xmlUrl="https://nope.example/rss"/> -->
              <outline text="Sub">
                <outline text="Deep" xmlUrl="https://deep.example/atom.xml"/>
              </outline>
            </outline>
            <outline text="tech">
              <outline text="Merged case-insensitively" xmlUrl="https://merged.example/feed"/>
              <outline text="Ars dup" xmlUrl="https://feeds.arstechnica.com/arstechnica/index"/>
            </outline>
            <outline title="Untitled wrapper has a title attr only">
              <outline text="In wrapper" xmlUrl="feed://wrapped.example/rss"/>
            </outline>
            <outline text="">
              <outline text="Blank folder passes through" xmlUrl="https://blank.example/rss"/>
            </outline>
            <outline type="rss" text="Parent feed" xmlUrl="https://parent.example/rss">
              <outline text="Child of feed" xmlUrl="https://child.example/rss"/>
            </outline>
            <outline text="Top level, no type" xmlUrl="https://top.example/rss"/>
            <outline text="Not a feed, no children"/>
            <outline type="link" text="A link" url="https://link.example/rss"/>
          </body>
        </opml>
        """

    @Test func messyExport() throws {
        let doc = try coder.parse(Self.messy)
        #expect(doc.folders.map { [$0.title] + $0.sources.map(\.title) } == [
            ["Tech", "Ars Technica", "AT&T \u{2013} Blog", "Single quoted", "Merged case-insensitively"],
            ["Sub", "Deep"],
            ["Untitled wrapper has a title attr only", "In wrapper"],
        ])
        #expect(doc.unfiled.map(\.title) == ["Blank folder passes through", "Parent feed", "Child of feed", "Top level, no type", "A link"])
        #expect(doc.folders[2].sources[0].feedUrl == "https://wrapped.example/rss", "feed:// becomes https://")
        #expect(doc.folders[0].sources[0].htmlUrl == "https://arstechnica.com")
        #expect(doc.folders[0].sources[1].htmlUrl == nil)
        #expect(doc.folders.allSatisfy { $0.sources.allSatisfy { $0.kind == nil } }, "foreign exports carry no kind")
    }

    @Test func inoreaderWrapper() throws {
        let xml = #"<?xml version="1.0" encoding="UTF-8"?><opml version="1.0"><head><title>Subscriptions in Inoreader</title></head><body><outline text="Subscriptions" title="Subscriptions"><outline text="News" title="News"><outline text="BBC" title="BBC" type="rss" xmlUrl="https://feeds.bbci.co.uk/news/rss.xml" htmlUrl="https://www.bbc.co.uk/news"/></outline><outline text="Loose" title="Loose" type="rss" xmlUrl="https://loose.example/rss"/></outline></body></opml>"#
        let doc = try coder.parse(xml)
        #expect(doc.folders.map { [$0.title] + $0.sources.map(\.title) } == [["News", "BBC"], ["Subscriptions", "Loose"]])
    }

    @Test func feedSchemes() throws {
        let xml = #"<opml><body><outline text="A" xmlUrl="feed:https://a.example/rss"/><outline text="B" xmlUrl="FEED://b.example/rss"/></body></opml>"#
        let doc = try coder.parse(xml)
        #expect(doc.unfiled.map(\.feedUrl) == ["https://a.example/rss", "https://b.example/rss"])
    }

    @Test func unusualCharacters() throws {
        // A combining mark right after a quote must not glue the quote into one Character.
        let xml = "<opml><body><outline text=\"\u{301}e\r\nx\" xmlUrl=\"https://c.example/rss\"/></body></opml>"
        let doc = try coder.parse(xml)
        #expect(doc.unfiled.map(\.feedUrl) == ["https://c.example/rss"])
        #expect(doc.unfiled.first?.title == "\u{301}e\r\nx")
    }

    @Test func largeFileParsesQuickly() throws {
        let outlines = (0..<2000).map { #"<outline type="rss" text="Feed \#($0) &amp; co" xmlUrl="https://f\#($0).example/rss" htmlUrl="https://f\#($0).example"/>"# }
        let xml = "<opml version=\"2.0\"><body><outline text=\"Big\">" + outlines.joined(separator: "\n") + "</outline></body></opml>"
        let start = Date()
        let doc = try coder.parse(xml)
        #expect(doc.folders.first?.sources.count == 2000)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func entities() {
        #expect(DefaultOPMLCoder.decodeEntities("Tom &amp;amp; Jerry &#x2014; &lt;b&gt; &bogus;") == "Tom & Jerry \u{2014} <b> &bogus;")
        #expect(DefaultOPMLCoder.decodeEntities("&#0; &#X41;") == "&#0; A")
    }

    @Test func rejectsNonOPML() throws {
        #expect(throws: OPMLError.notOPML) { try coder.parse("<rss><channel/></rss>") }
        #expect(throws: OPMLError.notOPML) { try coder.parse("not xml at all") }
        #expect(OPMLError.notOPML.localizedDescription == "Not an OPML file")
        #expect(try coder.parse(#"<opml version="2.0"><body/></opml>"#) == OPMLDocument())
    }

    /// End to end through the database: folders are created, known feeds skipped.
    @Test func importIntoDatabase() async throws {
        let db = try Fixture.db()
        try Fixture.source(db, title: "Ars", url: "https://arstechnica.com", feedUrl: "https://feeds.arstechnica.com/arstechnica/index")
        let result = try await db.importOPML(try coder.parse(Self.messy))
        #expect(result.skipped == 1)
        #expect(result.added == 10)
        #expect(result.foldersCreated == 3)
        #expect(result.errors.isEmpty)
        let (sources, folders) = try await db.sourcesAndFolders()
        #expect(Set(folders.map(\.title)) == ["Tech", "Sub", "Untitled wrapper has a title attr only"])
        #expect(sources.count == 11)

        // Export and re-import into a fresh database round-trips every source.
        let xml = coder.serialize(folders: folders, sources: sources, now: Date())
        let fresh = try Fixture.db()
        let again = try await fresh.importOPML(try coder.parse(xml))
        #expect(again.added == 11)
        #expect(again.foldersCreated == 3)
    }
}
