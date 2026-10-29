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

/// What stands behind a story row in a topic's list: the other outlets' articles and the Hacker News thread. A list row has one
/// when its lead has either (`FeedItem.story`); a lone article, a video, an episode or a Hacker News thread of its own has none.
public struct TopicStory: Sendable, Hashable {
    /// Every article of the story, the lead first and then the others newest first (the lead's outlet is in the stack too, so
    /// "Yahoo, KHOU, The Cool Down" is `outlets.map(\.name)`). One for a story that only has a discussion.
    public var outlets: [TopicOutlet]
    /// The story's Hacker News thread (the one with the most points when several were submitted).
    public var discussion: TopicDiscussion?

    public init(outlets: [TopicOutlet], discussion: TopicDiscussion? = nil) {
        self.outlets = outlets
        self.discussion = discussion
    }

    /// The other outlets (everything but the lead).
    public var others: [TopicOutlet] { Array(outlets.dropFirst()) }
}

/// Which stored articles of a topic are the same story, by their titles.
///
/// A title becomes a set of significant words: lowercased, without accents, punctuation, stop words, the topic's own keyword and
/// one- and two-letter words, each cut back to a rough stem ("reunites" and "reunited" are "reunit"). Two articles are one story
/// when they were published within `window` of each other and their sets overlap enough (`isSameStory`). A Hacker News thread
/// joins a story whose article it links to, or whose title it matches the same way.
public enum TopicStories {
    /// How far apart two articles of one story were published.
    public static let window: TimeInterval = 3 * 86_400

    /// Shared words needed: at least `minShared` and `minOverlap` of the shorter title's words, or (for short titles)
    /// `minSharedShort` and `minOverlapShort`. Tuned on the Firefox topic: "Firefox Just Reunited Some Of The Internet's Most Iconic
    /// Early Memes In A Nostalgic New Ad" and "'The internet used to be fun': Firefox reunites 2000s meme stars for anti-AI ad"
    /// share 4 of 7 words; the three Smart Window headlines share 5 of 8; the Tesla court and Apple 27.2 headlines share 5 to 8.
    /// Looser bars (0.33 with 3 words) pull in different stories on the same company ("South Korean Police Are Cracking Down On
    /// Tesla Owners Jailbreaking FSD" with the court case).
    static let minShared = 3
    static let minOverlap = 0.5
    static let minSharedShort = 2
    static let minOverlapShort = 0.75

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

    /// The word sets are alike enough to be one story (the time window is checked separately: `isSameStory`).
    public static func overlaps(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let shared = a.intersection(b).count
        let overlap = Double(shared) / Double(min(a.count, b.count))
        return (shared >= minShared && overlap >= minOverlap) || (shared >= minSharedShort && overlap >= minOverlapShort)
    }

    /// Two articles: published within `window` of each other with title words that overlap.
    public static func isSameStory(_ a: Set<String>, _ aDate: Date, _ b: Set<String>, _ bDate: Date) -> Bool {
        abs(aDate.timeIntervalSince(bDate)) <= window && overlaps(a, b)
    }
}

extension Topic {
    /// What a stored item of a topic came from, by what the search stored it as: a Hacker News story (`hn:`), a Reddit post
    /// (`reddit:`), a video or an episode (media), or else a news article.
    static func place(guid: String, videoId: String?, audioUrl: String?) -> TopicPlace {
        if guid.hasPrefix("hn:") { return .hackerNews }
        if guid.hasPrefix("reddit:") { return .reddit }
        if videoId != nil || audioUrl != nil { return .media }
        return .news
    }
}
