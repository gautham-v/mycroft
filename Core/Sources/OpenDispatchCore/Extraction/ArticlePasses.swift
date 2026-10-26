import Foundation
import SwiftSoup

/// The DOM passes of src/lib/extract.ts that run before Readability (on the page) and after it (on its output).
/// Each function mirrors the web function of the same name; comments carry the web's reasoning.
enum ArticlePasses {
    typealias DOM = ExtractionDOM
    typealias P = ExtractionDOM.Pattern

    // MARK: srcset

    struct SrcsetCandidate: Equatable, Sendable {
        var url: String
        var descriptor: String
    }

    /// Parse a srcset per the HTML spec's outline: URLs may contain commas (CDN transforms like w_640,c_fill).
    static func parseSrcset(_ srcset: String) -> [SrcsetCandidate] {
        let s = Array(srcset)
        var out: [SrcsetCandidate] = []
        var i = 0
        func isSpace(_ c: Character) -> Bool { c.isWhitespace }
        while i < s.count {
            while i < s.count && (isSpace(s[i]) || s[i] == ",") { i += 1 }
            if i >= s.count { break }
            var j = i
            while j < s.count && !isSpace(s[j]) { j += 1 }
            var url = String(s[i..<j])
            var descriptor = ""
            if url.hasSuffix(",") {
                while url.hasSuffix(",") { url.removeLast() }
                i = j
            } else {
                var k = j
                while k < s.count && s[k] != "," { k += 1 }
                descriptor = String(s[j..<k]).trimmingCharacters(in: .whitespacesAndNewlines)
                i = k + 1
            }
            if !url.isEmpty { out.append(SrcsetCandidate(url: url, descriptor: descriptor)) }
        }
        return out
    }

    static func absSrcset(_ srcset: String, base: String) -> String {
        parseSrcset(srcset).compactMap { c -> String? in
            guard let a = DOM.absURL(c.url, base: base) else { return nil }
            return [a, c.descriptor].filter { !$0.isEmpty }.joined(separator: " ")
        }.joined(separator: ", ")
    }

    /// Largest srcset candidate by w/x descriptor (a bare URL counts as 1x).
    static func largestCandidate(_ srcset: String) -> String? {
        var best: (url: String, n: Double)?
        for c in parseSrcset(srcset) {
            let parsed = DOM.jsParseFloat(c.descriptor) ?? 0
            let n = parsed == 0 ? 1 : parsed
            if best == nil || n > (best?.n ?? 0) { best = (c.url, n) }
        }
        return best?.url
    }

    // MARK: absolutizeDom

    // `data-asset` is a custom player's attribute; it is promoted only when it names a media file.
    static let lazySrc = ["data-src", "data-lazy-src", "data-original", "data-lazy", "data-url", "data-asset"]
    static let lazySrcset = ["data-srcset", "data-lazy-srcset"]
    static let lazyPoster = ["data-poster", "data-lazy-poster"]
    private static let mediaFile = P("\\.(?:jpe?g|png|gif|webp|avif|svg|mp4|webm|mov|m4v|ogg|ogv|mp3|m4a)(?:[?#]|$)", caseInsensitive: true)

    static func firstAttr(_ el: Element, _ names: [String]) -> String? {
        for n in names {
            guard let v = DOM.attr(el, n), !v.hasPrefix("data:") else { continue }
            if n == "data-asset" && !mediaFile.test(v) { continue }
            return v
        }
        return nil
    }

    static func isPlaceholderSrc(_ v: String?) -> Bool {
        guard let v, !v.isEmpty else { return true }
        return v.hasPrefix("data:") || v.lowercased() == "about:blank"
    }

    /// Absolutize links and media URLs, and promote lazy-load attributes (data-src, data-srcset, data-poster, ...) to
    /// the real ones. Runs before Readability and again on its output.
    static func absolutize(_ root: Element, base: String) {
        for el in DOM.select(root, "a[href]") {
            if let v = DOM.absURL(DOM.attr(el, "href"), base: base) { DOM.setAttr(el, "href", v) }
        }
        for el in DOM.select(root, "video, iframe") {
            let isVideo = DOM.tag(el) == "video"
            let lazy = firstAttr(el, lazySrc)
            // A <video> with <source> children plays those; don't add a competing src.
            let hasSources = isVideo && DOM.first(el, "source") != nil
            if let lazy, !hasSources, isPlaceholderSrc(DOM.attr(el, "src")) { DOM.setAttr(el, "src", lazy) }
            if isVideo, let poster = firstAttr(el, lazyPoster), isPlaceholderSrc(DOM.attr(el, "poster")) {
                DOM.setAttr(el, "poster", poster)
            }
        }
        for el in DOM.select(root, "img, source") {
            if let lazySet = firstAttr(el, lazySrcset), DOM.attr(el, "srcset") == nil { DOM.setAttr(el, "srcset", lazySet) }
            if let ss = DOM.attr(el, "srcset") { DOM.setAttr(el, "srcset", absSrcset(ss, base: base)) }
            if let lazy = firstAttr(el, lazySrc), isPlaceholderSrc(DOM.attr(el, "src")) { DOM.setAttr(el, "src", lazy) }
            // srcset-only images: give them a src so anything that reads src (sanitizer, hero pick) sees one.
            if DOM.tag(el) == "img", isPlaceholderSrc(DOM.attr(el, "src")),
               let ss = DOM.attr(el, "srcset"), let fromSet = largestCandidate(ss) {
                DOM.setAttr(el, "src", fromSet)
            }
            if let v = DOM.absURL(DOM.attr(el, "src"), base: base) { DOM.setAttr(el, "src", v) }
        }
        for el in DOM.select(root, "video[src], iframe[src]") {
            if let v = DOM.absURL(DOM.attr(el, "src"), base: base) { DOM.setAttr(el, "src", v) }
        }
        for el in DOM.select(root, "video[poster]") {
            if let v = DOM.absURL(DOM.attr(el, "poster"), base: base) { DOM.setAttr(el, "poster", v) }
        }
    }

