import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

private func md(_ html: String, base: String? = nil) -> String {
    MarkdownConverter.convert(html, baseURL: base)
}

@Suite("Markdown converter")
struct MarkdownConverterTests {
    @Test func headingsAndParagraphs() {
        #expect(md("<h1>Title</h1><p>One two.</p><h3>Sub <em>head</em></h3><p>Three.</p>")
            == "# Title\n\nOne two.\n\n### Sub *head*\n\nThree.")
    }

    @Test func inlineFormatting() {
        #expect(md("<p>a <strong>bold</strong>, <em>it</em> and <del>gone</del> <code>x = 1</code></p>")
            == "a **bold**, *it* and ~~gone~~ `x = 1`")
        // Edge spaces stay outside the markers; nested same-kind marks collapse.
        #expect(md("<p>a<b> loud </b>b <strong><b>x</b></strong></p>") == "a **loud** b **x**")
        #expect(md("<p>use <code>a`b</code> here</p>") == "use ``a`b`` here")
    }

    @Test func lineBreaksAndWhitespace() {
        #expect(md("<p>one<br>two<br><br>three</p>") == "one  \ntwo\n\nthree")
        #expect(md("<p>  lots \n\n of\t  space&nbsp;&nbsp;here  </p>\n\n\n<p> next </p>") == "lots of space here\n\nnext")
        #expect(md("<div>loose <b>text</b><p>para</p>tail</div>") == "loose **text**\n\npara\n\ntail")
        #expect(md("") == "")
        #expect(md("<p> </p><p><br></p>") == "")
    }

    @Test func escapesOnlyWhatWouldFormat() {
        #expect(md("<p>2 * 3 = 6, snake_case_name, _lead_ and `tick` &lt;b&gt;x</p>")
            == "2 \\* 3 = 6, snake_case_name, \\_lead\\_ and \\`tick\\` \\<b>x")
        #expect(md("<p># not a heading</p><p>- not a list</p><p>1. nor this</p><p>&gt; nor quote</p>")
            == "\\# not a heading\n\n\\- not a list\n\n1\\. nor this\n\n\\> nor quote")
        #expect(md("<p>Fish &amp; chips, AT&amp;T, 5 &lt; 6 &amp;amp; more</p>") == "Fish & chips, AT&T, 5 < 6 \\&amp; more")
        #expect(md("<p>C:\\Users and \\*</p>") == "C:\\Users and \\\\\\*")
    }

    @Test func links() {
        #expect(md("<p>see <a href=\"https://e.com/a\">the post</a>.</p>") == "see [the post](https://e.com/a).")
        #expect(md("<p><a href=\"https://e.com/x\">https://e.com/x</a></p>") == "<https://e.com/x>")
        #expect(md("<p><a href=\"/rel/path?q=1\">rel</a> <a href=\"../up\">up</a> <a href=\"//cdn.e.com/z\">proto</a></p>", base: "https://blog.example.com/posts/one")
            == "[rel](https://blog.example.com/rel/path?q=1) [up](https://blog.example.com/up) [proto](https://cdn.e.com/z)")
        // Fragments, javascript: and empty anchors lose the link but keep the text.
        #expect(md("<p><a href=\"#top\">top</a> <a href=\"javascript:x()\">js</a> <a href=\"https://e.com\"></a>end</p>") == "top js end")
        #expect(md("<p><a href=\"https://e.com/a_(b) c\">wiki</a></p>") == "[wiki](https://e.com/a_%28b%29%20c)")
        #expect(md("<a href=\"https://e.com/p\"><img src=\"/i.png\" alt=\"pic\"></a>", base: "https://e.com/x")
            == "[![pic](https://e.com/i.png)](https://e.com/p)")
    }

    @Test func images() {
        #expect(md("<p><img src=\"https://e.com/a.png\" alt=\"A [big] pic\"></p>") == "![A \\[big\\] pic](https://e.com/a.png)")
        #expect(md("<img src=\"a/b.jpg\">", base: "https://e.com/post/") == "![](https://e.com/post/a/b.jpg)")
        #expect(md("<img srcset=\"https://e.com/s.jpg 1x, https://e.com/l.jpg 2x\" alt=\"s\">") == "![s](https://e.com/s.jpg)")
        #expect(md("<img src=\"data:image/png;base64,AAAA\">") == "")
    }

    @Test func lists() {
        #expect(md("<ul><li>one</li><li>two <b>b</b></li></ul>") == "- one\n- two **b**")
        #expect(md("<ol><li>a</li><li>b</li><li>c</li></ol>") == "1. a\n2. b\n3. c")
        #expect(md("<ol start=\"4\"><li>a</li><li>b</li></ol>") == "4. a\n5. b")
        #expect(md("<ul><li>top<ul><li>mid<ol><li>deep</li></ol></li><li>mid2</li></ul></li><li>last</li></ul>")
            == "- top\n  - mid\n    1. deep\n  - mid2\n- last")
        #expect(md("<ul><li><p>para one</p><p>para two</p></li><li>x</li></ul>") == "- para one\n\n  para two\n- x")
        #expect(md("<p>before</p><ul><li>a</li></ul><p>after</p>") == "before\n\n- a\n\nafter")
    }

    @Test func blockquotes() {
        #expect(md("<blockquote><p>Quoted one.</p><p>Two <i>it</i>.</p></blockquote><p>Out</p>") == "> Quoted one.\n>\n> Two *it*.\n\nOut")
        #expect(md("<blockquote><p>outer</p><blockquote><p>inner</p></blockquote></blockquote>") == "> outer\n>\n> > inner")
    }

    @Test func codeBlocks() {
        #expect(md("<pre><code class=\"language-swift\">let a = 1\n  let b = &lt;2&gt;\n</code></pre>") == "```swift\nlet a = 1\n  let b = <2>\n```")
        #expect(md("<pre>plain\n\n\ttabbed</pre>") == "```\nplain\n\n\ttabbed\n```")
        #expect(md("<pre><code>has ``` inside</code></pre>") == "````\nhas ``` inside\n````")
        #expect(md("<pre><code>a<br>b</code></pre>") == "```\na\nb\n```")
        #expect(md("<ul><li>item<pre><code>code()</code></pre></li></ul>") == "- item\n\n  ```\n  code()\n  ```")
    }

    @Test func tables() {
        let html = "<table><thead><tr><th>Name</th><th>Qty</th></tr></thead><tbody><tr><td>Apple | red</td><td>1</td></tr><tr><td><b>Pear</b></td><td></td></tr></tbody></table>"
        #expect(md(html) == "| Name | Qty |\n| --- | --- |\n| Apple \\| red | 1 |\n| **Pear** |  |")
        // Spanning cells: plain rows instead of a pipe table.
        #expect(md("<table><tr><td colspan=\"2\">Wide</td></tr><tr><td>a</td><td>b</td></tr></table>") == "- Wide\n- a | b")
        // A one-cell layout table is just its content.
        #expect(md("<table><tr><td><p>Hello</p><p>World</p></td></tr></table>") == "Hello\n\nWorld")
    }

    @Test func rulesAndFigures() {
        #expect(md("<p>a</p><hr><p>b</p>") == "a\n\n---\n\nb")
        #expect(md("<figure><img src=\"https://e.com/f.jpg\" alt=\"f\"><figcaption>A <b>caption</b>.</figcaption></figure>")
            == "![f](https://e.com/f.jpg)\n\n*A caption.*")
        #expect(md("<picture><source srcset=\"x.webp\"><img src=\"https://e.com/p.jpg\" alt=\"p\"></picture>") == "![p](https://e.com/p.jpg)")
        #expect(md("<dl><dt>Term</dt><dd>Meaning</dd></dl>") == "**Term**\n\nMeaning")
    }

    @Test func embedsAndDroppedElements() {
        #expect(md("<iframe src=\"https://www.youtube-nocookie.com/embed/abc123?rel=0\"></iframe>") == "[YouTube video](https://www.youtube.com/watch?v=abc123)")
        #expect(md("<iframe src=\"https://player.vimeo.com/video/99\"></iframe>") == "[Vimeo video](https://vimeo.com/99)")
        #expect(md("<iframe src=\"https://ads.example.com/x\"></iframe><p>kept</p>") == "kept")
        #expect(md("<video src=\"https://e.com/v.mp4\" controls></video>") == "[Video](https://e.com/v.mp4)")
        #expect(md("<p>a</p><script>alert(1)</script><style>p{}</style><svg><text>glyph</text></svg><noscript><img src=\"https://e.com/n.png\"></noscript><p>b</p>")
            == "a\n\nb")
    }

    @Test func neverMoreThanOneBlankLine() {
        let out = md("<div><div><p>a</p></div><div></div><div><p></p></div><div><p>b</p></div></div><br><br><br><p>c</p>")
        #expect(!out.contains("\n\n\n"))
        #expect(out == "a\n\nb\n\nc")
    }

    @Test func summariesKeepPlainTextLines() {
        #expect(MarkdownConverter.convertSummary("Line one\nLine two\n\nPara <two> & more") == "Line one  \nLine two\n\nPara \\<two> & more")
        #expect(MarkdownConverter.convertSummary("<p>Html <b>summary</b></p>") == "Html **summary**")
    }

    @Test func wordCountSkipsMarkup() {
        #expect(MarkdownConverter.wordCount("# Title\n\n- one two\n\n---\n\n[three](https://e.com)") == 4)
    }
}

