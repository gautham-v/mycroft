import Foundation
import Testing
@testable import OpenDispatchCore

@Suite("Social posts: Bluesky, Mastodon, LinkedIn, Threads, Instagram")
struct SocialPostTests {
    // MARK: Addresses

    @Test func networks() {
        func n(_ u: String) -> SocialPost.Network? { SocialPosts.network(of: u) }
        #expect(n("https://bsky.app/profile/simonwillison.net/post/3mykwxawoa22u") == .bluesky)
        #expect(n("https://bsky.app/profile/did:plc:abc/post/3mykwxawoa22u?x=1") == .bluesky)
        #expect(n("https://bsky.app/profile/simonwillison.net") == nil)
        #expect(n("https://mastodon.social/@Gargron/117502470959656060") == .mastodon)
        #expect(n("https://fosstodon.org/@kim@functional.cafe/9/") == .mastodon)
        #expect(n("https://mastodon.social/@Gargron") == nil)
        #expect(n("https://medium.com/@someone/my-post-1a2b3c") == nil)
        #expect(n("https://www.linkedin.com/posts/gautham-v_my-post-activity-7511-XrVo") == .linkedin)
        #expect(n("https://www.linkedin.com/feed/update/urn:li:activity:7511146860494024706") == .linkedin)
        #expect(n("https://lnkd.in/p/gPbnF5yD") == .linkedin)
        #expect(n("https://www.linkedin.com/pulse/some-article") == nil)
        #expect(n("https://www.threads.com/@zuck/post/DOrreKBEtvX") == .threads)
        #expect(n("https://threads.net/@zuck/post/DOrreKBEtvX") == .threads)
        #expect(n("https://www.threads.com/@zuck") == nil)
        #expect(n("https://www.instagram.com/p/DKHqUAQNVWU/") == .instagram)
        #expect(n("https://www.instagram.com/nasa/reel/DKHqUAQNVWU/") == .instagram)
        #expect(n("https://www.instagram.com/nasa/") == nil)
        #expect(n("https://x.com/a/status/123") == nil)
        #expect(TextFormat.isSocialPost("https://x.com/a/status/123"))
        #expect(TextFormat.isSocialPost("https://bsky.app/profile/a.b/post/3x"))
        #expect(!TextFormat.isSocialPost("https://example.com/a"))
    }

    @Test func handleSplitting() {
        #expect(TextFormat.splitHandle("Simon Willison (@simonwillison.net)").handle == "simonwillison.net")
        #expect(TextFormat.splitHandle("Eugen Rochko (@Gargron@mastodon.social)").handle == "Gargron@mastodon.social")
        #expect(TextFormat.splitHandle("Gautham (@gautham-v)").name == "Gautham")
    }

    // MARK: Bluesky

    @Test func blueskyCardAndFacets() throws {
        let post = try #require(BlueskyPost.parse(Data(SocialFixtures.blueskyCard.utf8), canonical: "https://bsky.app/profile/simonwillison.net/post/3mykwxawoa22u"))
        #expect(post.author.name == "Simon Willison")
        #expect(post.author.handle == "simonwillison.net")
        #expect(post.date == ISO8601.date(from: "2026-10-23T19:45:54.167Z"))
        // Facet byte ranges are UTF-8 offsets: the link, tag and mention land on their own text after "é✨".
        #expect(post.paragraphs.count == 2)
        #expect(post.paragraphs[1] == "<a href=\"https://simonwillison.net/2026/Oct/23/kimi-k31-pro/\">simonwillison.net/2026/Oct/23/...</a> <a href=\"https://bsky.app/hashtag/llms\">#llms</a> <a href=\"https://bsky.app/profile/did:plc:z72i7hdynmk6r22z27h6tvur\">@bsky.app</a>")
        #expect(post.card?.title == "Introducing Kimi K3.1 Pro")
        #expect(post.card?.domain == "simonwillison.net")
        let item = post.item()
        #expect(item.title == "é✨ Notes on Kimi K3.1 - a big deal")
        #expect(item.author == "Simon Willison (@simonwillison.net)")
        #expect(item.url == "https://bsky.app/profile/simonwillison.net/post/3mykwxawoa22u")
        #expect(item.thumbnailUrl == nil)
        let html = try #require(post.render()?.contentHtml)
        #expect(html.contains("<div class=\"x-post\">"))
        #expect(html.contains("<span class=\"x-name\">Simon Willison</span>"))
        #expect(html.contains("<a class=\"x-card\" href=\"https://simonwillison.net/2026/Oct/23/kimi-k31-pro/\""))
        #expect(html.contains("Open on Bluesky"))
    }