    // MARK: neutralizeReadabilityClasses

    // Readability's REGEXPS.unlikelyCandidates and .negative, copied: utility-CSS tokens trip them.
    private static let readabilityUnlikely = P("-ad-|ai2html|banner|breadcrumbs|combx|comment|community|cover-wrap|disqus|extra|footer|gdpr|header|legends|menu|related|remark|replies|rss|shoutbox|sidebar|skyscraper|social|sponsor|supplemental|ad-break|agegate|pagination|pager|popup|yom-remote", caseInsensitive: true)
    private static let readabilityNegative = P("-ad-|hidden|^hid$|banner|combx|comment|com-|contact|footer|gdpr|masthead|media|meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|widget", caseInsensitive: true)
    static func readabilityJunk(_ s: String) -> Bool { readabilityUnlikely.test(s) || readabilityNegative.test(s) }
    /// A Tailwind-style utility token: variants (`md:`), arbitrary values (`[...]`, `(...)`), or a styling prefix.
    static let utilityClass = P("[:\\[\\]()@!/]|^-?(?:overflow|overscroll|scroll|snap|object|line-clamp|text|bg|aspect)-")
    private static let layoutNegative = P("hidden|scroll|media|meta|header|extra|masthead|legends|remark|cover-wrap", caseInsensitive: true)
    private static let hyphenOrUnderscore = P("[-_]")
    static let contentTags = "h1, h2, h3, h4, h5, h6, p, li, dt, dd, figure, figcaption, picture, img, a, span, strong, b, em, i, code, pre, blockquote"
    static let media = "img, picture, video, svg"

    static func dropClassTokens(_ el: Element, _ drop: (String) -> Bool) {
        let tokens = DOM.classTokens(el)
        let kept = tokens.filter { !drop($0) }
        if kept.count != tokens.count { DOM.setAttr(el, "class", kept.joined(separator: " ")) }
    }

    /// Before Readability: drop (1) utility tokens that match its word lists, anywhere; (2) compound layout-word tokens
    /// on content elements, plus an id that would delete a heading; (3) layout words inside figures, text-free media
    /// wrappers and code-block wrappers.
    static func neutralizeReadabilityClasses(_ root: Element) {
        for el in DOM.select(root, "[class]") {
            dropClassTokens(el) { readabilityJunk($0) && utilityClass.test($0) }
        }
        for el in DOM.select(root, contentTags) {
            dropClassTokens(el) { hyphenOrUnderscore.test($0) && layoutNegative.test($0) }
            if DOM.isTag(el, DOM.headingTags), readabilityJunk(DOM.attr(el, "id") ?? "") { DOM.removeAttr(el, "id") }
        }
        func inFigure(_ el: Element) -> Bool { DOM.tag(el) == "figure" || DOM.closest(el, "figure") != nil }
        func mediaWrapper(_ el: Element) -> Bool { DOM.first(el, media) != nil && DOM.text(el).isEmpty }
        // Text outside the code is at most a toolbar ("JSON", "Copy").
        func codeWrapper(_ el: Element) -> Bool {
            let pres = DOM.select(el, "pre")
            let inCode = pres.reduce(0) { $0 + DOM.textLen(DOM.text($1)) }
            return !pres.isEmpty && DOM.textLen(DOM.text(el)) - inCode <= 40
        }
        for el in DOM.select(root, "[class]") {
            // A bare `hidden` really is hidden (the desktop copy of a responsive pair); keep it.
            if inFigure(el) || mediaWrapper(el) || codeWrapper(el) {
                dropClassTokens(el) { $0 != "hidden" && layoutNegative.test($0) }
            }
        }
    }

    // MARK: removeScreenReaderText

    private static let srOnlyClass = P("^(?:[\\w-]*__)?(?:sr-?only|sr-text|visually-?hidden|screen-?reader(?:-?text|-?only)?|a11y-?hidden|assistive-?text|show-for-sr|element-invisible|hidden-visually|u-hidden-visually)(?:__[\\w-]+)?$", caseInsensitive: true)
    private static let srOnlyStyle = P("clip\\s*:\\s*rect\\(\\s*0|clip-path\\s*:\\s*inset\\(\\s*50%", caseInsensitive: true)
    private static let onePx = P("(?:^|;)\\s*(?:width|height)\\s*:\\s*1px", caseInsensitive: true)
    private static let positionAbsolute = P("position\\s*:\\s*absolute", caseInsensitive: true)
    // Tailwind's responsive undo (`sr-only sm:not-sr-only`): visible from that breakpoint up, so it is real text.
    private static let responsiveNotSrOnly = P("^(?:sm|md|lg|xl|[2-9]xl|min-\\[[^\\]]*\\]|@[\\w-]*(?:/[\\w-]+)?):not-sr-only$")
    private static let letterOrNumber = P("[\\p{L}\\p{N}]")

    static func isScreenReaderOnly(_ el: Element) -> Bool {
        let tokens = DOM.classTokens(el)
        if tokens.contains(where: { srOnlyClass.test($0) }) { return !tokens.contains(where: { responsiveNotSrOnly.test($0) }) }
        let style = DOM.attr(el, "style") ?? ""
        return srOnlyStyle.test(style) || (positionAbsolute.test(style) && onePx.test(style))
    }