// MARK: Documents

private struct StubExtractor: ContentExtractor {
    var html: String? = "<p>Body text.</p>"
    var fails = false
    struct Boom: Error {}
    func extractArticle(url: String, feed: FeedRef?) async throws -> ExtractResult {
        if fails { throw Boom() }
        return ExtractResult(contentHtml: html, leadImage: nil)
    }
    func extractPodcastNotes(url: String, feed: FeedRef) async throws -> ExtractResult {
        if fails { throw Boom() }
        return ExtractResult(contentHtml: html, leadImage: nil)
    }
}

private struct StubTranscripts: TranscriptFetching {
    var result: Transcript?
    var fails = false
    struct Boom: Error {}
    func transcript(for item: Item, source: Source) async throws -> Transcript? {
        if fails { throw Boom() }
        return result
    }
}

private let utc = TimeZone(identifier: "UTC")!

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private let now = date(2026, 10, 27, 8, 4)

private func service(_ db: AppDatabase, extractor: StubExtractor = StubExtractor(), transcripts: StubTranscripts = StubTranscripts()) -> CopyService {
    var svc = CopyService(database: db, content: ContentService(database: db, extractor: extractor), transcripts: transcripts)
    svc.timeZone = utc
    return svc
}

@discardableResult
private func insert(_ db: AppDatabase, _ source: Source, _ item: ParsedItem) throws -> Int64 {
    try Fixture.items(db, sourceId: source.id, [item])[0].id
}

