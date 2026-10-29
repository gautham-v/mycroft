import Foundation

/// A news article found by Explore. Opening it stores it as an opened link (`OpenDispatchServices.openExploreArticle`), which
/// the reader shows like any article (with its paywall banner when only a teaser can be read).
public struct ExploreArticle: Sendable, Hashable, Identifiable {
    /// The article's own address (not Bing's redirect).
    public var url: String
    public var title: String
    /// The outlet as Bing names it ("The Guardian", "Barron's on MSN"); nil when the answer has none.
    public var outlet: String?
    public var published: Date
    public var summary: String?
    /// A thumbnail, when Bing has a picture for the article.
    public var imageUrl: String?

    public var id: String { url }

    public init(url: String, title: String, outlet: String? = nil, published: Date, summary: String? = nil, imageUrl: String? = nil) {
        self.url = url
        self.title = title
        self.outlet = outlet
        self.published = published
        self.summary = summary
        self.imageUrl = imageUrl
    }
}

/// Explore's news section, its own call like the others so it lands (or fails) alone.
public protocol ArticleSearching: Sendable {
    /// Recent news articles matching the query, most relevant first. Throws when news can't be searched.
    func articles(_ query: String) async throws -> [ExploreArticle]
}

/// News through Bing News' RSS (`BingNews`, shared with Topics): the query as typed, and again limited with `site:` to the large
/// outlets Bing's own ten-odd answers seldom include (the sites the app is signed in to, `MajorOutlets`, and the known
/// paywalled sites unless the lists hide those), all at the same time.
///
/// Unlike a topic, which wants the newest, a search box wants the best match, so Bing's own relevance order is kept (no
/// `qft=sortbydate`): it still answers with the last few days' stories, and date order only adds the most recent mentions.
/// The searches' answers are interleaved (the plain search's first, then each outlet group's, then every second result, ...),
/// since ranks of different searches can't be compared. Kept: the last 30 days, in a language the user reads, once per address
/// (and once per outlet and headline). An outlet search that answers with an article that never mentions the query's words in
/// its headline or summary is dropped, as `site:` searches pad their answers with loose matches.
public struct DefaultArticleSearch: ArticleSearching {
    typealias Fetch = @Sendable (_ url: String, _ headers: [String: String]) async throws -> (Data, HTTPURLResponse)

    static let timeout: TimeInterval = 10
    /// Kept in all.
    static let limit = 30
    static let days = 30

    let fetch: Fetch
    let languages: TopicLanguages
    /// The outlet searches' sites, in groups (`BingNews.outletSites`).
    let sites: @Sendable () -> [[String]]

    public init(languages: TopicLanguages = .current) {
        self.init(fetch: { url, headers in try await HTTP.fetch(url, timeout: Self.timeout, headers: headers) }, languages: languages)
    }

    /// Tests inject a fake network and the sites.
    init(fetch: @escaping Fetch, languages: TopicLanguages = .current, sites: @escaping @Sendable () -> [[String]] = { BingNews.outletSites() }) {
        self.fetch = fetch
        self.languages = languages
        self.sites = sites
    }

    public func articles(_ query: String) async throws -> [ExploreArticle] {
        try await articles(query, now: Date())
    }

    func articles(_ query: String, now: Date) async throws -> [ExploreArticle] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let market = languages.market
        let urls = [BingNews.url(query: q, market: market, newestFirst: false)]
            + sites().map { BingNews.url(query: q, market: market, sites: $0, newestFirst: false) }
        let answers = try await BingNews.search(urls) { url in
            let (data, res) = try await self.fetch(url, ["Accept": HTTP.feedAccept])
            guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
            return data
        }
        return Self.merge(answers, query: q, languages: languages, now: now)
    }

    /// The answers of one search each (the first is the plain one) as one list; see the type's comment.
    static func merge(_ answers: [[BingNews.Article]], query: String, languages: TopicLanguages, now: Date) -> [ExploreArticle] {
        let matcher = TopicMatcher(keyword: query)
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var seen = Set<String>()
        var out: [ExploreArticle] = []
        for rank in 0..<(answers.map(\.count).max() ?? 0) {
            for (i, answer) in answers.enumerated() where rank < answer.count {
                let a = answer[rank]
                guard a.published >= cutoff, !languages.rejects(a.title), i == 0 || matcher.matches(title: a.title, summary: a.summary),
                      seen.insert(key(url: a.url)).inserted, seen.insert(key(outlet: a.publisher, title: a.title)).inserted else { continue }
                let summary = a.summary.map { TextFormat.stripHTML($0) }.flatMap { $0.isEmpty ? nil : $0 }
                out.append(ExploreArticle(url: a.url, title: a.title, outlet: a.publisher, published: min(a.published, now), summary: summary, imageUrl: a.imageUrl))
                if out.count == limit { return out }
            }
        }
        return out
    }

    /// An address without its scheme, "www.", fragment and trailing slash, folded: the same article from two searches.
    static func key(url: String) -> String {
        guard var c = URLComponents(string: url) else { return url.lowercased() }
        c.scheme = nil
        c.fragment = nil
        while c.path.count > 1, c.path.hasSuffix("/") { c.path.removeLast() }
        var s = (c.string ?? url).lowercased()
        if s.hasPrefix("//www.") { s.removeFirst(6) } else if s.hasPrefix("//") { s.removeFirst(2) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The same headline from the same outlet under two addresses.
    private static func key(outlet: String?, title: String) -> String {
        "\(TopicMatcher.fold(outlet ?? ""))\n\(TopicMatcher.fold(title))"
    }
}
