import Foundation

/// Where a Topic looks. `news`, `discussions` and `media` are searched on every refresh and their matches
/// stored as the topic's items; `subscriptions` adds no stored items: the topic's list also shows matching
/// items from the user's own subscribed sources (`Queries.items`).
public struct TopicPlaces: Codable, Sendable, Hashable {
    /// Web news sites (Bing News).
    public var news: Bool
    /// Hacker News and Reddit.
    public var discussions: Bool
    /// YouTube videos and podcast episodes.
    public var media: Bool
    /// Also list matching items from the sources the user follows.
    public var subscriptions: Bool

    public static let all = TopicPlaces()

    public init(news: Bool = true, discussions: Bool = true, media: Bool = true, subscriptions: Bool = true) {
        self.news = news
        self.discussions = discussions
        self.media = media
        self.subscriptions = subscriptions
    }

    /// The places a refresh searches (`subscriptions` is not one of them).
    public var searched: [TopicPlace] {
        TopicPlace.allCases.filter { place in
            switch place {
            case .news: news
            case .discussions: discussions
            case .media: media
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case news, discussions, media, subscriptions }

    /// Missing keys read as on, so a record written by an older or newer build still decodes.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        news = try c.decodeIfPresent(Bool.self, forKey: .news) ?? true
        discussions = try c.decodeIfPresent(Bool.self, forKey: .discussions) ?? true
        media = try c.decodeIfPresent(Bool.self, forKey: .media) ?? true
        subscriptions = try c.decodeIfPresent(Bool.self, forKey: .subscriptions) ?? true
    }
}

/// A place a refresh searches, and the unit a failure is counted in: a place fails when each of its
/// providers (Hacker News and Reddit for discussions) did.
public enum TopicPlace: String, Codable, Sendable, CaseIterable, Hashable {
    case news, discussions, media
}

/// What a Topic follows. Stored as JSON in `sources.topic_options` and synced as one field of the Source
/// record, so every device agrees on it. The encoding is deterministic (sorted keys) because the sync hash
/// compares it as text.
public struct TopicOptions: Codable, Sendable, Hashable {
    /// The search, as typed. A multi-word keyword is sent to providers as a quoted phrase.
    public var keyword: String
    /// "Leave out": an item whose title or summary has one of these is dropped.
    public var excluded: [String]
    /// "Show: Notable only": store only notable matches (`TopicNotability`).
    public var notableOnly: Bool
    public var places: TopicPlaces
    /// Skip articles from sites behind a hard paywall (`TopicPaywalls`).
    public var skipPaywalled: Bool

    public init(keyword: String, excluded: [String] = [], notableOnly: Bool = false, places: TopicPlaces = .all,
                skipPaywalled: Bool = true) {
        self.keyword = keyword
        self.excluded = excluded
        self.notableOnly = notableOnly
        self.places = places
        self.skipPaywalled = skipPaywalled
    }

    private enum CodingKeys: String, CodingKey { case keyword, excluded, notableOnly, places, skipPaywalled }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyword = try c.decode(String.self, forKey: .keyword)
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
        notableOnly = try c.decodeIfPresent(Bool.self, forKey: .notableOnly) ?? false
        places = try c.decodeIfPresent(TopicPlaces.self, forKey: .places) ?? .all
        skipPaywalled = try c.decodeIfPresent(Bool.self, forKey: .skipPaywalled) ?? true
    }

    /// Keyword and excluded words trimmed, blanks and repeats (any case) dropped.
    public var cleaned: TopicOptions {
        var o = self
        o.keyword = keyword.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var seen = Set<String>()
        o.excluded = excluded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return o
    }

    /// "Leave out" as the field shows it: comma separated.
    public var excludedText: String { excluded.joined(separator: ", ") }

    /// The words of a comma separated "Leave out" field.
    public static func excludedWords(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// The stored / synced text form.
    public var json: String {
        (try? Self.encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// nil for text that isn't an options object with a keyword.
    public init?(json: String?) {
        guard let json, let data = json.data(using: .utf8), let o = try? JSONDecoder().decode(TopicOptions.self, from: data) else { return nil }
        self = o
    }
}

/// The per-topic filter behind the chips under a topic's header (All / Articles / Discussions / Videos / Episodes).
public enum TopicContentFilter: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case all, articles, discussions, videos, episodes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .articles: "Articles"
        case .discussions: "Discussions"
        case .videos: "Videos"
        case .episodes: "Episodes"
        }
    }

    /// Which chip an item falls under (never `.all`). A discussion is a Hacker News story (it has a comments
    /// page) or a Reddit post; a video has a video id; an episode has audio and no video.
    public static func category(of item: Item) -> TopicContentFilter {
        if item.videoId != nil { return .videos }
        if item.audioUrl != nil { return .episodes }
        if item.hnCommentsUrl != nil || Topic.isRedditPost(item.url) { return .discussions }
        return .articles
    }
}

