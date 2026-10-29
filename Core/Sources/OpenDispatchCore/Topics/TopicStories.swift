import Foundation

/// One outlet's article in a news story, as a row of the story lists it.
public struct TopicOutlet: Sendable, Hashable, Identifiable {
    /// The article's item id.
    public var id: Int64
    /// The outlet: the publisher Bing News names ("Yahoo", "KHOU", "The Cool Down on MSN").
    public var name: String
    /// The outlet's own headline.
    public var title: String
    public var url: String
    /// The article's site, without "www." (what `SourceBadge` draws a favicon for).
    public var host: String
    public var publishedAt: Date

    public init(id: Int64, name: String, title: String, url: String, publishedAt: Date) {
        self.id = id
        self.name = name
        self.title = title
        self.url = url
        self.host = URLHost.host(of: url)
        self.publishedAt = publishedAt
    }

    /// A post's author as a story lists it: the name a post was stored with, without its handle ("Nikkei Asia (@asia.nikkei.com)"
    /// is "Nikkei Asia"); the handle when there is no name. nil for none.
    static func postAuthor(_ author: String?) -> String? {
        guard let author, !author.isEmpty else { return nil }
        guard author.hasSuffix(")"), let open = author.range(of: " (@", options: .backwards) else { return author }
        let name = author[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? String(author[open.upperBound...].dropLast()) : name
    }
}

/// The Hacker News thread about a news story.
public struct TopicDiscussion: Sendable, Hashable, Identifiable {
    /// The Hacker News item's id in the database.
    public var id: Int64
    public var points: Int
    public var comments: Int
    /// The thread: `https://news.ycombinator.com/item?id=…`.
    public var url: String

    public init(id: Int64, points: Int, comments: Int, url: String) {
        self.id = id
        self.points = points
        self.comments = comments
        self.url = url
    }
}

/// What stands behind a story row in a topic's list: the other outlets' articles, the Hacker News thread and the posts on X and
/// Bluesky sharing it. A list row has one when its lead has any of them (`FeedItem.story`); a lone article, a video, an episode,
/// a post or a Hacker News thread of its own has none.
public struct TopicStory: Sendable, Hashable {
    /// Every article of the story, the lead first and then the others newest first (the lead's outlet is in the stack too, so
    /// "Yahoo, KHOU, The Cool Down" is `outlets.map(\.name)`). One for a story that only has a discussion.
    public var outlets: [TopicOutlet]
    /// The story's Hacker News thread (the one with the most points when several were submitted).
    public var discussion: TopicDiscussion?
    /// The posts on X and Bluesky sharing the story, newest first: the author as `name`, the post's text as `title`.
    public var posts: [TopicOutlet]

    public init(outlets: [TopicOutlet], discussion: TopicDiscussion? = nil, posts: [TopicOutlet] = []) {
        self.outlets = outlets
        self.discussion = discussion
        self.posts = posts
    }

    /// The other outlets (everything but the lead).
    public var others: [TopicOutlet] { Array(outlets.dropFirst()) }
}

/// Which stored articles of a topic are the same story, by their titles.
///
/// A title becomes a set of significant words: lowercased, without accents, punctuation, stop words, the topic's own keyword and
/// one- and two-letter words, each cut back to a rough stem ("reunites" and "reunited" are "reunit"). Two articles are one story
/// when they were published within `window` of each other and their sets overlap enough (`isSameStory`), weighing each word by
/// how rare it is among the topic's titles (`Weights`). A Hacker News thread joins a story whose article it links to, or whose
/// title it matches the same way. A post on X or Bluesky joins a story whose article it links to, or whose headline it repeats or
/// closely rewords (`postOverlaps`), since most of a topic's posts are outlets and readers sharing the day's articles.
public enum TopicStories {
    /// How far apart two articles of one story were published.
    public static let window: TimeInterval = 3 * 86_400

    /// Two titles are one story when the words they share carry at least `minScore` of the lighter title's weight (`Weights`)
    /// and they share three words or more, or, sharing only two, when those carry `minScoreTwoWords`. Tuned on the Firefox topic:
    /// the four Smart Window headlines score 0.33 to 0.60 with each other and the meme-ad coverage 0.24 to 1.0, while different
    /// stories on the same product stay below: "Please hold tests until security fixes ship" against "Firefox 159 fixes 167
    /// security flaws" (two words, 0.20), a settings-page story against the Smart Window one (two words, 0.33).
    static let minShared = 2
    static let minScore = 0.24
    static let minScoreTwoWords = 0.45

    /// A post joins an article's story when they share `minPostShared` words carrying `minPostScore` of the lighter one's weight:
    /// stricter than two articles, since a post's text is longer and wanders. Tuned on the chip exports topic: reshares and
    /// rewordings of its three headlines score 0.48 to 1.0 against them, while posts about China's chip exports, Korea's GDP
    /// figure or the Bank of Korea's warning (against the GDP story) score 0.21 to 0.39.
    static let minPostShared = 3
    static let minPostScore = 0.45

    /// How much each word says about which story a title is about, from every title being grouped: a word few of the topic's
    /// titles use ("smart", "window") says more than one most of them share. A word's weight is log(1 + titles / titles using it).
    public struct Weights: Sendable {
        private let weights: [String: Double]

