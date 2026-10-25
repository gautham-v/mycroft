import Foundation

/// Port of src/lib/dedupe.ts: dedupe a feed batch before the upsert. The guid is the primary identity
/// (unique per source in the DB), but aggregators like Hacker News give each *submission* its own guid,
/// so the same story submitted twice arrives as two items with one link. Pure; no network.
public enum FeedDedupe {
    /// A link shared by this many items (stored + incoming) is a feed-wide link, not a story.
    public static let sharedLinkMin = 3

    /// Query params that only track the click, never change the page (TRACKING_PARAM).
    private static let trackingParam = try? NSRegularExpression(
        pattern: "^(utm_\\w+|fbclid|gclid|dclid|msclkid|mc_cid|mc_eid|igshid|ref_src)$", options: [.caseInsensitive])
    private static let nonWord = try? NSRegularExpression(pattern: "[^\\p{L}\\p{N}]+")

    private static func isTracking(_ key: String) -> Bool {
        guard let re = trackingParam else { return false }
        return re.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    /// Comparison key for "same page": scheme, www., default port, trailing slash, tracking params and
    /// in-page anchors ignored; remaining params sorted. Nil for unparseable URLs and for bare site roots,
    /// which many items legitimately share.
    public static func linkKey(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URLComponents(string: trimmed), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", var host = u.host?.lowercased(), !host.isEmpty
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = u.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }

        let params = parseQuery(u.percentEncodedQuery)
            .enumerated()
            .filter { !isTracking($0.element.0) }
            .sorted { a, b in
                let c = a.element.0.compare(b.element.0, locale: Locale(identifier: "en"))
                return c == .orderedSame ? a.offset < b.offset : c == .orderedAscending
            }
            .map(\.element)
        let query = params.isEmpty ? "" : "?" + params.map { formEncode($0.0) + "=" + formEncode($0.1) }.joined(separator: "&")

        // "#/route" and "#!/route" are SPA pages; any other hash is an anchor within one page.
        var hash = ""
        if let f = u.percentEncodedFragment, f.hasPrefix("/") || f.hasPrefix("!/") { hash = "#" + f }
        if path.isEmpty && query.isEmpty && hash.isEmpty { return nil }

        var port = ""
        if let p = u.port, !((scheme == "http" && p == 80) || (scheme == "https" && p == 443)) { port = ":\(p)" }
        return "\(host)\(port)\(path)\(query)\(hash)"
    }

    /// Title comparison key: lowercased, runs of non-letters/digits collapsed to one space, trimmed.
    public static func titleKey(_ title: String) -> String {
        let lower = title.lowercased()
        guard let re = nonWord else { return lower }
        return re.stringByReplacingMatches(in: lower, range: NSRange(lower.startIndex..., in: lower), withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Drop incoming items that repeat a guid, or that repeat a stored or earlier item's link. Items whose
    /// guid is already stored always pass, so their row keeps updating. `linkOnly` (aggregators): one link is
    /// one story whatever the title; elsewhere a shared link only counts when the title matches too (a
    /// republish under a new guid), and links shared by `sharedLinkMin`+ items are left alone. Items linking
    /// to `siteURL` are never deduped by link. Among new duplicates the most HN points wins, then feed order.
    /// Output keeps feed order (first appearance of each guid; the last copy of a repeated guid wins, like a JS Map).
    public static func dedupe(_ incoming: [ParsedItem], stored: [StoredItemKey] = [], linkOnly: Bool = false, siteURL: String? = nil) -> [ParsedItem] {
        let storedGuids = Set(stored.map(\.guid))
        let siteKey = siteURL.flatMap { linkKey($0) }

        // Guid first: one statement must not touch a row twice.
        var order: [String] = []
        var latest: [String: ParsedItem] = [:]
        for it in incoming {
            if latest[it.guid] == nil { order.append(it.guid) }
            latest[it.guid] = it
        }
        let byGuid = order.compactMap { latest[$0] }

        func keyOf(url: String, title: String) -> String? {
            guard let k = linkKey(url), k != siteKey else { return nil }
            return linkOnly ? k : "\(k) \(titleKey(title))"
        }

        // Distinct guids per link (by link alone, so a feed-wide link is spotted even when titles differ).
        var guidsPerLink: [String: Set<String>] = [:]
        for (guid, url) in stored.map({ ($0.guid, $0.url) }) + byGuid.map({ ($0.guid, $0.url) }) {
            guard let k = linkKey(url) else { continue }
            guidsPerLink[k, default: []].insert(guid)
        }
        // Aggregators have no feed-wide links (an Ask HN post links to its own HN page).
        func shared(_ url: String) -> Bool {
            !linkOnly && (guidsPerLink[linkKey(url) ?? ""]?.count ?? 0) >= sharedLinkMin
        }

        var claimed = Set<String>()
        for s in stored {
            if let k = keyOf(url: s.url, title: s.title), !shared(s.url) { claimed.insert(k) }
        }

        var keep = Set<Int>()
        // Rows we already have claim their link before any new item can.
        for (i, it) in byGuid.enumerated() where storedGuids.contains(it.guid) {
            keep.insert(i)
            if let k = keyOf(url: it.url, title: it.title) { claimed.insert(k) }
        }
        let fresh = byGuid.enumerated()
            .filter { !storedGuids.contains($0.element.guid) }
            .sorted { a, b in
                let pa = a.element.hnPoints ?? 0, pb = b.element.hnPoints ?? 0
                return pa != pb ? pa > pb : a.offset < b.offset
            }
        for (i, it) in fresh {
            if let k = keyOf(url: it.url, title: it.title), !shared(it.url) {
                if claimed.contains(k) { continue }
                claimed.insert(k)
            }
            keep.insert(i)
        }
        return byGuid.enumerated().filter { keep.contains($0.offset) }.map(\.element)
    }

    // MARK: URLSearchParams semantics

    /// application/x-www-form-urlencoded parse: split on "&", skip empty pieces, "+" is a space, percent-decode.
    private static func parseQuery(_ query: String?) -> [(String, String)] {
        guard let query, !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { piece in
            let parts = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (s: Substring) -> String in
                let spaced = s.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            return (decode(parts[0]), parts.count > 1 ? decode(parts[1]) : "")
        }
    }

    private static let formAllowed: CharacterSet = {
        var s = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        s.insert(charactersIn: "*-._ ")
        return s
    }()

    /// URLSearchParams.toString byte serializer: alphanumerics and `*-._` kept, space as "+", rest %XX.
    private static func formEncode(_ s: String) -> String {
        (s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s).replacingOccurrences(of: " ", with: "+")
    }
}
