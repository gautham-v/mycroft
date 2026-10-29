import Foundation
import SwiftSoup

/// The page's own interface that Readability keeps when it picks a container around the header: site navigation and
/// skip links, logos, login and newsletter prompts, text-to-speech players, tooltips, deks and kickers under the
/// title, date and byline lines, pull quotes and sidenotes that repeat the text. `removePageInterface` runs on the
/// page (class names intact), `removeInterfaceBlocks` on the extracted article.
extension ArticlePasses {
    // MARK: removePageInterface

    private static let skipLink = P("^skip (?:to |directly to )?(?:the )?(?:main |primary |site |page )?(?:content|navigation|menu|footer|search)\\b", caseInsensitive: true)

    /// Widgets that are interface by name: tooltips ("You're currently following this author!", Business Insider),
    /// text-to-speech players (CBC's `textToSpeech`, Fox's `beyondwords-wrapper`). Short ones only.
    private static let widgetClass = P("^(?:[\\w-]*[-_])?(?:tool-?tips?|toggle-?tips?|beyondwords|speechify|text-?to-?speech|tts(?:[-_]?[a-z]+)?)(?:[-_][\\w-]+)?$", caseInsensitive: true)

    /// Pull quotes and margin notes: a copy of text that is also in the article.
    private static let pullQuoteClass = P("^(?:[\\w-]*[-_])?pull-?quotes?(?:[-_][\\w-]+)?$", caseInsensitive: true)
    private static let sideNoteClass = P("^(?:[\\w-]*[-_])?(?:side|margin)-?notes?$|^post-block-footnote(?:[-_][\\w-]+)?$|^footnote-(?:inline|aside)$", caseInsensitive: true)
    private static let keyNoise = P("[^\\p{L}\\p{N}]+")

    /// Named widgets with unique markup. Valnet's (Android Police, and its sister sites): the sign-in link in the
    /// header, the author's bio (a popover on the page), and display cards, the product / spec / related-story boxes
    /// with the site's logo as a full-width image.
    private static let namedWidgets = [
        "a#login-button-article-sidebar", "div.with-excerpt[data-nosnippet]",
        "div.display-card", "aside.display-card", "section.display-card",
        // Fox's video card without its player: the clip's title and description under the poster.
        "div.info:has(h4.title a[href*=/video/])",
    ]

    /// An avatar by its alt text ("Subhajit Chaudhury's avatar", "veritas profile picture") or its host
    /// (cdn-avatars.huggingface.co, avatars.githubusercontent.com).
    private static let avatarAlt = P("(?:^|\\s)(?:avatar|profile (?:picture|photo|image)|author (?:photo|image|picture))$", caseInsensitive: true)
    private static let avatarHost = P("//(?:[\\w-]+\\.)?(?:cdn-)?avatars?\\.[\\w.-]+/", caseInsensitive: true)

    static func removePageInterface(_ root: Element, pageURL: String) {
        // Site navigation, breadcrumbs and menus (Pitchfork's header, Cleveland.com's "News" trail). A <nav> that holds
        // the story itself (a sloppy template) stays.
        for el in DOM.select(root, "nav, [role=navigation], [role=tooltip]") where DOM.isConnected(el) {
            if DOM.proseLen(el) >= ArticleExtraction.regionMinProse { continue }
            DOM.remove(el)
        }
        for a in DOM.select(root, "a[href]") where DOM.isConnected(a) && skipLink.test(DOM.text(a)) {
            DOM.remove(lineBlock(a, root: root))
        }
        removeLogoLinks(root, pageURL: pageURL)
        for el in DOM.select(root, "[class], [id]") where DOM.isConnected(el) && !DOM.isTag(el, ["body", "html", "main", "article"]) {
            let tokens = DOM.classTokens(el) + [DOM.attr(el, "id") ?? ""]
            guard tokens.contains(where: { widgetClass.test($0) }),
                  DOM.textLen(DOM.text(el)) <= maxFurnitureText, DOM.first(el, "h1") == nil else { continue }
            DOM.remove(el)
        }
        for sel in namedWidgets { for el in DOM.select(root, sel) where DOM.isConnected(el) { DOM.remove(el) } }
        removeRepeatedAsides(root)
        removeHeadlineDek(root)
    }

