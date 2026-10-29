import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

/// Topics in the database: the migration, the queries that keep them out of the curated views and into their own list,
/// editing, the per-item reading rules and notifications.
@Suite("Topic store")
struct TopicStoreTests {
    private let now = Fixture.base

    private func topic(_ db: AppDatabase, _ keyword: String = "vision pro", excluded: [String] = [], subscriptions: Bool = true) async throws -> Source {
        try await db.createTopic(TopicOptions(
            keyword: keyword, excluded: excluded, places: TopicPlaces(news: true, discussions: true, media: true, subscriptions: subscriptions)))
    }

    @discardableResult
    private func store(_ db: AppDatabase, _ source: Source, _ items: [ParsedItem]) throws -> [UpsertedItem] {
        try Fixture.items(db, sourceId: source.id, items)
    }

    private func item(_ guid: String, _ title: String, age: TimeInterval, url: String? = nil, video: String? = nil, audio: String? = nil,
                      comments: String? = nil, summary: String? = nil) -> ParsedItem {
        ParsedItem(guid: guid, url: url ?? "https://example.com/\(guid)", title: title, summary: summary, author: "Origin \(guid)",
                   publishedAt: now.addingTimeInterval(-age), videoId: video, audioUrl: audio, hnCommentsUrl: comments)
    }

    // MARK: Migration

