import Foundation
import GRDB

/// Built-in sources and default folders (port of src/db/seed.ts and seedFolders in src/lib/folders.ts).
public enum Seed {
    public struct SeedSource: Sendable, Hashable {
        public var title: String
        public var url: String
        public var feedUrl: String
        public var kind: SourceKind
        public var group: String
    }

    private static func yt(_ title: String, _ channelId: String) -> SeedSource {
        SeedSource(
            title: title,
            url: "https://www.youtube.com/channel/\(channelId)",
            feedUrl: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)",
            kind: .youtube, group: SourceGroup.youtube)
    }

    public static let sources: [SeedSource] = [
        SeedSource(title: "Hacker News", url: "https://news.ycombinator.com", feedUrl: "https://hnrss.org/newest?points=100", kind: .rss, group: "aggregator"),
        SeedSource(title: "Ars Technica AI", url: "https://arstechnica.com", feedUrl: "https://feeds.arstechnica.com/arstechnica/technology-lab", kind: .rss, group: "news"),
        SeedSource(title: "The Verge AI", url: "https://www.theverge.com", feedUrl: "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml", kind: .rss, group: "news"),
        SeedSource(title: "TechCrunch AI", url: "https://techcrunch.com", feedUrl: "https://techcrunch.com/category/artificial-intelligence/feed/", kind: .rss, group: "news"),
        SeedSource(title: "MIT Technology Review AI", url: "https://www.technologyreview.com", feedUrl: "https://www.technologyreview.com/topic/artificial-intelligence/feed", kind: .rss, group: "news"),
        SeedSource(title: "Simon Willison", url: "https://simonwillison.net", feedUrl: "https://simonwillison.net/atom/everything/", kind: .rss, group: "blogs"),
        SeedSource(title: "OpenAI News", url: "https://openai.com", feedUrl: "https://openai.com/news/rss.xml", kind: .rss, group: "labs"),
        SeedSource(title: "Google DeepMind Blog", url: "https://deepmind.google", feedUrl: "https://deepmind.google/blog/rss.xml", kind: .rss, group: "labs"),
        yt("Matthew Berman", "UCawZsQWqfGSbCI5yjkdVkTA"),
        yt("Lenny's Podcast", "UC6t1O76G0jYXOAoYCm153dA"),
        yt("Ryan Peterman", "UCzB7YGrrxDC_POenf86H3_Q"),
        yt("Claude", "UCV03SRZXJEz-hchIAogeJOg"),
        yt("Anthropic", "UCrDwWp7EBBv4NwvScIpBDOA"),
        yt("Casually Explained", "UCr3cBLTYmIK9kY0F_OdFWFQ"),
        yt("Lex Clips", "UCJIfeSCssxSC_Dhc5s7woww"),
        yt("AI Engineer", "UCLKPca3kwwd-B59HNr-_lvA"),
        yt("Fireship", "UCsBjURrPoezykLs9EqgamOA"),
    ]

    /// Fallback feed URLs tried when the primary returns an error (FEED_FALLBACKS; currently empty).
    public static let feedFallbacks: [String: [String]] = [:]

    /// Insert the built-in sources once per database (meta "seeded" guard, so removals stick), then
    /// create the default folders once (meta "folders_seeded"). `force` re-upserts the source list.
    public static func seedIfNeeded(_ db: Database, force: Bool = false, now: Date = Date()) throws {
        let seeded = try Queries.meta(db, MetaKey.seeded)
        if force || seeded == nil {
            try upsertSources(db, now: now)
            if seeded == nil {
                try Queries.setMeta(db, MetaKey.seeded, ISO8601.string(from: now))
            }
        }
        try seedFolders(db, now: now)
    }

    /// Upsert by feed_url: title, url, kind and group follow the list; everything else is kept.
    static func upsertSources(_ db: Database, now: Date) throws {
        for s in sources {
            try db.execute(sql: """
                INSERT INTO sources (title, url, feed_url, kind, "group", position, created_at) VALUES (?, ?, ?, ?, ?, 0, ?)
                ON CONFLICT(feed_url) DO UPDATE SET title = excluded.title, url = excluded.url, kind = excluded.kind, "group" = excluded."group"
                """, arguments: [s.title, s.url, s.feedUrl, s.kind, s.group, now])
        }
    }

    /// Default folders for the first run, keyed by the legacy group (youtube/posts by kind/url):
    /// Labs, Blogs, News (news + aggregator), Posts, YouTube. Empty folders are dropped and positions
    /// are numbered by lowercase title within each folder. Runs once per database.
    public static func seedFolders(_ db: Database, now: Date = Date()) throws {
        if try Queries.meta(db, MetaKey.foldersSeeded) != nil { return }
        var ids: [String: Int64] = [:]
        for (i, title) in ["Labs", "Blogs", "News", "Posts", "YouTube"].enumerated() {
            var f = Folder(title: title, position: i, createdAt: now)
            try f.insert(db)
            ids[title] = f.id
        }
        for s in try Source.fetchAll(db) {
            let target: String?
            if PostSource.isPostURL(s.url) { target = "Posts" }
            else if s.kind == .youtube { target = "YouTube" }
            else if s.group == SourceGroup.labs { target = "Labs" }
            else if s.group == SourceGroup.blogs { target = "Blogs" }
            else if s.group == SourceGroup.news || s.group == SourceGroup.aggregator { target = "News" }
            else { target = nil }
            if let target, let fid = ids[target] {
                try db.execute(sql: "UPDATE sources SET folder_id = ? WHERE id = ?", arguments: [fid, s.id])
            }
        }
        try db.execute(sql: "DELETE FROM folders WHERE id NOT IN (SELECT folder_id FROM sources WHERE folder_id IS NOT NULL)")
        try db.execute(sql: """
            UPDATE sources SET position = (
              SELECT rn FROM (
                SELECT id, row_number() OVER (PARTITION BY folder_id ORDER BY lower(title)) - 1 AS rn FROM sources
              ) r WHERE r.id = sources.id
            )
            """)
        try Queries.setMeta(db, MetaKey.foldersSeeded, ISO8601.string(from: now))
    }
}
