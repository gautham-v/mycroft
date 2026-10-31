import Foundation

/// A source the app could suggest, and why (Explore's start and Add Sources' For You).
public struct SourceSuggestion: Sendable, Hashable, Identifiable {
    public enum Evidence: Int, Sendable, Hashable, Comparable {
        /// The user opened its posts or articles, through a topic or a link.
        case opened
        /// Something the user opened links to it.
        case linked
        /// It's in a catalog subject the user reads, next to a source they open.
        case subject

        public static func < (a: Evidence, b: Evidence) -> Bool { a.rawValue < b.rawValue }
    }

    public var result: SourceSearchResult
    public var reason: String
    public var evidence: Evidence
    /// How many opens or links back it up.
    public var strength: Int
    /// The catalog entry behind it, which `isWalled` can ask about; nil for an account or community found in History.
    public var starter: StarterSource?

    public var id: String { result.feedUrl }

    public init(result: SourceSearchResult, reason: String, evidence: Evidence, strength: Int, starter: StarterSource? = nil) {
        self.result = result
        self.reason = reason
        self.evidence = evidence
        self.strength = strength
        self.starter = starter
    }
}

/// What opened rows say about sources outside the library, in plain counts. Kept apart from the database so it can be
/// tested on its own: `Queries.sourceSuggestions` reads the rows and hands them here.
struct SourceSuggester {
    /// One opened row.
    struct Opened {
        var feedUrl: String
        var sourceTitle: String
        var itemUrl: String
        /// The item's text and summary, when this device still has them, for what it links to.
        var content: String?
        /// The topic it was opened through, when that topic still exists.
        var topic: String?
        /// A topic's or an opened link's row: the reader went outside the subscriptions for it.
        var isOutsideLibrary: Bool
    }

    /// A source in the library.
    struct Followed {
        var feedUrl: String
        var title: String
        var host: String
    }

    /// Evidence below this stays quiet: one open or one link is often an accident.
    static let minimumEvidence = 2
    static let maxEvidenced = 12
    static let subjects = 3
    static let perSubject = 2
    /// Opens in a subject before it counts as one the user reads.
    static let minimumSubjectOpens = 3

    var opened: [Opened]
    var followed: [Followed]
    /// `SourceSearch.feedKey`s of sources removed or dismissed: never suggested back.
    var removed: Set<String>
    /// Their titles: a source removed under one address shouldn't come back under another.
    var removedTitles: [String] = []
    var catalog: [StarterPack] = StarterSources.packs
    var formats: Set<String> = StarterSources.formats

    private struct Tally {
        var name: String
        var count = 0
        var topics: [String: Int] = [:]

        var topic: String? { topics.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }

        mutating func add(topic: String?) {
            count += 1
            if let topic { topics[topic, default: 0] += 1 }
        }
    }