    /// Remove text meant only for screen readers, and aria-hidden icon glyphs that carry no words.
    static func removeScreenReaderText(_ root: Element) {
        for el in DOM.select(root, "[class], [style]") {
            if DOM.isConnected(el), !DOM.isTag(el, ["body", "html"]), isScreenReaderOnly(el) { DOM.remove(el) }
        }
        for el in DOM.select(root, "span[aria-hidden=true], i[aria-hidden=true]") {
            if DOM.isConnected(el), DOM.first(el, "img, picture, video") == nil, !letterOrNumber.test(DOM.rawText(el)) {
                DOM.remove(el)
            }
        }
    }

    // MARK: removePlayerChrome

    // "00:00 / 01:59", "1–13 of 13"; a CSS-drawn separator leaves "00:0100:14".
    private static let timeCode = P("^\\d{1,2}:\\d{2}(?::\\d{2})?(?:\\s*[/|]?\\s*\\d{1,2}:\\d{2}(?::\\d{2})?)?$")
    private static let nOfM = P("^\\d+(?:\\s*[–—-]\\s*\\d+)?\\s+of\\s+\\d+$", caseInsensitive: true)
    static let playerPart = "video, audio, button, [role=slider], [role=button], [aria-live]"
    static let textBlock = "p, li, dt, dd, td, th, figcaption, blockquote, h1, h2, h3, h4, h5, h6, pre, code"

    /// Inside a player or carousel: a live region itself, or near a control or a video (never past `root`).
    static func inPlayer(_ el: Element, root: Element) -> Bool {
        if el.hasAttr("aria-live") { return true }
        var a = el.parent()
        var i = 0
        while let cur = a, cur !== root, !(cur is Document), i < 4, !DOM.isTag(cur, ["body", "article", "main"]) {
            if DOM.first(cur, playerPart) != nil { return true }
            a = cur.parent()
            i += 1
        }
        return false
    }

    /// Drop media-player chrome: sliders, toolbars, and elements whose whole text is a time code or a counter,
    /// when they sit beside player controls (a timestamp in prose or a list stays).
    static func removePlayerChrome(_ root: Element) {
        for el in DOM.select(root, "[role=slider], [role=toolbar], [role=progressbar]") {
            if DOM.isConnected(el), !DOM.isTag(el, ["body", "html"]) { DOM.remove(el) }
        }
        for el in DOM.select(root, "span, div, output, small, label, p") {
            guard DOM.isConnected(el), DOM.first(el, media) == nil else { continue }
            let t = DOM.squash(DOM.rawText(el))
            if t.isEmpty || t.count > 24 || !(timeCode.test(t) || nOfM.test(t)) { continue }
            if let parent = el.parent(), DOM.closest(parent, textBlock) != nil { continue }
            if inPlayer(el, root: root) { DOM.remove(el) }
        }
    }

    // MARK: normalizeCodeBlocks

    private static let gutterNumbers = P("^1(?:\\s+\\d+)*$")
    private static let langClass = P("\\b(?:language|lang)-[\\w+#-]+")

    private static func trimTrailingNewline(_ s: String) -> String {
        s.hasSuffix("\n") ? String(s.dropLast()) : s
    }

    /// Code blocks that render each line as its own element with a line-number cell, or that sit in a line-number
    /// table: rebuild each as a plain <pre><code>, one line per row, numbers dropped.
    static func normalizeCodeBlocks(_ root: Element) {
        for pre in DOM.select(root, "pre") {
            guard DOM.isConnected(pre) else { continue }
            if let parent = pre.parent(), DOM.closest(parent, "pre") != nil { continue }
            // Inside <pre> a <br> is a newline; make it one so the text keeps it.
            for br in DOM.select(pre, "br") { DOM.replace(br, with: TextNode("\n", "")) }
            let rows = DOM.children(pre).filter { !DOM.isTag($0, ["br", "script", "style"]) }
            var text: String?
            func lineNo(_ row: Element, _ i: Int) -> Element? {
                let kids = DOM.children(row)
                guard let first = kids.first, let last = kids.last, first !== last else { return nil }
                return DOM.rawText(first).trimmingCharacters(in: .whitespacesAndNewlines) == String(i + 1) ? first : nil
            }
            if rows.count >= 2, rows.allSatisfy({ DOM.isTag($0, ["div", "p", "span", "li"]) }) {
                let numbered = rows.enumerated().map { lineNo($0.element, $0.offset) }
                if Double(numbered.compactMap { $0 }.count) >= Double(rows.count) * 0.8 {
                    numbered.forEach { if let n = $0 { DOM.remove(n) } }
                    text = rows.map { trimTrailingNewline(DOM.rawText($0)) }.joined(separator: "\n")
                } else if rows.allSatisfy({ DOM.isTag($0, ["div", "p"]) }) {
                    text = rows.map { trimTrailingNewline(DOM.rawText($0)) }.joined(separator: "\n")
                }
            }
            // A gutter <pre> of bare sequential numbers next to the code (line-number tables): drop it.
            let t = DOM.rawText(pre).trimmingCharacters(in: .whitespacesAndNewlines)
            if gutterNumbers.test(t) {
                let nums = t.split(whereSeparator: { $0.isWhitespace })
                if nums.enumerated().allSatisfy({ Int($0.element) == $0.offset + 1 }),
                   let table = DOM.closest(pre, "table"),
                   DOM.select(table, "pre").contains(where: { $0 !== pre }) {
                    DOM.remove(DOM.closest(pre, "td") ?? pre)
                    continue
                }
            }
            // <code><pre>…</pre></code> is inverted; the outer <code> goes too.
            var outer: Element = pre
            if let parent = pre.parent(), DOM.tag(parent) == "code", DOM.children(parent).count == 1 { outer = parent }
            let classes = [outer, pre, DOM.first(pre, "code")].map { $0.flatMap { DOM.attr($0, "class") } ?? "" }.joined(separator: " ")
            let lang = langClass.firstMatch(classes)?[0] ?? nil
            if text == nil && outer === pre { continue }
            guard let fresh = DOM.createElement("pre", near: pre), let code = DOM.createElement("code", near: pre) else { continue }
            if let lang { DOM.setAttr(code, "class", lang) }
            _ = try? code.appendChild(TextNode(text ?? DOM.rawText(pre), ""))
            _ = try? fresh.appendChild(code)
            DOM.replace(outer, with: fresh)
        }
        // Line-number tables: once the gutter is gone, a one-cell table is just a wrapper.
        for table in DOM.select(root, "table") {
            guard DOM.isConnected(table) else { continue }
            let cells = DOM.select(table, "td, th")
            guard cells.count == 1, let pre = DOM.first(table, "pre") else { continue }
            if DOM.rawText(cells[0]).trimmingCharacters(in: .whitespacesAndNewlines) == DOM.rawText(pre).trimmingCharacters(in: .whitespacesAndNewlines) {
                DOM.replace(table, with: pre)
            }
        }
    }

