import Foundation

/// Where a search result lives. Its row names it, and `readType` is what the "Add sources" chips filter by, so another place
/// needs no new chip.
public enum SourcePlace: String, Sendable, Hashable, CaseIterable {
    case x, youtube, bluesky, mastodon, reddit, site, podcast, instagram

    public var name: String {
        switch self {
        case .x: "X"
        case .youtube: "YouTube"
        case .bluesky: "Bluesky"
        case .mastodon: "Mastodon"
        case .reddit: "Reddit"
        case .site: "Site"
        case .podcast: "Podcast"
        case .instagram: "Instagram"
        }
    }

    /// The place's own site, for its favicon; nil for a site or a show, which have their own.
    public var host: String? {
        switch self {
        case .x: "x.com"
        case .youtube: "youtube.com"
        case .bluesky: "bsky.app"
        case .mastodon: "joinmastodon.org"
        case .reddit: "reddit.com"
        case .instagram: "instagram.com"
        case .site, .podcast: nil
        }
    }

    /// How its items read, the kinds the sidebar lists.
    public var readType: SourceType {
        switch self {
        case .x, .bluesky, .mastodon, .reddit, .instagram: .post
        case .youtube: .video
        case .site: .article
        case .podcast: .podcast
        }
    }
}

/// Orders what the searches found across places: who was meant first, then who is followed.
///
/// A result is an exact match (its handle or name is the query), the same person as an exact handle (same name, and followed), a name
/// match (every word of the query is in it), or related (the place thought it fit). Inside each, the most followed comes first, and no
/// place takes more than `placeLimit` of the first `placeLimitWithin`. A handle match under an unrelated name, that nothing else backs
/// up, is someone else who holds the handle ("fireship" on X is a CHIEF INSPECTOR), so it counts as related.
public enum SourceRanking {
    /// Under this many followers an account is a namesake, unless its handle is exactly what was typed.
    static let minFollowers: Double = 1000
    static let placeLimit = 3
    static let placeLimitWithin = 8
    /// Feedly readers are far fewer than a site's real audience, so they are scaled to compare with followers.
    static let readerScale: Double = 50
    /// Audiences for what doesn't report one, so a community or a show that matches isn't sunk by it.
    static let redditAudience: Double = 200_000
    static let podcastAudience: Double = 100_000
    static let otherAudience: Double = 1000

