import Foundation

/// A topic's searches, with no key anywhere:
///
/// - news: Bing News' RSS (`/news/search?format=rss`), newest first. Its links go through an `apiclick` redirect that names the
///   article in its `url` parameter, which is read back out; the publisher is in `News:Source`.
/// - discussions: Hacker News through Algolia's API, and Reddit's search (JSON, falling back to its RSS when the JSON is refused,
///   which it often is outside a browser; the RSS has no score).
/// - media: YouTube videos from Explore's search (upload-date order, last month) and podcast episodes from the iTunes Search API.
///
/// Every answer is filtered here the same way: it must be recent (the retention window), mention the keyword in its title or
/// summary and none of the leave-out words, and (as the topic says) not come from a paywalled site and be notable. At most
/// `perProviderCap` of the newest are kept per provider. Places run at the same time and one failing doesn't fail the others.
public struct DefaultTopicSearch: TopicSearching {
    typealias Fetch = @Sendable (_ url: String, _ headers: [String: String]) async throws -> (Data, HTTPURLResponse)

    static let timeout: TimeInterval = 10
    /// Kept per provider (Bing, Hacker News, Reddit, YouTube, iTunes), newest first.
    static let perProviderCap = 30
    /// Reddit asks for a descriptive User-Agent and refuses generic ones.
    static let redditUserAgent = "macOS:com.gauthamv.opendispatch:1.0 (RSS reader; +https://github.com/gautham-v/opendispatch)"

    let fetch: Fetch
    let explore: any ExploreSearching

    public init(explore: any ExploreSearching = DefaultExploreSearch()) {
        self.init(fetch: { url, headers in try await HTTP.fetch(url, timeout: Self.timeout, headers: headers) }, explore: explore)
    }

    /// Tests inject a fake network.
    init(fetch: @escaping Fetch, explore: any ExploreSearching) {
        self.fetch = fetch
        self.explore = explore
    }

    // MARK: TopicSearching

    private enum PlaceResult: Sendable {
        case found([ParsedItem])
        case failed(String)
    }

    public func search(_ options: TopicOptions, subscriptions: TopicSubscriptions, now: Date = Date()) async -> TopicSearchOutcome {
        let o = options.cleaned
        let places = o.places.searched
        guard !o.keyword.isEmpty, !places.isEmpty else { return TopicSearchOutcome(searched: places) }
        let matcher = TopicMatcher(o)
        var results: [TopicPlace: PlaceResult] = [:]
        await withTaskGroup(of: (TopicPlace, PlaceResult).self) { group in
            for place in places {
                group.addTask { (place, await self.run(place, o, matcher, subscriptions, now)) }
            }
            for await (place, result) in group { results[place] = result }
        }
        var items: [ParsedItem] = []
        var failures: [TopicPlace: String] = [:]
        for place in places {
            switch results[place] {
            case .found(let found)?: items.append(contentsOf: found)
            case .failed(let message)?: failures[place] = message
            case nil: break
            }
        }
        items.sort { $0.publishedAt != $1.publishedAt ? $0.publishedAt > $1.publishedAt : $0.guid < $1.guid }
        return TopicSearchOutcome(items: items, searched: places, failures: failures)
    }

