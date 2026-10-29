import Foundation
import Testing
@testable import OpenDispatchCore

/// Explore's articles. Fixtures/Topics/bing-news-relevance.xml is Bing's answer for "openai" in its own order (the first six of
/// the real answer, then a story from 60 days earlier and one with no title); bing-news-outlets.xml is a `site:` answer (real
/// Reuters, Bloomberg and Journal articles, the Politico story the plain answer has under another host, a result that never
/// mentions the word, and one with no picture).
@Suite("Article search")
struct ArticleSearchTests {
    private let now = ISO8601.date(from: "2026-10-29T12:00:00Z")!
    private let english = TopicFixtures.english

    /// Answers the plain search with the relevance fixture and every `site:` search with the outlets one, recording the addresses.
    private final class Network: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        var failPlain = false
        var failOutlets = false
        var urls: [String] { lock.lock(); defer { lock.unlock() }; return asked }

        private func record(_ url: String) {
            lock.lock()
            asked.append(url)
            lock.unlock()
        }

        func search(sites: [[String]] = [["reuters.com", "bloomberg.com"], ["nytimes.com"]]) -> DefaultArticleSearch {
            DefaultArticleSearch(fetch: { url, _ in
                self.record(url)
                let outlets = url.contains("site%3A")
                let data = outlets ? TopicFixtures.data("bing-news-outlets", "xml") : TopicFixtures.data("bing-news-relevance", "xml")
                let status = (outlets ? self.failOutlets : self.failPlain) ? 503 : 200
                return (data, HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }, languages: TopicFixtures.english, sites: { sites })
        }
    }

    @Test func asksBingInItsOwnOrderForTheQueryAsTyped() async throws {
        let net = Network()
        _ = try await net.search().articles("iphone duo", now: now)
        let urls = net.urls
        // One plain search and one per group of sites, with no sort by date and no quotes around the words.
        #expect(urls.count == 3)
        #expect(urls.contains("https://www.bing.com/news/search?q=iphone%20duo&format=rss&mkt=en-US&setlang=en-US"))
        #expect(urls.filter { $0.contains("site%3A") }.count == 2)
        #expect(urls.allSatisfy { !$0.contains("qft=") && !$0.contains("%22") })
        #expect(urls.contains { $0.contains("q=iphone%20duo%20%28site%3Areuters.com%20OR%20site%3Abloomberg.com%29&") })
        #expect(try await net.search().articles("   ", now: now).isEmpty)
    }

    @Test func mergesTheSearchesInterleavedOnceEachRecentAndOnTopic() async throws {
        let found = try await Network().search().articles("openai", now: now)
        let urls = found.map(\.url)
        // The plain answer's first, then the outlet groups' first (both groups get the same fixture, so the second's is a repeat), and so on.
        #expect(found.first?.url.hasPrefix("https://247wallst.com/") == true)
        #expect(found.map(\.outlet).prefix(3) == ["24/7 Wall St.", "Reuters", "AppleInsider"])
        // The 60-day-old story, the untitled one and the outlet result that never says "openai" are gone.
        #expect(!urls.contains { $0.contains("old/openai-devday") || $0.contains("untitled") || $0.contains("seattle") })
        // The Politico story is there once, from the plain search (www.politico.com), though the outlet search found it too.
        #expect(urls.filter { $0.contains("politico.com") }.count == 1)
        #expect(urls.contains { $0.hasPrefix("https://www.politico.com/") })
        // A headline from one outlet isn't repeated under another address, and every address is the article's, not Bing's.
        #expect(Set(urls).count == urls.count)
        #expect(urls.allSatisfy { !$0.contains("bing.com") })
        // 6 plain + 5 distinct outlet articles, each outlet group answering the same fixture.
        #expect(found.count == 11)
        #expect(found.allSatisfy { !$0.title.isEmpty && $0.published <= now })
    }

