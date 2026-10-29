import Foundation

/// What the lists do with articles from sites that want a subscription you haven't signed in with
/// (Settings → Integrations → Paywalled articles). Sites the app is signed in to always show in full.
public enum PaywallTreatment: String, Codable, CaseIterable, Identifiable, Sendable {
    case show, mark, hide

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .show: "Show"
        case .mark: "Mark"
        case .hide: "Hide"
        }
    }
}

extension PaywallTreatment {
    static let key = "openfeed.paywall-treatment"

    /// The setting as the App last set it, for Core code that can't see the App's settings (Topics' outlet searches).
    /// Mark until the App has set it.
    public static var current: PaywallTreatment {
        get { UserDefaults.standard.string(forKey: key).flatMap(PaywallTreatment.init(rawValue:)) ?? .mark }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// How an article's site stands for this reader.
public enum PaywallStatus: Sendable, Hashable {
    /// No paywall known.
    case free
    /// The app is signed in to the site on this device: read as you.
    case signedIn
    /// Every article is for subscribers: marked, or hidden with `.hide`.
    case walled
    /// Some articles read in full and some don't: marked, never hidden.
    case metered
}

/// What the app has learned about one site's paywall, synced with the settings.
public struct PaywallSiteRecord: Codable, Sendable, Hashable {
    /// Articles that came back cut short, and articles that read in full after the site had walled one.
    public var walled: Int
    public var full: Int
    /// "Don't Ask Again": the reader stops offering to sign in to this site.
    public var declined: Bool
    public var lastSeen: Date

    public init(walled: Int = 0, full: Int = 0, declined: Bool = false, lastSeen: Date = Date()) {
        self.walled = walled
        self.full = full
        self.declined = declined
        self.lastSeen = lastSeen
    }
}

/// Every site that has walled an article, by `Paywalls.site(of:)`. Part of the synced settings, so the lists and the
/// Settings list agree across devices; sign-ins themselves are per device (`SiteSignIns`).
public struct PaywallBook: Codable, Sendable, Hashable {
    public var sites: [String: PaywallSiteRecord]

    public init(sites: [String: PaywallSiteRecord] = [:]) {
        self.sites = sites
    }

    /// Counts an article the reader read: `walled` when it came back cut short. A full read is only counted for a site
    /// already in the book or on the known list, so the book holds paywalled sites only.
    public mutating func record(url: String, walled: Bool, now: Date = Date()) {
        let site = Paywalls.site(of: url)
        guard !site.isEmpty else { return }
        if walled {
            var r = sites[site] ?? PaywallSiteRecord(lastSeen: now)
            r.walled = min(r.walled + 1, Self.cap)
            r.lastSeen = now
            sites[site] = r
        } else if var r = sites[site] ?? (TopicPaywalls.isPaywalled(url) ? PaywallSiteRecord(lastSeen: now) : nil) {
            r.full = min(r.full + 1, Self.cap)
            r.lastSeen = now
            sites[site] = r
        }
    }

    /// "Don't Ask Again" for the article's site, or asking again.
    public mutating func setDeclined(_ declined: Bool, url: String, now: Date = Date()) {
        let site = Paywalls.site(of: url)
        guard !site.isEmpty else { return }
        var r = sites[site] ?? PaywallSiteRecord(lastSeen: now)
        r.declined = declined
        sites[site] = r
    }

    public func isDeclined(url: String) -> Bool { sites[Paywalls.site(of: url)]?.declined ?? false }

    static let cap = 9999
}

/// Which sites want a subscription, from the known list (`TopicPaywalls`) and what the reader has learned (`PaywallBook`).
public enum Paywalls {
    /// A site's key: the known paywalled domain the host belongs to ("cooking.nytimes.com" is "nytimes.com"), else the
    /// host without "www.", so each Substack is a site of its own.
    public static func site(of url: String) -> String {
        let host = URLHost.host(of: url)
        guard !host.isEmpty else { return "" }
        return TopicPaywalls.domains.first { host == $0 || host.hasSuffix("." + $0) } ?? host
    }

    /// How many walled articles make a site that isn't on the known list count as paywalled.
    public static let learnedAfter = 2

    /// `publisher` is an aggregator item's outlet ("Barron's on MSN"), checked against the known publishers.
    public static func status(url: String, publisher: String? = nil, signedIn: Set<String>, book: PaywallBook) -> PaywallStatus {
        let site = site(of: url)
        guard !site.isEmpty else { return .free }
        if signedIn.contains(site) { return .signedIn }
        let record = book.sites[site]
        let known = TopicPaywalls.isPaywalled(url) || publisher.map(TopicPaywalls.isPaywalled(publisher:)) == true
        guard known || (record?.walled ?? 0) >= learnedAfter else { return .free }
        return (record?.full ?? 0) > 0 ? .metered : .walled
    }
}

/// The sites this device is signed in to through the sign-in sheet (beyond X and Reddit, which `WebAccount` covers).
/// A session lives in the app's web data store, which doesn't sync, so this list is per device (UserDefaults).
/// Articles from these sites are read in a hidden web view that carries the sign-in (`SignedInPages`).
public enum SiteSignIns {
    static let key = "openfeed.signed-in-sites"

    public static var sites: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    public static func contains(url: String) -> Bool {
        let site = Paywalls.site(of: url)
        return !site.isEmpty && sites.contains(site)
    }

    public static func add(_ site: String) {
        guard !site.isEmpty else { return }
        UserDefaults.standard.set(Array(sites.union([site])).sorted(), forKey: key)
    }

    public static func remove(_ site: String) {
        UserDefaults.standard.set(Array(sites.subtracting([site])).sorted(), forKey: key)
    }
}