    /// The site's logo linking home (Pitchfork's, SB Nation's wordmark): a link to the root of the site holding
    /// nothing but a picture.
    private static func removeLogoLinks(_ root: Element, pageURL: String) {
        guard let page = URL(string: pageURL), let host = page.host(percentEncoded: false) else { return }
        for a in DOM.select(root, "a[href]") where DOM.isConnected(a) {
            guard DOM.first(a, "img, picture, svg") != nil, DOM.closest(a, "figure") == nil,
                  let href = DOM.absURL(DOM.attr(a, "href"), base: pageURL), let u = URL(string: href),
                  u.host(percentEncoded: false) == host, u.path.isEmpty || u.path == "/" else { continue }
            // Text outside svg (an svg's <title> reads as a label of the drawing, not as words on the page).
            let words = DOM.select(a, "svg").reduce(DOM.text(a)) { rest, svg in
                let t = DOM.text(svg)
                return t.isEmpty ? rest : rest.replacingOccurrences(of: t, with: "")
            }
            if DOM.squash(words).count <= 3 { DOM.remove(lineBlock(a, root: root)) }
        }
    }

    /// Pull quotes, sidenotes and margin footnotes whose text the page also has elsewhere (Aeon's `pullquote`
    /// paragraphs, Mother Jones' `wp-block-pullquote`, blog.orange.tw's `sidenote` spans next to the Notes list). One
    /// that is the only copy stays.
    private static func removeRepeatedAsides(_ root: Element) {
        func key(_ s: String) -> String {
            var k = keyNoise.replacing(s.lowercased(), with: "")
            while let c = k.first, c.isNumber { k.removeFirst() }
            return k
        }
        var pageKey: String?
        for el in DOM.select(root, "[class]") where DOM.isConnected(el) {
            let tokens = DOM.classTokens(el)
            guard tokens.contains(where: { pullQuoteClass.test($0) || sideNoteClass.test($0) }) else { continue }
            // The outermost box of the quote (a figure around its blockquote), not an inner piece.
            if let p = el.parent(), DOM.classTokens(p).contains(where: { pullQuoteClass.test($0) || sideNoteClass.test($0) }) { continue }
            let k = key(DOM.text(el))
            guard k.count >= 20 else { continue }
            pageKey = pageKey ?? key(DOM.text(root))
            if let all = pageKey, all.components(separatedBy: k).count > 2 { DOM.remove(el) }
        }
    }

    // MARK: Header: kicker and dek

    /// A dek by name: `dek`, `deck`, `standfirst`, `subtitle`, `subhead`, `summary` (also camel-cased: CBC's
    /// `detailSummary`).
    private static let dekClass = P("(?:^|[-_]|[a-z])(?:dek|deck|standfirst|stand-first|subtitle|sub-title|subhead(?:line|ing)?|sub-headline|subhed|summary)(?:[-_][\\w-]+)?$", caseInsensitive: true)
    static let maxDekText = 400
    /// Nothing counts as the story's own text before a paragraph this long.
    private static let bodyParagraph = 150

    private static func isDekCandidate(_ el: Element) -> Bool {
        guard DOM.isTag(el, ["p", "h2", "h3", "h4", "div", "span"]) else { return false }
        let n = DOM.textLen(DOM.text(el))
        return n >= 15 && n <= maxDekText && DOM.first(el, "p, div, ul, ol, h1, h2, h3, h4, h5, h6, figure, table, blockquote") == nil
            && DOM.first(el, contentMedia) == nil
    }