        public init(_ titles: [Set<String>]) {
            var used: [String: Int] = [:]
            for words in titles { for w in words { used[w, default: 0] += 1 } }
            let n = Double(max(titles.count, 1))
            weights = used.mapValues { log(1 + n / Double($0)) }
        }

        /// Every word weighs the same: the score is the share of the shorter title's words the two have in common.
        public static let uniform = Weights([])

        func weight(_ word: String) -> Double { weights[word] ?? 1 }
        func total(_ words: Set<String>) -> Double { words.reduce(0) { $0 + weight($1) } }
    }

    /// Words that carry no story. Also the "Show HN:" and "Ask HN:" prefixes of Hacker News titles.
    static let stopWords: Set<String> = Set("""
        a an the and or but nor of to in on at by for from with without as is are was were be been being am it its this that these those
        how what why who whom when where which will can could would should may might must has have had do does did not no yes
        new now just says say said after over into about up out more most some all any your you we our they their he she his her
        i me my amid vs via per than then too very also still here there get gets got s t
        show ask hn tell
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// The significant words of a title, minus the topic's keyword.
    public static func words(of title: String, keyword: String) -> Set<String> {
        let drop = Set(wordList(keyword).map(stem))
        var out = Set<String>()
        for w in wordList(title) where !stopWords.contains(w) {
            let s = stem(w)
            if s.count >= 2, !drop.contains(s) { out.insert(s) }
        }
        return out
    }

    private static func wordList(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "").replacingOccurrences(of: "'", with: "")
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 || $0.first?.isNumber == true }
    }

    /// A crude stem: plural s, "ies", "ing", "ed", a trailing e. Enough to line up "reunites" with "reunited".
    static func stem(_ word: String) -> String {
        var w = word
        if w.hasSuffix("ies"), w.count > 4 { w = String(w.dropLast(3)) + "y" }
        else if w.hasSuffix("ing"), w.count > 5 { w = String(w.dropLast(3)) }
        else if w.hasSuffix("ed"), w.count > 4 { w = String(w.dropLast(2)) }
        else if w.hasSuffix("s"), !w.hasSuffix("ss"), w.count > 3 { w = String(w.dropLast()) }
        if w.hasSuffix("e"), w.count > 4 { w = String(w.dropLast()) }
        return w
    }

    /// How alike two titles' word sets are: the weight of the words they share over the lighter title's total, 0 to 1.
    public static func score(_ a: Set<String>, _ b: Set<String>, weights: Weights = .uniform) -> Double {
        let lighter = min(weights.total(a), weights.total(b))
        guard lighter > 0 else { return 0 }
        return weights.total(a.intersection(b)) / lighter
    }

    /// The word sets are alike enough to be one story (the time window is checked separately: `isSameStory`).
    public static func overlaps(_ a: Set<String>, _ b: Set<String>, weights: Weights = .uniform) -> Bool {
        let shared = a.intersection(b).count
        guard shared >= minShared else { return false }
        return score(a, b, weights: weights) >= (shared > minShared ? minScore : minScoreTwoWords)
    }

    /// The weaker test a Hacker News thread passes against an article: two shared words carrying `minScore`. A thread that
    /// passes it against two articles of one story is that story's discussion (a short HN title rarely shares more).
    static func nearlyOverlaps(_ a: Set<String>, _ b: Set<String>, weights: Weights) -> Bool {
        a.intersection(b).count >= minShared && score(a, b, weights: weights) >= minScore
    }

    /// A post's words against an article's: alike enough for the post to be about that article's story (`minPostScore`).
    static func postOverlaps(_ post: Set<String>, _ article: Set<String>, weights: Weights) -> Bool {
        post.intersection(article).count >= minPostShared && score(post, article, weights: weights) >= minPostScore
    }

    /// Two articles: published within `window` of each other with title words that overlap.
    public static func isSameStory(_ a: Set<String>, _ aDate: Date, _ b: Set<String>, _ bDate: Date, weights: Weights = .uniform) -> Bool {
        abs(aDate.timeIntervalSince(bDate)) <= window && overlaps(a, b, weights: weights)
    }
}

extension Topic {
    /// What a stored item of a topic came from, by what the search stored it as: a Hacker News story (`hn:`), a Reddit post
    /// (`reddit:`), a post on X (`x:`) or Bluesky (`bsky:`), a video or an episode (media), or else a news article.
    static func place(guid: String, videoId: String?, audioUrl: String?) -> TopicPlace {
        if guid.hasPrefix("hn:") { return .hackerNews }
        if guid.hasPrefix("reddit:") { return .reddit }
        if guid.hasPrefix("x:") { return .x }
        if guid.hasPrefix("bsky:") { return .bluesky }
        if videoId != nil || audioUrl != nil { return .media }
        return .news
    }

    /// The stored item is a post on X or Bluesky (by its guid, as `place` reads it).
    static func isPost(guid: String) -> Bool { guid.hasPrefix("x:") || guid.hasPrefix("bsky:") }

    /// SQL for `isPost` on the `items` row `table` names.
    static func isPostSQL(_ table: String) -> String { "(\(table).guid LIKE 'x:%' OR \(table).guid LIKE 'bsky:%')" }
}