    @Test func blueskyImagesAndNoText() throws {
        let post = try #require(BlueskyPost.parse(Data(SocialFixtures.blueskyImages.utf8), canonical: "https://bsky.app/profile/jane.example.com/post/3myqf3elq7s2m"))
        #expect(post.author.name == "jane.example.com")  // no display name
        #expect(post.media.count == 2)
        #expect(post.media[0].url == "https://cdn.bsky.app/f1")
        #expect(post.media[0].alt == "A tennis court")
        #expect(post.media[1].alt == nil)
        // A post of only photos is named for them; the list thumbnail is the small size.
        #expect(post.item().title == "Photo")
        #expect(post.item().thumbnailUrl == "https://cdn.bsky.app/t1")
        let r = try #require(post.render())
        #expect(r.contentHtml?.contains("x-media x-media-grid") == true)
        #expect(r.contentHtml?.contains("alt=\"A tennis court\"") == true)
        #expect(r.leadImage == "https://cdn.bsky.app/t1")
    }

    @Test func blueskyVideo() throws {
        let post = try #require(BlueskyPost.parse(Data(SocialFixtures.blueskyVideo.utf8), canonical: "https://bsky.app/profile/zoo.example.com/post/3mykmsu7tnc23"))
        let m = try #require(post.media.first)
        #expect(m.kind == .video)
        #expect(m.url.hasSuffix("playlist.m3u8"))
        #expect(m.poster?.hasSuffix("thumbnail.jpg") == true)
        let html = try #require(post.render()?.contentHtml)
        #expect(html.contains("<video src=\"https://video.bsky.app/watch/did/cid/playlist.m3u8\" poster=\"https://video.bsky.app/watch/did/cid/thumbnail.jpg\""))
        #expect(post.item().thumbnailUrl == "https://video.bsky.app/watch/did/cid/thumbnail.jpg")
    }

    @Test func blueskyQuoteWithMedia() throws {
        let post = try #require(BlueskyPost.parse(Data(SocialFixtures.blueskyQuoteWithMedia.utf8), canonical: "https://bsky.app/profile/maud.example.com/post/3mxkb3qz4cs27"))
        #expect(post.media.map(\.url) == ["https://cdn.bsky.app/m-f"])
        let q = try #require(post.quote)
        #expect(q.author.handle == "rob.example.com")
        #expect(q.href == "https://bsky.app/profile/rob.example.com/post/3mxk4ubvur22l")
        #expect(q.media.map(\.url) == ["https://cdn.bsky.app/q-f"])
        let item = post.item()
        #expect(item.summary == "Quoting rob: Probably the coolest thing")
        #expect(item.quoteAvatarUrl == "https://cdn.bsky.app/avatar/rob")
        let html = try #require(post.render()?.contentHtml)
        #expect(html.contains("<div class=\"x-quote\">"))
        #expect(html.contains("<a class=\"x-quote-link\" href=\"https://bsky.app/profile/rob.example.com/post/3mxk4ubvur22l\""))
    }

    @Test func blueskyUnavailable() throws {
        // A quoted post that's gone is left out; a missing post is nil.
        let post = try #require(BlueskyPost.parse(Data(SocialFixtures.blueskyQuoteGone.utf8), canonical: "https://bsky.app/profile/a.example.com/post/3x"))
        #expect(post.quote == nil)
        #expect(post.item().title == "look at this")
        #expect(BlueskyPost.parse(Data(SocialFixtures.blueskyNotFound.utf8), canonical: "x") == nil)
    }

    // MARK: Mastodon