    /// The deck and kicker around the title <h1>. The reader draws the title itself, and a dek left above the first
    /// picture keeps the app from seeing that the body opens with the lead image. A dek is (1) named as one and
    /// before the first long paragraph (Reason's `entry-subtitle`, CBC's `deck`, Slate's `article__dek`; CNBC's
    /// `ArticleBody-subtitle` section headings come after paragraphs and stay), or (2) the only thing beside the
    /// title in its box (Eater). A kicker is a short link or two above the title's box (Eater's "Travel Guides").
    static func removeHeadlineDek(_ root: Element) {
        guard let headline = ArticleExtraction.headline(root) else { return }
        let order = DOM.documentOrder(root)
        func at(_ el: Element) -> Int { order[ObjectIdentifier(el)] ?? -1 }
        // The same title twice (a sticky copy beside the page's own) both get their furniture removed.
        let title = DOM.norm(DOM.text(headline))
        let h1s = DOM.select(root, "h1").filter { DOM.norm(DOM.text($0)) == title }
        let titleAt = at(headline)
        let candidates = DOM.select(root, "*").filter { at($0) > titleAt && DOM.classTokens($0).contains(where: { dekClass.test($0) }) && isDekCandidate($0) }
        let candidateSet = Set(candidates.map { ObjectIdentifier($0) })
        // The first paragraph that is the story, not a dek.
        let bodyAt = DOM.select(root, "p").first { p in
            at(p) > titleAt && DOM.textLen(DOM.text(p)) >= bodyParagraph && !candidateSet.contains(ObjectIdentifier(p))
                && !candidates.contains(where: { DOM.contains($0, p) }) && DOM.closest(p, "aside, nav, footer") == nil
        }.map(at) ?? Int.max
        for el in candidates where DOM.isConnected(el) && at(el) < bodyAt { DOM.remove(lineBlock(el, root: root)) }
        for h1 in h1s where DOM.isConnected(h1) {
            // Only the headline and one short line in their box.
            if let box = h1.parent(), !(box is Document) {
                let kids = DOM.children(box).filter { hasMediaOrText($0) }
                if kids.count == 2, kids[0] === h1, DOM.isTag(kids[1], ["p", "h2", "h3", "div"]), isDekCandidate(kids[1]),
                   DOM.textLen(DOM.text(kids[1])) >= 40,
                   DOM.select(root, "p").contains(where: { at($0) > at(kids[1]) && DOM.textLen(DOM.text($0)) >= bodyParagraph && !DOM.contains(box, $0) }) {
                    DOM.remove(kids[1])
                }
            }
            // Kickers above the title's box, up the tree a few levels.
            var node: Element = h1
            for _ in 0..<3 {
                guard let up = node.parent(), !(up is Document), !DOM.isTag(up, ["body", "html", "main", "article"]) else { break }
                var sib = try? up.previousElementSibling()
                while let cur = sib {
                    sib = try? cur.previousElementSibling()
                    if DOM.textLen(DOM.text(cur)) <= 60, DOM.first(cur, contentMedia) == nil, !DOM.matches(cur, contentMedia),
                       DOM.first(cur, "h1, h2, h3") == nil { DOM.remove(cur) } else { break }
                }
                node = up
            }
        }
    }

    // MARK: removeInterfaceBlocks

