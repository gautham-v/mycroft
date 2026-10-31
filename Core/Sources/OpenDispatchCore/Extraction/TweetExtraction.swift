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
    private static let restID = P(#"\\"rest_id\\":\\"(\d+)\\""#)
    private static let normalAvatar = P(#"_normal(\.\w+)$"#)
    private static let inlineToken = P(#"https?://\S+|@[A-Za-z0-9_]{1,15}"#)
    private static let blankLine = P(#"\n\s*\n"#)
    private static let trailingTco = P(#"\s*(https://t\.co/\w+)\s*$"#)

    struct User: Equatable {
        var name: String
        var handle: String
        var avatar: String?
    }

    typealias Links = [String: (display: String, expanded: String)]

    struct Media: Equatable {
        enum Kind: String { case photo, video, gif = "animated_gif" }
        var kind: Kind
        var url: String
        var poster: String?
        var width: Int?
        var height: Int?
        /// Alt text (other networks' photos carry it).
        var alt: String?
        /// A small version for list thumbnails, where the network has one.
        var thumb: String?
    }

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

    /// The UTF-16 offset of the bracket closing the one at `open` in X's escaped page data, or nil. Brackets
    /// inside string values (post text can hold them) don't count. The data is JSON inside a JSON string, so each
    /// `\x` pair is read as `x` first and the JSON underneath is scanned as usual.
    static func closing(_ n: NSString, open: Int) -> Int? {
        let o = n.character(at: open), c: unichar = o == 0x5B ? 0x5D : 0x7D
        var depth = 0, inString = false, escaped = false
        var i = open
        while i < n.length {
            let at = i
            var ch = n.character(at: i)
            if ch == 0x5C, i + 1 < n.length { i += 1; ch = n.character(at: i) }
            i += 1
            if inString {
                if escaped { escaped = false } else if ch == 0x5C { escaped = true } else if ch == 0x22 { inString = false }
            } else if ch == 0x22 {
                inString = true
            } else if ch == o {
                depth += 1
            } else if ch == c {
                depth -= 1
                if depth == 0 { return at }
            }
        }
        return nil
    }

    /// Post text within [from, to): long posts keep the full text under NoteTweet, after an `entity_set` whose
    /// cashtags and hashtags carry `text` keys of their own.
    static func tweetText(_ raw: String, from: Int, to: Int) -> String? {
        let region = slice(raw, from, to)
        let r = ns(region)
        var noteText: String?
        let note = r.range(of: #"\"NoteTweet\""#)
        if note.location != NSNotFound {
            var start = note.location
            let set = r.range(of: #"\"entity_set\":{"#, range: NSRange(location: start, length: r.length - start))
            if set.location != NSNotFound, let close = closing(r, open: set.location + set.length - 1) { start = close }
            noteText = escapedJSONString(region, key: "text", from: start)
        }
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
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a · MMM d, yyyy"
        return f
    }()

    /// A date line ("Oct 25, 2026") in the system time zone.
    static func dateLine(_ date: Date) -> String { dateFormatter.string(from: date) }

    /// The footer's time and date ("3:21 PM · Oct 25, 2026") in the system time zone.
    static func stampLine(_ date: Date) -> String { stampFormatter.string(from: date) }

    /// `\"created_at_ms\":1792865465000` after `from`.
    static func tweetTime(_ raw: String, from: Int) -> Date? {
        guard let m = datePattern.firstMatch(raw, from: from), let ms = m[1].flatMap({ Double($0) }) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// `tweetTime` as a date line.
    static func tweetDate(_ raw: String, from: Int) -> String? { tweetTime(raw, from: from).map(dateLine) }

    /// A string binding of the post's link card.
    static func cardString(_ card: String, key: String) -> String? {
        let p = P(#"\\"key\\":\\""# + NSRegularExpression.escapedPattern(for: key) + #"\\",\\"value\\":\{\\"string_value\\":\\"((?:\\\\.|[^\\])*?)\\""#)
        guard let m = p.firstMatch(card), let v = m[1] else { return nil }
        return unescapeTwice(v)
    }

    /// An image binding of the post's link card. The fields sort by name, so `alt` comes first on an image that has
    /// it, and `height` is not always there.
    static func cardImage(_ card: String, key: String) -> String? {
        let p = P(#"\\"key\\":\\""# + NSRegularExpression.escapedPattern(for: key) + #"\\",\\"value\\":\{\\"image_value\\":\{(?:\\"alt\\":\\"(?:\\\\.|[^\\])*?\\",)?(?:\\"height\\":\d+,)?\\"url\\":\\"([^"\\]*)\\""#)
        return p.firstMatch(card)?[1] ?? nil
    }

    /// Whether a card's headline says what the post already says, as when a site's post is its headline. By words,
    /// because the two are often worded a little differently ("you all", "y'all"). A short headline or a much longer
    /// post can share most of its words by chance, so those don't count.
    static func repeatsPost(headline: String, text: String) -> Bool {
        func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let title = words(headline), post = words(inlineToken.replacing(text, with: " "))
        guard title.count >= 4, post.count <= title.count * 2 else { return false }
        let known = Set(post)
        return Double(title.filter(known.contains).count) >= Double(title.count) * 0.8
    }

    /// The post's photos, videos and GIFs: the first `media_entities2` array in [from, to). Every post in the page
    /// data carries one (empty when it has no media), sorted before `quoted_tweet_results`.
    static func tweetMedia(_ raw: String, from: Int, to: Int) -> [Media] {
        let n = ns(raw)
        let key = n.range(of: #"\"media_entities2\":["#, range: NSRange(location: from, length: max(0, min(to, n.length) - from)))
        guard key.location != NSNotFound else { return [] }
        let open = key.location + key.length - 1
        guard let close = closing(n, open: open),
              let json = ExtractionPayload.jsonString("\"\(n.substring(with: NSRange(location: open, length: close - open + 1)))\""),
              let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let kind = (m["type"] as? String).flatMap(Media.Kind.init(rawValue:)),
                  let image = m["media_url_https"] as? String else { return nil }
            let info = m["original_info"] as? [String: Any]
            let width = info?["width"] as? Int, height = info?["height"] as? Int
            if kind == .photo {
                return Media(kind: kind, url: "\(image)?name=large", width: width, height: height)
            }
            let variants = ((m["video_info"] as? [String: Any])?["variants"] as? [[String: Any]]) ?? []
            let best = variants.filter { $0["content_type"] as? String == "video/mp4" }
                .max { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }
            guard let url = best?["url"] as? String else { return nil }
            return Media(kind: kind, url: url, poster: image, width: width, height: height)
        }
    }

    /// Media under the text: photos as images, videos with controls, GIFs as muted loops.
    static func mediaHTML(_ media: [Media]) -> String {
        guard !media.isEmpty else { return "" }
        let items = media.map { m -> String in
            let size = [m.width.map { " width=\"\($0)\"" }, m.height.map { " height=\"\($0)\"" }].compactMap { $0 }.joined()
            let poster = m.poster.map { " poster=\"\(DOM.escapeAttr($0))\"" } ?? ""
            switch m.kind {
            case .photo: return "<img src=\"\(DOM.escapeAttr(m.url))\" alt=\"\(DOM.escapeAttr(m.alt ?? ""))\"\(size)>"
            case .video: return "<video src=\"\(DOM.escapeAttr(m.url))\"\(poster)\(size) playsinline></video>"
            case .gif: return "<video src=\"\(DOM.escapeAttr(m.url))\"\(poster)\(size) autoplay loop muted playsinline></video>"
            }
        }
        return "<div class=\"x-media\(media.count > 1 ? " x-media-grid" : "")\">\(items.joined())</div>"
    }

    /// Post text with the t.co links X appends for attached media removed (they are not among the post's links).
    static func withoutMediaLinks(_ text: String, links: Links) -> String {
        var t = text
        while let m = trailingTco.firstMatchWithRange(t), let url = m.groups[1], links[url] == nil {
            t = ns(t).replacingCharacters(in: m.range, with: "")
        }
        return t
    }

    /// The author row. `profile` is the account's page where it isn't x.com/handle.
    static func whoHTML(_ u: User, date: String?, profile: String? = nil) -> String {
        let av = u.avatar.map { "<img class=\"x-avatar\" src=\"\(DOM.escapeAttr($0))\" alt=\"\">" } ?? ""
        let when = date.map { "<span class=\"x-when\">· \(DOM.escapeHTML($0))</span>" } ?? ""
        let handle = profile.map { "<a class=\"x-handle\" href=\"\(DOM.escapeAttr($0))\">@\(DOM.escapeHTML(u.handle))</a>" }
            ?? "<a class=\"x-handle\" href=\"https://x.com/\(u.handle)\">@\(u.handle)</a>"
        return "<div class=\"x-who\">\(av)<span class=\"x-name\">\(DOM.escapeHTML(u.name))</span>\(handle)\(when)</div>"
    }

    /// A link card: lead image, domain, title. `large` puts a full-width image above the text; otherwise it is a
    /// thumbnail beside it. With `imageSize`, a large card shows the whole image at its own shape instead of cropping it.
    static func cardHTML(href: String, title: String, domain: String?, image: String?, large: Bool = false, showsTitle: Bool = true,
                         imageSize: (width: Int, height: Int)? = nil) -> String {
        let size = imageSize.map { " width=\"\($0.width)\" height=\"\($0.height)\"" } ?? ""
        let pic = image.map { "<img class=\"x-card-img\(imageSize == nil ? "" : " x-card-whole")\" src=\"\(DOM.escapeAttr($0))\"\(size) alt=\"\">" } ?? ""
        let shownDomain = domain ?? DOM.hostname(href) ?? ""
        let shownTitle = showsTitle ? "<span class=\"x-card-title\">\(DOM.escapeHTML(title))</span>" : ""
        return "<a class=\"x-card\(large ? " x-card-large" : "")\" href=\"\(DOM.escapeAttr(href))\">\(pic)<span class=\"x-card-text\"><span class=\"x-card-domain\">\(DOM.escapeHTML(shownDomain))</span>\(shownTitle)</span></a>"
    }

    /// The footer: when the post went up. (The reader's toolbar opens the post on its network.)
    static func footHTML(date: Date?) -> String {
        date.map { "<div class=\"x-foot\"><span>\(DOM.escapeHTML(stampLine($0)))</span></div>" } ?? ""
    }

    /// A paragraph's inner HTML, lines split at <br>, as blocks: runs of two or more bulleted lines ("• a", "- b")
    /// become a list, so wrapped items indent under their text instead of under the bullet.
    static func paragraphHTML(_ inner: String) -> String {
        let lines = inner.components(separatedBy: "<br>")
        let bullets = lines.map(bulletItem)
        let listed = bullets.indices.map { i in
            bullets[i] != nil && ((i > 0 && bullets[i - 1] != nil) || (i + 1 < bullets.count && bullets[i + 1] != nil))
        }
        var out = ""
        var i = 0
        while i < lines.count {
            var j = i
            while j < lines.count, listed[j] == listed[i] { j += 1 }
            if listed[i] {
                out += "<ul>\(bullets[i..<j].map { "<li>\($0 ?? "")</li>" }.joined())</ul>"
            } else {
                let text = lines[i..<j].joined(separator: "<br>").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out += "<p>\(text)</p>" }
            }
            i = j
        }
        return out
    }

    /// A line's text after a leading bullet ("•", "·", "▪", "◦", "-", "–", "*" and a space), or nil.
    static func bulletItem(_ line: String) -> String? {
        let t = line.drop { $0.isWhitespace }
        guard let first = t.first, "•·▪◦‣-–*".contains(first), t.dropFirst().first?.isWhitespace == true else { return nil }
        let rest = t.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    static func bodyHTML(_ text: String, links: Links, drop: String? = nil) -> String {
        let marker = "\u{1F}"
        let paras = blankLine.replacing(text, with: marker).components(separatedBy: marker).map { p -> String in
            var s = p
            if let drop, !drop.isEmpty, let r = s.range(of: drop) { s.removeSubrange(r) }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if paras.isEmpty { return "" }
        return "<div class=\"x-body\">\(paras.map { paragraphHTML(tweetInline($0, links: links)) }.joined())</div>"
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
    /// card, a footer. The first photo or video still is the lead image (the list thumbnail of a post stored
    /// without one). Pure; nil when the page carries neither post text nor media.
    static func fromPage(raw: String, canonical: String, user: String) -> ExtractResult? {
        let rawNS = ns(raw)
        // The quoted post's data is nested inside the main post's, after its own fields.
        let qiRange = rawNS.range(of: #"\"quoted_tweet_results\""#)
        let qi = qiRange.location == NSNotFound ? -1 : qiRange.location
        let end = qi >= 0 ? qi : rawNS.length
        // Where the quoted post's data ends. The page holds more after it (the rest of the main post, replies,
        // the main post again), so reading the quoted post's text or media past this picks up someone else's.
        var quoteEnd = rawNS.length
        if qi >= 0 {
            let brace = rawNS.range(of: "{", range: NSRange(location: qi, length: min(40, rawNS.length - qi)))
            if brace.location != NSNotFound, let close = closing(rawNS, open: brace.location) { quoteEnd = close + 1 }
        }
        var links: Links = [:]
        for m in linkPattern.allMatches(raw) {
            if let display = m[1], let expanded = m[2], let url = m[3] { links[url] = (display, expanded) }
        }
        let media = tweetMedia(raw, from: 0, to: end)
        guard var text = tweetText(raw, from: 0, to: end) else { return nil }
        if !media.isEmpty { text = withoutMediaLinks(text, links: links) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !media.isEmpty else { return nil }
        let ogName = ogTitle.firstMatch(raw)?[1] ?? nil
        let author = tweetUser(raw, from: 0) ?? User(name: ogName ?? "@\(user)", handle: user, avatar: nil)

        // Link card (main post only: its data comes before the quoted post's).
        var card = ""
        var cardURL: String?
        let ciRange = rawNS.range(of: #"\"binding_values\":["#)
        if ciRange.location != NSNotFound, ciRange.location < end {
            let ci = ciRange.location
            let region = slice(raw, ci, min(closing(rawNS, open: ci + ciRange.length - 1) ?? end, end))
            let title = cardString(region, key: "title")
            let domain = cardString(region, key: "vanity_url") ?? cardString(region, key: "domain")
            cardURL = cardString(region, key: "card_url")
            // X has the large image only on a card it shows large; a small card keeps its thumbnail.
            let large = cardImage(region, key: "summary_photo_image_large")
            let img = large ?? cardImage(region, key: "thumbnail_image_large")
            let href = cardURL.flatMap { links[$0]?.expanded } ?? cardURL
            if let title, let href {
                let repeated = large != nil && repeatsPost(headline: title, text: text)
                card = cardHTML(href: href, title: title, domain: domain, image: img, large: large != nil, showsTitle: !repeated)
            }
        }

        var quoted = ""
        if qi >= 0 {
            let qid = restID.firstMatch(slice(raw, qi, qi + 400))?[1] ?? nil
            let qm = tweetMedia(raw, from: qi, to: quoteEnd)
            if let qu = tweetUser(raw, from: qi), var qt = tweetText(raw, from: qi, to: quoteEnd) {
                if !qm.isEmpty { qt = withoutMediaLinks(qt, links: links) }
                if !qt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !qm.isEmpty {
                    let href = qid.map { "https://x.com/\(qu.handle)/status/\($0)" } ?? "https://x.com/\(qu.handle)"
                    quoted = "<div class=\"x-quote\">\(whoHTML(qu, date: tweetDate(raw, from: qi)))\(bodyHTML(qt, links: links))\(mediaHTML(qm))<a class=\"x-quote-link\" href=\"\(href)\">View post</a></div>"
                }
            }
        }

        let foot = footHTML(date: tweetTime(raw, from: 0))
        let html = ArticleSanitizer.sanitize(
            "<div class=\"x-post\">\(whoHTML(author, date: nil))\(bodyHTML(text, links: links, drop: card.isEmpty ? nil : cardURL))\(mediaHTML(media))\(quoted)\(card)\(foot)</div>"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = media.first.map { "\(($0.poster ?? $0.url).replacingOccurrences(of: "?name=large", with: ""))?name=small" }
        return html.isEmpty ? nil : ExtractResult(contentHtml: html, leadImage: lead)
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