    @Test func mastodonPhotos() throws {
        let post = try #require(MastodonPost.parse(Data(SocialFixtures.mastodonPhotos.utf8), host: "mastodon.social", canonical: "https://mastodon.social/@Gargron/117502470959656060"))
        #expect(post.author.name == "Eugen Rochko")
        #expect(post.author.handle == "Gargron@mastodon.social")
        #expect(post.author.profile == "https://mastodon.social/@Gargron")
        #expect(post.date == ISO8601.date(from: "2026-10-25T16:23:38.704Z"))
        #expect(post.paragraphs.count == 2)
        // The hidden "https://www." and the tail are dropped, an ellipsis marks the cut.
        #expect(post.paragraphs[1] == "<a href=\"https://www.createdrops.com/autumn-collection-2026-2\">createdrops.com/autumn-collect…</a>")
        #expect(post.media.map(\.url) == ["https://files.mastodon.social/o1.jpg", "https://files.mastodon.social/o2.jpg"])
        #expect(post.media[0].width == 2345)
        let item = post.item()
        #expect(item.title == "Okay, I'm new to this, but I've put prints up on a little shop.")
        #expect(item.author == "Eugen Rochko (@Gargron@mastodon.social)")
        #expect(item.thumbnailUrl == "https://files.mastodon.social/s1.jpg")
    }

    @Test func mastodonRemoteWarningEmojiVideoCard() throws {
        let post = try #require(MastodonPost.parse(Data(SocialFixtures.mastodonRemote.utf8), host: "fosstodon.org", canonical: "https://fosstodon.org/@kim@functional.cafe/9"))
        #expect(post.author.handle == "kim@functional.cafe")  // already names its server
        #expect(post.author.name == "Kim")  // the emoji shortcode is dropped from the name
        #expect(post.paragraphs.first == "<strong>Long thread ahead</strong>")
        #expect(post.paragraphs[1].contains("<img class=\"x-emoji\" src=\"https://cdn.example/blobcat-static.png\" alt=\":blobcat:\">"))
        #expect(post.paragraphs[2] == "<a href=\"https://functional.cafe/tags/nature\">#nature</a>")
        // Video and GIF kept; audio left out.
        #expect(post.media.map(\.kind) == [.video, .gif])
        #expect(post.card?.title == "An article")
        #expect(post.card?.domain == "Example")
        let html = try #require(post.render()?.contentHtml)
        #expect(html.contains("<img class=\"x-emoji\""))
        #expect(html.contains("autoplay loop muted"))
        #expect(html.contains("<span class=\"x-card-domain\">Example</span>"))
        #expect(post.item().title == "Long thread ahead")
    }

    @Test func mastodonQuote() throws {
        let post = try #require(MastodonPost.parse(Data(SocialFixtures.mastodonQuote.utf8), host: "mastodon.social", canonical: "https://mastodon.social/@rec/117512461000110123"))
        // The "RE:" line goes; the quoted post shows below.
        #expect(post.paragraphs == ["It is all on <a href=\"https://hcxp.co/@IDIOTEQ\">@IDIOTEQ</a> <br>Find the link below"])
        let q = try #require(post.quote)
        #expect(q.author.handle == "sauv@mastodon.social")
        #expect(q.paragraphs == ["NEW ALBUM, film premiere today"])
        #expect(q.media.count == 1)
        #expect(q.href == "https://mastodon.social/@sauv/117512455371012662")
        #expect(post.item().summary == "Quoting Sauv: NEW ALBUM, film premiere today")
        #expect(post.item().title == "It is all on @IDIOTEQ Find the link below")
        // A quote that isn't accepted yet keeps its "RE:" line.
        let pending = try #require(MastodonPost.parse(Data(SocialFixtures.mastodonQuotePending.utf8), host: "mastodon.social", canonical: "https://mastodon.social/@a/5"))
        #expect(pending.quote == nil)
        #expect(pending.paragraphs.first?.hasPrefix("RE:") == true)
    }

    @Test func mastodonNotAStatus() {
        #expect(MastodonPost.parse(Data("<html>404</html>".utf8), host: "example.com", canonical: "x") == nil)
        #expect(MastodonPost.parse(Data(#"{"error":"Record not found"}"#.utf8), host: "example.com", canonical: "x") == nil)
    }