    // MARK: dropDarkVariants

    private static let darkToken = P("^(?!no[-_]|has[-_])(?:[\\w-]*[-_])?dark(?:[-_]?mode)?(?:[-_](?:alt|alternative|only|variant|version|image|img))?$", caseInsensitive: true)
    private static let darkVariant = P("^dark:(?!hidden)")

    /// A light and a dark copy of a figure side by side, toggled by CSS: keep the light copy.
    static func dropDarkVariants(_ root: Element) {
        func isDark(_ el: Element) -> Bool {
            let tokens = DOM.classTokens(el)
            if tokens.contains(where: { darkToken.test($0) }) { return true }
            return tokens.contains("hidden") && tokens.contains(where: { darkVariant.test($0) })
        }
        for el in DOM.select(root, "img, picture, video") {
            guard DOM.isConnected(el), isDark(el), let parent = el.parent() else { continue }
            let siblings = DOM.children(parent).filter { $0 !== el && DOM.isTag($0, ["img", "picture", "video"]) }
            if siblings.contains(where: { !isDark($0) }) { DOM.remove(el) }
        }
    }

    // MARK: protectMedia / restoreMedia

    static let placeholder = "https://opendispatch.invalid/media/"
    private static let placeholderImg = P("<img[^>]*?src=\"https://opendispatch\\.invalid/media/(\\d+)\"[^>]*>")

    /// Readability only understands <img>: a wrapper holding just a <video> or an inline <svg> chart scores as empty.
    /// Stand each one in as a placeholder <img> while Readability runs; restoreMedia puts the originals back.
    static func protectMedia(_ root: Element) -> [String] {
        var saved: [String] = []
        for el in DOM.select(root, "video, audio, svg") {
            guard DOM.isConnected(el) else { continue }
            if let parent = el.parent(), DOM.closest(parent, "svg, video, audio") != nil { continue }
            if DOM.tag(el) == "svg" && isIconSvg(el) { continue }
            guard let img = DOM.createElement("img", near: el) else { continue }
            DOM.setAttr(img, "src", "\(placeholder)\(saved.count)")
            DOM.setAttr(img, "alt", DOM.attr(el, "aria-label") ?? "")
            saved.append(DOM.outerHTML(el))
            DOM.replace(el, with: img)
        }
        return saved
    }

    static func restoreMedia(_ html: String, _ saved: [String]) -> String {
        guard !saved.isEmpty else { return html }
        return placeholderImg.replacing(html) { g in
            guard let s = g[1], let i = Int(s), saved.indices.contains(i) else { return "" }
            return saved[i]
        }
    }

    // MARK: markClientRenderedFigures

    static let figureMedia = "img, picture, svg, video, audio, iframe, canvas, object, embed, table, pre, math, noscript"

    /// Figures whose graphic is drawn client-side arrive as a caption with nothing above it. Say so and link to the
    /// figure on the original page. (The web app also rendered openai.com's Vega-Lite charts server-side; the native
    /// port does not bundle Vega, so those figures get the link too.)
    static func markClientRenderedFigures(_ root: Element, pageURL: String) {
        for fig in DOM.select(root, "figure") {
            guard let caption = DOM.first(fig, "figcaption"), DOM.first(fig, figureMedia) == nil else { continue }
            let figText = DOM.rawText(fig)
            let capText = DOM.rawText(caption)
            var body = figText
            if !capText.isEmpty, let r = body.range(of: capText) { body.removeSubrange(r) }
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let targets = ([fig] + DOM.select(fig, "[id]")).filter { DOM.attr($0, "id") != nil }
            let pageBase = pageURL.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? pageURL
            let href = targets.first.flatMap { DOM.attr($0, "id") }.map { "\(pageBase)#\(DOM.encodeURIComponent($0))" } ?? pageURL
            _ = try? caption.before("<p><em>Interactive figure not shown here. View it in the <a href=\"\(DOM.escapeAttr(href))\">original article</a>.</em></p>")
        }
    }

    // MARK: placePayloadVideos

    static let videoSlot = "[data-video-container]"

