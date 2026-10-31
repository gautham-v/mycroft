import Foundation

/// Well-known feeds to start from, offered by the empty "Add sources" sheet and the first-run board. A suggestion only: nothing is
/// added until it is chosen. Each is added through the detector like a search result.
public struct StarterSource: Sendable, Hashable, Identifiable {
    public var title: String
    /// The site, for its favicon.
    public var host: String
    public var feedUrl: String

    public var id: String { feedUrl }

    public init(title: String, host: String, feedUrl: String) {
        self.title = title
        self.host = host
        self.feedUrl = feedUrl
    }
}

public struct StarterPack: Sendable, Hashable, Identifiable {
    public var name: String
    public var sources: [StarterSource]

    public var id: String { name }

    public init(name: String, sources: [StarterSource]) {
        self.name = name
        self.sources = sources
    }
}

public enum StarterSources {
    public static let packs: [StarterPack] = [
        StarterPack(name: "News", sources: [
            StarterSource(title: "NPR", host: "npr.org", feedUrl: "https://feeds.npr.org/1001/rss.xml"),
            StarterSource(title: "BBC News", host: "bbc.com", feedUrl: "https://feeds.bbci.co.uk/news/rss.xml"),
            StarterSource(title: "The Guardian", host: "theguardian.com", feedUrl: "https://www.theguardian.com/world/rss"),
        ]),
        StarterPack(name: "Tech", sources: [
            StarterSource(title: "The Verge", host: "theverge.com", feedUrl: "https://www.theverge.com/rss/index.xml"),
            StarterSource(title: "Ars Technica", host: "arstechnica.com", feedUrl: "https://feeds.arstechnica.com/arstechnica/index"),
            StarterSource(title: "Hacker News", host: "news.ycombinator.com", feedUrl: "https://hnrss.org/newest?points=100"),
        ]),
        StarterPack(name: "AI", sources: [
            StarterSource(title: "Simon Willison", host: "simonwillison.net", feedUrl: "https://simonwillison.net/atom/everything/"),
            StarterSource(title: "OpenAI News", host: "openai.com", feedUrl: "https://openai.com/news/rss.xml"),
            StarterSource(title: "Google DeepMind Blog", host: "deepmind.google", feedUrl: "https://deepmind.google/blog/rss.xml"),
        ]),
        StarterPack(name: "Sports", sources: [
            StarterSource(title: "ESPN", host: "espn.com", feedUrl: "https://www.espn.com/espn/rss/news"),
            StarterSource(title: "CBS Sports", host: "cbssports.com", feedUrl: "https://www.cbssports.com/rss/headlines/"),
            StarterSource(title: "BBC Sport", host: "bbc.co.uk", feedUrl: "https://feeds.bbci.co.uk/sport/rss.xml"),
        ]),
    ]
}