    // MARK: LinkedIn

    private static let linkedinURL = "https://www.linkedin.com/posts/gautham-v_my-firefox-browser-agent-is-now-17x-faster-ugcPost-7511145035032170496-PMDR/?utm_source=share&utm_medium=member_desktop&rcm=ACoAAB"

    @Test func linkedinVideoPost() throws {
        let post = try #require(LinkedInPost.parse(html: SocialFixtures.linkedinVideoPost, pageURL: Self.linkedinURL))
        #expect(post.url == "https://www.linkedin.com/posts/gautham-v_my-firefox-browser-agent-is-now-17x-faster-ugcPost-7511145035032170496-PMDR/")
        #expect(post.author.name == "Gautham Vemulapalli")
        #expect(post.author.handle == "gautham-v")
        #expect(post.author.profile == "https://www.linkedin.com/in/gautham-v")
        #expect(post.author.avatar == nil)  // the page has only a placeholder
        // The post's own date, not a comment's.
        #expect(post.date == ISO8601.date(from: "2026-09-30T19:36:01.901Z"))
        #expect(post.paragraphs.count == 4)
        #expect(post.paragraphs[0] == "My Firefox browser agent is now 1.7x faster than Claude in Chrome.")
        #expect(post.paragraphs[1] == "It runs 16 tasks &amp; 3 runs each:<br>- 14.9s vs 25.5s per task<br>- Less than half the input tokens")
        // Redirect wrappers are opened; a lnkd.in target stays; hashtags link to LinkedIn's hashtag page.
        #expect(post.paragraphs[2] == "I wrote up how: <a href=\"https://lnkd.in/gB2qS63B\">https://lnkd.in/gB2qS63B</a>")
        #expect(post.paragraphs[3].hasPrefix("Source: <a href=\"https://github.com/gautham-v/agent-bridge\">https://github.com/gautham-v/agent-bridge</a> "))
        #expect(post.paragraphs[3].contains("<a href=\"https://www.linkedin.com/feed/hashtag/?keywords=firefox\">#firefox</a>"))
        #expect(post.paragraphs[3].hasSuffix("<a href=\"https://www.linkedin.com/in/someone-else\">Someone Else</a>"))
        // The best MP4 and its cover; the comment's image is not the post's.
        let m = try #require(post.media.first)
        #expect(post.media.count == 1)
        #expect(m.kind == .video)
        #expect(m.url.contains("mp4-720p") && m.url.contains("t=hi"))
        #expect(m.poster?.contains("videocover-high") == true)
        let item = post.item()
        #expect(item.title == "My Firefox browser agent is now 1.7x faster than Claude in Chrome.")
        #expect(item.author == "Gautham Vemulapalli (@gautham-v)")
        #expect(item.thumbnailUrl?.contains("videocover-high") == true)
        let html = try #require(post.render()?.contentHtml)
        #expect(html.contains("<video src=\"https://dms.licdn.com/playlist/vid/v2/x/mp4-720p/"))
        #expect(html.contains("Open on LinkedIn"))
        #expect(!html.contains("redir/redirect"))
    }

    @Test func linkedinPhotosPost() throws {
        let post = try #require(LinkedInPost.parse(html: SocialFixtures.linkedinPhotosPost, pageURL: "https://www.linkedin.com/posts/acme_we-shipped-activity-1-AbCd"))
        #expect(post.author.name == "Acme Inc")
        #expect(post.author.handle == "acme")
        #expect(post.author.avatar == "https://media.licdn.com/dms/image/v2/logo/company-logo_100_100/0/1")
        #expect(post.media.count == 2)
        #expect(post.media[0].alt == nil)  // LinkedIn's generic "Image"
        #expect(post.media[1].alt == "The team")
        #expect(post.date == nil)
    }

    @Test func linkedinWall() {
        #expect(LinkedInPost.parse(html: SocialFixtures.linkedinWall, pageURL: Self.linkedinURL) == nil)
    }