/// Whether a result mentions a topic: every word of the keyword, and none of the excluded words, in the
/// title or the summary. Ignores case and diacritics. A word matches at the start of a word of the text
/// ("agent" finds "agents", not "reagent"), and a word of three letters or fewer must also end there, so
/// "AI" doesn't find "said". The same rule filters the providers' results and picks which of the user's
/// own items a topic's list adds (`Queries.items`).
public struct TopicMatcher: Sendable, Hashable {
    private let words: [String]
    private let excluded: [String]

    public init(keyword: String, excluded: [String] = []) {
        words = Self.keywordWords(keyword)
        self.excluded = excluded.map(Self.fold).filter { !$0.isEmpty }
    }

    public init(_ options: TopicOptions) {
        self.init(keyword: options.keyword, excluded: options.excluded)
    }

    /// The keyword's words, folded, without the quotes someone may have typed around a phrase.
    static func keywordWords(_ keyword: String) -> [String] {
        fold(keyword).split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}")) }
            .filter { !$0.isEmpty }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `summary` may be HTML. `host` is the site a result links to: a story that names no keyword but lives on a site that does
    /// (a Hacker News story at openai.com, for "OpenAI") counts as a match; the leave-out words are still looked for in the text only.
    public func matches(title: String, summary: String?, host: String? = nil) -> Bool {
        guard !words.isEmpty else { return false }
        let t = Self.fold(title)
        if excluded.contains(where: { Self.contains(t, $0) }) { return false }
        let titleHasAll = words.allSatisfy { Self.contains(t, $0) }
        // The summary is only stripped and folded when the title alone doesn't settle it.
        if titleHasAll && excluded.isEmpty { return true }
        // Plain summaries (most of them) have no markup or entity to take out, which is the costly part.
        let plain = summary.map { $0.contains("<") || $0.contains("&") ? TextFormat.stripHTML($0) : $0 } ?? ""
        let s = Self.fold(plain)
        if excluded.contains(where: { Self.contains(s, $0) }) { return false }
        if titleHasAll { return true }
        let both = t + "\n" + s
        if words.allSatisfy({ Self.contains(both, $0) }) { return true }
        guard let host, !host.isEmpty else { return false }
        let h = Self.fold(host)
        return words.allSatisfy { Self.contains(h, $0) }
    }

    /// `text` holds `term` starting at a word boundary (ending at one too when the term is short).
    static func contains(_ text: String, _ term: String) -> Bool {
        guard !term.isEmpty else { return false }
        let needsEnd = term.count <= 3
        let startsWord = term.first.map(isWordCharacter) ?? false
        let endsWord = term.last.map(isWordCharacter) ?? false
        var from = text.startIndex
        while let r = text.range(of: term, range: from..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            let startOK = !startsWord || before.map { !isWordCharacter($0) } ?? true
            let endOK = !needsEnd || !endsWord || after.map { !isWordCharacter($0) } ?? true
            if startOK && endOK { return true }
            from = text.index(after: r.lowerBound)
            if from >= text.endIndex { break }
        }
        return false
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
}

/// Reserved identifiers and small helpers for Topics.
public enum Topic {
    /// A topic's `feed_url` is `opendispatch:topic:<uuid>`: fixed when it is made and never derived from the
    /// keyword, so editing the keyword keeps the topic's items, saved items, history and sync records.
    public static let feedURLPrefix = "opendispatch:topic:"

    public static func isTopicFeedURL(_ feedUrl: String) -> Bool { feedUrl.hasPrefix(feedURLPrefix) }

    public static func newFeedURL() -> String { feedURLPrefix + UUID().uuidString.lowercased() }

    /// The address a topic's source gets as its site URL (shown nowhere; the column can't be empty).
    static let siteURL = "https://opendispatch.app"

    /// A Reddit post's permalink.
    static func isRedditPost(_ url: String) -> Bool {
        let host = URLHost.host(of: url)
        return (host == "reddit.com" || host.hasSuffix(".reddit.com")) && url.contains("/comments/")
    }
}

/// The matcher the SQL function used last. A list query calls the function once per candidate row with the same topic, and building
/// a matcher folds the keyword and leave-out words each time.
final class TopicMatcherCache: @unchecked Sendable {
    static let shared = TopicMatcherCache()
    private let lock = NSLock()
    private var last: (keyword: String, excluded: [String], matcher: TopicMatcher)?

    func matcher(keyword: String, excluded: [String]) -> TopicMatcher {
        lock.lock()
        defer { lock.unlock() }
        if let last, last.keyword == keyword, last.excluded == excluded { return last.matcher }
        let m = TopicMatcher(keyword: keyword, excluded: excluded)
        last = (keyword, excluded, m)
        return m
    }
}
