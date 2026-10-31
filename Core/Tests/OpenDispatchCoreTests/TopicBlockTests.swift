import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

@Suite("Topic block list")
struct TopicBlockTests {
    private func key(_ url: String, guid: String = "g", author: String? = nil, videoId: String? = nil, audioUrl: String? = nil) -> String? {
        Topic.blockKey(guid: guid, url: url, author: author, videoId: videoId, audioUrl: audioUrl)
    }

    @Test func aBlockNamesTheSiteAccountSubredditOrChannel() {
        #expect(key("https://www.note.com/a/b") == "note.com")
        #expect(key("https://sports.yahoo.com/nfl/story") == "sports.yahoo.com")
        #expect(key("https://x.com/AdamSchefter/status/123", guid: "x:123") == "@AdamSchefter")
        #expect(key("https://bsky.app/profile/alice.bsky.social/post/3abc", guid: "bsky:1") == "@alice.bsky.social")
        #expect(key("https://www.reddit.com/r/nfl/comments/abc/title/", guid: "reddit:abc") == "r/nfl")
        #expect(key("https://www.youtube.com/watch?v=abc", author: " Fireship ", videoId: "abc") == "Fireship")
        #expect(key("https://podcasts.apple.com/us/podcast/x/id1?i=2", author: "Hard Fork", audioUrl: "https://a/b.mp3") == "Hard Fork")
    }

    @Test func someRowsCantBeBlocked() {
        #expect(key("https://www.note.com/a", guid: "hn:1") == nil)
        #expect(key("https://news.ycombinator.com/item?id=1") == nil)
        #expect(key("https://www.youtube.com/watch?v=abc", videoId: "abc") == nil)
        #expect(key("not a url") == nil)
    }

    @Test func aSiteCoversItsSubdomainsAndCaseDoesntMatter() {
        #expect(Topic.isBlocked("note.com", by: ["Note.com"]))
        #expect(Topic.isBlocked("www.msn.com", by: ["msn.com"]))
        #expect(!Topic.isBlocked("denote.com", by: ["note.com"]))
        #expect(Topic.isBlocked("@adamschefter", by: ["@AdamSchefter"]))
        #expect(!Topic.isBlocked("sports.yahoo.com", by: ["news.yahoo.com"]))
    }

    @Test func noBlocksKeepsTheStoredTextTopicsAlreadySyncAs() throws {
        let plain = TopicOptions(keyword: "rust")
        #expect(!plain.json.contains("blocked"))
        var blocked = plain
        blocked.blocked = ["note.com"]
        #expect(blocked.json.contains(#""blocked":["note.com"]"#))
        #expect(TopicOptions(json: blocked.json) == blocked)
        #expect(TopicOptions(json: plain.json)?.blocked == [])
        #expect(TopicOptions(keyword: "x", blocked: [" note.com ", "NOTE.com", ""]).cleaned.blocked == ["note.com"])
    }

    @Test func aSearchDropsBlockedResults() {
        let now = TopicFixtures.now
        func candidate(_ url: String) -> DefaultTopicSearch.Candidate {
            .init(item: ParsedItem(guid: url, url: url, title: "Claude news", publishedAt: now))
        }
        let o = TopicOptions(keyword: "claude", blocked: ["note.com"])
        let out = DefaultTopicSearch.finish([candidate("https://note.com/a"), candidate("https://theverge.com/a")], o, TopicMatcher(o), .empty, now)
        #expect(out.map(\.url) == ["https://theverge.com/a"])
    }

    @Test func aBlockedRowLeavesTheListAtOnceAndGoesWhenTidied() async throws {
        let db = try Fixture.db()
        let topic = try await db.createTopic(TopicOptions(keyword: "claude", places: TopicPlaces(subscriptions: true)))
        let stored = try Fixture.items(db, sourceId: topic.id, [
            ParsedItem(guid: "https://note.com/a", url: "https://note.com/a", title: "Claude on note", publishedAt: Date()),
            ParsedItem(guid: "https://note.com/saved", url: "https://note.com/saved", title: "Claude saved", publishedAt: Date()),
            ParsedItem(guid: "https://theverge.com/a", url: "https://theverge.com/a", title: "Claude on Verge", publishedAt: Date()),
        ])
        try await db.setSaved(itemId: stored[1].id, saved: true)
        // A followed site's own story joins the topic's list; the block covers it too.
        let followed = try Fixture.source(db, title: "Note")
        try Fixture.items(db, sourceId: followed.id, [
            ParsedItem(guid: "f", url: "https://note.com/followed", title: "Claude followed", publishedAt: Date()),
        ])
        #expect(try await db.items(ItemQuery(sourceId: topic.id)).items.count == 4)

        try await db.setTopicBlocked(id: topic.id, blocked: ["note.com"])
        let titles = { try await db.items(ItemQuery(sourceId: topic.id)).items.map(\.item.title).sorted() }
        #expect(try await titles() == ["Claude on Verge", "Claude saved"])
        #expect(try await db.itemCounts(sourceId: topic.id).items == 3)

        // Undo before the cleanup brings everything back.
        try await db.setTopicBlocked(id: topic.id, blocked: [])
        #expect(try await db.items(ItemQuery(sourceId: topic.id)).items.count == 4)

        try await db.setTopicBlocked(id: topic.id, blocked: ["note.com"])
        #expect(try await db.tidyTopic(id: topic.id) == 1)
        #expect(try await db.itemCounts(sourceId: topic.id) == (items: 2, saved: 1))
        #expect(try await titles() == ["Claude on Verge", "Claude saved"])
    }

    @Test func aHeldRemovalLeavesEveryList() async throws {
        let db = try Fixture.db()
        let gone = try Fixture.source(db, title: "Gone")
        let kept = try Fixture.source(db, title: "Kept")
        let items = try Fixture.items(db, sourceId: gone.id, Fixture.parsed(3, prefix: "g"))
        try Fixture.items(db, sourceId: kept.id, Fixture.parsed(1, prefix: "k"))
        try await db.setSaved(itemId: items[0].id, saved: true)
        #expect(try await db.itemCounts(sourceId: gone.id) == (items: 3, saved: 1))
        for query in [ItemQuery(excludedSourceIds: [gone.id]), ItemQuery(order: .balanced, excludedSourceIds: [gone.id])] {
            #expect(try await db.items(query).items.map(\.source.id) == [kept.id])
        }
        #expect(try await db.items(ItemQuery(view: .saved, excludedSourceIds: [gone.id])).items.isEmpty)
    }
}