    @Test func linkedinLinks() {
        #expect(LinkedInPost.linkTarget("https://www.linkedin.com/redir/redirect?url=javascript%3Aalert(1)&urlhash=x", text: "x") == nil)
        #expect(LinkedInPost.linkTarget("https://www.linkedin.com/in/a-b?trk=1", text: "A B") == "https://www.linkedin.com/in/a-b")
        #expect(LinkedInPost.linkTarget("https://example.com/a?b=1", text: "a") == "https://example.com/a?b=1")
        #expect(LinkedInPost.linkTarget("https://www.linkedin.com/signup/cold-join?x=1", text: "sign up") == nil)
        #expect(LinkedInPost.canonicalURL("https://www.linkedin.com/posts/a_b-ugcPost-1-XyZ/?utm_source=share&rcm=x#f") == "https://www.linkedin.com/posts/a_b-ugcPost-1-XyZ/")
    }

    // MARK: Threads and Instagram

    @Test func threadsPreview() throws {
        let canonical = "https://www.threads.com/@zuck/post/DOrreKBEtvX"
        let post = try #require(PreviewTagPost.parse(html: SocialFixtures.threadsPreview, canonical: canonical, network: .threads))
        #expect(post.author.name == "Mark Zuckerberg")
        #expect(post.author.handle == "zuck")
        #expect(post.paragraphs == ["09/17 = 👌✍️"])
        #expect(post.media.count == 1)
        #expect(post.date == nil)
        #expect(post.item().author == "Mark Zuckerberg (@zuck)")
        let extra = PreviewTagPost.parseEmbed(html: SocialFixtures.threadsEmbed)
        #expect(extra.avatar?.contains("t51.82787-19") == true)
        #expect(extra.date == ISO8601.date(from: "2025-09-16T12:00:00Z"))
        // The login wall has no author.
        #expect(PreviewTagPost.parse(html: SocialFixtures.threadsWall, canonical: canonical, network: .threads) == nil)
    }

    @Test func instagramPreview() throws {
        let canonical = "https://www.instagram.com/p/DKHqUAQNVWU/"
        let post = try #require(PreviewTagPost.parse(html: SocialFixtures.instagramPreview, canonical: canonical, network: .instagram))
        #expect(post.author.name == "NASA")
        #expect(post.author.handle == "nasa")
        #expect(post.date == ISO8601.date(from: "2025-05-26T12:00:00Z"))
        #expect(post.paragraphs == ["On #MemorialDay, we remember and honor those who gave the last full measure of devotion.", "Ad astra per aspera.", "#NASA #Space"])
        #expect(post.media.count == 1)
        #expect(post.item().title == "On #MemorialDay, we remember and honor those who gave the last full measure of devotion.")
        let extra = PreviewTagPost.parseEmbed(html: SocialFixtures.instagramEmbed)
        #expect(extra.avatar?.contains("t51.2885-19") == true)
        #expect(extra.date == nil)
        #expect(PreviewTagPost.parse(html: SocialFixtures.instagramWall, canonical: canonical, network: .instagram) == nil)
    }

    @Test func unreadablePostTitles() {
        #expect(SocialPosts.unreadableTitle("https://www.threads.com/@zuck/post/ABC", network: .threads) == "Post by @zuck on Threads")
        #expect(SocialPosts.unreadableTitle("https://www.instagram.com/nasa/p/ABC/", network: .instagram) == "Post by @nasa on Instagram")
        #expect(SocialPosts.unreadableTitle("https://www.instagram.com/p/ABC/", network: .instagram) == "Instagram post")
    }

    @Test func plainTextLinks() {
        #expect(SocialPost.paragraphs(fromPlain: "See https://e.com/a, and <b>\n\nTwo") == ["See <a href=\"https://e.com/a\">https://e.com/a</a>, and &lt;b&gt;", "Two"])
    }

    // MARK: Fetch flow (stubbed)

