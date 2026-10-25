import Foundation

/// Posts on X (port of extractTweet / tweetFromPage in src/lib/extract.ts). The status page is server-rendered with
/// the post's data as an escaped JSON blob: the full text (long posts under NoteTweet) and the t.co expansions.
/// The official oEmbed is the fallback; it truncates long posts. The reader styles the x-* classes.
enum TweetExtraction {
    typealias P = ExtractionDOM.Pattern
    typealias DOM = ExtractionDOM

    static let tweetURL = P(#"^https?://(?:www\.|mobile\.)?(?:twitter|x)\.com/([^/]+)/status/(\d+)"#, caseInsensitive: true)
    private static let userPattern = P(#"(?:\\"avatar\\":\{\\"image_url\\":\\"([^"\\]*)\\"\},)?\\"core\\":\{\\"name\\":\\"((?:\\\\.|[^\\])*?)\\",\\"screen_name\\":\\"([A-Za-z0-9_]+)\\""#)
    private static let datePattern = P(#"\\"created_at_ms\\":(\d{10,})"#)
    private static let linkPattern = P(#"\\"display_url\\":\\"([^"\\]*)\\",\\"expanded_url\\":\\"([^"\\]*)\\",\\"indices\\":\[\d+,\d+\],\\"url\\":\\"([^"\\]*)\\""#)
    private static let ogTitle = P(#"<meta property="og:title" content="([^"]*?)(?: \(@[^)]*\))?(?: on X)?""#)
    private static let cardImage = P(#"\\"key\\":\\"thumbnail_image_large\\",\\"value\\":\{\\"image_value\\":\{\\"height\\":\d+,\\"url\\":\\"([^"\\]*)\\""#)
    private static let restID = P(#"\\"rest_id\\":\\"(\d+)\\""#)
    private static let normalAvatar = P(#"_normal(\.\w+)$"#)
    private static let inlineToken = P(#"https?://\S+|@[A-Za-z0-9_]{1,15}"#)
    private static let blankLine = P(#"\n\s*\n"#)

    struct User: Equatable {
        var name: String
        var handle: String
        var avatar: String?
    }

    typealias Links = [String: (display: String, expanded: String)]

    /// Two layers: a JSON string literal holding JSON-escaped text.
    static func unescapeTwice(_ s: String) -> String? {
        guard let inner = ExtractionPayload.jsonString("\"\(s)\"") else { return nil }
        return ExtractionPayload.jsonString("\"\(inner)\"")
    }

    private static func ns(_ s: String) -> NSString { s as NSString }

    /// A JSON string value embedded in X's escaped page data: `\"key\":\"...\"`, at or after UTF-16 offset `from`.
    static func escapedJSONString(_ raw: String, key: String, from: Int = 0) -> String? {
        let p = P(#"\\""# + NSRegularExpression.escapedPattern(for: key) + #"\\":\\"((?:\\\\.|[^\\])*?)\\""#)
        guard let m = p.firstMatch(raw, from: from), let v = m[1] else { return nil }
        return unescapeTwice(v)
    }

    private static func slice(_ raw: String, _ from: Int, _ to: Int) -> String {
        let n = ns(raw)
        let lo = max(0, min(from, n.length)), hi = max(lo, min(to, n.length))
        return n.substring(with: NSRange(location: lo, length: hi - lo))
    }

    /// Post text within [from, to): long posts keep the full text under NoteTweet.
    static func tweetText(_ raw: String, from: Int, to: Int) -> String? {
        let region = slice(raw, from, to)
        let note = ns(region).range(of: #"\"NoteTweet\""#)
        let noteText = note.location != NSNotFound ? escapedJSONString(region, key: "text", from: note.location) : nil
        return noteText ?? escapedJSONString(region, key: "full_text")
    }

    /// X account data after `from`: avatar, name and handle sit together in the page data.
    static func tweetUser(_ raw: String, from: Int) -> User? {
        guard let m = userPattern.firstMatch(raw, from: from), let rawName = m[2], let handle = m[3],
              let name = unescapeTwice(rawName) else { return nil }
        let avatar = m[1].map { normalAvatar.replacing($0, with: "_bigger$1") }
        return User(name: name, handle: handle, avatar: avatar)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    /// `\"created_at_ms\":1792865465000` after `from`, as a date line ("Oct 25, 2026", UTC).
    static func tweetDate(_ raw: String, from: Int) -> String? {
        guard let m = datePattern.firstMatch(raw, from: from), let ms = m[1].flatMap({ Double($0) }) else { return nil }
        return dateFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// A string binding of the post's link card.
    static func cardString(_ card: String, key: String) -> String? {
        let p = P(#"\\"key\\":\\""# + NSRegularExpression.escapedPattern(for: key) + #"\\",\\"value\\":\{\\"string_value\\":\\"((?:\\\\.|[^\\])*?)\\""#)
        guard let m = p.firstMatch(card), let v = m[1] else { return nil }
        return unescapeTwice(v)
    }

    static func whoHTML(_ u: User, date: String?) -> String {
        let av = u.avatar.map { "<img class=\"x-avatar\" src=\"\(DOM.escapeAttr($0))\" alt=\"\">" } ?? ""
        let when = date.map { "<span class=\"x-when\">· \(DOM.escapeHTML($0))</span>" } ?? ""
        return "<div class=\"x-who\">\(av)<span class=\"x-name\">\(DOM.escapeHTML(u.name))</span><a class=\"x-handle\" href=\"https://x.com/\(u.handle)\">@\(u.handle)</a>\(when)</div>"
    }

    static func bodyHTML(_ text: String, links: Links, drop: String? = nil) -> String {
        let marker = "\u{1F}"
        let paras = blankLine.replacing(text, with: marker).components(separatedBy: marker).map { p -> String in
            var s = p
            if let drop, !drop.isEmpty, let r = s.range(of: drop) { s.removeSubrange(r) }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return "<div class=\"x-body\">\(paras.map { "<p>\(tweetInline($0, links: links))</p>" }.joined())</div>"
    }

    /// Escape a paragraph of post text; link URLs (t.co expanded) and @mentions; keep line breaks.
    static func tweetInline(_ p: String, links: Links) -> String {
        let n = ns(p)
        var out = ""
        var last = 0
        func plain(_ s: String) -> String { DOM.escapeHTML(s).replacingOccurrences(of: "\n", with: "<br>") }
        for m in inlineToken.regex.matches(in: p, range: NSRange(location: 0, length: n.length)) {
            out += plain(n.substring(with: NSRange(location: last, length: m.range.location - last)))
            let tok = n.substring(with: m.range)
            if tok.hasPrefix("@") {
                out += "<a href=\"https://x.com/\(tok.dropFirst())\">\(tok)</a>"
            } else {
                let l = links[tok]
                out += "<a href=\"\(DOM.escapeAttr(l?.expanded ?? tok))\">\(DOM.escapeHTML(l?.display ?? tok))</a>"
            }
            last = m.range.location + m.range.length
        }
        out += plain(n.substring(from: last))
        return out
    }

    /// A post rendered as a post from the status page HTML: author row, text, the quoted post as a card, the link
    /// card, a footer. Pure; nil when the page carries no post text.
    static func fromPage(raw: String, canonical: String, user: String) -> ExtractResult? {
        let rawNS = ns(raw)
        // The quoted post's data is nested inside the main post's, after its own fields.
        let qiRange = rawNS.range(of: #"\"quoted_tweet_results\""#)
        let qi = qiRange.location == NSNotFound ? -1 : qiRange.location
        let end = qi >= 0 ? qi : rawNS.length
        guard let text = tweetText(raw, from: 0, to: end), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var links: Links = [:]
        for m in linkPattern.allMatches(raw) {
            if let display = m[1], let expanded = m[2], let url = m[3] { links[url] = (display, expanded) }
        }
        let ogName = ogTitle.firstMatch(raw)?[1] ?? nil
        let author = tweetUser(raw, from: 0) ?? User(name: ogName ?? "@\(user)", handle: user, avatar: nil)

        // Link card (main post only: its data comes before the quoted post's).
        var card = ""
        var cardURL: String?
        let ciRange = rawNS.range(of: #"\"binding_values\""#)
        if ciRange.location != NSNotFound, ciRange.location < end {
            let ci = ciRange.location
            let region = slice(raw, ci, min(ci + 6000, end))
            let title = cardString(region, key: "title")
            let domain = cardString(region, key: "vanity_url") ?? cardString(region, key: "domain")
            cardURL = cardString(region, key: "card_url")
            let img = cardImage.firstMatch(region)?[1] ?? nil
            let href = cardURL.flatMap { links[$0]?.expanded } ?? cardURL
            if let title, let href {
                let pic = img.map { "<img class=\"x-card-img\" src=\"\(DOM.escapeAttr($0))\" alt=\"\">" } ?? ""
                let shownDomain = domain ?? DOM.hostname(href) ?? ""
                card = "<a class=\"x-card\" href=\"\(DOM.escapeAttr(href))\">\(pic)<span class=\"x-card-text\"><span class=\"x-card-domain\">\(DOM.escapeHTML(shownDomain))</span><span class=\"x-card-title\">\(DOM.escapeHTML(title))</span></span></a>"
            }
        }

        var quoted = ""
        if qi >= 0 {
            let qid = restID.firstMatch(slice(raw, qi, qi + 400))?[1] ?? nil
            if let qu = tweetUser(raw, from: qi), let qt = tweetText(raw, from: qi, to: rawNS.length),
               !qt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let href = qid.map { "https://x.com/\(qu.handle)/status/\($0)" } ?? "https://x.com/\(qu.handle)"
                quoted = "<div class=\"x-quote\">\(whoHTML(qu, date: tweetDate(raw, from: qi)))\(bodyHTML(qt, links: links))<a class=\"x-quote-link\" href=\"\(href)\">View post</a></div>"
            }
        }

        let foot = "<div class=\"x-foot\"><span>\(DOM.escapeHTML(tweetDate(raw, from: 0) ?? ""))</span><a class=\"x-open\" href=\"\(canonical)\">Open on X</a></div>"
        let html = ArticleSanitizer.sanitize(
            "<div class=\"x-post\">\(whoHTML(author, date: nil))\(bodyHTML(text, links: links, drop: card.isEmpty ? nil : cardURL))\(quoted)\(card)\(foot)</div>"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return html.isEmpty ? nil : ExtractResult(contentHtml: html, leadImage: nil)
    }

    /// The oEmbed fallback's HTML → a blockquote and a byline. Pure.
    static func fromOEmbed(html: String, authorName: String?, authorURL: String?, canonical: String) -> ExtractResult? {
        guard let inner = DOM.withFragment(html, { DOM.first($0, "blockquote p").map(DOM.innerHTML) }) ?? nil else { return nil }
        guard !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let by = authorName.map { "<p><a href=\"\(DOM.escapeAttr(authorURL ?? canonical))\">\(DOM.escapeHTML($0))</a> on X</p>" } ?? ""
        let out = ArticleSanitizer.sanitize("<blockquote><p>\(inner)</p></blockquote>\(by)").trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : ExtractResult(contentHtml: out, leadImage: nil)
    }

    /// The post at `url`, or nil when `url` is not an X status URL or nothing could be read.
    static func extract(url: String, timeout: TimeInterval, session: URLSession = HTTP.session) async throws -> ExtractResult? {
        guard let m = tweetURL.firstMatch(url), let user = m[1], let id = m[2] else { return nil }
        let canonical = "https://x.com/\(user)/status/\(id)"
        if let (data, res) = try? await HTTP.fetch(canonical, timeout: timeout, headers: HTTP.browserHeaders, session: session),
           (200..<300).contains(res.statusCode),
           let page = fromPage(raw: HTTP.text(data, response: res), canonical: canonical, user: user) {
            return page
        }
        let api = "https://publish.twitter.com/oembed?url=\(DOM.encodeURIComponent(canonical))&omit_script=true&dnt=true"
        let (data, res) = try await HTTP.fetch(api, timeout: timeout, headers: ["Accept": "application/json"], session: session)
        guard (200..<300).contains(res.statusCode),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let html = obj["html"] as? String, !html.isEmpty else { return nil }
        return fromOEmbed(html: html, authorName: obj["author_name"] as? String, authorURL: obj["author_url"] as? String, canonical: canonical)
    }
}