    private static let blockTags: Set<String> = [
        "div", "section", "aside", "header", "footer", "article", "main", "nav", "p", "h1", "h2", "h3", "h4", "h5", "h6", "figure",
        "blockquote", "pre", "table", "ul", "ol", "li", "dl", "hr", "form", "details", "figcaption", "fieldset", "address",
    ]
    private static let leafBlocks: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "figure", "blockquote", "pre", "table", "ul", "ol", "dl", "hr", "figcaption", "details",
    ]

    /// The article's blocks in order: paragraphs, headings, lists, figures, and any box holding only inline content
    /// (`<div>Updated on</div>`, a lone link).
    static func interfaceBlocks(_ root: Element) -> [Element] {
        var out: [Element] = []
        func walk(_ el: Element) {
            if DOM.isTag(el, leafBlocks) { out.append(el); return }
            if !DOM.children(el).contains(where: { DOM.isTag($0, blockTags) }) {
                if hasMediaOrText(el) { out.append(el) }
                return
            }
            for node in el.getChildNodes() {
                guard let c = node as? Element else { continue }
                if DOM.isTag(c, blockTags) { walk(c) } else if hasMediaOrText(c) { out.append(c) }
            }
        }
        for node in root.getChildNodes() {
            guard let c = node as? Element else { continue }
            walk(c)
        }
        return out
    }

    /// Remove a line and the wrappers it alone filled.
    static func dropBlock(_ el: Element, root: Element) {
        guard !DOM.matches(el, contentMedia), DOM.first(el, contentMedia) == nil else { return }
        let gone = lineBlock(el, root: root)
        var parent = gone.parent()
        DOM.remove(gone)
        while let p = parent, p !== root, !(p is Document), !hasMediaOrText(p) {
            parent = p.parent()
            DOM.remove(p)
        }
    }

    /// Lines that are the page's interface, whole (a block holding only this): the "view image in full size" hint
    /// under Medium's pictures, its sign-in prompt, text-to-speech players, a video player's fallback, the Washington
    /// Post's masthead slogan, slider counters, a login link.
    private static let interfaceLines = [
        P("^press enter or click to view image in full size$", caseInsensitive: true),
        P("^get .{2,80}[’']?s? stories in your inbox$", caseInsensitive: true),
        P("^join medium for free to get updates from this writer\\.?$", caseInsensitive: true),
        P("^remember me for faster sign in$", caseInsensitive: true),
        P("^listen to (?:this|the) (?:article|story)$", caseInsensitive: true),
        P("^(?:new ?)?you can now listen to [^.!]{1,40} articles!?$", caseInsensitive: true),
        P("^estimated \\d+(?:\\.\\d+)? (?:minutes?|mins?)$", caseInsensitive: true),
        P("^the audio version of this article is generated by ai.{0,260}$", caseInsensitive: true),
        P("^text to speech icon$", caseInsensitive: true),
        P("^to view this video please enable javascript.{0,120}$", caseInsensitive: true),
        P("^sign in to your [^.]{1,40} account$", caseInsensitive: true),
        P("^you(?:'|’)re currently following this (?:author|topic)!?(?: click to unsubscribe.{0,40})?$", caseInsensitive: true),
        P("^democracy dies in darkness$", caseInsensitive: true),
        P("^opens in new window$", caseInsensitive: true),
        P("^back to (?:all )?(?:articles|blog|posts|stories|news)$", caseInsensitive: true),
        P("^\\d{2} ?/ ?\\d{2}$"),
        // A comment widget's prompt (Future plc's sites).
        P("^(?:upload images, audio, and videos by dragging in the text input, pasting, or clicking here\\.?|tap or paste here to upload images)$", caseInsensitive: true),
        P("^this article has been gifted to you$", caseInsensitive: true),
        P("^log in to read this subscriber-only article for free\\.?$", caseInsensitive: true),
        P("^not registered with [^?]{1,30}\\? register for free$", caseInsensitive: true),
        P("^you must confirm your public display name before commenting$", caseInsensitive: true),
        P("^please logout and then login again, you will then be prompted to enter your display name\\.?$", caseInsensitive: true),
    ]
    /// Lines that are interface only at the top of the story (a login link beside the title).
    private static let leadLines = P("^(?:(?:sign|log) ?in|register|subscribers only|lire en français)$", caseInsensitive: true)
    private static let separatorOnly = P("^[|·•/.\\-–—\\s]+$")
    private static let tocLabel = P("^(?:table of )?contents$", caseInsensitive: true)
    private static let inlineSet: Set<String> = ["a", "span", "em", "i", "strong", "b", "small", "time"]

    // MARK: Date and byline lines

    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]
    private static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
    ]
    private static let dateLabels: Set<String> = ["updated", "update", "published", "posted", "issued", "modified", "edited"]
    private static let dateFiller: Set<String> = [
        "on", "at", "ago", "today", "yesterday", "last", "min", "mins", "minute", "minutes", "hour", "hours", "day", "days", "read", "reading",
        "am", "pm", "edt", "est", "cdt", "cst", "mdt", "mst", "pdt", "pst", "utc", "gmt", "bst", "cet", "cest", "ist", "et", "ct", "pt",
    ]
    private static let dateWords: [String] = (months.union(weekdays).union(dateLabels).union(dateFiller)).sorted { $0.count > $1.count }
    private static let dateToken = P("[a-z]+|\\d+(?::\\d+)*(?:st|nd|rd|th)?|#\\w+|\\S")
    private static let dayPeriod = P("\\b([ap])\\.m\\.?", caseInsensitive: true)

    /// Splits a run of letters into known date words ("amfri" → "am", "fri"), false when something else is in it.
    private static func knownDateWords(_ run: Substring) -> (ok: Bool, label: Bool, date: Bool) {
        var rest = run, label = false, date = false
        while !rest.isEmpty {
            guard let w = dateWords.first(where: { rest.hasPrefix($0) }) else { return (false, false, false) }
            if dateLabels.contains(w) || w == "ago" { label = true }
            if months.contains(w) || weekdays.contains(w) { date = true }
            rest = rest.dropFirst(w.count)
        }
        return (true, label, date)
    }

    /// A line that is only a date: "Updated on", "Posted Fri 30 Oct 2026 at 6:02amFri 30 Oct 2026 at 6:02am", "Thu Oct
    /// 29 2026, 12:51 PM EDT · 1 minute read", "October 28, 2026 at 7:39 p.m. EDT8 minutes ago", "2026-10-27 · 16 min ·
    /// #computing", "3 days ago". A year, a clock time, "ago" or a label has to be in it.
    static func isDateLine(_ text: String) -> Bool {
        guard text.count <= 90 else { return false }
        let t = dayPeriod.replacing(text.lowercased(), with: "$1m")
        var signal = false, hasDigit = false, hasWord = false, tokens = 0, labeled = false
        for m in dateToken.allMatches(t) {
            guard let tok = m[0], let c = tok.first else { continue }
            if c.isLetter {
                let r = knownDateWords(Substring(tok))
                guard r.ok else { return false }
                hasWord = true
                tokens += 1
                if r.label { signal = true; labeled = true }
            } else if c.isNumber {
                hasDigit = true
                tokens += 1
                // A day, a month, a year or a time: not a release number ("2026-079") or a version.
                let digits = tok.prefix(while: { $0.isNumber }).count
                if !tok.contains(":") && ![1, 2, 4].contains(digits) { return false }
                if tok.contains(":") || (tok.count == 4 && (tok.hasPrefix("19") || tok.hasPrefix("20"))) { signal = true }
            } else if c == "#" {
                continue
            } else if !"-–—·•|/,:.()@".contains(c) {
                return false
            }
        }
        if t.contains("read") && !hasDigit { return false }
        return signal && (hasDigit || hasWord) && (tokens >= 2 || labeled)
    }

    private static let countLine = P("^[-–—•·.,\\d\\s]{1,8}[km]?$", caseInsensitive: true)
    private static let bylineStart = P("^by\\s+\\p{Lu}")
    private static let staffByline = P("^the athletic(?: [a-z.]+){0,3} (?:staff|team)$", caseInsensitive: true)

    /// "By <a>Name, TITLE</a>": a short line with one or two links, in the header.
    private static func isByline(_ b: Element, _ text: String) -> Bool {
        if staffByline.test(text) { return true }
        guard bylineStart.test(text), text.count <= 110, !text.hasSuffix(".") else { return false }
        let links = DOM.select(b, "a[href]")
        return !links.isEmpty && links.count <= 2
    }

    private static let kickerPath = P("/(?:topics?|tags?|categor(?:y|ies)|section|sections)/", caseInsensitive: true)

    /// A topic or section chip above the story: one short link and nothing else ("Topic: Children", "Faith-based",
    /// "Politics", "NFL"), pointing at a section or topic page.
    private static func isKicker(_ b: Element, _ text: String, site: String?) -> Bool {
        guard text.count <= 30, text.split(separator: " ").count <= 4 else { return false }
        let links = DOM.select(b, "a[href]") + (DOM.matches(b, "a[href]") ? [b] : [])
        guard links.count == 1, let href = DOM.attr(links[0], "href") else { return false }
        let linkText = DOM.text(links[0])
        guard linkText == text || text.hasSuffix(linkText) else { return false }
        let url = URL(string: href)
        if let site, let host = url?.host(percentEncoded: false), host.replacingOccurrences(of: "www.", with: "") != site { return false }
        let path = url?.path ?? href
        let depth = path.split(separator: "/").count
        return depth <= 2 || kickerPath.test(path)
    }

    /// Strips and rules drawn as pictures (Autopian's `vidframe_min_top-1024x33.png`): far wider than tall and short.
    private static let sizedName = P("[-_](\\d{2,4})x(\\d{1,4})\\.(?:png|jpe?g|gif|webp)(?:[?#]|$)", caseInsensitive: true)
    private static func isStripImage(_ img: Element) -> Bool {
        var w = DOM.jsNumber(DOM.attr(img, "width")), h = DOM.jsNumber(DOM.attr(img, "height"))
        if !(w > 0 && h > 0), let m = sizedName.firstMatch(DOM.attr(img, "src") ?? ""), let a = m[1].flatMap({ Double($0) }), let b = m[2].flatMap({ Double($0) }) { w = a; h = b }
        return w > 0 && h > 0 && h <= 40 && w / h >= 12
    }

    /// Wrappers an image alone filled go with it.
    private static func dropImage(_ img: Element, root: Element) {
        var gone: Element = img
        while let p = gone.parent(), p !== root, !(p is Document), DOM.children(p).count == 1, DOM.text(p).isEmpty { gone = p }
        let parent = gone.parent()
        DOM.remove(gone)
        var up = parent
        while let p = up, p !== root, !(p is Document), !hasMediaOrText(p) { up = p.parent(); DOM.remove(p) }
    }

    /// The blocks that open or close an extraction and are the page's interface. Dates, counts, kickers and
    /// bylines only before the first paragraph of the story (and dates at the end), so a dated line in the text stays.
    static func removeInterfaceBlocks(_ root: Element, base: String? = nil) {
        for img in DOM.select(root, "img") where DOM.isConnected(img) {
            let alt = DOM.attr(img, "alt") ?? "", src = DOM.attr(img, "src") ?? ""
            if avatarAlt.test(alt) || avatarHost.test(src) || isStripImage(img) { dropImage(img, root: root) }
        }
        for el in DOM.select(root, "p, div, li, span, a, h2, h3, h4, h5, h6, small, em, strong, label") where DOM.isConnected(el) {
            let t = DOM.text(el)
            guard !t.isEmpty, t.count <= 280, DOM.first(el, contentMedia) == nil, interfaceLines.contains(where: { $0.test(t) }) else { continue }
            let block = lineBlock(el, root: root)
            if DOM.isTag(block, inlineSet), let parent = block.parent(), DOM.text(parent) != t { continue }
            dropBlock(block, root: root)
        }
        var blocks = interfaceBlocks(root)
        // A contents label left over once its list of anchors went.
        for (i, b) in blocks.enumerated() where DOM.isConnected(b) && tocLabel.test(DOM.text(b)) {
            if i + 1 < blocks.count, DOM.isTag(blocks[i + 1], ["ul", "ol"]), DOM.first(blocks[i + 1], "a[href]") != nil { continue }
            dropBlock(b, root: root)
        }
        blocks = blocks.filter { DOM.isConnected($0) }
        // A header or footer line only where there is a story: a note that is one short line is the note.
        guard blocks.contains(where: { DOM.isTag($0, ["p", "blockquote"]) && DOM.textLen(DOM.text($0)) >= 100 }) else { return }
        let site = base.flatMap { URL(string: $0)?.host(percentEncoded: false) }?.replacingOccurrences(of: "www.", with: "")
        var sawMeta = false, prose = 0
        for (i, b) in blocks.prefix(14).enumerated() {
            let t = DOM.text(b)
            if DOM.isTag(b, ["hr"]) && prose == 0 { dropBlock(b, root: root); continue }
            if t.isEmpty || DOM.isTag(b, ["figure"]) || DOM.matches(b, contentMedia) || DOM.first(b, contentMedia) != nil { continue }
            // A dek or the first paragraph may sit above the date line (the Washington Post's), but the story's own
            // text ends the header, and only whole date lines go after it.
            if t.count >= 100 {
                if DOM.isTag(b, ["p", "blockquote"]) { prose += 1 }
                if prose >= 2 { break }
                continue
            }
            if (isDateLine(t) && !DOM.isTag(b, DOM.headingTags)) || (prose == 0 && sawMeta && countLine.test(t) && t.contains(where: { $0.isNumber || $0 == "-" })) || (prose == 0 && (separatorOnly.test(t) || leadLines.test(t))) {
                sawMeta = true
                dropBlock(b, root: root)
            } else if prose == 0, i < 8, isByline(b, t) || isKicker(b, t, site: site) {
                sawMeta = true
                dropBlock(b, root: root)
            }
        }
        for b in blocks.suffix(3) where DOM.isConnected(b) && !DOM.isTag(b, DOM.headingTags) && (isDateLine(DOM.text(b)) || separatorOnly.test(DOM.text(b))) { dropBlock(b, root: root) }
        removeRepeatedLeadBlocks(root)
        removeTrailingLabels(root)
    }

    private static let endMatter = P("^(?:sources?|references?|credits?|notes?|footnotes?|acknowledge?ments?|bibliography|links|further reading|about the authors?|correction)s?:?$", caseInsensitive: true)
    private static let sentenceEnd = P("[.!?…:”\"')\\]]$")

    /// Headings and label-like lines that end the extraction with nothing under them: what is left of a "Collections
    /// mentioned in this article" / "More from this author" / "Community" block once its cards and comment form are
    /// gone (Hugging Face). A story ends in a sentence.
    private static func removeTrailingLabels(_ root: Element) {
        let blocks = interfaceBlocks(root).filter { DOM.isConnected($0) }
        var tail: [Element] = []
        for b in blocks.reversed() {
            let t = DOM.text(b)
            if t.isEmpty && !hasMediaOrText(b) { continue }
            let label = DOM.isTag(b, DOM.headingTags) || (DOM.isTag(b, ["p", "div"]) && t.count <= 40 && !sentenceEnd.test(t) && DOM.first(b, contentMedia) == nil)
            guard label else { break }
            tail.append(b)
        }
        // The end matter of a story is its own: "Sources" over a name, "Acknowledgements".
        guard tail.contains(where: { DOM.isTag($0, DOM.headingTags) }), blocks.count > tail.count,
              !tail.contains(where: { endMatter.test(DOM.text($0)) }) else { return }
        for b in tail where DOM.isConnected(b) { dropBlock(b, root: root) }
    }

    /// The same paragraph twice near the top: a teaser block before the full text (Foreign Policy's first two
    /// paragraphs, CBC's summary above the deck and again as the first paragraph). The earlier copy goes.
    private static func removeRepeatedLeadBlocks(_ root: Element) {
        let blocks = interfaceBlocks(root).prefix(18).filter { !DOM.isTag($0, ["figure", "ul", "ol", "table", "hr"]) }
        let texts = blocks.map { DOM.norm(DOM.text($0)) }
        for (i, b) in blocks.enumerated() where texts[i].count >= 60 && DOM.isConnected(b) {
            // In another box: the same paragraph twice in a row is the writer's, not a template's.
            if blocks.indices.contains(where: { $0 > i && texts[$0] == texts[i] && blocks[$0].parent() !== b.parent() }) { dropBlock(b, root: root) }
        }
    }

    // MARK: dropRepeatedHeader

    private static let titleDate = P("\\s*[-–—|·]\\s*(?:\\d{4}-\\d{2}-\\d{2}|[a-z]{3,9}\\.? \\d{1,2},? \\d{4})\\s*$", caseInsensitive: true)
    private static let titleSite = P("\\s+[|–—:-]\\s+[^|–—:-]{1,40}$")
    private static let namesLine = P("^(?:\\p{Lu}[\\p{L}’'.-]+)(?: \\p{Lu}[\\p{L}’'.-]+){0,3}(?:(?:, | and | & )\\p{Lu}[\\p{L}’'.-]+(?: \\p{Lu}[\\p{L}’'.-]+){0,3}){0,5}$")
    private static let ellipsis = P("\\s*(?:…|\\.{3})$")

    /// What the page already says above the story: the title again as a block near the top (a typewriter-style
    /// header, DeepMind's h2, Simon Willison's "Title - 2026-10-28"), with a line of names under it; and the
    /// description (the standfirst under the title, blog.google's) when it stands alone before the picture or a rule.
    /// Matched ignoring case and punctuation.
    static func dropRepeatedHeader(_ html: String, titles: [String], description: String?) -> String {
        func key(_ s: String) -> String { DOM.norm(s).filter { $0.isLetter || $0.isNumber } }
        let keys = Set(titles.flatMap { [key($0), key(titleSite.replacing($0, with: ""))] }.filter { $0.count >= 12 })
        let descKey = description.map { key(ellipsis.replacing($0, with: "")) } ?? ""
        guard !keys.isEmpty || descKey.count >= 25 else { return html }
        return DOM.withFragment("<div id=\"__root\">\(html)</div>") { body -> String in
            guard let root = DOM.first(body, "#__root") else { return html }
            let blocks = interfaceBlocks(root)
            for (i, b) in blocks.prefix(6).enumerated() where DOM.isConnected(b) && !DOM.isTag(b, ["figure", "ul", "ol", "table"]) {
                let text = DOM.text(b)
                if keys.contains(key(titleDate.replacing(text, with: ""))) {
                    dropBlock(b, root: root)
                    if i + 1 < blocks.count, DOM.isTag(blocks[i + 1], ["p", "div"]), namesLine.test(DOM.text(blocks[i + 1])) { dropBlock(blocks[i + 1], root: root) }
                } else if descKey.count >= 25, i < 4, text.count <= 300, key(ellipsis.replacing(text, with: "")) == descKey,
                          i + 1 < blocks.count, DOM.isTag(blocks[i + 1], ["hr", "figure"]) || DOM.first(blocks[i + 1], contentMedia) != nil {
                    dropBlock(b, root: root)
                }
            }
            return DOM.innerHTML(root)
        } ?? html
    }
}
