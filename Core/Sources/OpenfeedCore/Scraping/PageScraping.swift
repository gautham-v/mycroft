import Foundation
import SwiftSoup

/// Per-article fields from Open Graph, JSON-LD, <title> and <time> (port of `ArticleMeta`, scrape.ts).
public struct ArticleMeta: Sendable, Hashable {
    public var title: String?
    public var summary: String?
    public var author: String?
    public var publishedAt: Date?
    public var thumbnailUrl: String?
    /// og:type when present ("article", "website", ...), lowercased.
    public var ogType: String?
    /// A post on X that quotes another: the quoted account's avatar (pbs.twimg.com).
    public var quoteAvatarUrl: String?

    public init(title: String? = nil, summary: String? = nil, author: String? = nil, publishedAt: Date? = nil,
                thumbnailUrl: String? = nil, ogType: String? = nil, quoteAvatarUrl: String? = nil) {
        self.title = title
        self.summary = summary
        self.author = author
        self.publishedAt = publishedAt
        self.thumbnailUrl = thumbnailUrl
        self.ogType = ogType
        self.quoteAvatarUrl = quoteAvatarUrl
    }
}

/// Pure parts of src/lib/scrape.ts: picking article links off a listing page, the listing's title,
/// and per-article metadata. Scraped-page sources (kind `page`) are listing pages with no RSS/Atom
/// feed, e.g. https://www.anthropic.com/news.
public enum PageScraping {
    /// MAX_LINKS.
    public static let maxLinks = 30

    // MARK: - URLs

    /// Canonical form used as item url/guid and for "already seen" checks: origin + path,
    /// no hash, no query, no trailing slash (root stays "/").
    public static func canonicalURL(_ url: URL) -> String {
        let scheme = (url.scheme ?? "https").lowercased()
        let host = (url.host(percentEncoded: true) ?? "").lowercased()
        return "\(scheme)://\(host)\(portSuffix(url, scheme: scheme))\(trimmedPath(url))"
    }