    /// Put players that exist only in the RSC payload into their figures (matched by poster <img>, an alt-text label,
    /// or the first empty video slot after the paragraph that precedes the player in the payload).
    static func placePayloadVideos(_ root: Element, _ videos: [ExtractionPayload.Video]) {
        guard !videos.isEmpty else { return }
        let order = DOM.documentOrder(root)
        func at(_ el: Element) -> Int { order[ObjectIdentifier(el)] ?? -1 }
        let figures = DOM.select(root, "figure")
        var claimed: [Element] = []
        for v in videos {
            if DOM.select(root, "iframe[src]").contains(where: { (DOM.attr($0, "src") ?? "").contains(v.key) }) { continue }
            let names = v.names.map { DOM.norm($0) }
            func isPoster(_ img: Element) -> Bool {
                if names.contains(DOM.norm(DOM.attr(img, "alt"))) { return true }
                if let file = v.posterFile, !file.isEmpty, (DOM.attr(img, "src") ?? "").contains(file) { return true }
                return false
            }
            let open = figures.filter { f in !claimed.contains(where: { $0 === f }) }
            var poster: Element?
            var fig: Element?
            for f in open {
                if let p = DOM.select(f, "img").first(where: isPoster) { poster = p; fig = f; break }
            }
            if fig == nil {
                fig = open.first { f in DOM.select(f, "span, div, p").contains { names.contains(DOM.norm(DOM.text($0))) } }
            }
            if fig == nil, let anchor = v.anchor {
                let a = DOM.norm(anchor)
                if let para = DOM.select(root, "p, li, blockquote, h2, h3, h4").first(where: { DOM.norm(DOM.text($0)).contains(a) }),
                   let next = open.first(where: { at($0) > at(para) }),
                   DOM.first(next, "iframe, video") == nil,
                   DOM.first(next, videoSlot) != nil || (DOM.first(next, figureMedia) == nil && DOM.text(next).isEmpty) {
                    fig = next
                }
            }
            guard let target = fig, let iframe = DOM.createElement("iframe", near: target) else { continue }
            claimed.append(target)
            DOM.setAttr(iframe, "src", ArticleSanitizer.embedSrc(v.src, watchable: true))
            DOM.setAttr(iframe, "allow", "fullscreen; picture-in-picture")
            DOM.setAttr(iframe, "allowfullscreen", "")
            if let poster {
                DOM.replace(poster, with: iframe)
            } else if let slot = DOM.first(target, videoSlot) {
                _ = slot.empty()
                _ = try? slot.appendChild(iframe)
            } else {
                _ = try? target.prependChild(iframe)
            }
        }
    }

    // MARK: Images

    static let tinyImg: Double = 64
    private static let authorHref = P("/(authors?|author-profile|people|staff|contributors?)/", caseInsensitive: true)
    private static let avatarSrc = P("gravatar\\.com|/avatars?/|[?&]s=(?:[1-9]\\d?|1[0-2]\\d)(?:&|$)", caseInsensitive: true)
    private static let avatarClass = P("\\b(avatar|author)", caseInsensitive: true)
    static let genericLead = P("logo|favicon|\\bicon|avatar|gravatar|placeholder|default[-_]?(?:og|share|social)", caseInsensitive: true)

    static func isTinyImg(_ img: Element) -> Bool {
        let w = DOM.jsNumber(DOM.attr(img, "width"))
        let h = DOM.jsNumber(DOM.attr(img, "height"))
        if w > 0 && h > 0 && w <= tinyImg && h <= tinyImg { return true }
        return avatarSrc.test(DOM.attr(img, "src") ?? "") || avatarClass.test(DOM.attr(img, "class") ?? "")
    }