    /// Copies of an account rather than the account: bots, bridges from other networks, parodies.
    private static let notTheAccount = ExtractionDOM.Pattern(
        #"parody|unofficial|\{bot\}|🤖|brid\.gy|birdsite|selfhosted\.social| - Topic$|handle\.invalid|threads\.net|feediverse|sportsbots"#, caseInsensitive: true)

    /// Combines the searches: feeds from `SourceSearching`, channels and the other places' accounts. Feedly's copies of a channel go, and
    /// so do its feeds of an X account, third-party bridges the account itself replaces. A query with an "@" keeps only that handle
    /// among accounts.
    public static func rank(query: String, feeds: [SourceSearchResult], accounts: [SourceSearchResult]) -> [SourceSearchResult] {
        let name = SourceSearch.name(in: query)
        let exactOnly = query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@")
        let accountKeys = Set(accounts.map { SourceSearch.feedKey($0.feedUrl) })
        let kept = feeds.filter { feed in
            if accountKeys.contains(SourceSearch.feedKey(feed.feedUrl)) { return false }
            if let site = feed.siteUrl.flatMap({ URLComponents(string: $0)?.host }), PageScraping.isXHost(site) { return false }
            return true
        }
        var seen = Set<String>()
        let all = (accounts + kept).filter { seen.insert(SourceSearch.feedKey($0.feedUrl)).inserted }
        var candidates = all.compactMap { candidate(from: $0, name: name, exactOnly: exactOnly) }

        // Same name on several places backs up a match.
        var places: [String: Set<SourcePlace>] = [:]
        for c in candidates where c.tier >= .nameMatch { places[c.nameKey, default: []].insert(c.result.place) }
        let people = Set(candidates.filter { $0.exactHandle && (places[$0.nameKey]?.count ?? 0) > 1 }.map(\.nameKey))
        var best: [String: Double] = [:]
        for c in candidates where c.tier >= .nameMatch {
            if let n = c.followers { best[c.nameKey] = max(best[c.nameKey] ?? 0, n) }
        }
        for i in candidates.indices {
            let c = candidates[i]
            let backed = (places[c.nameKey]?.count ?? 0) > 1
            let isAccount = c.result.place != .site && c.result.place != .podcast
            if c.tier == .nameMatch, people.contains(c.nameKey), isAccount, (c.followers ?? 0) >= minFollowers {
                candidates[i].tier = .exact
            } else if c.exactHandle, !c.nameKey.contains(c.queryKey), !backed {
                candidates[i].tier = .related
            }
            let audience = c.followers
                ?? (backed ? best[c.nameKey].map { $0 / 2 } : nil)
                ?? (c.result.place == .reddit ? redditAudience : c.result.place == .podcast ? podcastAudience : otherAudience)
            candidates[i].score = Double(candidates[i].tier.rawValue) * 10 + log10(max(audience, 1))
        }

        // A site or show with nothing of the name in it is the search's fallback for few matches; it has no use once anything matched.
        if candidates.contains(where: { $0.tier >= .nameMatch }) {
            candidates.removeAll { $0.tier == .related && ($0.result.place == .site || $0.result.place == .podcast) }
        }
        // sort isn't stable, so ties keep the order the places answered in by their index.
        let sorted = candidates.enumerated().sorted { a, b in
            a.element.score == b.element.score ? a.offset < b.offset : a.element.score > b.element.score
        }.map(\.element.result)

        var top: [SourceSearchResult] = []
        var rest: [SourceSearchResult] = []
        var counts: [SourcePlace: Int] = [:]
        for r in sorted {
            if top.count < placeLimitWithin, counts[r.place, default: 0] < placeLimit {
                top.append(r)
                counts[r.place, default: 0] += 1
            } else {
                rest.append(r)
            }
        }
        return top + rest
    }

    private enum Tier: Int, Comparable {
        case related = 1, nameMatch, exact
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    private struct Candidate {
        var result: SourceSearchResult
        var nameKey: String
        var queryKey: String
        var tier: Tier
        var exactHandle: Bool
        var followers: Double?
        var score: Double = 0
    }

    private static func candidate(from r: SourceSearchResult, name: String, exactOnly: Bool) -> Candidate? {
        let text = r.title + " " + (r.handle ?? r.subtitle)
        if notTheAccount.test(text) { return nil }
        let queryKey = key(name)
        let nameKey = key(r.title)
        let handleKey = r.handle.map { key(String($0.split(whereSeparator: { $0 == "." || $0 == "@" }).first ?? "")) }
        let exactHandle = handleKey == queryKey
        let isAccount = r.place != .site && r.place != .podcast
        if exactOnly, isAccount, !exactHandle { return nil }

        let followers = r.readers.map { Double($0) * readerScale } ?? SourceSearch.subscriberCount(r.audience)
        let reports = isAccount && r.audience != nil
        if reports, (followers ?? 0) < minFollowers, !exactHandle { return nil }
        // An account that never set a name is rarely the one being looked for.
        if isAccount, r.place == .bluesky || r.place == .mastodon, r.title == r.handle, !exactHandle { return nil }

        var tier: Tier = .related
        let words = name.lowercased().split(whereSeparator: \.isWhitespace).map { key(String($0)) }
        if exactHandle || nameKey == queryKey {
            tier = reports && (followers ?? 0) < minFollowers && !exactOnly ? .nameMatch : .exact
        } else if words.allSatisfy({ key(text).contains($0) }) {
            tier = .nameMatch
        }
        return Candidate(result: r, nameKey: nameKey, queryKey: queryKey, tier: tier, exactHandle: exactHandle, followers: followers)
    }

    /// Lowercased letters and digits, in any script.
    private static func key(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