    @Test func migrationRebuildsSourcesKeepingEverything() throws {
        let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
        try AppDatabase.migrator.migrate(queue, upTo: "v7-history")
        try queue.write { d in
            try d.execute(sql: "INSERT INTO folders (title, position) VALUES ('News', 0)")
            for i in 1...3 {
                try d.execute(sql: """
                    INSERT INTO sources (title, url, feed_url, kind, "group", folder_id, position, is_hidden, notify_since, pinned_at)
                    VALUES (?, ?, ?, 'rss', 'blogs', 1, ?, ?, ?, ?)
                    """, arguments: ["S\(i)", "https://s\(i).example", "https://s\(i).example/feed", i, i == 2, i == 1 ? Fixture.base : nil, i == 3 ? Fixture.base : nil])
            }
            try d.execute(sql: "INSERT INTO items (source_id, guid, url, title, published_at) VALUES (1, 'a', 'https://s1.example/a', 'A', ?), (2, 'b', 'https://s2.example/b', 'B', ?)",
                          arguments: [Fixture.base, Fixture.base])
            // The third source is removed, so the table's id counter is ahead of its rows.
            try d.execute(sql: "DELETE FROM sources WHERE id = 3")
        }
        try AppDatabase.migrator.migrate(queue)
        try queue.write { d in
            let sources = try Source.order(Source.Columns.id).fetchAll(d)
            #expect(sources.map(\.title) == ["S1", "S2"])
            #expect(sources.map(\.folderId) == [1, 1])
            #expect(sources[0].notifySince == Fixture.base && sources[0].pinnedAt == nil)
            #expect(sources[1].isHidden && sources[1].topicOptions == nil)
            #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM items") == 2)
            #expect(try Row.fetchAll(d, sql: "PRAGMA foreign_key_check").isEmpty)
            // The id counter wasn't reset: a new source doesn't reuse the removed one's id.
            var fresh = Source(title: "New", url: "https://n.example", feedUrl: "https://n.example/feed", kind: .rss, group: "blogs")
            try fresh.insert(d)
            #expect(fresh.id == 4)
            // The new kind is allowed, an unknown one still isn't, and the folder index is back.
            var topic = Source(title: "t", url: Topic.siteURL, feedUrl: Topic.newFeedURL(), kind: .topic, group: "topics",
                               topicOptions: TopicOptions(keyword: "t"))
            try topic.insert(d)
            #expect(try Source.fetchOne(d, key: topic.id)?.topicOptions == TopicOptions(keyword: "t"))
            #expect(throws: DatabaseError.self) {
                try d.execute(sql: "INSERT INTO sources (title, url, feed_url, kind, \"group\") VALUES ('x', 'u', 'f', 'bogus', 'g')")
            }
            #expect(try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'sources'").contains("sources_folder_idx"))
            // Deleting a source still removes its items.
            try d.execute(sql: "DELETE FROM sources WHERE id = 1")
            #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM items") == 1)
        }
    }

    // MARK: Create, edit, find, delete

    @Test func createdTopicHasAStableIdentityAndTheKeywordAsTitle() async throws {
        let db = try Fixture.db()
        let t = try await topic(db, "  Vision   Pro ")
        #expect(t.isTopic && t.kind == .topic)
        #expect(t.feedUrl.hasPrefix("opendispatch:topic:") && t.feedUrl.count > "opendispatch:topic:".count)
        #expect(t.title == "Vision Pro" && t.topicKeyword == "Vision Pro")
        #expect(t.group == SourceGroup.topics)
        #expect(t.topicOptions?.keyword == "Vision Pro")
        let second = try await topic(db, "rust")
        #expect(second.position == t.position + 1)

        // The same keyword again (any case, spacing, diacritics) is the same topic.
        let again = try await db.createTopic(TopicOptions(keyword: "VISION pro", notableOnly: true))
        #expect(again.id == t.id && again.topicOptions?.notableOnly == false)
        #expect(try await db.topic(keyword: "vision  PRO")?.id == t.id)
        #expect(try await db.topic(keyword: "visión pro")?.id == t.id)
        #expect(try await db.topic(keyword: "other") == nil)
        #expect(try await db.topics().map(\.title) == ["Vision Pro", "rust"])
        await #expect(throws: QueryError.self) { try await db.createTopic(TopicOptions(keyword: "   ")) }
    }

    @Test func updatingKeepsIdentityAndDropsItemsThatNoLongerMatch() async throws {
        let db = try Fixture.db()
        let t = try await topic(db)
        let rows = try store(db, t, [
            item("a", "Vision Pro hands-on", age: 100), item("b", "Vision Pro rumor mill", age: 200),
            item("c", "Vision Pro deal", age: 300),
        ])
        try await db.setSaved(itemId: rows[1].id, saved: true)

        let edited = try await db.updateTopic(id: t.id, options: TopicOptions(keyword: "Vision Pro 2", excluded: ["deal"], notableOnly: true))
        #expect(edited.id == t.id && edited.feedUrl == t.feedUrl)
        #expect(edited.title == "Vision Pro 2" && edited.topicOptions?.notableOnly == true)
        // "Vision Pro 2" names none of them, but the saved one stays; and edits don't touch notify.
        #expect(try await db.items(ItemQuery(sourceId: t.id)).items.map(\.item.guid) == ["b"])

        let kept = try await db.updateTopic(id: t.id, options: TopicOptions(keyword: "vision", excluded: ["deal"]))
        #expect(kept.title == "vision")
        await #expect(throws: QueryError.self) { try await db.updateTopic(id: 9999, options: TopicOptions(keyword: "x")) }
        let blog = try Fixture.source(db)
        await #expect(throws: QueryError.self) { try await db.updateTopic(id: blog.id, options: TopicOptions(keyword: "x")) }
        await #expect(throws: QueryError.self) { try await db.updateTopic(id: t.id, options: TopicOptions(keyword: " ")) }
    }

    @Test func deletingATopicRemovesItsItemsButNotASourceByThatCall() async throws {
        let db = try Fixture.db()
        let t = try await topic(db)
        try store(db, t, [item("a", "Vision Pro", age: 10)])
        let blog = try Fixture.source(db)
        #expect(try await db.deleteTopic(id: blog.id) == false)
        #expect(try await db.source(id: blog.id) != nil)
        #expect(try await db.deleteTopic(id: t.id))
        #expect(try await db.source(id: t.id) == nil)
        #expect(try await db.reader.read { try Item.fetchCount($0) } == 0)
    }

    // MARK: Lists

    @Test func topicsAreInTheSourceTableButNotInSubscriptionLists() async throws {
        let db = try Fixture.db()
        let t = try await topic(db)
        let blog = try Fixture.source(db, title: "Blog")
        let all = try await db.writer.read { try Queries.sources($0) }
        #expect(Set(all.map(\.id)) == [t.id, blog.id])
        // What the app lists as sources leaves topics out.
        #expect(try await db.sources().map(\.id) == [blog.id])
        #expect(try await db.sourcesAndFolders().sources.map(\.id) == [blog.id])
        #expect(try await db.topics().map(\.id) == [t.id])

        #expect(SourceList.inFolder(all, nil).map(\.id) == [blog.id] && SourceList.allInFolder(all, nil).map(\.id) == [blog.id])
        #expect(SourceList.matching(all, query: "vision").isEmpty)
        #expect(SourceList.topics(all).map(\.id) == [t.id])
    }

    @Test func opmlExportSkipsTopics() async throws {
        let db = try Fixture.db()
        _ = try await topic(db, "secret keyword")
        _ = try Fixture.source(db, title: "Blog", feedUrl: "https://blog.example.com/feed")
        let xml = try await OpenDispatchServices.live(database: db).exportOPML()
        #expect(xml.contains("https://blog.example.com/feed"))
        #expect(!xml.contains("opendispatch:topic") && !xml.contains("secret keyword"))
        // The coder drops them too when handed a mixed list.
        let mixed = try await db.writer.read { try Queries.sources($0) }
        #expect(!DefaultOPMLCoder().serialize(folders: [], sources: mixed, now: now).contains("opendispatch:topic"))
    }

    // MARK: Items

    @Test func topicItemsStayOutOfTheCuratedViewsButAreInTheirTopicAndSaved() async throws {
        let db = try Fixture.db()
        let t = try await topic(db, subscriptions: false)
        let blog = try Fixture.source(db, title: "Blog")
        let video = try Fixture.source(db, title: "Chan", url: "https://www.youtube.com/channel/UCx", kind: .youtube)
        let folder = try await db.createFolder(title: "F", withSource: blog.id)
        let rows = try store(db, t, [
            item("t-article", "Vision Pro review", age: 100), item("t-video", "Vision Pro video", age: 200, video: "vid00000001"),
            item("t-episode", "Vision Pro episode", age: 300, audio: "https://cdn.example/e.mp3"),
        ])
        try store(db, blog, [item("b1", "Blog post", age: 400)])
        try store(db, video, [item("v1", "A video", age: 500, video: "vid00000002")])

        for view in FeedView.allCases where view != .saved {
            let guids = try await db.items(ItemQuery(view: view)).items.map(\.item.guid)
            #expect(!guids.contains { $0.hasPrefix("t-") }, "\(view)")
        }
        #expect(try await db.items(ItemQuery(folderId: folder.id)).items.map(\.item.guid) == ["b1"])
        #expect(try await db.items(ItemQuery(search: "Vision")).items.isEmpty)
        #expect(try await db.items(ItemQuery(sourceId: t.id)).items.map(\.item.guid) == ["t-article", "t-video", "t-episode"])

        try await db.setSaved(itemId: rows[0].id, saved: true)
        #expect(try await db.items(ItemQuery(view: .saved)).items.map(\.item.guid) == ["t-article"])
        #expect(try await db.items(ItemQuery(sourceId: t.id)).items.count == 3)
    }

    @Test func chipsFilterATopicsItemsByKind() async throws {
        let db = try Fixture.db()
        let t = try await topic(db, subscriptions: false)
        try store(db, t, [
            item("article", "Vision Pro review", age: 100),
            item("hn", "Vision Pro on HN", age: 200, url: "https://example.com/story", comments: "https://news.ycombinator.com/item?id=1"),
            item("reddit", "Vision Pro on Reddit", age: 300, url: "https://www.reddit.com/r/apple/comments/abc/vision_pro/"),
            item("video", "Vision Pro video", age: 400, video: "vid00000001"),
            item("episode", "Vision Pro episode", age: 500, audio: "https://cdn.example/e.mp3"),
        ])
        func guids(_ f: TopicContentFilter) async throws -> [String] {
            try await db.items(ItemQuery(sourceId: t.id, topicFilter: f)).items.map(\.item.guid)
        }
        #expect(try await guids(.all) == ["article", "hn", "reddit", "video", "episode"])
        #expect(try await guids(.articles) == ["article"])
        #expect(try await guids(.discussions) == ["hn", "reddit"])
        #expect(try await guids(.videos) == ["video"])
        #expect(try await guids(.episodes) == ["episode"])
        // The same split the app can compute for one item.
        let page = try await db.items(ItemQuery(sourceId: t.id)).items
        for f in [TopicContentFilter.articles, .discussions, .videos, .episodes] {
            #expect(try await guids(f) == page.filter { TopicContentFilter.category(of: $0.item) == f }.map(\.item.guid))
        }
    }

    @Test func aTopicsListAlsoShowsMatchingItemsOfTheUsersSources() async throws {
        let db = try Fixture.db()
        let t = try await topic(db, excluded: ["rumor"])
        let blog = try Fixture.source(db, title: "Blog")
        let other = try Fixture.source(db, title: "Other")
        try store(db, t, [item("t1", "Vision Pro stored", age: 1_000), item("t2", "Vision Pro stored two", age: 3_000)])
        try store(db, blog, [
            item("b-match", "Our Vision Pro take", age: 2_000), item("b-no", "Unrelated post", age: 2_500),
            item("b-body", "Weekly notes", age: 4_000, summary: "<p>Mostly about the VISION PRO.</p>"),
            item("b-excluded", "Vision Pro rumor", age: 5_000), item("b-short", "Vision", age: 6_000),
        ])
        try store(db, other, [item("o-match", "Vision Pro, again", age: 7_000)])
        // An opened link that mentions it isn't a subscription.
        _ = try await db.insertOpenedLink(item("https://opened.example/x", "Opened: Vision Pro", age: 10))

        let list = try await db.items(ItemQuery(sourceId: t.id)).items
        #expect(list.map(\.item.guid) == ["t1", "b-match", "t2", "b-body", "o-match"])
        // Each shows under its own source; the unread count for the topic is its own items only.
        #expect(list.map(\.source.title) == ["vision pro", "Blog", "vision pro", "Blog", "Other"])

        // Keyset paging over the mixed list: no repeats, no gaps.
        var paged: [String] = []
        var q = ItemQuery(sourceId: t.id, limit: 2)
        while true {
            let page = try await db.items(q)
            paged += page.items.map(\.item.guid)
            guard let next = page.nextCursor else { break }
            q = q.after(next)
        }
        #expect(paged == list.map(\.item.guid))

        // Turned off: only what the topic stored.
        let off = try await db.updateTopic(id: t.id, options: TopicOptions(keyword: "vision pro", excluded: ["rumor"], places: TopicPlaces(subscriptions: false)))
        #expect(try await db.items(ItemQuery(sourceId: off.id)).items.map(\.item.guid) == ["t1", "t2"])
        // And the curated views still don't show the topic's own items.
        #expect(try await db.items(ItemQuery()).items.allSatisfy { !$0.item.guid.hasPrefix("t") })
    }

    @Test func unreadCountsAreEachSourcesOwnItems() async throws {
        let db = try Fixture.db()
        let t = try await topic(db)
        let blog = try Fixture.source(db, title: "Blog")
        let rows = try store(db, t, [item("t1", "Vision Pro one", age: 10), item("t2", "Vision Pro two", age: 20)])
        try store(db, blog, [item("b1", "Vision Pro blog", age: 30)])
        #expect(try await db.unreadCounts() == [t.id: 2, blog.id: 1])

        let first = try #require(try await db.feedItem(id: rows[0].id))
        _ = try await db.setRead(HistoryEntry(item: first), read: true)
        #expect(try await db.unreadCounts() == [t.id: 1, blog.id: 1])
        // Mark All as Read on the topic's list (which includes the blog's matching item) reads them all.
        _ = try await db.markAllRead(ItemQuery(sourceId: t.id))
        #expect(try await db.unreadCounts().isEmpty)
    }

    // MARK: Reading a topic's items

    @Test func eachItemReadsAndPlaysByWhatItIs() async throws {
        let db = try Fixture.db()
        let t = try await topic(db, subscriptions: false)
        try store(db, t, [
            item("article", "Vision Pro review", age: 100, url: "https://www.theverge.com/a/b"),
            item("video", "Vision Pro video", age: 200, url: "https://www.youtube.com/watch?v=vid00000001", video: "vid00000001"),
            item("episode", "Vision Pro episode", age: 300, url: "https://podcasts.apple.com/us/podcast/id1?i=2", audio: "https://cdn.example/e.mp3"),
        ])
        let list = try await db.items(ItemQuery(sourceId: t.id)).items
        let byGuid = Dictionary(uniqueKeysWithValues: list.map { ($0.item.guid, $0) })
        let article = try #require(byGuid["article"]), video = try #require(byGuid["video"]), episode = try #require(byGuid["episode"])

        #expect(article.source.kind == .rss && article.source.type == .article)
        #expect(video.source.kind == .youtube && video.source.type == .video)
        #expect(episode.source.kind == .podcast && episode.source.type == .podcast)
        // Still the topic, named by its keyword; the badge uses the item's own site.
        #expect(article.source.isTopic && article.source.id == t.id && article.source.title == "vision pro")
        #expect(article.source.host == "theverge.com" && video.source.host == "youtube.com")
        // History keeps what the item was.
        #expect(HistoryEntry(item: video).sourceKind == .youtube)
        #expect(HistoryEntry(item: video).sourceFeedUrl == t.feedUrl)
        #expect(HistoryEntry(item: article).sourceKind == .rss)
        #expect(HistoryEntry.isMedia(video) && HistoryEntry.isMedia(episode) && !HistoryEntry.isMedia(article))
        let header = ItemMarkdown.header(item: video.item, source: video.source, timeZone: .gmt)
        #expect(header.contains("YouTube") && header.contains("Origin video") && !header.contains("vision pro"))
        #expect(video.originName == "Origin video" && article.originName == "Origin article")
        #expect(WebhookPayload(item: article).source.title == "Origin article")
    }

    @Test func contentIsReadByWhatTheItemIs() async throws {
        let db = try Fixture.db()
        let t = try await topic(db, subscriptions: false)
        let episodeItem = try #require(ApplePodcastEpisode.item(lookup: ApplePodcastFixtures.episodes,
                                                                link: .init(country: "us", showID: "1627920305", episodeID: ApplePodcastFixtures.episodeID)).item)
        try store(db, t, [
            item("article", "Vision Pro review", age: 100, url: "https://www.theverge.com/a/b"),
            item("video", "Vision Pro video", age: 200, video: "vid00000001"), episodeItem,
        ])
        let list = try await db.items(ItemQuery(sourceId: t.id)).items
        let article = try #require(list.first { $0.item.guid == "article" }), video = try #require(list.first { $0.item.guid == "video" })
        let episode = try #require(list.first { $0.item.audioUrl != nil })

        let extractor = TopicExtractorStub()
        var content = ContentService(database: db, extractor: extractor)
        let net = ApplePodcastFixtures.Network([ApplePodcastEpisode.lookupURL(showID: "1627920305", country: "us", limit: 0): ApplePodcastFixtures.show])
        content.lookup = net.fetch

        // A video has no body.
        #expect(try await content.content(forItem: video.id).contentHtml == nil)
        // An article is extracted from its page, never from the topic's non-existent feed.
        #expect(try await content.content(forItem: article.id).contentHtml == "<p>Article</p>")
        #expect(extractor.articles.map(\.url) == ["https://www.theverge.com/a/b"])
        #expect(extractor.articles.allSatisfy { $0.feed == nil })
        // An episode's notes come from its show's feed, found through the Apple address, like an opened episode's.
        #expect(try await content.content(forItem: episode.id).contentHtml == "<p>Notes</p>")
        #expect(extractor.notes == [.init(url: ApplePodcastFixtures.audio, feed: FeedRef(feedUrl: ApplePodcastFixtures.showFeedURL, guid: episodeItem.guid))])
    }

    // MARK: Notifications

    @Test func alertsNameTheTopicAndWhereTheItemCameFrom() async throws {
        let db = try Fixture.db()
        let t = try await topic(db, "Vision Pro")
        let blog = try Fixture.source(db, title: "Blog")
        _ = try await db.setSourceNotify(id: t.id, on: true)
        _ = try await db.setSourceNotify(id: blog.id, on: true)
        // Stored after notifications were turned on.
        let fresh = Date()
        try await db.writer.write { d in
            _ = try Queries.upsertItems(d, sourceId: t.id, items: [
                ParsedItem(guid: "hn:1", url: "https://example.com/1", title: "Vision Pro lands", author: "Hacker News", publishedAt: fresh)], now: fresh.addingTimeInterval(1))
            _ = try Queries.upsertItems(d, sourceId: blog.id, items: [
                ParsedItem(guid: "b", url: "https://example.com/b", title: "Blog post", author: "Writer", publishedAt: fresh)], now: fresh.addingTimeInterval(1))
        }
        let alerts = try await db.takeNewPostAlerts()
        let topicAlert = try #require(alerts.first { $0.sourceId == t.id })
        let blogAlert = try #require(alerts.first { $0.sourceId == blog.id })
        #expect(topicAlert.isTopic && topicAlert.itemAuthor == "Hacker News")
        #expect(topicAlert.heading == "Vision Pro \u{00B7} Hacker News")
        #expect(blogAlert.heading == "Blog" && !blogAlert.isTopic)
        // A topic item with no author is announced by the keyword alone.
        #expect(NewPostAlert(itemId: 1, title: "t", publishedAt: now, sourceId: 1, sourceTitle: "rust", itemAuthor: " ", isTopic: true).heading == "rust")
    }

    @Test func matcherCountsAMentionInTheSitesHost() {
        let m = TopicMatcher(keyword: "OpenAI", excluded: ["rumor"])
        #expect(!m.matches(title: "Three new discoveries in mathematics", summary: nil))
        #expect(m.matches(title: "Three new discoveries in mathematics", summary: nil, host: "openai.com"))
        // Leave-out words still apply to the text.
        #expect(!m.matches(title: "A rumor about the lab", summary: nil, host: "openai.com"))
        #expect(!TopicMatcher(keyword: "vision pro").matches(title: "x", summary: nil, host: "example.com"))
    }
}

/// Records what the article and show-notes extractions were asked for.
private final class TopicExtractorStub: ContentExtractor, @unchecked Sendable {
    struct Article: Equatable { var url: String; var feed: FeedRef? }
    struct Notes: Equatable { var url: String; var feed: FeedRef }
    private let lock = NSLock()
    private var articleCalls: [Article] = []
    private var noteCalls: [Notes] = []
    var articles: [Article] { lock.lock(); defer { lock.unlock() }; return articleCalls }
    var notes: [Notes] { lock.lock(); defer { lock.unlock() }; return noteCalls }

    func extractArticle(url: String, feed: FeedRef?) async throws -> ExtractResult {
        lock.lock(); articleCalls.append(Article(url: url, feed: feed)); lock.unlock()
        return ExtractResult(contentHtml: "<p>Article</p>", leadImage: nil)
    }

    func extractPodcastNotes(url: String, feed: FeedRef) async throws -> ExtractResult {
        lock.lock(); noteCalls.append(Notes(url: url, feed: feed)); lock.unlock()
        return ExtractResult(contentHtml: "<p>Notes</p>", leadImage: nil)
    }
}