    /// Inline SVG icons and decoration: aria-hidden, small declared or viewBox size, or no size at all.
    static func isIconSvg(_ svg: Element) -> Bool {
        if let parent = svg.parent(), DOM.closest(parent, "svg") != nil { return false }
        if DOM.attr(svg, "aria-hidden") == "true" { return true }
        let w = DOM.jsParseFloat(DOM.attr(svg, "width")) ?? 0
        let h = DOM.jsParseFloat(DOM.attr(svg, "height")) ?? 0
        if w > 0 && h > 0 { return w <= tinyImg && h <= tinyImg }
        let vbRaw = (DOM.attr(svg, "viewbox") ?? DOM.attr(svg, "viewBox") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let vb = vbRaw.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { Double($0) ?? .nan }
        if vb.count == 4 && vb[2] > 0 && vb[3] > 0 { return vb[2] <= tinyImg && vb[3] <= tinyImg }
        return true
    }

    /// Site logos and avatars make poor heroes; prefer nothing over those.
    static func usableLead(_ u: String?) -> String? {
        guard let u, !u.isEmpty, !genericLead.test(u) else { return nil }
        return u
    }

    // README badges (build status, chat, version): never a hero.
    private static let badgeHost = P("(?:^|\\.)(?:shields\\.io|badgen\\.net|badge\\.fury\\.io|travis-ci\\.(?:org|com)|circleci\\.com|codecov\\.io|coveralls\\.io|readthedocs\\.org|deepwiki\\.com|snyk\\.io|bestpractices\\.dev)$", caseInsensitive: true)
    private static let badgePath = P("/badges?(?:/|\\.svg)|[/_-]badge\\.svg(?:[?#]|$)|/workflows/[^/]+/badge", caseInsensitive: true)

    static func isBadge(_ img: Element) -> Bool {
        let src = DOM.attr(img, "src") ?? ""
        if let url = URL(string: src), url.scheme != nil, let host = url.host(percentEncoded: false) {
            if badgeHost.test(host) || badgePath.test(url.path(percentEncoded: true)) { return true }
        }
        // A strip: far wider than tall and short (badges, dividers, wordmarks).
        let w = DOM.jsNumber(DOM.attr(img, "width"))
        let h = DOM.jsNumber(DOM.attr(img, "height"))
        return w > 0 && h > 0 && h <= 40 && w / h >= 3
    }

    /// First content image that is big enough to be a hero (declared width ≥ 400, or undeclared).
    static func firstImage(_ html: String) -> String? {
        DOM.withFragment(html) { body -> String? in
            for img in DOM.select(body, "img[src]") {
                let w = DOM.jsNumber(DOM.attr(img, "width"))
                guard let src = DOM.attr(img, "src") else { continue }
                if isTinyImg(img) || isBadge(img) || (w > 0 && w < 400) || genericLead.test(src) { continue }
                return src
            }
            return nil
        } ?? nil
    }

    // MARK: Boilerplate

    static let contentMedia = "img, picture, video, audio, svg, iframe, pre, table, canvas, math"

    static func hasMediaOrText(_ el: Element) -> Bool {
        !DOM.text(el).isEmpty || DOM.matches(el, contentMedia) || DOM.first(el, contentMedia) != nil
    }

    private static let boilerplateLines = [
        P("^(?:view|see|read) (?:full |author )?bio$", caseInsensitive: true),
        P("^share(?: this)?(?: (?:article|story|post|page))?:?$", caseInsensitive: true),
        P("^\\[email ?protected\\]$", caseInsensitive: true),
    ]
    private static let relatedLine = P("^(?:related|recommended) (?:articles?|stories|posts|reading|content):?$", caseInsensitive: true)
    private static let affiliate = P("\\bwhen you (?:buy|purchase|shop|click)\\b.{0,80}\\b(?:we|us|our)\\b.{0,40}\\b(?:commission|earn|compensat)|\\b(?:links?|purchases?|buy|shop)\\b.{0,80}\\bwe (?:may |might |could )?(?:earn|receive|get) (?:a |an )?(?:small |affiliate )?(?:commission|share of (?:the )?(?:sales?|revenue))\\b|\\bwe (?:may |might |could )?(?:earn|receive|get) (?:a |an )?(?:small |affiliate )?(?:commission|share of (?:the )?(?:sales?|revenue))\\b.{0,80}\\b(?:links?|purchases?|buy|shop)|\\b(?:this|our) (?:post|article|page|site|story|newsletter) (?:may )?(?:contains?|includes?|uses?) affiliate links\\b", caseInsensitive: true)
    private static let quotation = P("[\"“”«»]")
    private static let cfEmail = P("\\[email ?protected\\]", caseInsensitive: true)
    private static let bioLead = P("^(?:[A-Z][\\p{L}’'.-]+ ){0,3}[A-Z][\\p{L}’'.-]+ (?:is|was|covers|writes|reports|has (?:been|covered|written|reported))\\b")
    private static let bioRole = P("\\b(?:reporter|writer|editor|journalist|correspondent|contributor|columnist|covers|covering)\\b")
    private static let bioPlace = P("\\b(?:based (?:in|out of)|previously (?:worked|wrote|covered|was))\\b")
    private static let pronoun = P("\\b(?:he|she|they|his|her|their)\\b", caseInsensitive: true)
    private static let bioSignal = P("\\bview bio\\b|\\[email ?protected\\]|\\b(?:contact|reach|email|verify outreach from)\\b.{0,40}\\b(?:him|her|them|at)\\b|\\bfollow (?:him|her|them)\\b|\\bfollow\\b.{0,40}\\bon (?:twitter|x|bluesky|mastodon|threads|linkedin|instagram)\\b", caseInsensitive: true)
    static let cfEmailLink = "a[href*=/cdn-cgi/l/email-protection]"

    static func isBio(_ t: String) -> Bool {
        guard bioLead.test(t) else { return false }
        let head = String(t.prefix(300))
        return bioRole.test(head) || (bioPlace.test(head) && pronoun.test(t))
    }

    /// The outermost ancestor (below root) holding exactly the same text: the block a line sits in.
    static func lineBlock(_ el: Element, root: Element) -> Element {
        let t = DOM.text(el)
        var b = el
        while let p = b.parent(), p !== root, !(p is Document), DOM.text(p) == t { b = p }
        return b
    }

    /// The next node after `node` in document order that holds text or media, staying inside `root`.
    static func nextContent(_ node: Node, root: Element) -> Node? {
        func step(_ n: Node) -> Node? {
            var cur: Node? = n
            while let c = cur, c !== root, c.nextSibling() == nil { cur = c.parent() }
            guard let c = cur, c !== root else { return nil }
            return c.nextSibling()
        }
        var cur = step(node)
        while let c = cur {
            if let t = c as? TextNode, !DOM.squash(t.getWholeText()).isEmpty { return c }
            if let el = c as? Element, !DOM.isTag(el, ["hr", "br", "script", "style"]), hasMediaOrText(el) { return c }
            cur = step(c)
        }
        return nil
    }

    /// Generic boilerplate Readability leaves in: affiliate disclosures, "View Bio" / "Share this" / "Related articles"
    /// lines, Cloudflare's "[email protected]" placeholder, and an author bio at the very end. Only short blocks.
    static func removeBoilerplate(_ root: Element) {
        func ps() -> [Element] { DOM.select(root, "p").filter { DOM.isConnected($0) && !DOM.text($0).isEmpty } }
        // Trailing bio first, while its signals are still there.
        let all = ps()
        let tail = Array(all.suffix(3))
        let start = tail.indices.first { i in
            let rest = tail[i...]
            return isBio(DOM.text(tail[i]))
                && rest.allSatisfy { DOM.text($0).count <= 400 }
                && rest.contains { bioSignal.test(DOM.text($0)) || DOM.first($0, cfEmailLink) != nil }
        }
        if let start, all.count > tail.count {
            for p in tail[start...] { DOM.remove(lineBlock(p, root: root)) }
        }
        // Cloudflare-obfuscated addresses: drop a short line holding one, else just the link.
        for el in DOM.select(root, "\(cfEmailLink), .__cf_email__") {
            guard DOM.isConnected(el) else { continue }
            if let block = DOM.closest(el, "p, li"), DOM.text(block).count <= 400 { DOM.remove(block) }
            else { DOM.remove(lineBlock(el, root: root)) }
        }
        for p in ps() where cfEmail.test(DOM.text(p)) && DOM.text(p).count <= 400 { DOM.remove(p) }
        for el in DOM.select(root, "p, li, div, section, aside, a, span, em, small, h2, h3, h4, h5, h6") {
            guard DOM.isConnected(el) else { continue }
            let t = DOM.text(el)
            if !t.isEmpty, boilerplateLines.contains(where: { $0.test(t) }) { DOM.remove(lineBlock(el, root: root)) }
        }
        for el in DOM.select(root, "p, li, div, section, aside, span, strong, b, h2, h3, h4, h5, h6") {
            guard DOM.isConnected(el), relatedLine.test(DOM.text(el)) else { continue }
            let block = lineBlock(el, root: root)
            var links = false
            if let next = nextContent(block, root: root) as? Element {
                links = DOM.matches(next, "a[href]") || DOM.first(next, "a[href]") != nil
            }
            if !links { DOM.remove(block) }
        }
        for el in DOM.select(root, "p, li, div, section, aside, small") {
            guard DOM.isConnected(el) else { continue }
            let t = DOM.text(el)
            if t.count <= 300, affiliate.test(t), !quotation.test(t), DOM.first(el, contentMedia) == nil { DOM.remove(el) }
        }
    }

    static let embedPlayer = "video, iframe[src*=player.vimeo.com/], iframe[src*=youtube.com/embed/], iframe[src*=youtube-nocookie.com/embed/]"
    private static let posterWord = P("\\bposter\\b", caseInsensitive: true)

    /// Media left without anything to play, and a poster still beside its own video.
    static func removeDeadMedia(_ root: Element) {
        for player in DOM.select(root, embedPlayer) {
            guard let box = DOM.closest(player, "figure") ?? player.parent()?.parent(), !(box is Document) else { continue }
            for img in DOM.select(box, "img") {
                guard posterWord.test("\(DOM.attr(img, "alt") ?? "") \(DOM.attr(img, "src") ?? "")") else { continue }
                var gone: Element = img
                // Its wrappers go too when it was all they held.
                while let p = gone.parent(), p !== box, DOM.children(p).count == 1, DOM.text(p).isEmpty { gone = p }
                DOM.remove(gone)
            }
        }
        for v in DOM.select(root, "video") {
            let playable = DOM.attr(v, "src") != nil || DOM.select(v, "source").contains { DOM.attr($0, "src") != nil }
            if !playable { DOM.remove(v) }
        }
        for img in DOM.select(root, "img[src]") {
            guard DOM.isConnected(img), let parent = img.parent(), let src = DOM.attr(img, "src") else { continue }
            if DOM.select(parent, "video[poster]").contains(where: { DOM.attr($0, "poster") == src }) { DOM.remove(img) }
        }
    }

    // MARK: cleanArticle

    private static let labelText = P("^[^.]{1,40}:$")

    /// Readability keeps inline author cards and link-only navigation tables. Drop both, plus avatar-sized images,
    /// boilerplate lines, player leftovers and section labels left with nothing under them. With `base`, URLs are
    /// absolutized again first.
    static func cleanArticle(_ html: String, base: String?) -> String {
        DOM.withFragment("<div id=\"__root\">\(html)</div>") { body -> String in
            guard let root = DOM.first(body, "#__root") else { return html }
            return cleanArticle(root: root, base: base)
        } ?? html
    }

    private static func cleanArticle(root: Element, base: String?) -> String {
        if let base { absolutize(root, base: base) }
        removeScreenReaderText(root)
        removePlayerChrome(root)
        removeDeadMedia(root)
        for el in DOM.select(root, "div, section, aside, p, figure") {
            guard DOM.isConnected(el) else { continue }
            if DOM.rawText(el).trimmingCharacters(in: .whitespacesAndNewlines).count > 400 { continue }
            let hasAvatar = DOM.select(el, "img").contains(where: isTinyImg)
            let hasAuthorLink = DOM.select(el, "a[href]").contains {
                authorHref.test(DOM.attr($0, "href") ?? "") || DOM.attr($0, "rel") == "author"
            }
            if hasAvatar || hasAuthorLink { DOM.remove(el) }
        }
        // After author cards: their profile links are what identifies them.
        removeBoilerplate(root)
        for img in DOM.select(root, "img") where isTinyImg(img) { DOM.remove(img) }
        for svg in DOM.select(root, "svg") where DOM.isConnected(svg) && isIconSvg(svg) { DOM.remove(svg) }
        // Navigation tables (old-school sites): mostly links, little prose.
        for table in DOM.select(root, "table") {
            guard DOM.isConnected(table) else { continue }
            let text = DOM.squash(DOM.rawText(table))
            let links = DOM.select(table, "a[href]")
            let linkText = links.reduce(0) { $0 + DOM.rawText($1).trimmingCharacters(in: .whitespacesAndNewlines).count }
            if links.count >= 4 && !text.isEmpty && Double(linkText) / Double(text.count) > 0.6 { DOM.remove(table) }
        }
        // Section labels left with nothing under them: real headings, or short bold "Label:" lines.
        func isLabel(_ el: Element) -> Bool {
            if DOM.isTag(el, DOM.headingTags) { return true }
            guard DOM.isTag(el, ["b", "strong", "p"]), labelText.test(DOM.text(el)) else { return false }
            return DOM.tag(el) == "p" || DOM.text(el.parent()) == DOM.text(el)
        }
        func rank(_ el: Element) -> Int {
            let t = DOM.tag(el)
            if DOM.headingTags.contains(t), let n = Int(t.dropFirst()) { return n }
            return 7
        }
        func leadingLabel(_ n: Node?) -> Element? {
            var el = n as? Element
            while let cur = el {
                if isLabel(cur) { return cur }
                if DOM.matches(cur, contentMedia) { return nil }
                let first = cur.getChildNodes().first { c in
                    if let t = c as? TextNode { return !DOM.squash(t.getWholeText()).isEmpty }
                    if let e = c as? Element { return hasMediaOrText(e) }
                    return false
                }
                el = first as? Element
            }
            return nil
        }
        for h in DOM.select(root, "h1, h2, h3, h4, h5, h6, b, strong, p") {
            guard DOM.isConnected(h), isLabel(h) else { continue }
            let block = lineBlock(h, root: root)
            let next = nextContent(block, root: root)
            let label = leadingLabel(next)
            if next == nil || (label.map { rank($0) <= rank(h) } ?? false) { DOM.remove(block) }
        }
        return DOM.innerHTML(root)
    }

    // MARK: mergeSplitContainers

    private static let contentToken = P("(?:^|[-_])(?:content|body|text|article|entry|story|post|prose|copy)(?:[-_]|$)", caseInsensitive: true)
    private static let sideToken = P("comment|repl|related|sidebar|footer|header|nav|menu|teaser|card|excerpt|summary|preview|promo|widget|share|caption|meta|author|bio|tag", caseInsensitive: true)
    private static let commentToken = P("^(?:[\\w-]*[-_])?(?:comments?|comment-?list|repl(?:y|ies)|disqus|discussions?|responses)(?:[-_][\\w-]*)?$", caseInsensitive: true)
    static let maxSplitDepth = 4
    static let maxTextBetween = 200

    /// The next node after `node`'s subtree in document order.
    static func nextOutside(_ node: Node) -> Node? {
        var n: Node? = node
        while let c = n, c.nextSibling() == nil { n = c.parent() }
        return n?.nextSibling()
    }

    /// What sits between two elements in document order, outside both: text length and whether it holds a heading.
    static func between(_ a: Element, _ b: Element) -> (text: Int, heading: Bool) {
        var text = 0
        var heading = false
        var cur = nextOutside(a)
        while let c = cur, c !== b {
            if DOM.contains(c, b) {
                cur = c.childNodeSize() > 0 ? c.childNode(0) : nextOutside(c)
                continue
            }
            if let el = c as? Element {
                if !DOM.isTag(el, ["script", "style", "noscript", "template"]) {
                    text += DOM.textLen(DOM.text(el))
                    if DOM.isTag(el, ["h1", "h2", "h3"]) || DOM.first(el, "h1, h2, h3") != nil { heading = true }
                }
            } else if let t = c as? TextNode {
                text += DOM.textLen(t.getWholeText())
            }
            cur = nextOutside(c)
        }
        return (text, heading)
    }

    static func depthBelow(_ el: Element, _ ancestor: Element) -> Int {
        var d = 0
        var n: Element? = el
        while let c = n, c !== ancestor { d += 1; n = c.parent() }
        return d
    }

    /// True when `el` or an ancestor below `stop` is a comment thread (by class token or id).
    static func inComments(_ el: Element, stop: Element?) -> Bool {
        var n: Element? = el
        while let c = n, c !== stop, !(c is Document) {
            let names = DOM.classTokens(c) + [DOM.attr(c, "id") ?? ""]
            if names.contains(where: { !$0.isEmpty && commentToken.test($0) }) { return true }
            n = c.parent()
        }
        return false
    }

    static func commonAncestor(_ els: [Element]) -> Element? {
        var anc = els.first?.parent()
        while let a = anc, !els.allSatisfy({ DOM.contains(a, $0) }) { anc = a.parent() }
        return anc
    }

    /// Sites that split one article across several same-class containers (Ars Technica's `.post-content` blocks with
    /// ads between them): join them into the first when they are near-siblings in the same <article>, each holds prose,
    /// and only a little text and no heading separates them. Blocks inside a comment thread never join.
    static func mergeSplitContainers(_ root: Element) {
        var keys: [String] = []
        var groups: [String: [Element]] = [:]
        for el in DOM.select(root, "div[class], section[class], article[class]") {
            for t in DOM.classTokens(el) {
                guard contentToken.test(t), !sideToken.test(t), !utilityClass.test(t) else { continue }
                let key = t.lowercased()
                if groups[key] == nil { keys.append(key) }
                groups[key, default: []].append(el)
            }
        }
        for key in keys {
            let live = (groups[key] ?? []).filter { DOM.isConnected($0) }
            // Outermost only: a .post-content nested in another .post-content is part of it already.
            let outer = live.filter { m in !live.contains { $0 !== m && DOM.contains($0, m) } }
            guard outer.count >= 2 else { continue }
            let top = commonAncestor(outer)
            let blocks = outer.filter { !inComments($0, stop: top) }
            guard blocks.count >= 2, !blocks.contains(where: { DOM.proseLen($0) < 80 }) else { continue }
            let art = DOM.closest(blocks[0], "article")
            guard blocks.allSatisfy({ DOM.closest($0, "article") === art }) else { continue }
            guard let anc = commonAncestor(blocks), !blocks.contains(where: { depthBelow($0, anc) > maxSplitDepth }) else { continue }
            let gaps = (1..<blocks.count).map { between(blocks[$0 - 1], blocks[$0]) }
            if gaps.contains(where: { $0.heading || $0.text > maxTextBetween }) { continue }
            let first = blocks[0]
            for b in blocks.dropFirst() {
                for child in b.getChildNodes() { _ = try? first.appendChild(child) }
                DOM.remove(b)
            }
        }
    }

    /// Page-wide cleanup that must happen while the page's class names and structure are intact.
    static func prepare(_ root: Element, base: String, pageURL: String, videos: [ExtractionPayload.Video] = []) {
        absolutize(root, base: base)
        removeScreenReaderText(root)
        removePlayerChrome(root)
        normalizeCodeBlocks(root)
        dropDarkVariants(root)
        markClientRenderedFigures(root, pageURL: pageURL)
        placePayloadVideos(root, videos)
    }
}