    /// canonicalUrl(new URL(string)); nil when the string isn't an absolute URL.
    public static func canonicalURL(_ string: String) -> String? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil, url.host() != nil
        else { return nil }
        return canonicalURL(url)
    }

    private static func portSuffix(_ url: URL, scheme: String) -> String {
        guard let port = url.port else { return "" }
        if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) { return "" }
        return ":\(port)"
    }

    private static func trimmedPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: true)
        while path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    private static func bareHost(_ h: String) -> String {
        let l = h.lowercased()
        return l.hasPrefix("www.") ? String(l.dropFirst(4)) : l
    }

    private static let xHost = ScrapingText.regex(#"^(?:www\.|mobile\.)?(?:x|twitter)\.com$"#, [.caseInsensitive])
    private static let tweetPath = ScrapingText.regex(#"^/[^/]+/status/\d+$"#)

    /// X / Twitter hosts: the server-rendered profile HTML lists posts as /<user>/status/<id>.
    public static func isXHost(_ host: String) -> Bool { ScrapingText.test(xHost, host) }

    private static func isTweetPath(_ path: String) -> Bool { ScrapingText.test(tweetPath, path) }

    // MARK: - Link heuristics

    /// Path segments that are listing furniture, not articles.
    private static let stopSegments: Set<String> = [
        "page", "pages", "tag", "tags", "category", "categories", "topic", "topics", "author", "authors",
        "feed", "rss", "atom", "search", "archive", "archives", "all", "latest", "index", "subscribe",
        "login", "signup", "about", "contact", "privacy", "terms",
    ]
    private static let locales = Set(
        "ar bg cs da de el en es et fa fi fr he hi hr hu id it ja ko lt lv ms nb nl no pl pt ro ru sk sl sr sv th tr uk vi zh"
            .split(separator: " ").map(String.init))
    private static let localeShape = ScrapingText.regex(#"^[a-z]{2}(?:[-_][a-z]{2,4})?$"#, [.caseInsensitive])
    private static let fileExt = ScrapingText.regex(#"\.(xml|json|rss|atom|pdf|zip|png|jpe?g|gif|webp|svg|ico|css|js|mp3|mp4)$"#, [.caseInsensitive])
    /// Hyphenated words, at least one letter: "claude-duet", "2026-us-midterms".
    private static let slug = ScrapingText.regex(#"^(?=.*[a-z])[a-z0-9]+(?:[-_][a-z0-9]+)+$"#, [.caseInsensitive])
    private static let pagination = ScrapingText.regex(#"^\d{1,3}$"#)
    private static let strictLast = ScrapingText.regex(#"[a-z]|\d{4,}"#, [.caseInsensitive])
    private static let lettersOnly = ScrapingText.regex(#"^[a-z]+$"#)
    private static let skipHref = ScrapingText.regex(#"^(#|mailto:|tel:|javascript:|data:)"#, [.caseInsensitive])
    private static let wordRun = ScrapingText.regex(#"[a-z0-9]+"#)

    /// "de", "pt-br", "zh_hans".
    private static func isLocale(_ seg: String) -> Bool {
        let head = seg.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return locales.contains(head) && ScrapingText.test(localeShape, seg)
    }

    private static func words(_ s: String) -> [String] {
        ScrapingText.allGroups(wordRun, s.lowercased(), group: 0)
    }

    struct Link {
        var url: String
        /// Path segments, percent-decoded.
        var segs: [String]
        var texts: [String]
        var order: Int
        var last: String { segs.last ?? "" }
    }

    /// Same-host links on the page keyed by canonical URL, first occurrence order, anchor texts merged.
    static func collectLinks(_ doc: Document, pageURL: URL) -> [Link] {
        let pageHost = pageURL.host(percentEncoded: true) ?? ""
        var base = pageURL
        if let baseHref = try? doc.select("base[href]").first()?.attr("href"),
           let b = URL(string: baseHref.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: pageURL)?.absoluteURL {
            base = b
        }
        var out: [Link] = []
        var index: [String: Int] = [:]
        guard let anchors = try? doc.select("a[href]") else { return [] }
        for a in anchors {
            let href = ((try? a.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if href.isEmpty || ScrapingText.test(skipHref, href) { continue }
            // decodeURIComponent throws on malformed escapes; Foundation would quietly re-encode the "%".
            let hrefPath = href.prefix { $0 != "?" && $0 != "#" }
            if hrefPath.contains("%"), String(hrefPath).removingPercentEncoding == nil { continue }
            guard let resolved = URL(string: href, relativeTo: base)?.absoluteURL.standardized,
                  let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = resolved.host(percentEncoded: true), bareHost(host) == bareHost(pageHost)
            else { continue }
            let rawSegs = resolved.path(percentEncoded: true).split(separator: "/").map(String.init)
            var decoded: [String] = []
            var ok = true
            for s in rawSegs {
                guard let d = s.removingPercentEncoding else { ok = false; break }
                decoded.append(d)
            }
            if !ok { continue }
            // Normalise to the listing's host so www/non-www variants dedupe.
            var c = URLComponents(url: resolved, resolvingAgainstBaseURL: true)
            c?.host = pageURL.host()
            guard let normalized = c?.url else { continue }
            let key = canonicalURL(normalized)
            let text = ScrapingText.collapse((try? a.text()) ?? "")
            if let i = index[key] {
                if !text.isEmpty { out[i].texts.append(text) }
            } else {
                index[key] = out.count
                out.append(Link(url: key, segs: decoded, texts: text.isEmpty ? [] : [text], order: out.count))
            }
        }
        return out
    }

    /// Nav/category links: a one-word slug whose anchor text is just that word ("/news/policy" → "Policy").
    private static func isLabelLink(_ l: Link) -> Bool {
        let last = l.last.lowercased()
        guard ScrapingText.test(lettersOnly, last) else { return false }
        var longest = ""
        for t in l.texts where t.count > longest.count { longest = t }
        let w = words(longest)
        return w.isEmpty || (w.count <= 2 && w.contains(last))
    }

    private static func isExcluded(_ l: Link, listingSegs: [String]) -> Bool {
        let last = l.last
        if last.isEmpty { return true }
        if stopSegments.contains(last.lowercased()) || ScrapingText.test(fileExt, last) { return true }
        if ScrapingText.test(pagination, last) { return true }  // pagination ("/news/2")
        if l.segs.contains(where: { stopSegments.contains($0.lowercased()) && !listingSegs.contains($0) }) { return true }
        // Localized copies: "/de/resources/articles/..." when the listing isn't under "/de".
        if let first = l.segs.first, isLocale(first), first != listingSegs.first, l.segs.count > 1 { return true }
        return isLabelLink(l)
    }

    /// Article-like links on a listing page, in page order (max 30).
    /// Strict: same-origin paths one segment below the listing path (/news → /news/<slug>).
    /// Fallback: the most common parent path among same-origin links with a slug-like last segment.
    public static func findArticleLinks(html: String, pageURL: String) -> [String] {
        guard let page = URL(string: pageURL), page.host() != nil, let doc = try? SwiftSoup.parse(html, pageURL) else { return [] }
        return articleLinks(doc, page: page)
    }

    static func articleLinks(_ doc: Document, page: URL) -> [String] {
        let all = collectLinks(doc, pageURL: page)
        if isXHost(page.host() ?? "") {
            // Only posts: profile tabs (/user/media, /user/with_replies) and compose links are furniture.
            return all.filter { l in URL(string: l.url).map { isTweetPath($0.path(percentEncoded: true)) } ?? false }
                .prefix(maxLinks).map(\.url)
        }
        let listingSegs = page.path(percentEncoded: true).split(separator: "/").map(String.init)
        let listingKey = listingSegs.joined(separator: "/")
        let links = all.filter { !$0.segs.isEmpty && !isExcluded($0, listingSegs: listingSegs) }

        // At the site root every nav link is one segment below the listing, so only the fallback applies there.
        if !listingSegs.isEmpty {
            let strict = links.filter { l in
                l.segs.count == listingSegs.count + 1
                    && l.segs.dropLast().joined(separator: "/") == listingKey
                    && ScrapingText.test(strictLast, l.last)
            }
            if !strict.isEmpty { return strict.prefix(maxLinks).map(\.url) }
        }

        var groups: [String: [Link]] = [:]
        var groupOrder: [String] = []
        for l in links where ScrapingText.test(slug, l.last) {
            let prefix = l.segs.dropLast().joined(separator: "/")
            if groups[prefix] == nil { groupOrder.append(prefix) }
            groups[prefix, default: []].append(l)
        }
        var best: [Link] = []
        for key in groupOrder {
            guard let g = groups[key], let first = g.first else { continue }
            if g.count > best.count || (g.count == best.count && first.order < (best.first?.order ?? Int.max)) { best = g }
        }
        return best.count >= 2 ? best.prefix(maxLinks).map(\.url) : []
    }

    // MARK: - Titles

    private static let titleSep = ScrapingText.regex(#"\s+[|\\·•—–-]\s+"#)

    private static func titleText(_ doc: Document) -> String {
        ScrapingText.collapse((try? doc.select("title").first()?.text()) ?? "")
    }

    /// Source title for a listing page: "Claude Articles", "Anthropic Newsroom".
    public static func listingTitle(html: String, pageURL: String) -> String {
        let host = URL(string: pageURL)?.host() ?? ""
        guard let doc = try? SwiftSoup.parse(html, pageURL) else { return bareHost(host) }
        let meta = PageMeta.meta(in: doc)
        let og = meta("og:title")
        let site = meta("og:site_name")
        // "Kun Chen (@kunchenguid) on X" already names the site.
        if let og, isXHost(host) { return og }
        if let og, let site, !og.lowercased().contains(site.lowercased()) { return "\(site) \(og)" }
        let raw = titleText(doc)
        let parts = ScrapingText.split(raw, by: titleSep).filter { !$0.isEmpty }
        if parts.count == 2, parts[1].split(separator: " ", omittingEmptySubsequences: false).count <= 3 {
            return "\(parts[1]) \(parts[0])"
        }
        return og ?? (raw.isEmpty ? bareHost(host) : raw)
    }

    // MARK: - Article metadata

    private static let urlLike = ScrapingText.regex(#"^https?://"#)

    /// ldAuthor: person names joined; publisher-as-author (Organization) and URLs dropped.
    private static func ldAuthor(_ v: Any?) -> String? {
        guard let v, !(v is NSNull) else { return nil }
        let list: [Any] = (v as? [Any]) ?? [v]
        let names = list.compactMap { a -> String? in
            if let o = a as? [String: Any] {
                if (o["@type"] as? String) == "Organization" { return nil }
                return ScrapingText.str(o["name"])
            }
            return ScrapingText.str(a)
        }.filter { !ScrapingText.test(urlLike, $0) }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private static func firstAttr(_ doc: Document, _ selector: String, _ attr: String) -> String? {
        guard let el = try? doc.select(selector).first() else { return nil }
        return try? el.attr(attr)
    }

    /// Per-article fields from Open Graph, JSON-LD, <title> and <time>. Pure; no network.
    public static func extractArticleMeta(html: String, pageURL: String, now: Date = Date()) -> ArticleMeta {
        guard let doc = try? SwiftSoup.parse(html, pageURL) else { return ArticleMeta() }
        let meta = PageMeta.meta(in: doc)
        if let page = URL(string: pageURL), isXHost(page.host() ?? ""), isTweetPath(page.path(percentEncoded: true)) {
            return tweetMeta(meta, html: html, now: now)
        }
        let ld = PageMeta.ldArticle(in: doc)
        let docTitle = titleText(doc)
        let h1 = ScrapingText.collapse((try? doc.select("h1").first()?.text()) ?? "")
        let docParts = ScrapingText.split(docTitle, by: titleSep)
        let docFirst = docParts.first ?? ""
        let raw = meta("og:title", "twitter:title") ?? ScrapingText.str(ld?["headline"])
            ?? (h1.isEmpty ? nil : h1) ?? (docFirst.isEmpty ? nil : docFirst)
        // Drop a trailing site name: "Singapore office opening | Anthropic".
        let sites = [meta("og:site_name"), docParts.count > 1 ? docParts.last : nil].compactMap { $0?.lowercased() }
        var title = raw
        if let raw {
            let parts = ScrapingText.split(raw, by: titleSep)
            if parts.count > 1, let last = parts.last, sites.contains(last.lowercased()) {
                title = parts.dropLast().joined(separator: " | ")
            }
        }
        let published = PageMeta.toDate(meta("article:published_time", "og:published_time"), now: now)
            ?? PageMeta.toDate(ScrapingText.str(ld?["datePublished"]), now: now)
            ?? PageMeta.toDate(meta("datepublished", "date", "pubdate", "publish-date", "parsely-pub-date", "dc.date", "dc.date.issued"), now: now)
            ?? PageMeta.toDate(firstAttr(doc, "article time[datetime]", "datetime"), now: now)
            ?? PageMeta.toDate(firstAttr(doc, "time[datetime]", "datetime"), now: now)
        let author = meta("author", "parsely-author") ?? ldAuthor(ld?["author"])
        return ArticleMeta(
            title: ScrapingText.clip(title, 300),
            summary: ScrapingText.clip(meta("og:description", "description", "twitter:description") ?? ScrapingText.str(ld?["description"]), 400),
            author: author.flatMap { ScrapingText.test(urlLike, $0) ? nil : ScrapingText.clip($0, 120) },
            publishedAt: published,
            thumbnailUrl: PageMeta.pageImage(meta, ld: ld, pageURL: pageURL),
            ogType: meta("og:type")?.lowercased()
        )
    }

    private static let paragraphBreak = ScrapingText.regex(#"\n\s*\n"#)
    private static let onX = ScrapingText.regex(#"\s+on X$"#, [.caseInsensitive])
    private static let quotedName = ScrapingText.regex(#"\\"core\\":\{\\"name\\":\\"((?:\\\\.|[^\\])*?)\\",\\"screen_name\\""#)
    private static let quotedText = ScrapingText.regex(#"\\"full_text\\":\\"((?:\\\\.|[^\\])*?)\\""#)
    private static let quotedAvatar = ScrapingText.regex(#"\\"avatar\\":\{\\"image_url\\":\\"(https://pbs\.twimg\.com/[^\\"]+)\\""#)

    /// A post on X: og:title is the author ("Kun Chen (@kunchenguid) on X") and the post text is the
    /// description. The first paragraph is the headline; the summary names a quoted post, and the quoted
    /// account's avatar comes along. No thumbnail.
    private static func tweetMeta(_ meta: PageMeta.Reader, html: String, now: Date) -> ArticleMeta {
        let text = meta("og:description", "description", "twitter:description")
        let first = text.map { ScrapingText.split($0, by: paragraphBreak).first ?? $0 }
        let author = meta("og:title").map { ScrapingText.replace(onX, in: $0, with: "") }
        var summary: String?
        var quoteAvatar: String?
        if let qi = html.range(of: #"\"quoted_tweet_results\""#) {
            let tail = String(html[qi.lowerBound...])
            if let qn = ScrapingText.firstGroups(quotedName, tail)?[1], let qt = ScrapingText.firstGroups(quotedText, tail)?[1],
               let name = ScrapingText.jsonStringLiteral(qn).flatMap(ScrapingText.jsonStringLiteral),
               let full = ScrapingText.jsonStringLiteral(qt).flatMap(ScrapingText.jsonStringLiteral) {
                let line = full.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? full
                summary = ScrapingText.clip("Quoting \(name): \(line)", 200)
                quoteAvatar = ScrapingText.firstGroups(quotedAvatar, tail)?[1]
            }
        }
        return ArticleMeta(
            title: ScrapingText.clip(first, 140) ?? ScrapingText.clip(meta("og:title"), 300),
            summary: summary,
            author: ScrapingText.clip(author, 120),
            publishedAt: PageMeta.toDate(meta("article:published_time"), now: now),
            thumbnailUrl: nil,
            ogType: "article",
            quoteAvatarUrl: quoteAvatar
        )
    }
}