@Suite("Copy as Markdown: item")
struct CopyItemTests {
    @Test func articleDocument() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, title: "Simon's Blog", url: "https://blog.example.com")
        let id = try insert(db, src, ParsedItem(guid: "a", url: "https://blog.example.com/posts/one", title: "  Hello\n World ", summary: "Feed summary",
                                                author: "Simon", publishedAt: date(2026, 10, 27), hnCommentsUrl: "https://news.ycombinator.com/item?id=1"))
        let out = try await service(db, extractor: StubExtractor(html: "<h2>Intro</h2><p>Read <a href=\"/more\">more</a>.</p>")).markdown(forItem: id)
        #expect(out.markdown == """
            # Hello World
            Simon · Simon's Blog · October 27, 2026
            https://blog.example.com/posts/one
            Discussion: https://news.ycombinator.com/item?id=1

            ## Intro

            Read [more](https://blog.example.com/more).
            """)
        #expect(out.wordCount == 3)
        #expect(out.itemCount == 1)
        #expect(out.note == nil)
    }

    @Test func authorOmittedWhenSameAsSource() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, title: "Acme")
        let id = try insert(db, src, ParsedItem(guid: "a", url: "https://e.com/a", title: "T", author: "acme", publishedAt: date(2026, 10, 27)))
        let out = try await service(db).markdown(forItem: id)
        #expect(out.markdown.hasPrefix("# T\nAcme · October 27, 2026\nhttps://e.com/a\n\nBody text."))
        let noAuthor = try insert(db, src, ParsedItem(guid: "b", url: "https://e.com/b", title: "T2", author: "", publishedAt: date(2026, 10, 27)))
        #expect(try await service(db).markdown(forItem: noAuthor).markdown.contains("\nAcme · October 27, 2026\n"))
    }

    @Test func articleFallsBackToFeedSummary() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db)
        let id = try insert(db, src, ParsedItem(guid: "a", url: "https://e.com/a", title: "T", summary: "<p>Only <b>this</b> much.</p>", publishedAt: date(2026, 10, 27)))
        let out = try await service(db, extractor: StubExtractor(html: nil)).markdown(forItem: id)
        #expect(out.markdown.hasSuffix("\n\nOnly **this** much."))
        #expect(out.note?.contains("feed summary") == true)
        #expect(out.wordCount == 3)
    }

    @Test func extractionErrorsPropagateAndUnknownIdThrows() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db)
        let id = try insert(db, src, ParsedItem(guid: "a", url: "https://e.com/a", title: "T", publishedAt: date(2026, 10, 27)))
        await #expect(throws: (any Error).self) { try await service(db, extractor: StubExtractor(fails: true)).markdown(forItem: id) }
        await #expect(throws: QueryError.notFound("Item")) { try await service(db).markdown(forItem: 9999) }
    }

    @Test func promptComesFirst() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db)
        let id = try insert(db, src, ParsedItem(guid: "a", url: "https://e.com/a", title: "T", publishedAt: date(2026, 10, 27)))
        let svc = service(db)
        let plain = try await svc.markdown(forItem: id).markdown
        let withPrompt = try await svc.markdown(forItem: id, prompt: "  Summarize this.\n")
        #expect(withPrompt.markdown == "Summarize this.\n\n---\n\n" + plain)
        #expect(try await svc.markdown(forItem: id, prompt: " \n ").markdown == plain)
        #expect(withPrompt.wordCount == 2)
    }

    @Test func youtubeWithTranscript() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, title: "Fireship", url: "https://www.youtube.com/channel/UC1", kind: .youtube, group: "youtube")
        let id = try insert(db, src, ParsedItem(guid: "yt1", url: "https://www.youtube.com/watch?v=abc", title: "100 Seconds of Code",
                                                summary: "In this video.\nSee https://e.com", publishedAt: date(2026, 10, 27), videoId: "abc", durationSec: 125))
        let cues = [("Hello", 0.0), ("and welcome", 2.5), ("to the show.", 5), ("Next part", 31), ("starts here", 33), ("Much later", 100)]
            .map { Transcript.Segment(start: $0.1, text: $0.0) }
        let out = try await service(db, transcripts: StubTranscripts(result: Transcript(origin: .youtubeCaptions, segments: cues))).markdown(forItem: id)
        #expect(out.markdown == """
            # 100 Seconds of Code
            Fireship · YouTube · October 27, 2026 · 2:05
            https://www.youtube.com/watch?v=abc

            ## Description

            In this video.  
            See https://e.com

            ## Transcript (YouTube captions)

            [0:00] Hello and welcome to the show.

            [0:31] Next part starts here

            [1:40] Much later
            """)
        #expect(out.note == nil)
        #expect(out.wordCount == 5 + 12)
    }

    @Test func youtubeWithoutTranscript() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, title: "Chan", url: "https://www.youtube.com/channel/UC2", kind: .youtube, group: "youtube")
        let id = try insert(db, src, ParsedItem(guid: "yt1", url: "https://www.youtube.com/watch?v=abc", title: "Vid", summary: "About it", publishedAt: date(2026, 10, 27)))
        for stub in [StubTranscripts(result: nil), StubTranscripts(fails: true)] {
            let out = try await service(db, transcripts: stub).markdown(forItem: id)
            #expect(out.markdown == "# Vid\nChan · YouTube · October 27, 2026\nhttps://www.youtube.com/watch?v=abc\n\n## Description\n\nAbout it")
            #expect(out.note == "No transcript, so this has the description.")
            #expect(out.wordCount == 2)
        }
    }

    @Test func podcastWithSpeakersAndLongTimestamps() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, title: "The Show", url: "https://show.example.com", kind: .podcast, group: "podcast")
        let id = try insert(db, src, ParsedItem(guid: "ep1", url: "https://show.example.com/ep1", title: "Episode 1", summary: "feed notes",
                                                author: "Host", publishedAt: date(2026, 10, 27), durationSec: 5025, audioUrl: "https://show.example.com/ep1.mp3"))
        let segs = [
            Transcript.Segment(start: 0, speaker: "Ann", text: "Welcome."),
            Transcript.Segment(start: 4, speaker: "Ann", text: "Today we talk shop."),
            Transcript.Segment(start: 9, speaker: "Bob", text: "Thanks for having me."),
            Transcript.Segment(start: 3725, speaker: nil, text: "Closing\nthoughts."),
        ]
        let out = try await service(db, extractor: StubExtractor(html: "<p>Notes for <b>ep 1</b>.</p>"),
                                    transcripts: StubTranscripts(result: Transcript(origin: .podcastFeed, segments: segs))).markdown(forItem: id)
        #expect(out.markdown == """
            # Episode 1
            The Show · October 27, 2026 · 1:23:45
            https://show.example.com/ep1

            ## Show notes

            Notes for **ep 1**.

            ## Transcript (from the podcast feed)

            [0:00:00] Ann: Welcome. Today we talk shop.

            [0:00:09] Bob: Thanks for having me.

            [1:02:05] Closing thoughts.
            """)
        #expect(out.note == nil)
    }

    @Test func podcastWithoutTranscriptUsesShowNotes() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, title: "The Show", url: "https://show.example.com", kind: .podcast, group: "podcast")
        let id = try insert(db, src, ParsedItem(guid: "ep1", url: "https://show.example.com/ep1", title: "Ep", publishedAt: date(2026, 10, 27)))
        let out = try await service(db, transcripts: StubTranscripts(fails: true)).markdown(forItem: id)
        #expect(out.markdown.contains("## Show notes\n\nBody text."))
        #expect(!out.markdown.contains("Transcript"))
        #expect(out.note == "No transcript, so this has the show notes.")
    }

    @Test func untimedTranscriptIsParagraphs() {
        let t = Transcript(origin: .podcastFeed, segments: [
            Transcript.Segment(start: nil, speaker: "Ann", text: "First."),
            Transcript.Segment(start: nil, text: "# Second"),
        ])
        #expect(ItemMarkdown.transcriptText(t, long: false) == "Ann: First.\n\n\\# Second")
    }

    @Test func transcriptBreaksAtSentenceAfterTwentySeconds() {
        let t = Transcript(origin: .youtubeCaptions, segments: [
            Transcript.Segment(start: 0, text: "one"), Transcript.Segment(start: 10, text: "two."),
            Transcript.Segment(start: 21, text: "three"), Transcript.Segment(start: 70, text: "four"),
        ])
        #expect(ItemMarkdown.transcriptText(t, long: false) == "[0:00] one two.\n\n[0:21] three\n\n[1:10] four")
    }
}

// MARK: Digest

@Suite("Copy as Markdown: digest")
struct CopyDigestTests {
    @Test func sinceFiltersAndNewestFirst() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db, title: "Blog")
        try insert(db, src, ParsedItem(guid: "old", url: "https://e.com/old", title: "Old", summary: "old", publishedAt: now.addingTimeInterval(-30 * 3600)))
        try insert(db, src, ParsedItem(guid: "mid", url: "https://e.com/mid", title: "Mid", summary: "<p>Mid &amp; <b>summary</b> text</p>", publishedAt: now.addingTimeInterval(-5 * 3600)))
        try insert(db, src, ParsedItem(guid: "new", url: "https://e.com/new", title: "New", publishedAt: now.addingTimeInterval(-3600)))
        let out = try await service(db).digest(ItemQuery(), title: "All", since: now.addingTimeInterval(-24 * 3600), now: now)
        #expect(out.markdown == """
            # All · last 24 hours
            2 items · copied October 27, 2026 at 8:04 AM

            ## New
            Blog · Oct 27, 7:04 AM · https://e.com/new

            ## Mid
            Blog · Oct 27, 3:04 AM · https://e.com/mid
            Mid & summary text
            """)
        #expect(out.itemCount == 2)
        #expect(out.wordCount == 3)
        #expect(out.note == nil)
        // Boundary is inclusive; the old item appears once the window widens.
        let week = try await service(db).digest(ItemQuery(), title: "All", since: now.addingTimeInterval(-7 * 86400), now: now)
        #expect(week.itemCount == 3)
        #expect(week.markdown.hasPrefix("# All · last 7 days\n3 items"))
    }

    @Test func rangeLabels() async throws {
        let db = try Fixture.db()
        let svc = service(db)
        let custom = try await svc.digest(ItemQuery(), title: "X", since: date(2026, 10, 20, 0, 0), now: now)
        #expect(custom.markdown.hasPrefix("# X · since October 20, 2026\n"))
        #expect(custom.itemCount == 0)
    }

    @Test func emptyDigestIsStillValid() async throws {
        let db = try Fixture.db()
        let out = try await service(db).digest(ItemQuery(), title: "News", since: now.addingTimeInterval(-86400), now: now)
        #expect(out.markdown == "# News · last 24 hours\n0 items · copied October 27, 2026 at 8:04 AM\n\nNo items in this period.")
        #expect(out.itemCount == 0)
        #expect(out.wordCount == 0)
    }

    @Test func scopedToFolderSourceAndView() async throws {
        let db = try Fixture.db()
        let folder = try await db.createFolder(title: "Labs")
        let inFolder = try Fixture.source(db, title: "In", url: "https://in.example.com", folderId: folder.id)
        let other = try Fixture.source(db, title: "Out", url: "https://out.example.com")
        let yt = try Fixture.source(db, title: "Vids", url: "https://www.youtube.com/channel/UC9", kind: .youtube, group: "youtube")
        let t = now.addingTimeInterval(-3600)
        try insert(db, inFolder, ParsedItem(guid: "a", url: "https://in.example.com/a", title: "In A", publishedAt: t))
        try insert(db, other, ParsedItem(guid: "b", url: "https://out.example.com/b", title: "Out B", publishedAt: t))
        try insert(db, yt, ParsedItem(guid: "c", url: "https://www.youtube.com/watch?v=c", title: "Vid C", publishedAt: t))
        let svc = service(db)
        let since = now.addingTimeInterval(-86400)
        let byFolder = try await svc.digest(ItemQuery(folderId: folder.id), title: "Labs", since: since, now: now)
        #expect(byFolder.markdown.contains("In A") && !byFolder.markdown.contains("Out B"))
        let bySource = try await svc.digest(ItemQuery(sourceId: other.id), title: "Out", since: since, now: now)
        #expect(bySource.itemCount == 1 && bySource.markdown.contains("Out B"))
        let byView = try await svc.digest(ItemQuery(view: .video), title: "Video", since: since, now: now)
        #expect(byView.itemCount == 1 && byView.markdown.contains("Vid C"))
        // Cursor and search on the incoming query are ignored.
        let ignoring = ItemQuery(search: "nomatch", cursor: ItemCursor(publishedAt: date(2020, 1, 1), id: 1))
        #expect(try await svc.digest(ignoring, title: "All", since: since, now: now).itemCount == 3)
    }

    @Test func summariesTruncateAtWordBoundary() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db)
        let long = (0..<200).map { "word\($0)" }.joined(separator: " ")
        try insert(db, src, ParsedItem(guid: "a", url: "https://e.com/a", title: "Long", summary: "<p>\(long)</p>", publishedAt: now.addingTimeInterval(-60)))
        let out = try await service(db).digest(ItemQuery(), title: "All", since: now.addingTimeInterval(-86400), now: now)
        let summary = try #require(out.markdown.split(separator: "\n").last.map(String.init))
        #expect(summary.hasSuffix("…"))
        #expect(summary.count <= 281)
        let words = summary.dropLast().split(separator: " ")
        // Whole words only: every kept word is a complete original word, in order.
        #expect(words.enumerated().allSatisfy { $0.element == "word\($0.offset)" })
        #expect(words.count > 30)
        #expect(out.wordCount == words.count)
    }

    @Test func capsAtTwoHundredNewest() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db)
        let items = (0..<205).map { i in
            ParsedItem(guid: "g\(i)", url: "https://e.com/\(i)", title: "Item \(i)", publishedAt: now.addingTimeInterval(-60 - Double(i)))
        }
        try Fixture.items(db, sourceId: src.id, items)
        let out = try await service(db).digest(ItemQuery(limit: 5), title: "All", since: now.addingTimeInterval(-86400), now: now)
        #expect(out.itemCount == 200)
        #expect(out.markdown.contains("\nnewest 200 items · copied "))
        #expect(out.markdown.contains("## Item 0\n"))
        #expect(out.markdown.contains("## Item 199\n"))
        #expect(!out.markdown.contains("## Item 200\n"))
    }

    @Test func promptPrefixesDigest() async throws {
        let db = try Fixture.db()
        let out = try await service(db).digest(ItemQuery(), title: "All", since: now.addingTimeInterval(-86400), now: now, prompt: "What mattered?")
        #expect(out.markdown.hasPrefix("What mattered?\n\n---\n\n# All · last 24 hours\n"))
    }

    @Test func sinceQueryFiltersAtTheDatabase() async throws {
        let db = try Fixture.db()
        let src = try Fixture.source(db)
        try insert(db, src, ParsedItem(guid: "a", url: "https://e.com/a", title: "A", publishedAt: date(2026, 10, 1)))
        try insert(db, src, ParsedItem(guid: "b", url: "https://e.com/b", title: "B", publishedAt: date(2026, 10, 10)))
        let page = try await db.items(ItemQuery(since: date(2026, 10, 10)))
        #expect(page.items.map(\.item.title) == ["B"])
        #expect(try await db.items(ItemQuery()).items.count == 2)
    }
}