    /// One place: its providers at the same time, failing only when all of them did.
    private func run(_ place: TopicPlace, _ o: TopicOptions, _ matcher: TopicMatcher, _ subs: TopicSubscriptions, _ now: Date) async -> PlaceResult {
        typealias Provider = @Sendable () async throws -> [Candidate]
        let providers: [Provider]
        switch place {
        case .news: providers = [{ try await self.news(o, now) }]
        case .discussions: providers = [{ try await self.hackerNews(o, now) }, { try await self.reddit(o, now) }]
        case .media: providers = [{ try await self.videos(o, now) }, { try await self.episodes(o, now) }]
        }
        var found: [ParsedItem] = []
        var errors: [any Error] = []
        var succeeded = 0
        await withTaskGroup(of: Result<[Candidate], any Error>.self) { group in
            for provider in providers {
                group.addTask {
                    do { return .success(try await provider()) } catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result {
                case .success(let candidates):
                    succeeded += 1
                    found.append(contentsOf: Self.finish(candidates, o, matcher, subs, now, checkPaywall: place == .news))
                case .failure(let error):
                    errors.append(error)
                }
            }
        }
        if succeeded == 0, let first = errors.first { return .failed(HTTP.message(first)) }
        return .found(found)
    }

    // MARK: Candidates

    /// A result before filtering, with what the notable rule needs to know about where it came from.
    struct Candidate: Sendable {
        var item: ParsedItem
        /// Hacker News points or a Reddit score, with the bar it has to clear.
        var score: Int?
        var scoreBar: Int?
        /// The site the result links to.
        var host: String?
        /// The publisher, channel or show.
        var name: String?
        var channelID: String?

        func isNotable(_ subs: TopicSubscriptions) -> Bool {
            if let score, let scoreBar, score >= scoreBar { return true }
            if let host, subs.follows(host: host) { return true }
            if let name, subs.follows(name: name) { return true }
            return subs.follows(channelID: channelID)
        }
    }

    /// Recent, on topic, wanted and notable as the topic asks; the newest `perProviderCap`.
    static func finish(_ candidates: [Candidate], _ o: TopicOptions, _ matcher: TopicMatcher, _ subs: TopicSubscriptions,
                       _ now: Date, checkPaywall: Bool) -> [ParsedItem] {
        let cutoff = Retention.cutoff(now: now)
        var seen = Set<String>()
        let kept = candidates.filter { c in
            let item = c.item
            // The news site's or story's own host counts as a mention, except Hacker News' (every story of it would match "hacker news").
            let host = c.host == "news.ycombinator.com" ? nil : c.host
            guard item.publishedAt >= cutoff, matcher.matches(title: item.title, summary: item.summary, host: host) else { return false }
            if checkPaywall, o.skipPaywalled,
               TopicPaywalls.isPaywalled(item.url) || c.name.map(TopicPaywalls.isPaywalled(publisher:)) == true { return false }
            if o.notableOnly, !c.isNotable(subs) { return false }
            return seen.insert(item.guid).inserted
        }
        return kept.map { c in
            var item = c.item
            item.publishedAt = min(item.publishedAt, now)
            return item
        }
        .sorted { $0.publishedAt != $1.publishedAt ? $0.publishedAt > $1.publishedAt : $0.guid < $1.guid }
        .prefix(perProviderCap).map { $0 }
    }

    // MARK: Query building

    /// The keyword for a provider that understands quotes: several words become a phrase.
    static func phrase(_ keyword: String) -> String {
        let raw = keyword.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}")) }.filter { !$0.isEmpty }
        return raw.count > 1 ? "\"" + raw.joined(separator: " ") + "\"" : raw.first ?? keyword
    }

