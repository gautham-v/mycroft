import Foundation
import Testing
@testable import OpenDispatchCore

/// Saved answers in Fixtures/Discussions, trimmed: Reddit's search for "love is blind" (relevance, past week), a post page
/// ("Disgusted" in r/LoveIsBlindNetflix, its first five top-level comments and the trailing "more comments" partial) and a
/// "more comments" answer, all as the hidden web view fetches them; X timeline cells built from a signed-in search page and a
/// post page (two posts, then a post with three replies in two groups and a "Discover more" section); YouTube's comment
/// pages for one video (threads and one thread's replies); Hacker News item 8863 three levels deep; a Bluesky search and a
/// post's thread.
enum DiscussionFixtures {
    static func url(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Discussions") else {
            fatalError("missing fixture \(name)")
        }
        return url
    }

    static func data(_ name: String) -> Data { (try? Data(contentsOf: url(name))) ?? Data() }
    static func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }
    static func cells(_ name: String) -> [String] { (try? JSONDecoder().decode([String].self, from: data(name))) ?? [] }

    /// Answers each request by the first route whose key the URL contains, recording what was asked.
    final class Network: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [(url: String, body: Data?)] = []
        let routes: [(String, Data)]
        init(_ routes: [(String, Data)]) { self.routes = routes }
        var requests: [(url: String, body: Data?)] { lock.lock(); defer { lock.unlock() }; return asked }

        var discussions: DefaultDiscussions {
            DefaultDiscussions(fetch: { url, body in
                self.lock.lock(); self.asked.append((url, body)); self.lock.unlock()
                let data = self.routes.first { url.contains($0.0) }?.1
                return (data ?? Data(), HTTPURLResponse(url: URL(string: url)!, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
            })
        }
    }
}

@Suite("Discussions")
struct DiscussionTests {
    // MARK: Places

    @Test func tellsWhichPlaceAThreadIsOn() {
        #expect(DiscussionPlace.thread(of: "https://www.reddit.com/r/nfl/comments/1abc23/game_thread/") == .reddit)
        #expect(DiscussionPlace.thread(of: "https://old.reddit.com/r/nfl/comments/1abc23") == .reddit)
        #expect(DiscussionPlace.thread(of: "https://x.com/mahaaaay/status/2113372956336476401") == .x)
        #expect(DiscussionPlace.thread(of: "https://bsky.app/profile/a.bsky.social/post/3myq5k5egxk2t") == .bluesky)
        #expect(DiscussionPlace.thread(of: "https://news.ycombinator.com/item?id=8863") == .hackerNews)
        #expect(DiscussionPlace.thread(of: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == .youtube)
        #expect(DiscussionPlace.thread(of: "https://www.reddit.com/r/nfl/") == nil)
        #expect(DiscussionPlace.thread(of: "https://example.com/article") == nil)
        #expect(RedditPages.canonicalURL("https://old.reddit.com/r/nfl/comments/1abc23/game_thread/?sort=top") == "https://www.reddit.com/r/nfl/comments/1abc23/game_thread/")
        #expect(RedditPages.canonicalURL("https://reddit.com/r/nfl/comments/1abc23") == "https://www.reddit.com/r/nfl/comments/1abc23/")
    }

    @Test func searchesAPhraseAsAPhrase() {
        #expect(RedditPages.searchPath("love is blind", range: "week") == "/search/?q=%22love%20is%20blind%22&type=link&sort=relevance&t=week")
        #expect(RedditPages.searchPath("nfl", range: "month") == "/search/?q=nfl&type=link&sort=relevance&t=month")
        #expect(XPages.searchURL("love is blind") == "https://x.com/search?q=love%20is%20blind&src=typed_query&f=top")
    }

    @Test func readsRedditsOddDates() {
        #expect(DiscussionDates.parse("2026-10-28T10:44:14.463000+0000") == ISO8601.date(from: "2026-10-28T10:44:14.463Z"))
        #expect(DiscussionDates.parse("2026-10-28T11:31:42.120Z") == ISO8601.date(from: "2026-10-28T11:31:42.120Z"))
        #expect(DiscussionDates.parse("") == nil)
    }

    // MARK: Text

    @Test func readsHTMLIntoParagraphsAndLinks() {
        let text = RichText.html("""
            First <i>line</i><p>See <a href="/r/nfl/">r/nfl</a> &amp; <code>x</code></p><blockquote><p>quoted</p></blockquote><ul><li>one</li></ul><pre><code>a  b
            c</code></pre>
            """, base: "https://www.reddit.com")
        #expect(text.paragraphs.map(\.text) == ["First line", "See r/nfl & x", "quoted", "one", "a  b\nc"])
        #expect(text.paragraphs.map(\.style) == [.plain, .plain, .quote, .bullet, .code])
        #expect(text.paragraphs[0].runs.last == RichText.Run(text: "line", italic: true))
        #expect(text.paragraphs[1].runs.first { $0.link != nil }?.link == "https://www.reddit.com/r/nfl/")
    }

