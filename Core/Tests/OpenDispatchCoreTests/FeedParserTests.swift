import Foundation
import Testing
@testable import OpenDispatchCore

/// Hand-written fixtures, ported from scripts/parse-check.ts.
private enum ParseFixtures {
    static let hn = #"""
    <?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>Hacker News: Newest</title><link>https://news.ycombinator.com/newest</link>
    <item><title>Show HN: A tiny thing</title><description><![CDATA[
    <p>Article URL: <a href="https://example.com/post">https://example.com/post</a></p>
    <p>Comments URL: <a href="https://news.ycombinator.com/item?id=4242">https://news.ycombinator.com/item?id=4242</a></p>
    <p>Points: 187</p>
    <p># Comments: 64</p>
    ]]></description><pubDate>Fri, 23 Oct 2026 18:01:02 +0000</pubDate><link>https://example.com/post</link><dc:creator>pg</dc:creator><comments>https://news.ycombinator.com/item?id=4242</comments><guid isPermaLink="false">https://news.ycombinator.com/item?id=4242</guid></item>
    </channel></rss>
    """#

    static let youTube = #"""
    <?xml version="1.0" encoding="UTF-8"?><feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
    <title>Fireship</title><link rel="alternate" href="https://www.youtube.com/channel/UCsBjURrPoezykLs9EqgamOA"/>
    <entry><id>yt:video:dQw4w9WgXcQ</id><yt:videoId>dQw4w9WgXcQ</yt:videoId><yt:channelId>UCsBjURrPoezykLs9EqgamOA</yt:channelId><title>Rust in 100 seconds</title><link rel="alternate" href="https://www.youtube.com/watch?v=dQw4w9WgXcQ"/><author><name>Fireship</name></author><published>2026-10-22T14:00:00+00:00</published><updated>2026-10-22T15:00:00+00:00</updated>
    <media:group><media:title>Rust in 100 seconds</media:title><media:content url="https://www.youtube.com/v/dQw4w9WgXcQ?version=3" type="application/x-shockwave-flash" width="640" height="390"/><media:thumbnail url="https://i2.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg" width="480" height="360"/><media:description>Learn Rust fast. Links &amp; more below.</media:description></media:group></entry></feed>
    """#

    static let blog = #"""
    <?xml version="1.0"?><rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Blog</title><link>https://blog.example.com/</link>
    <item><title>Hello</title><link>/posts/hello</link><guid>abc</guid><pubDate>Thu, 22 Oct 2026 10:00:00 GMT</pubDate><description>Short &lt;b&gt;desc&lt;/b&gt;</description><content:encoded><![CDATA[<p>Body <img src="/img/a.png"></p>]]></content:encoded></item>
    <item><title>With media</title><link>https://blog.example.com/m</link><media:content url="https://cdn.example.com/x.jpg" medium="image"/></item>
    </channel></rss>
    """#

    static let podcast = #"""
    <?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel>
    <title>The Show</title><link>https://show.example.com/</link><itunes:author>Host</itunes:author><itunes:image href="https://cdn.example.com/show.jpg"/>
    <item><title>Ep 2</title><link>https://show.example.com/ep2</link><guid isPermaLink="false">ep-2</guid><pubDate>Thu, 22 Oct 2026 10:00:00 GMT</pubDate>
    <enclosure url="https://cdn.example.com/ep2.mp3" length="1" type="audio/mpeg"/><itunes:duration>1:02:03</itunes:duration><itunes:image href="https://cdn.example.com/ep2.jpg"/>
    <content:encoded><![CDATA[<p>Show notes for two. <img src="https://ads.example.com/sponsor.png"></p>]]></content:encoded></item>
    <item><title>Ep 1</title><guid isPermaLink="false">ep-1</guid><pubDate>Wed, 21 Oct 2026 10:00:00 GMT</pubDate>
    <enclosure url="https://cdn.example.com/ep1.m4a" length="1"/><itunes:duration>1800</itunes:duration>
    <description>Plain notes.