    @Test func carriesTheOutletSummaryDateAndPicture() async throws {
        let found = try await Network().search().articles("openai", now: now)
        let first = try #require(found.first)
        #expect(first.title == "OpenAI Now Makes Up 11% of Microsoft\u{2019}s Revenue")
        #expect(first.outlet == "24/7 Wall St.")
        #expect(first.summary?.hasPrefix("Microsoft's latest quarterly filing") == true)
        #expect(first.published == ISO8601.date(from: "2026-10-29T05:44:00Z"))
        // Bing's picture, at the size we draw, over https.
        #expect(first.imageUrl == "https://www.bing.com/th?id=ONUT.AetyxVLJ0i_kUAHpfVn8xg&pid=News&w=360&h=270&c=14")
        // One without a picture has none.
        #expect(found.first { $0.url.contains("ft.com") }?.imageUrl == nil)
    }

    @Test func aSearchThatFailsIsLeftOutAndAllFailingThrows() async throws {
        let net = Network()
        net.failOutlets = true
        let plainOnly = try await net.search().articles("openai", now: now)
        #expect(plainOnly.count == 6)
        net.failOutlets = false
        net.failPlain = true
        let outletsOnly = try await net.search().articles("openai", now: now)
        #expect(outletsOnly.contains { $0.url.contains("reuters.com") } && !outletsOnly.contains { $0.url.contains("247wallst") })
        net.failOutlets = true
        await #expect(throws: HTTPError.self) { try await net.search().articles("openai", now: now) }
    }

    @Test func keepsAtMostThirtyAndThePicturelessThumbnailRules() {
        let many = (0..<45).map { i in
            BingNews.Article(title: "Story \(i) about rust", url: "https://example.com/\(i)", publisher: "Example", summary: nil, published: now, imageUrl: nil)
        }
        #expect(DefaultArticleSearch.merge([many], query: "rust", languages: english, now: now).count == DefaultArticleSearch.limit)
        // Bing's address gets the size filled in and https; anything else is left alone.
        #expect(BingNews.thumbnail("http://www.bing.com/th?id=ONUT.x&pid=News", size: "w={0}&h={1}&c=14") == "https://www.bing.com/th?id=ONUT.x&pid=News&w=360&h=270&c=14")
        #expect(BingNews.thumbnail("http://www.bing.com/th?id=ONUT.x&pid=News", size: nil) == "http://www.bing.com/th?id=ONUT.x&pid=News")
        #expect(BingNews.thumbnail("https://cdn.example.com/a.jpg", size: "w={0}&h={1}") == "https://cdn.example.com/a.jpg")
        #expect(BingNews.thumbnail("not a url", size: nil) == nil)
        #expect(DefaultArticleSearch.key(url: "https://www.Example.com/a/b/?x=1#top") == DefaultArticleSearch.key(url: "http://example.com/a/b?x=1"))
    }

    @Test func topicsStillReadTheSameNewsAnswer() throws {
        // The shared parser leaves Topics' candidates as they were, picture or not.
        let found = try DefaultTopicSearch.parseNews(TopicFixtures.data("bing-news-relevance", "xml"))
        #expect(found.count == 6 + 1)  // the untitled one is out
        #expect(found[0].item.thumbnailUrl == nil)
        #expect(found[0].name == "24/7 Wall St.")
    }

    @Test func anOpenedArticleIsStoredLikeAnyOpenedLink() async throws {
        let article = ExploreArticle(
            url: "https://www.politico.com/news/2026/10/28/openai-election-war-room", title: "OpenAI launching election war room",
            outlet: "Politico", published: now, summary: "Summary.", imageUrl: "https://www.bing.com/th?id=x")
        let item = OpenedLinks.item(article: article)
        #expect(item.guid == article.url && item.url == article.url)
        #expect(item.author == "Politico" && item.summary == "Summary." && item.publishedAt == now)
        #expect(item.thumbnailUrl == nil)
        let db = try Fixture.db()
        let stored = try await db.insertOpenedLink(item)
        #expect(stored.source.feedUrl == OpenedLinks.linksFeedURL)
        #expect(try await db.openedLink(feedUrl: OpenedLinks.linksFeedURL, url: article.url)?.id == stored.id)
    }
}