    @Test func linksBareAddressesInPlainText() {
        let text = RichText.plain("Watch https://youtu.be/abc).\n\nSecond")
        #expect(text.paragraphs.count == 2)
        #expect(text.paragraphs[0].runs == [RichText.Run(text: "Watch "), RichText.Run(text: "https://youtu.be/abc", link: "https://youtu.be/abc"), RichText.Run(text: ").")])
    }

    // MARK: Reddit

    @Test func readsRedditSearchResults() {
        let posts = RedditPages.posts(inSearch: DiscussionFixtures.text("reddit-search.html"))
        #expect(posts.count == 6)
        let first = posts[0]
        #expect(first.title == "Nobody is talking about this ENOUGH")
        #expect(first.url == "https://www.reddit.com/r/LoveIsBlindNetflix/comments/1xcj9yx/nobody_is_talking_about_this_enough/")
        #expect(first.community == "r/LoveIsBlindNetflix")
        #expect(first.score == 1581 && first.comments == 990)
        #expect(first.published == DiscussionDates.parse("2026-10-22T13:56:18.644000+0000"))
        #expect(first.avatarUrl?.hasPrefix("https://styles.redditmedia.com/") == true)
        #expect(posts.allSatisfy { $0.place == .reddit && $0.author?.hasPrefix("u/") == true })
        #expect(posts.contains { $0.title == "Love Is Blind \u{2022} S11 Ep 9" && $0.comments == 2151 })
    }

