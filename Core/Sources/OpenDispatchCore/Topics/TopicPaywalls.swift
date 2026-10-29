import Foundation

/// Large news outlets whose articles read free, searched by name in Topics alongside the plain news search
/// (`DefaultTopicSearch.outletNews`) so a topic isn't left to the few answers Bing's own ranking gives.
public enum MajorOutlets {
    public static let domains: [String] = [
        "apnews.com", "reuters.com", "theguardian.com", "npr.org", "cnbc.com", "axios.com", "politico.com", "cbsnews.com",
        "nbcnews.com", "abcnews.go.com", "usatoday.com", "aljazeera.com", "theverge.com", "techcrunch.com", "arstechnica.com",
        "engadget.com",
    ]
}

/// Sites that put their articles behind a hard paywall, so a topic that skips paywalled sites leaves their
/// articles out. A static list, matched by host suffix ("www.nytimes.com" and "cooking.nytimes.com" are
/// "nytimes.com"). Sites that let a few articles through (metered) are not on it.
public enum TopicPaywalls {
    public static let domains: [String] = [
        "nytimes.com", "wsj.com", "bloomberg.com", "ft.com", "economist.com", "washingtonpost.com", "theatlantic.com",
        "newyorker.com", "businessinsider.com", "theinformation.com", "barrons.com", "thetimes.co.uk", "thetimes.com",
        "telegraph.co.uk", "hbr.org", "technologyreview.com", "foreignaffairs.com", "foreignpolicy.com", "stratechery.com",
        "afr.com", "nikkei.com", "handelsblatt.com", "lemonde.fr", "spiegel.de",
    ]

    /// The names a paywalled publisher goes by in a news answer, folded and without apostrophes. Needed because an aggregator
    /// such as MSN carries their articles under its own address ("Barron's on MSN").
    static let publishers: Set<String> = [
        "the new york times", "new york times", "the wall street journal", "wall street journal", "wsj", "bloomberg",
        "bloomberg news", "financial times", "ft", "the economist", "the washington post", "washington post", "the atlantic",
        "the new yorker", "business insider", "the information", "barrons", "the times", "the telegraph",
        "harvard business review", "mit technology review", "foreign affairs", "foreign policy", "stratechery",
    ]

    /// A news answer's publisher name is a paywalled one, however it was written ("The Wall Street Journal", "WSJ on MSN").
    public static func isPaywalled(publisher: String) -> Bool {
        var name = TopicMatcher.fold(publisher).replacingOccurrences(of: "\u{2019}", with: "").replacingOccurrences(of: "'", with: "")
        for suffix in [" on msn", ".com"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        return publishers.contains(name.trimmingCharacters(in: .whitespaces))
    }

    /// The URL's host is one of `domains` or a subdomain of one.
    public static func isPaywalled(_ url: String) -> Bool {
        let host = URLHost.host(of: url)
        return !host.isEmpty && domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
