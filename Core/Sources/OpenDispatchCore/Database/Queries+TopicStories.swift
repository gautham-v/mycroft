import Foundation
import GRDB

/// Topic stories: the articles several outlets wrote about one story are stored as one item each and listed as one row.
///
/// - A story's lead is its first stored article (the lowest id). It keeps `story_id` NULL, so the topic's list (which shows only
///   items with a NULL `story_id`) shows it, and carries `story_at`, the time of its newest article: the story sorts there, so
///   fresh coverage lifts a story back up the list. The keyset cursor is (`story_at` or `published_at`, id).
/// - Every other article of the story, and the Hacker News thread about it, has `story_id` = the lead's id.
/// - Only news articles open or join a story. Videos, episodes, Reddit posts and a Hacker News thread with no article stay rows
///   of their own, and so does an article no other outlet matched.
/// - Grouping is saved, so a story doesn't change between refreshes or between pages. Each refresh groups the articles it
///   stored (`groupTopicStories`); removing a lead gives its story to the next article (`repairStories`).
extension Queries {

    // MARK: Grouping

    private struct Article {
        var id: Int64
        var url: String
        var published: Date
        var words: Set<String>
        var storyId: Int64?
        var isHackerNews: Bool
    }

    /// Group a topic's stored articles into stories and attach Hacker News threads to them. Run in the transaction that stores a
    /// refresh's items, so a notification never sees an article of an existing story as a new post. Only articles and threads
    /// that aren't in a story are looked at: each joins the story of an earlier-stored article it matches, or stays a lead.
    /// Returns how many items were attached.
    @discardableResult
    static func groupTopicStories(_ db: Database, topic: Source) throws -> Int {
        guard topic.isTopic else { return 0 }
        let keyword = topic.topicOptions?.keyword ?? topic.title
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, guid, url, title, published_at, story_id, video_id, audio_url, hn_comments_url FROM items WHERE source_id = ? ORDER BY id
            """, arguments: [topic.id])
        var news: [Article] = []
        var threads: [Article] = []
        for row in rows {
            let guid: String = row["guid"]
            let url: String = row["url"]
            let video: String? = row["video_id"]
            let audio: String? = row["audio_url"]
            let comments: String? = row["hn_comments_url"]
            let place = Topic.place(guid: guid, videoId: video, audioUrl: audio)
            let isThread = place == .hackerNews
            guard isThread || (place == .news && comments == nil && !Topic.isRedditPost(url)) else { continue }
            let article = Article(
                id: row["id"], url: url, published: row["published_at"], words: TopicStories.words(of: row["title"], keyword: keyword),
                storyId: row["story_id"], isHackerNews: isThread)
            if isThread { threads.append(article) } else { news.append(article) }
        }

        // Who is in which story now (by lead id); a lead alone is a story of one.
        var leadOf: [Int64: Int64] = [:]
        var hasMembers = Set<Int64>()
        for a in news {
            leadOf[a.id] = a.storyId ?? a.id
            if let s = a.storyId { hasMembers.insert(s) }
        }
        var attached = 0
        func attach(_ id: Int64, to lead: Int64) throws {
            try db.execute(sql: "UPDATE items SET story_id = ? WHERE id = ?", arguments: [lead, id])
            attached += 1
        }

        // Articles, in the order they were stored: each may join the story of an earlier one. A lead with articles behind it is a
        // story of its own and isn't merged into another; an article joins the story of its best match.
        func bestStory(for a: Article, among others: ArraySlice<Article>) -> Int64? {
            var best: (score: Double, lead: Int64)?
            for b in others where b.id != a.id && TopicStories.isSameStory(a.words, a.published, b.words, b.published) {
                guard let lead = leadOf[b.id], lead != a.id else { continue }
                let score = Double(a.words.intersection(b.words).count) / Double(min(a.words.count, b.words.count))
                if best == nil || score > best!.score { best = (score, lead) }
            }
            return best?.lead
        }
        func isLoose(_ a: Article) -> Bool { a.storyId == nil && leadOf[a.id] == a.id && !hasMembers.contains(a.id) && !a.words.isEmpty }
        for (index, a) in news.enumerated() where isLoose(a) {
            if let lead = bestStory(for: a, among: news[..<index]) {
                try attach(a.id, to: lead)
                leadOf[a.id] = lead
                hasMembers.insert(lead)
            }
        }
        // An article that only matched something stored after it (a headline that links two others) joins that story now.
        var joined = true
        while joined {
            joined = false
            for a in news where isLoose(a) {
                if let lead = bestStory(for: a, among: news[...]) {
                    try attach(a.id, to: lead)
                    leadOf[a.id] = lead
                    hasMembers.insert(lead)
                    joined = true
                }
            }
        }

        // Hacker News threads: the story that links to the same page, else the best title match.
        let keys = Dictionary(news.compactMap { a in FeedDedupe.linkKey(a.url).map { ($0, a) } }, uniquingKeysWith: { first, _ in first })
        for t in threads where t.storyId == nil {
            if let key = FeedDedupe.linkKey(t.url), let a = keys[key], let lead = leadOf[a.id] {
                try attach(t.id, to: lead)
                continue
            }
            var best: (score: Double, lead: Int64)?
            for b in news where TopicStories.isSameStory(t.words, t.published, b.words, b.published) {
                let score = Double(t.words.intersection(b.words).count) / Double(max(1, min(t.words.count, b.words.count)))
                if best == nil || score > best!.score { best = (score, leadOf[b.id] ?? b.id) }
            }
            if let best { try attach(t.id, to: best.lead) }
        }

        try refreshStoryTimes(db)
        return attached
    }

    /// `story_at` of every lead with something behind it is its newest article's time; leads with nothing behind them have none.
    /// The Hacker News thread doesn't move a story: it is listed with it, not as news.
    static func refreshStoryTimes(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE items SET story_at = (
                SELECT max(m.published_at) FROM items m
                WHERE (m.id = items.id OR m.story_id = items.id) AND m.hn_comments_url IS NULL)
            WHERE story_id IS NULL AND EXISTS (SELECT 1 FROM items m WHERE m.story_id = items.id)
            """)
        try db.execute(sql: """
            UPDATE items SET story_at = NULL WHERE story_at IS NOT NULL AND (
                story_id IS NOT NULL OR NOT EXISTS (SELECT 1 FROM items m WHERE m.story_id = items.id))
            """)
    }

    /// The ids of the read leads, among the items `condition` selects (SQL on `items`), that have articles or a thread behind them.
    /// Call before deleting those items and pass the result to `repairStories`, so the story stays read.
    static func readStoryLeads(_ db: Database, where condition: String, arguments: StatementArguments) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: """
            SELECT id FROM items WHERE story_id IS NULL
              AND EXISTS (SELECT 1 FROM items m WHERE m.story_id = items.id)
              AND EXISTS (SELECT 1 FROM history h JOIN sources src ON src.id = items.source_id
                          WHERE h.source_feed_url = src.feed_url AND h.item_guid = items.guid AND h.read_at IS NOT NULL)
              AND \(condition)
            """, arguments: arguments))
    }

    /// After items were deleted: a story whose lead is gone passes to its oldest remaining article (and the others follow it),
    /// and a Hacker News thread left with no article of its story is a row of its own again. A story whose old lead was read
    /// (`readLeads`, from `readStoryLeads` before the delete) stays read: the new lead is marked read. The stories' times are
    /// renewed too, as a deleted newest article moves them. Returns how many items changed.
    @discardableResult
    static func repairStories(_ db: Database, readLeads: Set<Int64> = []) throws -> Int {
        let orphans = try Row.fetchAll(db, sql: """
            SELECT id, story_id, hn_comments_url FROM items
            WHERE story_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM items l WHERE l.id = items.story_id)
            ORDER BY id
            """)
        var changed = 0
        var byStory: [Int64: [Row]] = [:]
        for row in orphans { byStory[row["story_id"], default: []].append(row) }
        for (oldLead, rows) in byStory {
            let articles = rows.filter { ($0["hn_comments_url"] as String?) == nil }
            let threads = rows.filter { ($0["hn_comments_url"] as String?) != nil }
            let lead: Int64? = articles.first?["id"]
            for row in articles {
                let id: Int64 = row["id"]
                try db.execute(sql: "UPDATE items SET story_id = ? WHERE id = ?", arguments: [id == lead ? nil : lead, id])
                changed += 1
            }
            for row in threads {
                try db.execute(sql: "UPDATE items SET story_id = ? WHERE id = ?", arguments: [lead, row["id"] as Int64])
                changed += 1
            }
            if let lead, readLeads.contains(oldLead), let item = try feedItem(db, id: lead) {
                try setRead(db, HistoryEntry(item: item), read: true)
            }
        }
        try refreshStoryTimes(db)
        return changed
    }

    // MARK: Reading

    /// Give each lead in a page of a topic's list the outlets and discussion behind it, in one query for the page.
    static func attachStories(_ db: Database, to items: [FeedItem], topicId: Int64) throws -> [FeedItem] {
        let leads = items.filter { $0.item.sourceId == topicId && $0.item.storyId == nil }
        guard !leads.isEmpty else { return items }
        let ids = leads.map(\.item.id)
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, story_id, url, title, author, published_at, hn_points, hn_comments, hn_comments_url
            FROM items WHERE story_id IN (\(databaseQuestionMarks(count: ids.count))) ORDER BY published_at DESC, id
            """, arguments: StatementArguments(ids))
        guard !rows.isEmpty else { return items }
        var outlets: [Int64: [TopicOutlet]] = [:]
        var discussions: [Int64: TopicDiscussion] = [:]
        for row in rows {
            let lead: Int64 = row["story_id"]
            if let comments: String = row["hn_comments_url"] {
                let thread = TopicDiscussion(id: row["id"], points: row["hn_points"] ?? 0, comments: row["hn_comments"] ?? 0, url: comments)
                if let current = discussions[lead], (current.points, current.comments) >= (thread.points, thread.comments) { continue }
                discussions[lead] = thread
            } else {
                let url: String = row["url"]
                let name: String? = row["author"]
                outlets[lead, default: []].append(TopicOutlet(
                    id: row["id"], name: name.flatMap { $0.isEmpty ? nil : $0 } ?? URLHost.host(of: url), title: row["title"], url: url,
                    publishedAt: row["published_at"]))
            }
        }
        return items.map { feed in
            var feed = feed
            guard feed.item.sourceId == topicId, feed.item.storyId == nil else { return feed }
            let others = outlets[feed.item.id] ?? []
            let discussion = discussions[feed.item.id]
            guard !others.isEmpty || discussion != nil else { return feed }
            let lead = TopicOutlet(id: feed.item.id, name: feed.originName, title: feed.item.title, url: feed.item.url, publishedAt: feed.item.publishedAt)
            feed.story = TopicStory(outlets: [lead] + others, discussion: discussion)
            return feed
        }
    }

    // MARK: Hacker News numbers

    /// The Hacker News story ids ("50276099") of a topic's stored threads published since `since`, whose numbers a refresh renews.
    static func storedHackerNewsIDs(_ db: Database, sourceId: Int64, since: Date) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT guid FROM items WHERE source_id = ? AND guid LIKE 'hn:%' AND published_at >= ?",
                            arguments: [sourceId, since]).map { String($0.dropFirst(3)) }
    }

    /// Store renewed points and comment counts (by story id) on a topic's Hacker News threads.
    static func applyHackerNewsStats(_ db: Database, sourceId: Int64, stats: [String: TopicHackerNewsStats]) throws {
        for (id, s) in stats {
            try db.execute(sql: "UPDATE items SET hn_points = ?, hn_comments = ? WHERE source_id = ? AND guid = ?",
                           arguments: [s.points, s.comments, sourceId, "hn:\(id)"])
        }
    }
}