    private static let queryAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()

    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? s }

    private func get(_ url: String, headers: [String: String]) async throws -> Data {
        let (data, res) = try await fetch(url, headers)
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        return data
    }

    // MARK: News

    static func newsURL(_ keyword: String) -> String {
        "https://www.bing.com/news/search?q=\(encode(phrase(keyword)))&format=rss&qft=sortbydate%3d%221%22"
    }

    func news(_ o: TopicOptions, _ now: Date) async throws -> [Candidate] {
        let data = try await get(Self.newsURL(o.keyword), headers: ["Accept": HTTP.feedAccept])
        return try Self.parseNews(data)
    }

    /// The articles in a Bing News RSS answer. Throws when it isn't XML.
    static func parseNews(_ data: Data) throws -> [Candidate] {
        let entries = try TopicXML.entries(data)
        return entries.compactMap { e in
            guard let link = e["link"], let url = articleURL(fromBingLink: link), let title = e["title"], !title.isEmpty,
                  let published = e["pubDate"].flatMap(FeedParsingSupport.date(from:)) else { return nil }
            let publisher = e["News:Source"].flatMap { $0.isEmpty ? nil : $0 }
            let summary = e["description"].flatMap { $0.isEmpty ? nil : $0 }
            return Candidate(
                item: ParsedItem(guid: url, url: url, title: title, summary: summary, author: publisher, publishedAt: published),
                host: URLHost.host(of: url), name: publisher)
        }
    }

    /// The article a Bing News link stands for: its `url` parameter. A link that doesn't go through Bing is returned as it is.
    static func articleURL(fromBingLink link: String) -> String? {
        guard let c = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), let host = c.host?.lowercased() else { return nil }
        guard host == "bing.com" || host.hasSuffix(".bing.com") else {
            return ["http", "https"].contains(c.scheme?.lowercased() ?? "") ? c.string : nil
        }
        guard let target = c.queryItems?.first(where: { $0.name == "url" })?.value, let u = URLComponents(string: target),
              ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return nil }
        return target
    }

    // MARK: Hacker News

    static func hackerNewsURL(_ keyword: String, notableOnly: Bool, now: Date) -> String {
        let since = Int(Retention.cutoff(now: now).timeIntervalSince1970)
        var filters = "created_at_i%3E\(since)"
        if notableOnly { filters += ",points%3E=\(TopicNotability.hackerNewsPoints)" }
        return "https://hn.algolia.com/api/v1/search_by_date?query=\(encode(phrase(keyword)))&tags=story&hitsPerPage=50&numericFilters=\(filters)"
    }

    func hackerNews(_ o: TopicOptions, _ now: Date) async throws -> [Candidate] {
        let data = try await get(Self.hackerNewsURL(o.keyword, notableOnly: o.notableOnly, now: now), headers: ["Accept": "application/json"])
        return try Self.parseHackerNews(data)
    }

    private struct HNResponse: Decodable {
        struct Hit: Decodable {
            var objectID: String
            var title: String?
            var url: String?
            var story_text: String?
            var points: Int?
            var num_comments: Int?
            var created_at_i: Double?
        }
        var hits: [Hit]
    }

    /// The stories in an Algolia search answer. A story with no link (Ask HN, a text post) links to its own page.
    static func parseHackerNews(_ data: Data) throws -> [Candidate] {
        let hits = try JSONDecoder().decode(HNResponse.self, from: data).hits
        return hits.compactMap { h in
            guard let title = h.title, !title.isEmpty, let created = h.created_at_i else { return nil }
            let discussion = "https://news.ycombinator.com/item?id=\(h.objectID)"
            let link = h.url.flatMap { $0.isEmpty ? nil : $0 } ?? discussion
            let text = h.story_text.flatMap { $0.isEmpty ? nil : $0 }
            return Candidate(
                item: ParsedItem(
                    guid: "hn:\(h.objectID)", url: link, title: FeedParsingSupport.decodeHTMLEntities(title), summary: text,
                    author: "Hacker News", publishedAt: Date(timeIntervalSince1970: created), hnPoints: h.points ?? 0,
                    hnComments: h.num_comments ?? 0, hnCommentsUrl: discussion),
                score: h.points ?? 0, scoreBar: TopicNotability.hackerNewsPoints, host: URLHost.host(of: link))
        }
    }

    // MARK: Reddit

    static func redditURL(_ keyword: String, json: Bool) -> String {
        let q = encode(phrase(keyword))
        return json
            ? "https://www.reddit.com/search.json?q=\(q)&sort=new&t=week&limit=50&raw_json=1"
            : "https://www.reddit.com/search.rss?q=\(q)&sort=new&t=week"
    }

    func reddit(_ o: TopicOptions, _ now: Date) async throws -> [Candidate] {
        let headers = ["User-Agent": Self.redditUserAgent, "Accept": "application/json"]
        // Reddit refuses the JSON to many clients (a 403 page); its RSS is open but carries no score.
        if let data = try? await get(Self.redditURL(o.keyword, json: true), headers: headers), let found = try? Self.parseRedditJSON(data) {
            return found
        }
        let data = try await get(Self.redditURL(o.keyword, json: false), headers: ["User-Agent": Self.redditUserAgent, "Accept": HTTP.feedAccept])
        return try Self.parseRedditRSS(data)
    }

    private struct RedditResponse: Decodable {
        struct Listing: Decodable {
            struct Child: Decodable {
                struct Post: Decodable {
                    var id: String
                    var title: String
                    var selftext: String?
                    var subreddit: String?
                    var permalink: String
                    var score: Int?
                    var num_comments: Int?
                    var created_utc: Double
                    var over_18: Bool?
                    var thumbnail: String?
                }
                var kind: String?
                var data: Post
            }
            var children: [Child]
        }
        var data: Listing
    }

    /// The posts in a Reddit search answer (`search.json`). Throws when the answer isn't a listing. Adult posts are left out.
    static func parseRedditJSON(_ data: Data) throws -> [Candidate] {
        let children = try JSONDecoder().decode(RedditResponse.self, from: data).data.children
        return children.compactMap { child in
            let p = child.data
            guard child.kind == nil || child.kind == "t3", p.over_18 != true, !p.title.isEmpty else { return nil }
            let url = p.permalink.hasPrefix("http") ? p.permalink : "https://www.reddit.com" + p.permalink
            let body = p.selftext.flatMap { $0.isEmpty ? nil : String($0.prefix(600)) }
            let thumb = p.thumbnail.flatMap { $0.hasPrefix("http") ? $0 : nil }
            return Candidate(
                item: ParsedItem(
                    guid: "reddit:\(p.id)", url: url, title: p.title, summary: body, author: p.subreddit.map { "r/\($0)" } ?? "Reddit",
                    publishedAt: Date(timeIntervalSince1970: p.created_utc), thumbnailUrl: thumb, hnPoints: p.score,
                    hnComments: p.num_comments),
                score: p.score, scoreBar: TopicNotability.redditScore)
        }
    }

    /// The posts in a Reddit search RSS (Atom) answer: the entries named `t3_…` (the answer also lists matching subreddits as `t5_…`).
    /// There is no score or comment count in it.
    static func parseRedditRSS(_ data: Data) throws -> [Candidate] {
        let entries = try TopicXML.entries(data)
        return entries.compactMap { e in
            guard let id = e["id"], id.hasPrefix("t3_"), let title = e["title"], !title.isEmpty, let url = e["link@href"],
                  let published = (e["published"] ?? e["updated"]).flatMap(FeedParsingSupport.date(from:)) else { return nil }
            let label = e["category@label"].flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
            return Candidate(
                item: ParsedItem(
                    guid: "reddit:\(id.dropFirst(3))", url: url, title: FeedParsingSupport.decodeHTMLEntities(title),
                    summary: e["content"].flatMap(redditBody), author: label ?? "Reddit", publishedAt: published),
                score: nil, scoreBar: TopicNotability.redditScore)
        }
    }

    /// The post text out of an Atom `content` field, which wraps it in markup and ends with "submitted by …".
    static func redditBody(_ html: String) -> String? {
        var text = TextFormat.stripHTML(html)
        if let r = text.range(of: " submitted by ") { text = String(text[..<r.lowerBound]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(600))
    }

    // MARK: Media

    func videos(_ o: TopicOptions, _ now: Date) async throws -> [Candidate] {
        Self.candidates(videos: try await explore.recentVideos(Self.phrase(o.keyword)).videos, now: now)
    }

    /// Videos as items like a channel's own: the watch address, the channel as the author, the length. A video whose upload time
    /// ("3 hours ago") can't be read is left out, as the retention cut can't be applied to it.
    static func candidates(videos: [ExploreVideo], now: Date) -> [Candidate] {
        videos.compactMap { v in
            guard let published = v.published.flatMap({ publishedDate(relative: $0, now: now) }) else { return nil }
            let url = OpenedLinks.canonicalURL(v.watchUrl, videoID: v.id)
            return Candidate(
                item: ParsedItem(
                    guid: "yt:\(v.id)", url: url, title: v.title, author: v.channel.isEmpty ? nil : v.channel, publishedAt: published,
                    thumbnailUrl: FeedParsingSupport.youtubeThumbnail(videoID: v.id), videoId: v.id, durationSec: v.durationSeconds),
                name: v.channel, channelID: v.channelID)
        }
    }

    func episodes(_ o: TopicOptions, _ now: Date) async throws -> [Candidate] {
        Self.candidates(episodes: try await explore.recentEpisodes(o.keyword), now: now)
    }

    /// Episodes stored as their Apple Podcasts address would store them, so the reader's podcast player opens them exactly as it
    /// opens an Explore episode. One with no release date or no audio is left out.
    static func candidates(episodes: [ExploreEpisode], now: Date) -> [Candidate] {
        episodes.compactMap { e in
            guard e.published != nil, let item = ApplePodcastEpisode.item(explore: e, now: now) else { return nil }
            return Candidate(item: item, name: e.show)
        }
    }

    // MARK: Relative times

    private static let relativeTime = try? NSRegularExpression(
        pattern: #"(\d+)\s*(second|minute|hour|day|week|month|year)s?\s+ago"#, options: [.caseInsensitive])

    /// The moment a YouTube result's English upload time ("7 hours ago", "Streamed 3 days ago", "2 weeks ago") says, counted back
    /// from `now`; a month is 30 days and a year 365. nil for text in any other shape.
    static func publishedDate(relative text: String, now: Date) -> Date? {
        guard let re = relativeTime, let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nRange = Range(m.range(at: 1), in: text), let uRange = Range(m.range(at: 2), in: text),
              let n = Double(text[nRange]) else { return nil }
        let unit: Double
        switch text[uRange].lowercased() {
        case "second": unit = 1
        case "minute": unit = 60
        case "hour": unit = 3600
        case "day": unit = 86_400
        case "week": unit = 7 * 86_400
        case "month": unit = 30 * 86_400
        default: unit = 365 * 86_400
        }
        return now.addingTimeInterval(-n * unit)
    }
}

/// A minimal reader for the RSS and Atom answers topics get: every `item` / `entry` as a flat dictionary of its
/// children's text by path (`author/name`) and their attributes (`link@href`, `category@label`).
enum TopicXML {
    static func entries(_ data: Data) throws -> [[String: String]] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() || !reader.entries.isEmpty else { throw TopicSearchError("The answer wasn't a feed") }
        return reader.entries
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var entries: [[String: String]] = []
        private var stack: [String] = []
        private var current: [String: String]?
        private var entryDepth = 0
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            stack.append(name)
            if current == nil, name == "item" || name == "entry" {
                current = [:]
                entryDepth = stack.count
            } else if current != nil {
                let path = stack.dropFirst(entryDepth).joined(separator: "/")
                for (k, v) in attributes where current?["\(path)@\(k)"] == nil { current?["\(path)@\(k)"] = v }
            }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { stack.removeLast() }
            guard current != nil else { return }
            if stack.count == entryDepth {
                if let c = current { entries.append(c) }
                current = nil
                return
            }
            let path = stack.dropFirst(entryDepth).joined(separator: "/")
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, current?[path] == nil { current?[path] = value }
            text = ""
        }
    }
}