    Second paragraph &amp; more.</description></item>
    </channel></rss>
    """#

    static func hnItem(_ id: Int, _ title: String, _ link: String, _ points: Int, _ date: String) -> String {
        """
        <item><title><![CDATA[\(title)]]></title><description><![CDATA[
        <p>Comments URL: <a href="https://news.ycombinator.com/item?id=\(id)">https://news.ycombinator.com/item?id=\(id)</a></p>
        <p>Points: \(points)</p>
        <p># Comments: 1</p>
        ]]></description><pubDate>\(date)</pubDate><link>\(link)</link><dc:creator>x</dc:creator><comments>https://news.ycombinator.com/item?id=\(id)</comments><guid isPermaLink="false">https://news.ycombinator.com/item?id=\(id)</guid></item>
        """
    }

    static func matchFeed(_ rows: String) -> String {
        #"<?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>M</title><link>https://m.example.com/</link>"#
            + rows + "</channel></rss>"
    }

    static func matchRow(_ link: String, _ guid: String?, _ body: String) -> String {
        "<item><title>\(body)</title><link>\(link)</link>\(guid.map { "<guid>\($0)</guid>" } ?? "")<content:encoded><![CDATA[<p>\(body)</p>]]></content:encoded></item>"
    }
}

private func data(_ s: String) -> Data { Data(s.utf8) }
private func utc(_ iso: String) -> Date? { ISO8601.date(from: iso) }
private let parser = DefaultFeedParser()

@Suite("FeedParser: parse-check fixtures")
struct FeedParserFixtureTests {
    @Test func hackerNews() throws {
        let feed = try parser.parse(data(ParseFixtures.hn), kind: .rss, feedURL: "https://hnrss.org/newest?points=100")
        #expect(feed.title == "Hacker News: Newest")
        #expect(feed.link == "https://news.ycombinator.com/newest")
        #expect(feed.isPodcast == false)
        let item = try #require(feed.items.first)
        #expect(item.guid == "https://news.ycombinator.com/item?id=4242")
        #expect(item.url == "https://example.com/post")
        #expect(item.title == "Show HN: A tiny thing")
        #expect(item.author == "pg")
        #expect(item.summary == nil)
        #expect(item.thumbnailUrl == nil)
        #expect(item.hnPoints == 187)
        #expect(item.hnComments == 64)
        #expect(item.hnCommentsUrl == "https://news.ycombinator.com/item?id=4242")
        #expect(item.publishedAt == utc("2026-10-23T18:01:02Z"))
    }

    @Test func hnRulesOnlyForHnrss() throws {
        let feed = try parser.parse(data(ParseFixtures.hn), kind: .rss, feedURL: "https://example.com/feed")
        let item = try #require(feed.items.first)
        #expect(item.hnPoints == nil)
        #expect(item.hnCommentsUrl == nil)
        #expect(item.summary?.hasPrefix("Article URL: https://example.com/post") == true)
    }

    @Test func youTube() throws {
        let feed = try parser.parse(data(ParseFixtures.youTube), kind: .youtube,
                                    feedURL: "https://www.youtube.com/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA")
        #expect(feed.title == "Fireship")
        #expect(feed.link == "https://www.youtube.com/channel/UCsBjURrPoezykLs9EqgamOA")
        #expect(feed.isPodcast == false)
        let item = try #require(feed.items.first)
        #expect(item.guid == "yt:video:dQw4w9WgXcQ")
        #expect(item.url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(item.title == "Rust in 100 seconds")
        #expect(item.author == "Fireship")
        #expect(item.videoId == "dQw4w9WgXcQ")
        #expect(item.thumbnailUrl == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        #expect(item.summary == "Learn Rust fast. Links & more below.")
        #expect(item.publishedAt == utc("2026-10-22T14:00:00Z"))
        #expect(item.audioUrl == nil && item.durationSec == nil)
    }

    @Test func youTubeVideoIdFromEntryId() throws {
        let xml = ParseFixtures.youTube.replacingOccurrences(of: "<yt:videoId>dQw4w9WgXcQ</yt:videoId>", with: "")
        let item = try #require(try parser.parse(data(xml), kind: .youtube, feedURL: "https://www.youtube.com/feeds/videos.xml").items.first)
        #expect(item.videoId == "dQw4w9WgXcQ")
        #expect(item.thumbnailUrl == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    }

    @Test func blog() throws {
        let feed = try parser.parse(data(ParseFixtures.blog), kind: .rss, feedURL: "https://blog.example.com/feed")
        #expect(feed.items.count == 2)
        let hello = feed.items[0]
        #expect(hello.guid == "abc")
        #expect(hello.url == "https://blog.example.com/posts/hello")
        #expect(hello.summary == "Short desc")
        #expect(hello.thumbnailUrl == "https://blog.example.com/img/a.png")
        #expect(hello.publishedAt == utc("2026-10-22T10:00:00Z"))
        let media = feed.items[1]
        #expect(media.guid == "https://blog.example.com/m")
        #expect(media.thumbnailUrl == "https://cdn.example.com/x.jpg")
        #expect(media.summary == nil)
        #expect(feed.isPodcast == false)
        #expect(feed.items.allSatisfy { $0.audioUrl == nil && $0.durationSec == nil })
    }

    @Test func missingDateFallsBackToNow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let feed = try parser.parse(data(ParseFixtures.blog), kind: .rss, feedURL: "https://blog.example.com/feed", now: now)
        #expect(feed.items[1].publishedAt == now)
    }

    @Test func podcast() throws {
        let feed = try parser.parse(data(ParseFixtures.podcast), kind: .rss, feedURL: "https://show.example.com/feed.xml")
        #expect(feed.isPodcast)
        #expect(feed.imageUrl == "https://cdn.example.com/show.jpg")
        let e2 = feed.items[0], e1 = feed.items[1]
        #expect(e2.audioUrl == "https://cdn.example.com/ep2.mp3")
        #expect(e2.durationSec == 3723)
        // Episode art beats the sponsor image in the notes.
        #expect(e2.thumbnailUrl == "https://cdn.example.com/ep2.jpg")
        #expect(e2.summary == "Show notes for two.")
        // No type, audio extension; no link and an opaque guid -> the show page; show art fallback.
        #expect(e1.audioUrl == "https://cdn.example.com/ep1.m4a")
        #expect(e1.durationSec == 1800)
        #expect(e1.url == "https://show.example.com/")
        #expect(e1.guid == "ep-1")
        #expect(e1.thumbnailUrl == "https://cdn.example.com/show.jpg")
        #expect(e1.summary == "Plain notes. Second paragraph & more.")
    }

    @Test func podcastAsYouTubeKindHasNoAudio() throws {
        let feed = try parser.parse(data(ParseFixtures.podcast), kind: .youtube, feedURL: "https://show.example.com/feed.xml")
        #expect(feed.isPodcast == false)
        #expect(feed.items.allSatisfy { $0.audioUrl == nil })
    }

    @Test func hnDuplicatesKeepEveryItem() throws {
        let rows = [
            ParseFixtures.hnItem(50224422, "Missileer", "https://missileer.watch", 111, "Sat, 24 Oct 2026 19:43:27 +0000"),
            ParseFixtures.hnItem(50224300, "The Goose Programming Language", "https://aardappel.github.io/goose/", 170, "Sat, 24 Oct 2026 19:27:41 +0000"),
            ParseFixtures.hnItem(50224100, "The Goose Programming Language", "https://aardappel.github.io/goose/", 231, "Sat, 24 Oct 2026 19:06:55 +0000"),
        ].joined(separator: "\n")
        let xml = #"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>Hacker News: Newest</title><link>https://news.ycombinator.com/newest</link>"#
            + rows + "</channel></rss>"
        let feed = try parser.parse(data(xml), kind: .rss, feedURL: "https://hnrss.org/newest?points=100")
        #expect(feed.items.map(\.hnPoints) == [111, 170, 231])
        #expect(feed.items.map(\.url) == ["https://missileer.watch/", "https://aardappel.github.io/goose/", "https://aardappel.github.io/goose/"])
        #expect(feed.items.map(\.title)[1] == "The Goose Programming Language")
    }

    @Test func itemHTMLMatching() {
        let byQuery = data(ParseFixtures.matchFeed(
            ParseFixtures.matchRow("https://m.example.com/article.php?id=1", nil, "ONE")
                + ParseFixtures.matchRow("https://m.example.com/article.php?id=2", nil, "TWO")))
        #expect(parser.itemHTML(in: byQuery, guid: "x", url: "https://m.example.com/article.php?id=2")?.contains("TWO") == true)
        #expect(parser.itemHTML(in: byQuery, guid: "x", url: "https://m.example.com/article.php?id=1#top")?.contains("ONE") == true)
        #expect(parser.itemHTML(in: byQuery, guid: "x", url: "https://m.example.com/article.php?id=3") == nil)
        let byGuid = data(ParseFixtures.matchFeed(
            ParseFixtures.matchRow("https://m.example.com/p/", "g-a", "A") + ParseFixtures.matchRow("https://m.example.com/p/", "g-b", "B")))
        #expect(parser.itemHTML(in: byGuid, guid: "g-b", url: "https://m.example.com/p") == "<p>B</p>")
        #expect(parser.itemHTML(in: byGuid, guid: "zzz", url: "https://m.example.com/p") == "<p>A</p>")
        #expect(parser.itemHTML(in: data("<html><body>nope</body></html>"), guid: "a", url: "https://x") == nil)
    }

    @Test func itemHTMLFallsBackToDescriptionThenItunesSummary() {
        let feed = data(ParseFixtures.podcast)
        #expect(parser.itemHTML(in: feed, guid: "ep-2", url: "") == #"<p>Show notes for two. <img src="https://ads.example.com/sponsor.png"></p>"#)
        #expect(parser.itemHTML(in: feed, guid: "ep-1", url: "")?.hasPrefix("Plain notes.") == true)
        let summaryOnly = #"<rss><channel><item><guid>s</guid><link>https://x.com/a</link><itunes:summary xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">  Just a summary  </itunes:summary></item></channel></rss>"#
        #expect(parser.itemHTML(in: data(summaryOnly), guid: "s", url: "") == "Just a summary")
    }
}

@Suite("FeedParser: helpers")
struct FeedParsingSupportTests {
    @Test func duration() {
        #expect(FeedParsingSupport.parseDuration("1:02:03") == 3723)
        #expect(FeedParsingSupport.parseDuration("45:30") == 2730)
        #expect(FeedParsingSupport.parseDuration("1800") == 1800)
        #expect(FeedParsingSupport.parseDuration("1800.6") == 1801)
        #expect(FeedParsingSupport.parseDuration("00:29:41") == 1781)
        #expect(FeedParsingSupport.parseDuration("abc") == nil)
        #expect(FeedParsingSupport.parseDuration("") == nil)
        #expect(FeedParsingSupport.parseDuration("0") == nil)
        #expect(FeedParsingSupport.parseDuration("1:2:3:4") == nil)
        #expect(FeedParsingSupport.parseDuration(nil) == nil)
    }

    @Test func audioEnclosure() {
        #expect(FeedParsingSupport.audioEnclosure(url: "https://x/a.mp3", type: "audio/mpeg") == "https://x/a.mp3")
        #expect(FeedParsingSupport.audioEnclosure(url: "https://x/a.mp3?u=1", type: nil) == "https://x/a.mp3?u=1")
        #expect(FeedParsingSupport.audioEnclosure(url: "https://x/a.jpg", type: "image/jpeg") == nil)
        #expect(FeedParsingSupport.audioEnclosure(url: "https://x/a.mp4", type: "video/mp4") == nil)
        #expect(FeedParsingSupport.audioEnclosure(url: "https://x/a.MP3", type: "application/octet-stream") == "https://x/a.MP3")
        #expect(FeedParsingSupport.audioEnclosure(url: "https://x/a", type: "application/octet-stream") == nil)
        #expect(FeedParsingSupport.audioEnclosure(url: "  ", type: "audio/mpeg") == nil)
    }

    @Test func podcastHeuristic() {
        #expect(FeedParsingSupport.feedLooksLikePodcast(hasItunesTags: false, itemCount: 10, audioCount: 0) == false)
        #expect(FeedParsingSupport.feedLooksLikePodcast(hasItunesTags: false, itemCount: 10, audioCount: 5))
        #expect(FeedParsingSupport.feedLooksLikePodcast(hasItunesTags: false, itemCount: 10, audioCount: 3) == false)
        #expect(FeedParsingSupport.feedLooksLikePodcast(hasItunesTags: true, itemCount: 10, audioCount: 3))
        #expect(FeedParsingSupport.feedLooksLikePodcast(hasItunesTags: true, itemCount: 10, audioCount: 2) == false)
    }

    @Test func stripHTML() {
        #expect(FeedParsingSupport.stripHTML(nil) == nil)
        #expect(FeedParsingSupport.stripHTML("   ") == nil)
        #expect(FeedParsingSupport.stripHTML("<p>a</p><script>x()</script><style>p{}</style><p>b &amp; c&nbsp;d</p>") == "a b & c d")
        let long = String(repeating: "word ", count: 200)
        let cut = FeedParsingSupport.stripHTML(long, max: 12)
        #expect(cut == "word word w…")
        #expect(FeedParsingSupport.stripHTML("short", max: 12) == "short")
    }

    @Test func hnDescription() {
        let d = FeedParsingSupport.parseHNDescription("<p>Points: 12</p><p>#&nbsp;Comments: 3</p>")
        #expect(d.points == 12)
        #expect(d.comments == 3)
        #expect(FeedParsingSupport.parseHNDescription(nil).points == nil)
        #expect(FeedParsingSupport.isHNFeed("https://hnrss.org/newest?points=100"))
        #expect(FeedParsingSupport.isHNFeed("https://api.hnrss.org/x"))
        #expect(FeedParsingSupport.isHNFeed("https://nothnrss.org/x") == false)
        #expect(FeedParsingSupport.isHNFeed("not a url") == false)
    }

    @Test func absolutize() {
        typealias S = FeedParsingSupport
        #expect(S.absolutize("/a/b", base: "https://Example.com/feed") == "https://example.com/a/b")
        #expect(S.absolutize("https://x.com", base: nil) == "https://x.com/")
        #expect(S.absolutize("//cdn.x.com/i.png", base: "https://x.com/post") == "https://cdn.x.com/i.png")
        #expect(S.absolutize("../img/a.png", base: "https://x.com/a/b/post.html") == "https://x.com/a/img/a.png")
        #expect(S.absolutize("img.png?w=1&amp;h=2", base: "https://x.com/a/") == "https://x.com/a/img.png?w=1&h=2")
        #expect(S.absolutize("https://x.com/i.webp?q=90&#038;strip=all", base: nil) == "https://x.com/i.webp?q=90&strip=all")
        #expect(S.absolutize("relative/only", base: nil) == nil)
        #expect(S.absolutize("", base: "https://x.com") == nil)
        #expect(S.absolutize(nil, base: "https://x.com") == nil)
        #expect(S.absolutize("mailto:a@b.c", base: nil) == "mailto:a@b.c")
    }

    @Test func linkMatchKey() {
        #expect(FeedParsingSupport.linkMatchKey(" https://m.example.com/p/ ") == "https://m.example.com/p")
        #expect(FeedParsingSupport.linkMatchKey("https://m.example.com/p/?id=1#x") == "https://m.example.com/p?id=1")
        #expect(FeedParsingSupport.linkMatchKey("https://m.example.com/article.php?id=1") == "https://m.example.com/article.php?id=1")
    }

    @Test func dates() {
        typealias S = FeedParsingSupport
        #expect(S.date(from: "Fri, 23 Oct 2026 18:01:02 +0000") == utc("2026-10-23T18:01:02Z"))
        #expect(S.date(from: "Thu, 22 Oct 2026 10:00:00 GMT") == utc("2026-10-22T10:00:00Z"))
        #expect(S.date(from: "Thu, 22 Oct 2026 06:00:00 EDT") == utc("2026-10-22T10:00:00Z"))
        #expect(S.date(from: "22 Oct 2026 10:00 +0200") == utc("2026-10-22T08:00:00Z"))
        #expect(S.date(from: "Thursday, 22 October 2026 10:00:00 +0000") == utc("2026-10-22T10:00:00Z"))
        #expect(S.date(from: "Thu, 22 Oct 2026 10:00:00 +01:00") == utc("2026-10-22T09:00:00Z"))
        #expect(S.date(from: "2026-10-25T09:25:32-04:00") == utc("2026-10-25T13:25:32Z"))
        #expect(S.date(from: "2026-10-25T09:25:32.123Z")?.timeIntervalSince1970.rounded(.down) == utc("2026-10-25T09:25:32Z")?.timeIntervalSince1970)
        #expect(S.date(from: "2026-10-25T09:25:32.123456+0000")?.timeIntervalSince1970.rounded(.down) == utc("2026-10-25T09:25:32Z")?.timeIntervalSince1970)
        #expect(S.date(from: "2026-10-25 09:25:32 +0000") == utc("2026-10-25T09:25:32Z"))
        #expect(S.date(from: "2026-10-25") == utc("2026-10-25T00:00:00Z"))
        #expect(S.date(from: "not a date") == nil)
        #expect(S.date(from: "") == nil)
        #expect(S.date(from: nil) == nil)
    }

    @Test func entities() {
        #expect(FeedParsingSupport.decodeHTMLEntities("a &amp; b &mdash; &#8217;&#x2019; &hellip; &bogus;") == "a & b \u{2014} \u{2019}\u{2019} \u{2026} &bogus;")
    }
}

@Suite("FeedParser: robustness")
struct FeedParserRobustnessTests {
    @Test func rejectsNonFeeds() {
        #expect(throws: FeedParserError.self) {
            try parser.parse(data("<!doctype html><html><head><title>x</title></head><body><p>Hi</body></html>"), kind: .rss, feedURL: "https://x.com")
        }
        #expect(throws: FeedParserError.self) { try parser.parse(Data(), kind: .rss, feedURL: "https://x.com") }
        #expect(throws: FeedParserError.self) { try parser.parse(data("{\"version\": 1}"), kind: .rss, feedURL: "https://x.com") }
        #expect(throws: FeedParserError.self) { try parser.parse(data("<opml version=\"2.0\"><body/></opml>"), kind: .rss, feedURL: "https://x.com") }
    }

    @Test func repairsHtmlEntitiesBareAmpersandsAndLeadingJunk() throws {
        let xml = "\u{FEFF}\n\n  <?xml version=\"1.0\" encoding=\"UTF-8\"?><rss version=\"2.0\"><channel><title>Tom & Jerry&nbsp;Blog</title><link>https://t.example.com/</link>"
            + "<item><title>Caf&eacute; &mdash; news</title><link>https://t.example.com/a?x=1&y=2</link><description>Hi&nbsp;there \u{0001}</description></item></channel></rss>"
        let feed = try parser.parse(data(xml), kind: .rss, feedURL: "https://t.example.com/feed")
        #expect(feed.title == "Tom & Jerry\u{00A0}Blog")
        let item = try #require(feed.items.first)
        #expect(item.title == "Café \u{2014} news")
        #expect(item.url == "https://t.example.com/a?x=1&y=2")
        #expect(item.summary == "Hi there")
    }

    @Test func latin1Encoding() throws {
        let xml = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><rss version=\"2.0\"><channel><title>Caf\u{E9}</title><item><title>\u{C9}t\u{E9}</title><link>https://x.com/a</link></item></channel></rss>"
        let bytes = try #require(xml.data(using: .isoLatin1))
        let feed = try parser.parse(bytes, kind: .rss, feedURL: "https://x.com/feed")
        #expect(feed.title == "Café")
        #expect(feed.items.first?.title == "Été")
    }

    @Test func rss1RDF() throws {
        let xml = #"""
        <?xml version="1.0"?><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <channel rdf:about="https://r.example.com/"><title>RDF Site</title><link>https://r.example.com/</link></channel>
        <item rdf:about="https://r.example.com/1"><title>One</title><link>https://r.example.com/1</link><description>First &lt;i&gt;post&lt;/i&gt;</description><dc:date>2026-10-20T08:00:00Z</dc:date><dc:creator>Ann</dc:creator></item>
        </rdf:RDF>
        """#
        let feed = try parser.parse(data(xml), kind: .rss, feedURL: "https://r.example.com/index.rdf")
        #expect(feed.title == "RDF Site")
        let item = try #require(feed.items.first)
        #expect(item.url == "https://r.example.com/1")
        #expect(item.guid == "https://r.example.com/1")
        #expect(item.summary == "First post")
        #expect(item.author == "Ann")
        #expect(item.publishedAt == utc("2026-10-20T08:00:00Z"))
    }

    @Test func atomXhtmlContentAndRelativeLinks() throws {
        let xml = #"""
        <feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://a.example.com/"><title type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">A <b>Blog</b></div></title>
        <link href="https://a.example.com/"/><link rel="self" href="https://a.example.com/atom.xml"/>
        <entry><title>Post</title><link rel="self" href="https://a.example.com/api/1"/><link href="/posts/1"/><id>tag:a.example.com,2026:1</id><updated>2026-10-21T10:00:00Z</updated>
        <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Hello &amp; welcome <img src="/i/1.png"/></p></div></content></entry>
        <entry><title></title><id>tag:no-link</id></entry>
        </feed>
        """#
        let feed = try parser.parse(data(xml), kind: .rss, feedURL: "https://a.example.com/atom.xml")
        #expect(feed.title == "A Blog")
        #expect(feed.link == "https://a.example.com/")
        #expect(feed.items.count == 1)
        let item = try #require(feed.items.first)
        #expect(item.url == "https://a.example.com/posts/1")
        #expect(item.guid == "tag:a.example.com,2026:1")
        #expect(item.summary == "Hello & welcome")
        #expect(item.thumbnailUrl == "https://a.example.com/i/1.png")
        #expect(item.publishedAt == utc("2026-10-21T10:00:00Z"))
    }

    @Test func untitledAndGuidFallbacks() throws {
        let xml = #"<rss><channel><link>https://g.example.com/</link><item><link>https://g.example.com/x</link><guid isPermaLink="false"></guid></item><item><guid>https://g.example.com/from-guid</guid></item><item><title>No URL</title></item></channel></rss>"#
        let feed = try parser.parse(data(xml), kind: .rss, feedURL: "https://g.example.com/feed")
        #expect(feed.items.count == 2)
        #expect(feed.items[0].title == "(untitled)")
        #expect(feed.items[0].guid == "https://g.example.com/x")
        #expect(feed.items[1].url == "https://g.example.com/from-guid")
        #expect(feed.items[1].guid == "https://g.example.com/from-guid")
    }

    @Test func thumbnailPrecedence() throws {
        let xml = #"""
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel><link>https://p.example.com/</link>
        <item><link>https://p.example.com/1</link><media:content url="https://p.example.com/v.mp4" type="video/mp4"/><media:content url="https://p.example.com/c.png"/><media:thumbnail url="https://p.example.com/t.jpg"/></item>
        <item><link>https://p.example.com/2</link><media:thumbnail url="https://p.example.com/t2.jpg"/><enclosure url="https://p.example.com/e.jpg" type="image/jpeg"/></item>
        <item><link>https://p.example.com/3</link><media:group><media:thumbnail url="g.jpg"/></media:group></item>
        <item><link>https://p.example.com/4/</link><enclosure url="e4.jpg" type="image/jpeg"/><description>&lt;img src="d.jpg"&gt;</description></item>
        <item><link>https://p.example.com/5/</link><description>&lt;p&gt;x&lt;img alt="a" src='d5.jpg'&gt;</description></item>
        </channel></rss>
        """#
        let feed = try parser.parse(data(xml), kind: .rss, feedURL: "https://p.example.com/feed")
        #expect(feed.items.map(\.thumbnailUrl) == [
            "https://p.example.com/c.png", "https://p.example.com/t2.jpg", "https://p.example.com/g.jpg",
            "https://p.example.com/4/e4.jpg", "https://p.example.com/5/d5.jpg",
        ])
    }

    @Test func podcastEpisodeUrlFallsBackToHttpGuidThenAudio() throws {
        let xml = #"""
        <rss><channel><title>No link show</title>
        <item><guid>https://pod.example.com/ep/9</guid><enclosure url="https://cdn.example.com/9.mp3" type="audio/mpeg"/></item>
        <item><guid>opaque-8</guid><enclosure url="/audio/8.mp3"/></item>
        </channel></rss>
        """#
        let feed = try parser.parse(data(xml), kind: .rss, feedURL: "https://pod.example.com/feed.xml")
        #expect(feed.isPodcast)
        #expect(feed.items[0].url == "https://pod.example.com/ep/9")
        #expect(feed.items[1].audioUrl == "https://pod.example.com/audio/8.mp3")
        #expect(feed.items[1].url == "https://pod.example.com/audio/8.mp3")
        #expect(feed.items[1].guid == "opaque-8")
    }
}

@Suite("FeedParser: real feeds")
struct FeedParserRealFeedTests {
    @Test func youTubeChannel() throws {
        let feed = try parser.parse(data(RealFeedFixtures.youTube), kind: .youtube,
                                    feedURL: "https://www.youtube.com/feeds/videos.xml?channel_id=UCawZsQWqfGSbCI5yjkdVkTA")
        #expect(feed.title == "Matthew Berman")
        #expect(feed.link == "https://www.youtube.com/channel/UCawZsQWqfGSbCI5yjkdVkTA")
        #expect(feed.items.count == 2)
        let v = feed.items[0]
        #expect(v.guid == "yt:video:eQTOJZ6_NVU")
        #expect(v.videoId == "eQTOJZ6_NVU")
        #expect(v.url == "https://www.youtube.com/shorts/eQTOJZ6_NVU")
        #expect(v.title == "Sam Altman on What People Still Bring to an AI World")
        #expect(v.author == "Matthew Berman")
        #expect(v.thumbnailUrl == "https://i.ytimg.com/vi/eQTOJZ6_NVU/hqdefault.jpg")
        #expect(v.publishedAt == utc("2026-10-25T05:59:23Z"))
        #expect(v.summary?.hasPrefix("Join My Newsletter for Regular AI Updates") == true)
        #expect((v.summary?.count ?? 0) <= 600)
    }

    @Test func hackerNews() throws {
        let feed = try parser.parse(data(RealFeedFixtures.hackerNews), kind: .rss, feedURL: "https://hnrss.org/newest?points=100")
        #expect(feed.items.count == 2)
        let a = feed.items[0], b = feed.items[1]
        #expect(a.title == "Dolly Parton's Imagination Library")
        #expect(a.url == "https://imaginationlibrary.com/")
        #expect(a.guid == "https://news.ycombinator.com/item?id=50234474")
        #expect(a.author == "jumploops")
        #expect(a.hnPoints == 194 && a.hnComments == 31)
        #expect(a.hnCommentsUrl == "https://news.ycombinator.com/item?id=50234474")
        #expect(a.summary == nil && a.thumbnailUrl == nil)
        #expect(a.publishedAt == utc("2026-10-25T18:23:54Z"))
        #expect(b.hnPoints == 227 && b.hnComments == 52)
    }

    @Test func vergeAtom() throws {
        let feed = try parser.parse(data(RealFeedFixtures.verge), kind: .rss, feedURL: "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml")
        #expect(feed.title == "AI | The Verge")
        #expect(feed.link == "https://www.theverge.com/ai-artificial-intelligence")
        let a = try #require(feed.items.first)
        #expect(a.title == "r/opensource just banned AI, non-English speakers, and more")
        #expect(a.author == "Terrence O\u{2019}Brien")
        #expect(a.guid == "https://www.theverge.com/?p=1018217")
        #expect(a.url == "https://www.theverge.com/ai-artificial-intelligence/1018217/reddit-opensource-ai-ban")
        #expect(a.publishedAt == utc("2026-10-25T13:25:32Z"))
        #expect(a.thumbnailUrl == "https://platform.theverge.com/wp-content/uploads/sites/2/2025/08/STK115_Reddit_01.jpg.webp?quality=90&strip=all&crop=0,0,100,100")
        #expect(a.summary?.hasPrefix("The mods at r/opensource posted new submission rules") == true)
        #expect(a.summary?.hasSuffix("…") == true)
        #expect(parser.itemHTML(in: data(RealFeedFixtures.verge), guid: a.guid, url: a.url)?.contains("<figure>") == true)
    }

    @Test func simonWillisonAtom() throws {
        let feed = try parser.parse(data(RealFeedFixtures.simonWillison), kind: .rss, feedURL: "https://simonwillison.net/atom/everything/")
        #expect(feed.title == "Simon Willison's Weblog")
        #expect(feed.link == "http://simonwillison.net/")
        let a = try #require(feed.items.first)
        #expect(a.url == "https://simonwillison.net/2026/Oct/24/battledrones/")
        #expect(a.guid == "https://simonwillison.net/2026/Oct/24/battledrones/")
        #expect(a.summary?.hasPrefix("Release: battledrones v14: Compass Rose, a four player map I added four player online mode") == true)
        #expect(a.thumbnailUrl == "https://raw.githubusercontent.com/simonw/battledrones/v14/progress-shots/v14/compass-rose.jpg")
        // Atom summary (no <content>) is what the extractor's feed fallback gets.
        #expect(parser.itemHTML(in: data(RealFeedFixtures.simonWillison), guid: a.guid, url: a.url) == nil)
    }

    @Test func arsTechnicaRSS() throws {
        let feed = try parser.parse(data(RealFeedFixtures.arsTechnica), kind: .rss, feedURL: "https://feeds.arstechnica.com/arstechnica/technology-lab")
        #expect(feed.title == "Biz & IT - Ars Technica")
        #expect(feed.link == "https://arstechnica.com")
        #expect(feed.imageUrl == "https://cdn.arstechnica.net/wp-content/uploads/2016/10/cropped-ars-logo-512_480-60x60.png")
        #expect(feed.isPodcast == false)
        let a = try #require(feed.items.first)
        #expect(a.author == "Dan Goodin")
        #expect(a.summary == "Flubbed key signing \"ceremony\" allowed minting of web credentials for any site.")
        #expect(a.thumbnailUrl == "https://cdn.arstechnica.net/wp-content/uploads/2025/02/GettyImages-1778229942-1152x648.jpg")
        #expect(a.publishedAt == utc("2026-10-22T20:17:52Z"))
        let html = parser.itemHTML(in: data(RealFeedFixtures.arsTechnica), guid: a.guid, url: a.url)
        #expect(html?.contains("<h2>Don't let the door hit you on the butt</h2>") == true)
    }

    @Test func theDailyPodcast() throws {
        let feed = try parser.parse(data(RealFeedFixtures.theDaily), kind: .rss, feedURL: "https://feeds.simplecast.com/54nAGcIl")
        #expect(feed.title == "The Daily")
        #expect(feed.isPodcast)
        #expect(feed.imageUrl == "https://image.simplecastcdn.com/images/7f2f4c05-9c2f-4deb-82b7-b538062bc22d/73549bf1-94b3-40ff-8aeb-b4054848ec1b/3000x3000/the-daily-album-art-original.jpg?aid=rss_feed")
        let e = try #require(feed.items.first)
        #expect(e.guid == "e002eb18-11e7-4058-8ee9-68c6ed866929")
        #expect(e.title == "Tricks, Treats and Trends")
        #expect(e.url == "https://www.nytimes.com/the-daily")
        #expect(e.author == "The New York Times")
        #expect(e.durationSec == 1781)
        #expect(e.audioUrl == "https://dts.podtrac.com/redirect.mp3/pdst.fm/e/pfx.vpixl.com/6qj4J/pscrb.fm/rss/p/tracking.swap.fm/track/4jdbJYYRKqK96EGqOzQb/nyt.simplecastaudio.com/03d8b493-87fc-4bd1-931f-8a8e9b945d8a/episodes/c139c515-24f7-449e-a672-ae828726f1b2/audio/128/default.mp3?aid=rss_feed&awCollectionId=03d8b493-87fc-4bd1-931f-8a8e9b945d8a&awEpisodeId=c139c515-24f7-449e-a672-ae828726f1b2&feed=54nAGcIl")
        #expect(e.thumbnailUrl == "https://image.simplecastcdn.com/images/34e5431c-f7f7-4edd-9b5d-0277e197a71b/ac55fb54-26bb-4ea6-84ef-dc62cd89d764/nyt-podcast-thedaily-ytthumbnail-20-28.jpg")
        #expect(e.summary?.hasPrefix("Americans are expected to spend a record $13.5 billion on Halloween this year") == true)
        #expect(e.publishedAt == utc("2026-10-25T10:00:00Z"))
        let notes = parser.itemHTML(in: data(RealFeedFixtures.theDaily), guid: e.guid, url: e.url)
        #expect(notes?.hasPrefix("<p>Americans are expected") == true)
    }
}