    private static func fetch(_ routes: [String: (Int, String, [String: String])], log: LockedLog = LockedLog()) -> SocialPosts.Fetch {
        { url, headers in
            log.add(url, headers["User-Agent"] ?? "")
            guard let (status, body, _) = routes[url] else { return (Data(), HTTPURLResponse(url: URL(string: url)!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
            return (Data(body.utf8), HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    final class LockedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(String, String)] = []
        func add(_ url: String, _ ua: String) { lock.withLock { entries.append((url, ua)) } }
        var all: [(String, String)] { lock.withLock { entries } }
    }

    @Test func itemsThroughFetch() async throws {
        let log = LockedLog()
        let api = "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?uri=at%3A%2F%2Fsimonwillison.net%2Fapp.bsky.feed.post%2F3mykwxawoa22u&depth=0&parentHeight=0"
        let fetch = Self.fetch([api: (200, SocialFixtures.blueskyCard, [:])], log: log)
        let item = try #require(await SocialPosts.item(url: "https://bsky.app/profile/simonwillison.net/post/3mykwxawoa22u", fetch: fetch))
        #expect(item.title == "é✨ Notes on Kimi K3.1 - a big deal")
        #expect(log.all.map(\.0) == [api])

        // Mastodon asks the status API of the address's own server.
        let m = Self.fetch(["https://fosstodon.org/api/v1/statuses/9": (200, SocialFixtures.mastodonRemote, [:])])
        #expect(await SocialPosts.extract(url: "https://fosstodon.org/@kim@functional.cafe/9", fetch: m)?.contentHtml?.contains("x-post") == true)

        // A site that isn't Mastodon answers 404 there: not a post, the generic path takes over.
        let other = Self.fetch([:])
        #expect(await SocialPosts.item(url: "https://example.com/@someone/123", fetch: other) == nil)
        #expect(await SocialPosts.item(url: "https://bsky.app/profile/gone.example.com/post/3x", fetch: other) == nil)
    }

    @Test func previewTagPostsAskAsACrawler() async throws {
        let log = LockedLog()
        let fetch = Self.fetch([
            "https://www.instagram.com/p/DKHqUAQNVWU/": (200, SocialFixtures.instagramPreview, [:]),
            "https://www.instagram.com/p/DKHqUAQNVWU/embed/captioned/": (200, SocialFixtures.instagramEmbed, [:]),
        ], log: log)
        let item = try #require(await SocialPosts.item(url: "https://www.instagram.com/nasa/p/DKHqUAQNVWU/?igsh=abc", fetch: fetch))
        #expect(item.url == "https://www.instagram.com/p/DKHqUAQNVWU/")
        #expect(item.author == "NASA (@nasa)")
        #expect(log.all.count == 2)
        #expect(log.all.allSatisfy { $0.1.hasPrefix("facebookexternalhit") })

        // Unreadable: a title that names the author, not the wall's.
        let wall = Self.fetch(["https://www.threads.com/@zuck/post/ABC": (200, SocialFixtures.threadsWall, [:])])
        let fallback = try #require(await SocialPosts.item(url: "https://www.threads.com/@zuck/post/ABC", fetch: wall))
        #expect(fallback.title == "Post by @zuck on Threads")
        #expect(await SocialPosts.extract(url: "https://www.threads.com/@zuck/post/ABC", fetch: wall) == nil)
    }

    @Test func linkedinShortLinkResolvesToThePost() async throws {
        // The fetch follows the redirect; the stub answers with the final address.
        let short: SocialPosts.Fetch = { _, _ in
            (Data(SocialFixtures.linkedinVideoPost.utf8), HTTPURLResponse(url: URL(string: Self.linkedinURL)!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let item = try #require(await SocialPosts.item(url: "https://lnkd.in/p/gPbnF5yD", fetch: short))
        #expect(item.url == "https://www.linkedin.com/posts/gautham-v_my-firefox-browser-agent-is-now-17x-faster-ugcPost-7511145035032170496-PMDR/")
        #expect(item.guid == item.url)
        // A short link that leads elsewhere is not a post.
        let elsewhere: SocialPosts.Fetch = { _, _ in
            (Data("<html></html>".utf8), HTTPURLResponse(url: URL(string: "https://example.com/x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await SocialPosts.item(url: "https://lnkd.in/x", fetch: elsewhere) == nil)
    }
}