    @Test func aRedditVideoPlaysInThePost() throws {
        let post = try #require(RedditPages.post(inThread: """
            <shreddit-post permalink="/r/nfl/comments/1xjwc7y/prank/" content-href="https://v.redd.it/p543" post-title="Prank" post-type="video" domain="v.redd.it">
            <shreddit-player src="https://v.redd.it/p543/HLSPlaylist.m3u8?f=sd%2CsubsAll&amp;v=1&amp;a=1796007016%2CNj" poster="https://external-preview.redd.it/prank.png?format=pjpg&amp;s=afb"></shreddit-player>
            </shreddit-post>
            """))
        #expect(post.video == "https://v.redd.it/p543/HLSPlaylist.m3u8")
        #expect(post.leadImage == "https://external-preview.redd.it/prank.png?format=pjpg&s=afb")
        let content = try #require(RedditPages.contentHTML(post))
        #expect(content.contains("<div class=\"x-media\"><video") && content.contains("HLSPlaylist.m3u8") && content.contains("controls") && content.contains("poster="))
        #expect(content.contains("<div class=\"x-body\"><p>Prank</p></div>"))
        #expect(!content.contains("x-card"))
    }

    private static let redditLinkPost = """
        <shreddit-post permalink="/r/nfl/comments/1xjq7l0/brown/" content-href="LINK" post-title="Brown" post-type="link" domain="nypost.com" link-post-preview="description_under_media">
        <div slot="post-media-container"><img class="post-background-image-filter" src="https://external-preview.redd.it/blur.jpeg">
        <img id="post-image" data-post-media-primary src="https://external-preview.redd.it/b.jpeg?width=640&amp;s=1" width="640" height="336"
          srcset="https://external-preview.redd.it/b.jpeg?width=320&amp;s=0 320w, https://external-preview.redd.it/b.jpeg?width=1080&amp;s=2 1080w, https://external-preview.redd.it/b.jpeg?width=640&amp;s=1 640w">
        <div data-link-preview-cta-row><span>nypost.com</span><p property="schema:articleBody">  Patriots receiver missed practice.  </p></div></div>
        <shreddit-post-text-body slot="text-body"><div slot="text-body"><div property="schema:articleBody"><p>The poster's own words.</p></div></div></shreddit-post-text-body>
        </shreddit-post>
        """

    @Test func aRedditLinkPostShowsThePreviewAndThePostersText() throws {
        let post = try #require(RedditPages.post(inThread: Self.redditLinkPost.replacingOccurrences(of: "LINK", with: "https://nypost.com/a/")))
        #expect(post.linkDescription == "Patriots receiver missed practice.")
        #expect(post.bodyHTML?.contains("own words") == true && post.bodyHTML?.contains("Patriots") == false)
        #expect(post.preview?.url == "https://external-preview.redd.it/b.jpeg?width=1080&s=2")
        #expect(post.leadImage == post.preview?.url)
        let content = try #require(RedditPages.contentHTML(post))
        #expect(content.contains("x-card-large") && content.contains("x-card-whole") && content.contains("width=1080"))
        #expect(content.contains("width=\"640\"") && content.contains("height=\"336\""))
        #expect(content.contains("https://nypost.com/a/") && content.contains(">nypost.com<") && content.contains("Patriots receiver"))
        #expect(content.contains("own words"))
        // Author row, title and the poster's text, then the card.
        #expect(content.hasPrefix("<div class=\"x-post\">"))
        let parts = try ["x-body", "<p>Brown</p>", "own words", "x-card-large"].map { try #require(content.range(of: $0)).lowerBound }
        #expect(parts == parts.sorted())
    }

    @Test func aRedditPostLinkingToYouTubePlaysIt() async throws {
        struct Check: YouTubeEmbedChecking {
            let playable: Bool?
            func isPlayable(videoID: String) async -> Bool? { playable }
            func isPlayable(channelID: String) async -> Bool? { playable }
        }
        let post = try #require(RedditPages.post(inThread: """
            <shreddit-post permalink="/r/sports/comments/1wtvofg/liberty/" content-href="https://www.youtube.com/watch?v=VuM9DHF6dyc" post-title="Liberty" post-type="link" domain="youtube.com">
            <shreddit-embed html="&lt;iframe src=&quot;https://www.youtube.com/embed/VuM9DHF6dyc?feature=oembed&quot;&gt;&lt;/iframe&gt;" providerName="YouTube"></shreddit-embed>
            </shreddit-post>
            """))
        #expect(post.leadImage?.contains("VuM9DHF6dyc") == true)
        let fetch: EmbeddedPosts.Fetch = { _, _ in nil }
        for playable in [true, nil] {
            let embed = await DiscussionContent.embed(for: post, fetch: fetch, check: Check(playable: playable))
            let content = try #require(RedditPages.contentHTML(post, embed: embed))
            #expect(content.contains("<iframe") && content.contains("www.youtube-nocookie.com/embed/VuM9DHF6dyc"))
            #expect(!content.contains("x-card"))
            // The post opens with its author row, and the app draws no hero over a post.
            #expect(content.hasPrefix("<div class=\"x-post\">") && content.contains("<figure><iframe"))
            #expect(!LeadImage.contentHasHero(content, hero: try #require(post.leadImage)))
        }
        // The NFL's and the like won't play here: a card with the video's picture opens it.
        let blocked = await DiscussionContent.embed(for: post, fetch: fetch, check: Check(playable: false))
        #expect(blocked == nil)
        let card = try #require(RedditPages.contentHTML(post, embed: blocked))
        #expect(card.contains("x-card") && card.contains("VuM9DHF6dyc/") && card.contains("watch?v=VuM9DHF6dyc") && !card.contains("<iframe"))
    }

    @Test func aRedditPostLinkingToAPostShowsThatPost() throws {
        let linked = "https://bsky.app/profile/a.bsky.social/post/3mz"
        #expect(EmbeddedPosts.post(at: linked) == .social(url: linked))
        let post = try #require(RedditPages.post(inThread: Self.redditLinkPost.replacingOccurrences(of: "LINK", with: linked)))
        let content = try #require(RedditPages.contentHTML(post, embed: "<div class=\"x-post x-embed\"><div class=\"x-body\"><p>The post</p></div></div>"))
        #expect(content.contains("x-embed") && content.contains("The post") && !content.contains("x-card"))
        #expect(content.hasPrefix("<div class=\"x-post\">") && content.contains("<p>Brown</p>"))
    }

    /// A post page holding one post with these attributes and children.
    private func redditPost(_ attributes: String, _ inner: String = "") throws -> RedditPages.Post {
        try #require(RedditPages.post(inThread: "<shreddit-post permalink=\"/r/nfl/comments/1abc/t/\" \(attributes)>\(inner)</shreddit-post>"))
    }

    @Test func aRedditPostsAuthorRowIsItsCommunityAndPoster() throws {
        let post = try redditPost(
            "post-title=\"T\" post-type=\"text\" author=\"Sidecarlover\" subreddit-prefixed-name=\"r/nfl\" icon=\"https://preview.redd.it/snoovatar/author.png\"",
            "<img class=\"shreddit-subreddit-icon__icon\" src=\"https://styles.redditmedia.com/t5_2qmg3/styles/communityIcon_a.png\">")
        #expect(post.communityIcon == "https://styles.redditmedia.com/t5_2qmg3/styles/communityIcon_a.png")
        let content = try #require(RedditPages.contentHTML(post))
        #expect(content.hasPrefix("<div class=\"x-post\"><div class=\"x-who\"><img class=\"x-avatar\" src=\"https://styles.redditmedia.com/t5_2qmg3/styles/communityIcon_a.png\" alt=\"\" loading=\"lazy\" /><span class=\"x-name\">r/nfl</span><a class=\"x-handle\" href=\"https://www.reddit.com/user/Sidecarlover/\" target=\"_blank\" rel=\"noopener noreferrer\">u/Sidecarlover</a></div>"))
        #expect(!content.contains("@") && !content.contains("snoovatar"))
    }

    @Test func aRedditCommunityWithNoIconHasNoAvatar() throws {
        let post = try redditPost("post-title=\"T\" post-type=\"text\" author=\"a\" subreddit-prefixed-name=\"r/nfl\" icon=\"https://preview.redd.it/snoovatar/author.png\"")
        #expect(post.communityIcon == nil)
        let content = try #require(RedditPages.contentHTML(post))
        #expect(content.contains("<div class=\"x-who\"><span class=\"x-name\">r/nfl</span>") && !content.contains("x-avatar"))
    }

    @Test func aPostOnARedditProfileGoesByItsPoster() throws {
        let post = try redditPost("post-title=\"T\" post-type=\"text\" author=\"Sidecarlover\"")
        let content = try #require(RedditPages.contentHTML(post))
        #expect(content.contains("<span class=\"x-name\">u/Sidecarlover</span><a class=\"x-handle\" href=\"https://www.reddit.com/user/Sidecarlover/\" target=\"_blank\" rel=\"noopener noreferrer\">u/Sidecarlover</a>"))
    }

    @Test func aDeletedRedditPosterHasNoHandle() throws {
        for author in ["", "author=\"[deleted]\""] {
            let post = try redditPost("post-title=\"T\" post-type=\"text\" subreddit-prefixed-name=\"r/nfl\" \(author)")
            let content = try #require(RedditPages.contentHTML(post))
            #expect(content.contains("<div class=\"x-who\"><span class=\"x-name\">r/nfl</span></div>"))
            #expect(!content.contains("x-handle") && !content.contains("/user/"))
        }
        let nobody = try #require(RedditPages.contentHTML(try redditPost("post-title=\"T\" post-type=\"text\" author=\"[deleted]\"")))
        #expect(nobody.contains("<div class=\"x-who\"><span class=\"x-name\">[deleted]</span></div>"))
    }

    @Test func aRedditTitleIsThePostsEscapedText() throws {
        let post = try redditPost(
            "post-title=\"Fish &amp; chips &lt;b&gt;now&lt;/b&gt;\" post-type=\"text\"",
            "<div property=\"schema:articleBody\"><p>The text.</p></div>")
        let content = try #require(RedditPages.contentHTML(post))
        #expect(content.contains("<div class=\"x-body\"><p>Fish &amp; chips &lt;b&gt;now&lt;/b&gt;</p><p>The text.</p></div>"))
    }

    @Test func aRedditPostThatIsOnlyATitleShowsIt() throws {
        let content = try #require(RedditPages.contentHTML(try redditPost("post-title=\"T\" post-type=\"text\"")))
        #expect(content.contains("<div class=\"x-body\"><p>T</p></div>"))
        #expect(content.hasPrefix("<div class=\"x-post\">") && !content.contains("x-foot"))
        #expect(RedditPages.contentHTML(try redditPost("post-type=\"text\"")) == nil)
    }

    @Test func aRedditPostsFooterHasItsDateAndStats() throws {
        let stamp = "2026-10-28T10:44:14.463000+0000"
        let date = TweetExtraction.stampLine(try #require(DiscussionDates.parse(stamp)))
        func foot(_ attributes: String) throws -> String? {
            let content = try #require(RedditPages.contentHTML(try redditPost("post-title=\"T\" post-type=\"text\" \(attributes)")))
            return content.range(of: "<div class=\"x-foot\">").map { String(content[$0.lowerBound...]) }
        }
        #expect(try foot("created-timestamp=\"\(stamp)\" score=\"217\" comment-count=\"35\"") == "<div class=\"x-foot\"><span>\(date)</span><span>217 points · 35 comments</span></div></div>")
        #expect(try foot("created-timestamp=\"\(stamp)\" score=\"1\" comment-count=\"1\"") == "<div class=\"x-foot\"><span>\(date)</span><span>1 point · 1 comment</span></div></div>")
        #expect(try foot("created-timestamp=\"\(stamp)\" score=\"0\"") == "<div class=\"x-foot\"><span>\(date)</span><span>0 points</span></div></div>")
        #expect(try foot("comment-count=\"35\"") == "<div class=\"x-foot\"><span>35 comments</span></div></div>")
        #expect(try foot("created-timestamp=\"\(stamp)\"") == "<div class=\"x-foot\"><span>\(date)</span></div></div>")
        #expect(try foot("") == nil)
    }

    @Test func aRedditImageOrGalleryIsThePostsMedia() throws {
        let image = try redditPost("post-title=\"T\" post-type=\"image\" content-href=\"https://i.redd.it/a.jpeg\" author=\"a\"")
        let one = try #require(RedditPages.contentHTML(image))
        #expect(one.contains("</div><div class=\"x-media\"><img src=\"https://i.redd.it/a.jpeg\" alt=\"\" loading=\"lazy\" /></div>"))
        #expect(!one.contains("<figure>"))
        let gallery = try redditPost(
            "post-title=\"T\" post-type=\"gallery\"",
            "<gallery-carousel><img src=\"https://i.redd.it/a.jpeg\"><img data-lazy-src=\"https://i.redd.it/b.jpeg\"><img src=\"https://i.redd.it/a.jpeg\"></gallery-carousel>")
        let grid = try #require(RedditPages.contentHTML(gallery))
        #expect(grid.contains("<div class=\"x-media x-media-grid\"><img src=\"https://i.redd.it/a.jpeg\" alt=\"\" loading=\"lazy\" /><img src=\"https://i.redd.it/b.jpeg\" alt=\"\" loading=\"lazy\" /></div>"))
        #expect(!grid.contains("<figure>"))
    }

    @Test func otherPostsAuthorRowsStillShowAnAtSign() {
        let user = TweetExtraction.User(name: "A", handle: "a")
        #expect(TweetExtraction.whoHTML(user, date: nil) == "<div class=\"x-who\"><span class=\"x-name\">A</span><a class=\"x-handle\" href=\"https://x.com/a\">@a</a></div>")
        #expect(TweetExtraction.whoHTML(user, date: "Oct 25, 2026", profile: "https://bsky.app/profile/a") == "<div class=\"x-who\"><span class=\"x-name\">A</span><a class=\"x-handle\" href=\"https://bsky.app/profile/a\">@a</a><span class=\"x-when\">· Oct 25, 2026</span></div>")
        let bluesky = SocialPost(network: .bluesky, url: "https://bsky.app/profile/a/post/1", author: .init(name: "A", handle: "a", profile: "https://bsky.app/profile/a"), paragraphs: ["Hi"])
        #expect(bluesky.render()?.contentHtml?.contains(">@a</a>") == true)
    }

    @Test func readsARedditPostAndItsComments() throws {
        let html = DiscussionFixtures.text("reddit-thread.html")
        let post = try #require(RedditPages.post(inThread: html))
        #expect(post.title == "Disgusted")
        #expect(post.kind == .image)
        #expect(post.contentHref == "https://i.redd.it/rda2lbhft6yh1.jpeg")
        #expect(post.score == 3547 && post.comments == 1635 && post.author == "BlueZima2")
        #expect(post.bodyHTML?.contains("I watch all the various versions of Love is Blind") == true)
        let content = try #require(RedditPages.contentHTML(post))
        #expect(content.contains("i.redd.it/rda2lbhft6yh1.jpeg") && content.contains("various versions"))
        #expect(content.contains("<span class=\"x-name\">r/LoveIsBlindNetflix</span>") && content.contains(">u/BlueZima2</a>"))
        #expect(content.contains("<p>Disgusted</p>") && content.contains("3.5K points · 1.6K comments"))
        // The attribute named icon is the poster's picture.
        #expect(!content.contains("snoovatar"))

        let thread = RedditPages.thread(html)
        #expect(thread.total == 1635)
        let comments = thread.entries.compactMap(\.comment)
        #expect(comments.map(\.author).prefix(4) == ["brahbocop", "Remarkable-King6621", "okrahomegirl", "BlueZima2"])
        #expect(comments[0].score == 203 && comments[0].depth == 0)
        #expect(comments[0].body.paragraphs.first?.text.hasPrefix("Keep in mind, they are wearing mics") == true)
        #expect(comments[0].body.paragraphs.count == 2)
        let reply = try #require(comments.first { $0.author == "BlueZima2" })
        #expect(reply.depth == 1 && reply.byAuthor)
        // Each comment's "N more replies" partial comes after it, one deeper, and the post's own more partial ends the list.
        guard case .more(let firstMore) = thread.entries[1] else { Issue.record("no partial after the first comment"); return }
        #expect(firstMore.depth == 1 && firstMore.count == 27)
        let (path, cursor) = RedditPages.partial(firstMore.token)
        #expect(path.hasPrefix("/svc/shreddit/more-comments/LoveIsBlindNetflix/t3_1xhkn99?") && !cursor.isEmpty)
        guard case .more(let last) = thread.entries.last else { Issue.record("no trailing partial"); return }
        #expect(last.depth == 0 && last.count == 75)
    }

    @Test func readsMoreRedditCommentsAtTheirPlace() {
        let entries = DiscussionEntry.placed(RedditPages.moreEntries(DiscussionFixtures.text("reddit-more.html")), at: 1)
        let comments = entries.compactMap(\.comment)
        #expect(comments.count == 3)
        #expect(comments.allSatisfy { $0.depth >= 1 })
        #expect(comments[0].depth == 1)
    }

    @Test func tellsARedditBlockPage() {
        #expect(DiscussionWeb.isRedditBlock(status: 403, text: ""))
        #expect(DiscussionWeb.isRedditBlock(status: 200, text: #"<script>e.elements.namedItem("solution").value=n</script>"#))
        #expect(!DiscussionWeb.isRedditBlock(status: 200, text: DiscussionFixtures.text("reddit-thread.html") + "js_challenge"))
        #expect(!DiscussionWeb.isRedditBlock(status: 200, text: "<shreddit-post>"))
    }

    // MARK: X

    @Test func readsXSearchCells() {
        let posts = XPages.searchResults(inCells: DiscussionFixtures.cells("x-search.json"))
        #expect(posts.count == 2)
        let first = posts[0]
        #expect(first.url == "https://x.com/MurrayHillGuy1/status/2113747873405796631")
        #expect(first.author == "Murray Hill Guy" && first.handle == "MurrayHillGuy1")
        #expect(first.score == 7188 && first.comments == 1156)
        #expect(first.text?.hasPrefix("Love Is Blind perfectly sums up modern dating.") == true)
        #expect(first.thumbnailUrl == "https://pbs.twimg.com/media/HVWKfNxWwAA8Z5H?format=jpg&name=900x900")
        #expect(first.published == ISO8601.date(from: "2026-10-23T21:42:19.000Z"))
        #expect(posts[1].headline == "not to be dramatic but the indian girl on the new season of love is blind needs to get her ass beat")
    }

    @Test func readsXRepliesInTheirGroups() {
        let entries = XPages.replies(inCells: DiscussionFixtures.cells("x-thread.json"), threadURL: "https://x.com/mahaaaay/status/2113372956336476401")
        let comments = entries.compactMap(\.comment)
        #expect(comments.map(\.id) == ["2113599997619175900", "2113648150238097796", "2113666858624901198"])
        #expect(comments.map(\.depth) == [0, 1, 0])
        #expect(comments[1].byAuthor && !comments[0].byAuthor)
        #expect(comments[0].author == "Mika @Talentedmikado" && comments[0].score == 45)
        let text = comments[0].body.paragraphs.first
        #expect(text?.text == "She is the worst and she\u{2019}s Fiji not Indian but pro #LoveIsBlind \u{1F602}")
        #expect(text?.runs.contains { $0.link == "https://x.com/hashtag/LoveIsBlind" } == true)
    }

    @Test func readsRepliesFromXsOwnAnswer() {
        let entries = XPages.replies(inDetail: DiscussionFixtures.data("x-detail.json"), threadID: "2115613452165124133")
        let comments = entries.compactMap(\.comment)
        #expect(comments.count == 4)
        #expect(!comments.contains { $0.id == "2115613452165124133" })
        let first = comments[0]
        #expect(first.author == "compuficial @compuficial" && first.depth == 0 && first.score == 1)
        // The "@ThePrimeagen " a reply starts with is outside its display range.
        #expect(first.body.plainText == "don't worry everyone I'll tell you when to buy. they call me the nancy pelosi of tpot btw.")
        #expect(first.published == ISO8601.date(from: "2026-10-29T02:09:39Z"))
        #expect(first.url == "https://x.com/compuficial/status/2115627091676803570")
        #expect(first.avatarUrl?.hasPrefix("https://pbs.twimg.com/profile_images/") == true)
    }

    @Test func readsSearchFromXsOwnAnswer() {
        let posts = XPages.posts(inTimeline: DiscussionFixtures.data("x-search-timeline.json"))
        #expect(posts.count == 4)
        #expect(posts[0].url == "https://x.com/MurrayHillGuy1/status/2113747873405796631")
        #expect(posts[0].author == "Murray Hill Guy" && posts[0].score == 7189)
        #expect(posts[0].text?.hasPrefix("Love Is Blind perfectly sums up modern dating.") == true)
        #expect(posts.allSatisfy { $0.published != nil && $0.place == .x })
    }

    @Test func readsXCounts() {
        let counts = XPages.counts("1,156 replies, 705 reposts, 7188 likes, 1 bookmark, 4808889 views")
        #expect(counts == ["repl": 1156, "repost": 705, "like": 7188, "bookmark": 1, "view": 4808889])
    }

    // MARK: APIs

    @Test func readsAHackerNewsThread() async throws {
        let net = DiscussionFixtures.Network([("items/8863", DiscussionFixtures.data("hn-item.json"))])
        let thread = try await net.discussions.comments(for: "https://news.ycombinator.com/item?id=8863")
        let comments = thread.entries.compactMap(\.comment)
        #expect(comments.first?.author == "dhouston" && comments.first?.byAuthor == true)
        #expect(comments.map(\.depth).prefix(2) == [0, 1])
        #expect(comments.allSatisfy { !$0.body.isEmpty })
        #expect(net.requests.first?.url == "https://hn.algolia.com/api/v1/items/8863")
        let item = try HackerNewsThreads.item(DiscussionFixtures.data("hn-item.json"))
        #expect(HackerNewsThreads.contentHTML(item)?.contains("getdropbox.com") == true)
    }

    @Test func readsHackerNewsSearch() throws {
        let posts = try HackerNewsThreads.posts(inSearch: TopicFixtures.hn)
        #expect(!posts.isEmpty)
        #expect(posts.allSatisfy { $0.place == .hackerNews && $0.url.hasPrefix("https://news.ycombinator.com/item?id=") })
    }

    @Test func readsBlueskySearchAndThread() async throws {
        let posts = try BlueskyThreads.posts(inSearch: DiscussionFixtures.data("bluesky-search.json"))
        #expect(posts.count == 4)
        #expect(posts[0].handle == "pallavi.bsky.social" && posts[0].score == 20 && posts[0].comments == 1)
        #expect(posts[0].url.hasPrefix("https://bsky.app/profile/pallavi.bsky.social/post/"))
        #expect(posts[0].thumbnailUrl != nil)

        let net = DiscussionFixtures.Network([("getPostThread", DiscussionFixtures.data("bluesky-thread.json"))])
        let thread = try await net.discussions.comments(for: "https://bsky.app/profile/realqrampage.fightins.online/post/3myq5k5egxk2t")
        let comments = thread.entries.compactMap(\.comment)
        #expect(thread.total == 6)
        // Most liked first, each followed by its replies.
        #expect(comments.first?.author.hasSuffix("@tinkerspider.bsky.social") == true)
        #expect(comments[1].depth == 1)
        #expect(comments.filter { $0.depth == 0 }.count == 6)
    }

    @Test func readsYouTubeCommentsAndReplies() async throws {
        let watch = DiscussionFixtures.data("youtube-next.json")
        let token = try #require(try YouTubeComments.commentsToken(inWatch: watch))
        #expect(!token.isEmpty)

        let entries = try YouTubeComments.entries(DiscussionFixtures.data("youtube-comments.json"), depth: 0)
        let comments = entries.compactMap(\.comment)
        #expect(comments.count == 3)
        #expect(comments[0].author == "@bdr8823" && comments[0].score == 70_000)
        #expect(comments[0].body.plainText == "My algebra teacher said that this was a link to the test answers")
        #expect(comments[0].published != nil)
        guard case .more(let replies) = entries[1] else { Issue.record("no replies after the first thread"); return }
        #expect(replies.depth == 1 && replies.count == 650)
        guard case .more(let next) = entries.last else { Issue.record("no next page"); return }
        #expect(next.depth == 0)

        let more = try YouTubeComments.entries(DiscussionFixtures.data("youtube-replies.json"), depth: 1)
        #expect(more.compactMap(\.comment).count == 3)
        #expect(more.compactMap(\.comment).allSatisfy { $0.depth == 1 })
        guard case .more(let moreReplies) = more.last else { Issue.record("no more replies"); return }
        #expect(moreReplies.depth == 1)
    }

    @Test func readsCompactNumbers() {
        #expect(YouTubeComments.compactNumber("70K") == 70_000)
        #expect(YouTubeComments.compactNumber("1.2M") == 1_200_000)
        #expect(YouTubeComments.compactNumber("1,234") == 1234)
        #expect(YouTubeComments.compactNumber("") == nil)
    }

    // MARK: Opening

    @Test func storesAPostAsAnOpenedLink() {
        let x = DiscussionPost(place: .x, url: "https://x.com/a/status/1", text: "Line one\nLine two", author: "A Person", handle: "a", score: 5, comments: 2)
        let item = OpenedLinks.item(post: x)
        #expect(item.title == "Line one" && item.summary == "Line one\nLine two" && item.author == "A Person (@a)")
        #expect(item.hnPoints == 5 && item.hnComments == 2)
        let reddit = DiscussionPost(place: .reddit, url: "https://www.reddit.com/r/nfl/comments/1/x/", title: "Game thread", author: "u/b", handle: "b", community: "r/nfl")
        let r = OpenedLinks.item(post: reddit)
        #expect(r.title == "Game thread" && r.author == "r/nfl" && r.summary == nil)
    }
}

@Suite("Topics from posts")
struct TopicPostTests {
    private let now = ISO8601.date(from: "2026-10-29T03:00:00Z")!

    private func search(_ net: TopicFixtures.Network, web: DefaultTopicSearch.WebSearch? = nil, signedIn: Bool = false) -> DefaultTopicSearch {
        DefaultTopicSearch(fetch: { url, headers in try net.answer(url, headers: headers, body: nil) },
                           explore: DefaultExploreSearch(fetch: { url, body in try net.answer(url, headers: [:], body: body) }),
                           web: web, signedInToX: { signedIn }, languages: TopicLanguages(preferred: []))
    }

    private let only = TopicPlaces(news: false, hackerNews: false, reddit: false, x: true, bluesky: true, media: false, subscriptions: false)

    @Test func blueskyPostsMatchTheirWholeText() async throws {
        let net = TopicFixtures.Network([.init(fragment: "api.bsky.app", status: 200, body: DiscussionFixtures.data("bluesky-search.json"))])
        let out = await search(net).search(TopicOptions(keyword: "love is blind", places: only), subscriptions: .empty, now: now)
        #expect(out.searched == [.bluesky])
        #expect(!out.items.isEmpty)
        #expect(out.items.allSatisfy { $0.guid.hasPrefix("bsky:https://bsky.app/profile/") && $0.author?.contains("(@") == true })
        // A post whose first line doesn't name the keyword is still on topic when its text does.
        let post = DiscussionPost(place: .bluesky, url: "https://bsky.app/profile/a.b/post/c", text: "Episode 9 tonight\nlove is blind is chaos",
                                  author: "A", handle: "a.b", published: now)
        let candidates = DefaultTopicSearch.candidates(posts: [post], place: .bluesky, now: now)
        let options = TopicOptions(keyword: "love is blind")
        #expect(DefaultTopicSearch.finish(candidates, options, TopicMatcher(options), .empty, now).isEmpty)
        #expect(DefaultTopicSearch.finish(candidates, options, TopicMatcher(options), .empty, now, inText: true).count == 1)
        #expect(out.items.allSatisfy { Topic.place(guid: $0.guid, videoId: nil, audioUrl: nil) == .bluesky })
        let item = Item(id: 1, sourceId: 1, guid: out.items[0].guid, url: out.items[0].url, title: out.items[0].title, publishedAt: now)
        #expect(TopicContentFilter.category(of: item) == .posts)
    }

    @Test func xIsSearchedOnlySignedInAndNotEveryRefresh() async throws {
        let cells = DiscussionFixtures.cells("x-search.json")
        let asked = Counter()
        let web: DefaultTopicSearch.WebSearch = { place, _ in
            guard place == .x else { return [] }
            asked.add()
            return XPages.searchResults(inCells: cells)
        }
        let net = TopicFixtures.Network([])
        let places = TopicPlaces(news: false, hackerNews: false, reddit: false, x: true, bluesky: false, media: false, subscriptions: false)

        let signedOut = await search(net, web: web).search(TopicOptions(keyword: "love is blind", places: places), subscriptions: .empty, now: now)
        #expect(signedOut.searched.isEmpty && asked.value == 0)

        // The fixture's posts are from Oct 22 and 23, inside the window; the keyword is matched in the text.
        let options = TopicOptions(keyword: "love is blind", places: places)
        let first = await search(net, web: web, signedIn: true).search(options, subscriptions: .empty, now: now)
        #expect(first.searched == [.x] && asked.value == 1)
        #expect(Set(first.items.map(\.guid)).isSubset(of: ["x:2113747873405796631", "x:2113372956336476401"]))
        let again = await search(net, web: web, signedIn: true).search(options, subscriptions: .empty, now: now.addingTimeInterval(60))
        #expect(again.items.isEmpty && asked.value == 1)
    }

    @Test func storedPostsKeepTheirPlace() {
        #expect(Topic.place(guid: "x:1", videoId: nil, audioUrl: nil) == .x)
        #expect(Topic.place(guid: "bsky:https://bsky.app/profile/a/post/b", videoId: nil, audioUrl: nil) == .bluesky)
        #expect(Topic.isSocialPost("https://x.com/a/status/1") && !Topic.isSocialPost("https://www.reddit.com/r/a/comments/1/"))
        let decoded = TopicOptions(json: #"{"keyword":"x","places":{"news":true}}"#)
        #expect(decoded?.places.x == true && decoded?.places.bluesky == true && decoded?.places.reddit == false)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}
