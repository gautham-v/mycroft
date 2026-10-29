import Foundation

/// Bing News' RSS (`/news/search?format=rss`), no key: what Topics' news place and Explore's articles both read.
/// Its links go through an `apiclick` redirect that names the article in its `url` parameter, which is read back out; the
/// publisher is in `News:Source` and a picture, when it has one, in `News:Image`. Bing answers about ten articles, mostly
/// syndicated copies and small outlets, so a search is also run limited to large outlets (`site:`), a few sites at a time.
enum BingNews {
    /// One article of an answer.
    struct Article: Sendable, Hashable {
        var title: String
        var url: String
        var publisher: String?
        var summary: String?
        var published: Date
        /// A thumbnail at `imageWidth` x `imageHeight` (Bing's address takes the size), when the answer has a picture.
        var imageUrl: String?
    }

    /// The thumbnail size asked of Bing, 4:3; the address crops to it.
    static let imageWidth = 360
    static let imageHeight = 270

    /// Sites per outlet search: Bing drops `site:` terms past a query of about this many.
    static let sitesPerSearch = 8

    /// `query` is sent as it is. `market` ("en-US") asks Bing for the user's language and region; without one Bing picks from
    /// the address. `sites` limits the search to those sites. Newest first, or in Bing's own relevance order.
    static func url(query: String, market: String? = nil, sites: [String] = [], newestFirst: Bool = true) -> String {
        var q = query
        if !sites.isEmpty { q += " (" + sites.map { "site:\($0)" }.joined(separator: " OR ") + ")" }
        var url = "https://www.bing.com/news/search?q=\(DefaultTopicSearch.encode(q))&format=rss"
        if newestFirst { url += "&qft=sortbydate%3d%221%22" }
        if let market { url += "&mkt=\(DefaultTopicSearch.encode(market))&setlang=\(DefaultTopicSearch.encode(market))" }
        return url
    }

    /// The sites the outlet searches cover, in groups of `sitesPerSearch`: the ones the app is signed in to, the free major
    /// outlets, then the known paywalled sites, which are left out while the lists hide them (`PaywallTreatment.hide`).
    static func outletSites(signedIn: Set<String> = SiteSignIns.sites, paywalled: Bool = PaywallTreatment.current != .hide) -> [[String]] {
        var sites = signedIn.sorted()
        for domain in MajorOutlets.domains + (paywalled ? TopicPaywalls.domains : []) where !sites.contains(domain) { sites.append(domain) }
        return stride(from: 0, to: sites.count, by: sitesPerSearch).map { Array(sites[$0..<min($0 + sitesPerSearch, sites.count)]) }
    }

    /// Asks each address at the same time and returns the answers in request order; one that fails gives no articles.
    /// Throws (the first error) only when every request did.
    static func search(_ urls: [String], get: @escaping @Sendable (String) async throws -> Data) async throws -> [[Article]] {
        var answers = [[Article]](repeating: [], count: urls.count)
        var errors: [any Error] = []
        await withTaskGroup(of: (Int, Result<[Article], any Error>).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    do { return (i, .success(try parse(try await get(url)))) } catch { return (i, .failure(error)) }
                }
            }
            for await (i, result) in group {
                switch result {
                case .success(let found): answers[i] = found
                case .failure(let error): errors.append(error)
                }
            }
        }
        if errors.count == urls.count, let first = errors.first { throw first }
        return answers
    }

    /// The articles in a Bing News RSS answer, in its order; one with no usable link, title or date is left out. Throws when it
    /// isn't XML.
    static func parse(_ data: Data) throws -> [Article] {
        try TopicXML.entries(data).compactMap { e in
            guard let link = e["link"], let url = articleURL(fromBingLink: link), let title = e["title"], !title.isEmpty,
                  let published = e["pubDate"].flatMap(FeedParsingSupport.date(from:)) else { return nil }
            return Article(
                title: title, url: url, publisher: e["News:Source"].flatMap { $0.isEmpty ? nil : $0 },
                summary: e["description"].flatMap { $0.isEmpty ? nil : $0 }, published: published,
                imageUrl: e["News:Image"].flatMap { thumbnail($0, size: e["News:ImageSize"]) })
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

    /// A picture's address at the size we draw it: Bing's `News:Image` is the picture's id and `News:ImageSize` a template
    /// ("w={0}&h={1}&c=14") to fill with the size. An address that isn't Bing's (or has no template) is used as it is.
    static func thumbnail(_ image: String, size: String?) -> String? {
        guard var c = URLComponents(string: image.trimmingCharacters(in: .whitespacesAndNewlines)), let host = c.host?.lowercased(),
              ["http", "https"].contains(c.scheme?.lowercased() ?? "") else { return nil }
        guard host == "bing.com" || host.hasSuffix(".bing.com"), let size, !size.isEmpty else { return c.string }
        c.scheme = "https"
        let filled = size.replacingOccurrences(of: "{0}", with: String(imageWidth)).replacingOccurrences(of: "{1}", with: String(imageHeight))
        guard let extra = URLComponents(string: "?" + filled)?.queryItems else { return c.string }
        c.queryItems = (c.queryItems ?? []) + extra
        return c.string
    }
}