    func suggestions() -> [SourceSuggestion] {
        let followedKeys = Set(followed.map { SourceSearch.feedKey($0.feedUrl) })
        let followedHosts = Set(followed.map(\.host).filter { !$0.isEmpty })
        var seen = followedKeys.union(removed)
        func fresh(_ feedUrl: String) -> Bool { seen.insert(SourceSearch.feedKey(feedUrl)).inserted }
        // The same account is often followed under another address: a Bluesky or third-party feed titled "Claude(@claudeai)".
        let followedHandles = Set(followed.flatMap { Self.all(#"@([A-Za-z0-9_]{1,15})\b"#, in: $0.title).map { $0.lowercased() } })
        let removedNames = Set(removedTitles.map { Self.squeezed(Self.shortName($0)) })

        var communities: [String: Tally] = [:]
        var accounts: [String: Tally] = [:]
        var linkedAccounts: [String: Tally] = [:]
        var sites: [String: Tally] = [:]
        var linkedHosts: [String: Int] = [:]
        for row in opened {
            if let name = Self.community(in: row.itemUrl) {
                communities[name.lowercased(), default: Tally(name: name)].add(topic: row.topic)
            }
            if let handle = Self.postAuthor(in: row.itemUrl) {
                accounts[handle.lowercased(), default: Tally(name: handle)].add(topic: row.topic)
            }
            let host = URLHost.host(of: row.itemUrl)
            if row.isOutsideLibrary, !host.isEmpty {
                sites[host, default: Tally(name: host)].add(topic: row.topic)
            }
            guard let content = row.content else { continue }
            for handle in Self.linkedAccounts(in: content) {
                linkedAccounts[handle.lowercased(), default: Tally(name: handle)].count += 1
            }
            for linked in Self.linkedHosts(in: content) where linked != host { linkedHosts[linked, default: 0] += 1 }
        }

        var evidenced: [SourceSuggestion] = []
        for tally in communities.values where tally.count >= Self.minimumEvidence {
            let feedUrl = "\(RedditPages.origin)/r/\(tally.name)/.rss"
            guard fresh(feedUrl) else { continue }
            evidenced.append(SourceSuggestion(
                result: SourceSearchResult(title: "r/\(tally.name)", subtitle: "Reddit", feedUrl: feedUrl, kind: .rss, place: .reddit),
                reason: Self.openedReason(tally, noun: "posts"), evidence: .opened, strength: tally.count))
        }
        for tally in accounts.values where tally.count >= Self.minimumEvidence && !followedHandles.contains(tally.name.lowercased()) {
            guard let suggestion = account(tally, reason: Self.openedReason(tally, noun: "posts"), evidence: .opened),
                  fresh(suggestion.result.feedUrl) else { continue }
            evidenced.append(suggestion)
        }
        for tally in linkedAccounts.values where tally.count >= Self.minimumEvidence && !followedHandles.contains(tally.name.lowercased()) {
            guard let suggestion = account(tally, reason: Self.linkedReason(tally.count), evidence: .linked),
                  fresh(suggestion.result.feedUrl) else { continue }
            evidenced.append(suggestion)
        }

        // Sites come only from the catalog, whose entries are known to have a free, working feed: any host can be linked twice.
        let starters = catalog.flatMap(\.sources)
        for tally in sites.values where tally.count >= Self.minimumEvidence {
            guard let starter = starters.first(where: { Self.isSite($0, on: tally.name) }),
                  !followedHosts.contains(Self.host(of: starter)), fresh(starter.feedUrl) else { continue }
            evidenced.append(Self.suggestion(starter, reason: Self.openedReason(tally, noun: "articles"), evidence: .opened, strength: tally.count))
        }
        for (linked, count) in linkedHosts where count >= Self.minimumEvidence && !followedHosts.contains(linked) {
            guard let starter = starters.first(where: { Self.isSite($0, on: linked) || Self.isNamed($0, after: linked) }),
                  starter.place != .site || !followedHosts.contains(Self.host(of: starter)), fresh(starter.feedUrl) else { continue }
            evidenced.append(Self.suggestion(starter, reason: Self.linkedReason(count), evidence: .linked, strength: count))
        }
        // An open says more than a link: it's the user's own choice.
        func weight(_ s: SourceSuggestion) -> Int { s.evidence == .opened ? s.strength * 2 : s.strength }
        evidenced.sort { (-weight($0), $0.result.title.lowercased()) < (-weight($1), $1.result.title.lowercased()) }
        let suggestions = Array(evidenced.prefix(Self.maxEvidenced)) + subjectSuggestions(followedHosts: followedHosts, fresh: fresh)
        return suggestions.filter { suggestion in
            guard !removedNames.contains(Self.squeezed(suggestion.result.title)) else { return false }
            // A catalog entry on X too may be someone followed under another feed.
            guard suggestion.result.place == .x, let handle = suggestion.result.feedUrl.split(separator: "/").last else { return true }
            return !followedHandles.contains(handle.lowercased())
        }
    }

    /// Catalog entries beside what the user opens: similarity by subject rather than by words, since comparing headlines
    /// sent someone who reads the NFL to baseball.
    private func subjectSuggestions(followedHosts: Set<String>, fresh: (String) -> Bool) -> [SourceSuggestion] {
        var opensByFeed: [String: Int] = [:]
        for row in opened { opensByFeed[SourceSearch.feedKey(row.feedUrl), default: 0] += 1 }
        let byKey = Dictionary(followed.map { (SourceSearch.feedKey($0.feedUrl), $0) }, uniquingKeysWith: { a, _ in a })
        let byHost = Dictionary(followed.filter { !$0.host.isEmpty }.map { ($0.host, $0) }, uniquingKeysWith: { a, _ in a })

        var ranked: [(pack: StarterPack, opens: Int, lead: Followed)] = []
        for pack in catalog where !formats.contains(pack.name) {
            var opens = 0
            var lead: (source: Followed, opens: Int)?
            var counted = Set<String>()
            for starter in pack.sources {
                let member = byKey[SourceSearch.feedKey(starter.feedUrl)] ?? (starter.place == .site ? byHost[Self.host(of: starter)] : nil)
                guard let member, counted.insert(member.feedUrl).inserted else { continue }
                let count = opensByFeed[SourceSearch.feedKey(member.feedUrl)] ?? 0
                opens += count
                if count > (lead?.opens ?? 0) { lead = (member, count) }
            }
            if let lead, opens >= Self.minimumSubjectOpens { ranked.append((pack, opens, lead.source)) }
        }
        ranked.sort { ($1.opens, $0.pack.name) < ($0.opens, $1.pack.name) }

        var out: [SourceSuggestion] = []
        for subject in ranked.prefix(Self.subjects) {
            var taken = 0
            for starter in subject.pack.sources where taken < Self.perSubject {
                guard starter.place != .site || !followedHosts.contains(Self.host(of: starter)), fresh(starter.feedUrl) else { continue }
                out.append(Self.suggestion(starter, reason: "Also in \(subject.pack.name), with \(Self.shortName(subject.lead.title)).",
                                           evidence: .subject, strength: subject.opens))
                taken += 1
            }
        }
        return out
    }

    private func account(_ tally: Tally, reason: String, evidence: SourceSuggestion.Evidence) -> SourceSuggestion? {
        SourceSuggestion(
            result: SourceSearchResult(title: "@\(tally.name)", subtitle: "X · @\(tally.name)", feedUrl: "\(XPages.origin)/\(tally.name)",
                                       kind: .page, handle: tally.name, place: .x),
            reason: reason, evidence: evidence, strength: tally.count)
    }

    private static func suggestion(_ starter: StarterSource, reason: String, evidence: SourceSuggestion.Evidence, strength: Int) -> SourceSuggestion {
        let kind: SourceKind = switch starter.place {
        case .youtube: .youtube
        case .podcast: .podcast
        case .x: .page
        default: .rss
        }
        let host = host(of: starter)
        return SourceSuggestion(
            result: SourceSearchResult(title: starter.title, subtitle: starter.detail.trimmingCharacters(in: .whitespaces), feedUrl: starter.feedUrl,
                                       siteUrl: host.isEmpty ? nil : "https://\(host)", kind: kind, imageUrl: starter.imageUrl, place: starter.place),
            reason: reason, evidence: evidence, strength: strength, starter: starter)
    }

    private static func openedReason(_ tally: Tally, noun: String) -> String {
        if let topic = tally.topic { return "You opened \(tally.count) of its \(noun) through your \(topic) topic." }
        return "You opened \(tally.count) of its \(noun)."
    }

    private static func linkedReason(_ count: Int) -> String { "Linked from \(count) things you opened." }

    private static func shortName(_ title: String) -> String {
        Source(title: title, url: "", feedUrl: "", kind: .rss, group: "").shortTitle
    }

    private static func host(of starter: StarterSource) -> String {
        starter.host.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// A site in the catalog on this host or one under it.
    private static func isSite(_ starter: StarterSource, on host: String) -> Bool {
        guard starter.place == .site else { return false }
        let site = Self.host(of: starter)
        return !site.isEmpty && (host == site || host.hasSuffix("." + site))
    }

    /// A channel or show named after a site that was linked: "Lex Fridman" for lexfridman.com.
    private static func isNamed(_ starter: StarterSource, after host: String) -> Bool {
        guard starter.place != .site, let label = host.split(separator: ".").first else { return false }
        return squeezed(starter.title) == label
    }

    /// Letters and digits only, lowercased, so "Pro Football Talk" and "profootballtalk" are the same name.
    private static func squeezed(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Reading addresses

    /// The community in a Reddit post's address. A user's own page ("u_name") isn't one.
    static func community(in url: String) -> String? {
        guard let match = first(#"(?:^|//|\.)reddit\.com/r/([A-Za-z0-9_]{2,21})(?:/|$)"#, in: url), !match.hasPrefix("u_") else { return nil }
        return match
    }

    /// The account in the address of a post on X.
    static func postAuthor(in url: String) -> String? {
        guard let match = first(#"(?:^|//|\.)(?:x|twitter)\.com/([A-Za-z0-9_]{1,15})/status/"#, in: url), !reservedPaths.contains(match.lowercased()) else { return nil }
        return match
    }

    /// Accounts on X that a piece of text links to, each once. Only links count: an @ in prose is often not an account.
    static func linkedAccounts(in text: String) -> [String] {
        var seen = Set<String>()
        return all(#"https?://(?:www\.|mobile\.)?(?:x|twitter)\.com/([A-Za-z0-9_]{1,15})(?=[/"'?#\s<]|$)"#, in: text).filter {
            !reservedPaths.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted
        }
    }

    /// Sites a piece of text links to, each once.
    static func linkedHosts(in text: String) -> [String] {
        var seen = Set<String>()
        return all(#"https?://(?:www\.)?([A-Za-z0-9.-]+\.[A-Za-z]{2,})"#, in: text).map { $0.lowercased() }.filter { seen.insert($0).inserted }
    }

    private static let reservedPaths: Set<String> = [
        "i", "home", "search", "intent", "share", "hashtag", "explore", "settings", "messages", "notifications", "compose", "login", "signup", "tos", "privacy",
        "web", "user", "statuses", "status", "en", "about", "jobs", "download", "widgets", "following", "followers", "lists", "account", "oauth",
    ]

    private static func first(_ pattern: String, in text: String) -> String? {
        all(pattern, in: text, limit: 1).first
    }

    private static func all(_ pattern: String, in text: String, limit: Int = .max) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [String] = []
        regex.enumerateMatches(in: text, range: range) { match, _, stop in
            if let match, let r = Range(match.range(at: 1), in: text) { out.append(String(text[r])) }
            if out.count >= limit { stop.pointee = true }
        }
        return out
    }
}
