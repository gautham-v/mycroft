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
    /// A link through Google's redirector (`google.com/url?q=…`, pasted from Docs) goes straight to its target.
    static func unredirected(_ href: String) -> String {
        guard let c = URLComponents(string: href), let host = c.host?.lowercased(),
              host == "google.com" || host == "www.google.com", c.path == "/url",
              let target = c.queryItems?.first(where: { $0.name == "q" || $0.name == "url" })?.value,
              target.lowercased().hasPrefix("http") else { return href }
        return target
    }

    static func absolutize(_ root: Element, base: String) {
        for el in DOM.select(root, "a[href]") {
            if let v = DOM.absURL(DOM.attr(el, "href"), base: base) { DOM.setAttr(el, "href", unredirected(v)) }
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
        // A bare `hidden` really is hidden (the desktop copy of a responsive pair); keep it.
        func droppable(_ token: String) -> Bool { token != "hidden" && layoutNegative.test(token) }
        for el in DOM.select(root, "[class]") {
            // Tokens first: few elements carry a layout word, and the wrapper tests read the subtree's text
            // (on every classed element that made this pass most of the extraction time).
            guard DOM.classTokens(el).contains(where: droppable) else { continue }
            if inFigure(el) || mediaWrapper(el) || codeWrapper(el) {
                dropClassTokens(el, droppable)
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

    // MARK: normalizeEmbeds

    private static let mastodonEmbed = P(#"^(https?://[^/]+/@[^/?#]+/\d+)/embed\b"#, caseInsensitive: true)
    private static let linkedinEmbed = P(#"^https?://(?:www\.)?linkedin\.com/embed/feed/update/(urn:li:[a-z]+:\d+)"#, caseInsensitive: true)
    private static let tiktokUser = P(#"tiktok\.com/@([^/?#]+)"#, caseInsensitive: true)
    private static let blueskyURI = P(#"^at://([^/]+)/app\.bsky\.feed\.post/([A-Za-z0-9]+)"#)

    /// Every network's embed as one shape for `EmbeddedPosts`: a blockquote ending with a link to the post. Bluesky,
    /// Threads and TikTok blockquotes keep their fallback text and get the post's address from their data attributes
    /// (the sanitizer drops those); Instagram's fallback is only "View this post on Instagram" and icons, and Mastodon's
    /// and LinkedIn's are iframes the sanitizer would drop, so those become a blockquote with a link.
    static func normalizeEmbeds(_ root: Element) {
        func link(_ href: String, _ text: String) -> String {
            "<p><a href=\"\(DOM.escapeAttr(href))\">\(DOM.escapeHTML(text))</a></p>"
        }
        for q in DOM.select(root, "blockquote[data-bluesky-uri], blockquote[data-text-post-permalink], blockquote.tiktok-embed") {
            var href: String?
            if let m = blueskyURI.firstMatch(DOM.attr(q, "data-bluesky-uri") ?? ""), let did = m[1], let rkey = m[2] {
                href = "https://bsky.app/profile/\(did)/post/\(rkey)"
            }
            // A TikTok embed may name only its video (Mashable, Lifehacker); the account comes from its fallback's link.
            if href == nil, DOM.attr(q, "cite") == nil, let id = DOM.attr(q, "data-video-id") {
                let user = DOM.select(q, "a[href*=tiktok.com/@]").compactMap { tiktokUser.firstMatch(DOM.attr($0, "href") ?? "")?[1] ?? nil }.first
                href = "https://www.tiktok.com/@\(user ?? "tiktok")/video/\(id)"
            }
            href = href ?? DOM.attr(q, "data-text-post-permalink") ?? DOM.attr(q, "cite")
            guard let href else { continue }
            _ = try? q.append(link(href, href))
        }
        for q in DOM.select(root, "blockquote.instagram-media") {
            guard let href = DOM.attr(q, "data-instgrm-permalink") ?? DOM.select(q, "a[href*=instagram.com]").first.flatMap({ DOM.attr($0, "href") }) else { continue }
            DOM.replace(q, withHTML: "<blockquote>\(link(href, "View this post on Instagram"))</blockquote>")
        }
        for el in DOM.select(root, "iframe[src], blockquote[data-embed-url]") {
            let src = DOM.attr(el, "src") ?? DOM.attr(el, "data-embed-url") ?? ""
            var href: String?
            if let m = mastodonEmbed.firstMatch(src), let post = m[1] { href = post }
            if let m = linkedinEmbed.firstMatch(src), let urn = m[1] { href = "https://www.linkedin.com/feed/update/\(urn)" }
            guard let href else { continue }
            DOM.replace(el, withHTML: "<blockquote>\(link(href, href))</blockquote>")
        }
    }

    // MARK: removeInterface

    static let maxButtonText = 24

    /// Page controls that read as words once their styling is gone: short buttons ("toggle caption", "Share"; a longer
    /// one may be an accordion's question), popovers (an author card shown on hover) and Google's "add as a preferred
    /// source" link.
    static func removeInterface(_ root: Element) {
        for el in DOM.select(root, "button, [popover], [role=button][aria-haspopup], [role=button][aria-expanded]") where DOM.isConnected(el) {
            if DOM.matches(el, "[popover]") || DOM.text(el).count <= maxButtonText { DOM.remove(el) }
        }
        // Boxes that are page furniture by name: author cards and pop-overs (ESPN's author-overlay with its "Close"
        // link and bios, The Verge's byline card, TechCrunch's author-card-bio), calls to action and Ghost's
        // members-only prompt, AP's related-story lists. Short ones only, so a mislabeled article body survives.
        for el in DOM.select(root, "[class]") where DOM.isConnected(el) && !DOM.isTag(el, ["body", "html", "main", "article"]) {
            guard DOM.classTokens(el).contains(where: { furnitureClass.test($0) }), DOM.textLen(DOM.text(el)) <= maxFurnitureText,
                  DOM.first(el, "h1") == nil else { continue }
            DOM.remove(el)
        }
        for el in DOM.select(root, "a[href*=google.com/preferences/source]") where DOM.isConnected(el) {
            DOM.remove(lineBlock(el, root: root))
        }
    }

    static let maxFurnitureText = 1500
    private static let furnitureClass = P("^(?:[\\w-]*?[-_]{1,2})?(?:author[-_]?(?:overlay|card|bio|box|popover|profile|info)|byline[-_]?(?:wrap|card|popover)|action[-_]?box|cta(?:[-_]?(?:box|button|block|wrap|container))?|post[-_]access[-_]cta|gh[-_]post[-_]upgrade[-_]cta|page[-_]?promo|page[-_]?list(?:[-_]items?)?|recirc(?:ulation)?|newsletter[-_]?(?:signup|promo|cta|form))(?:[-_]{1,2}[\\w-]+)?$", caseInsensitive: true)

    // MARK: rebuildYouTube

    private static let youTubeID = P("^(?:yt|youtube)[-_]([\\w-]{11})$")
    private static let youTubeThumb = P("ytimg\\.com/vi/([\\w-]{11})/", caseInsensitive: true)

    /// A YouTube player its script never started: an <iframe id="yt-<id>"> with no src beside its thumbnail (Fox
    /// Sports). It gets the embed address, and the thumbnail goes.
    static func rebuildYouTube(_ root: Element) {
        for frame in DOM.select(root, "iframe[id]") where (DOM.attr(frame, "src") ?? "").isEmpty {
            guard let id = youTubeID.firstMatch(DOM.attr(frame, "id") ?? "")?[1] else { continue }
            DOM.setAttr(frame, "src", "https://www.youtube.com/embed/\(id)")
            guard let box = frame.parent() else { continue }
            for img in DOM.select(box, "img") where youTubeThumb.firstMatch(DOM.attr(img, "src") ?? "")?[1] == id {
                DOM.remove(DOM.closest(img, "a").flatMap { DOM.contains(box, $0) ? $0 : nil } ?? img)
            }
        }
    }

    // MARK: unlinkHeadings

    /// A heading that is one link (Fox Sports' "10. Jacksonville Jaguars" linking to the team page) is all link text
    /// to Readability, which then drops its block as navigation. The words stay, the link goes.
    static func unlinkHeadings(_ root: Element) {
        for h in DOM.select(root, "h2, h3, h4") {
            let links = DOM.select(h, "a[href]")
            guard links.count == 1, !DOM.text(h).isEmpty, DOM.text(links[0]) == DOM.text(h) else { continue }
            _ = try? links[0].unwrap()
        }
    }

    // MARK: collapsePictures

    private static let tinySrc = P("[,/_]w_\\d{1,2}[,/]|[?&](?:w|width)=\\d{1,2}(?:&|$)", caseInsensitive: true)
    private static let minWidthMedia = P("min-width", caseInsensitive: true)
    private static let darkMedia = P("prefers-color-scheme:\\s*dark", caseInsensitive: true)

    /// A <picture> becomes its <img>: the reader sizes one image to the column, while a <source> without `sizes`
    /// picks a candidate for the whole window (an openai.com diagram drawn at 197px) and a dark-scheme source follows
    /// the system, not the reader's theme. A picture whose script never added the <img> (ESPN's video cards) gets one
    /// from its largest light source.
    static func collapsePictures(_ root: Element) {
        for pic in DOM.select(root, "picture") where DOM.isConnected(pic) {
            let sources = DOM.select(pic, "source").filter { !darkMedia.test(DOM.attr($0, "media") ?? "") }
            if let img = DOM.first(pic, "img"), !isPlaceholderSrc(DOM.attr(img, "src")),
               sources.isEmpty || !tinySrc.test(DOM.attr(img, "src") ?? "") {
                DOM.replace(pic, with: img)
                continue
            }
            // SI's <img> is a 16px blurred stand-in (…c_fill,w_16…) for the sources; the desktop source is the picture.
            let ordered = sources.filter { minWidthMedia.test(DOM.attr($0, "media") ?? "") } + sources
            guard let src = ordered.compactMap({ s in DOM.attr(s, "srcset").flatMap(largestCandidate) ?? DOM.attr(s, "src") }).first,
                  let img = DOM.first(pic, "img") ?? DOM.createElement("img", near: pic) else { continue }
            DOM.setAttr(img, "src", src)
            DOM.removeAttr(img, "srcset")
            DOM.removeAttr(img, "sizes")
            DOM.replace(pic, with: img)
        }
    }

    // MARK: removeSamePageNav

    /// "Jump to a section" lists: links that only point at this page's own anchors. Absolutized they would leave the
    /// reader for the site; the anchors' ids are gone anyway.
    static func removeSamePageNav(_ root: Element, pageURL: String) {
        let page = pageURL.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? pageURL
        func isAnchor(_ a: Element) -> Bool {
            let href = DOM.attr(a, "href") ?? ""
            return href.hasPrefix("#") || (href.hasPrefix(page + "#"))
        }
        for list in DOM.select(root, "ul, ol") where DOM.isConnected(list) {
            let items = DOM.select(list, "li")
            guard !items.isEmpty, items.allSatisfy({ li in
                let links = DOM.select(li, "a[href]")
                return links.count == 1 && isAnchor(links[0]) && DOM.text(links[0]) == DOM.text(li)
            }) else { continue }
            DOM.remove(list)
        }
        for p in DOM.select(root, "p") where DOM.isConnected(p) {
            let links = DOM.select(p, "a[href]")
            guard links.count >= 2, links.allSatisfy(isAnchor) else { continue }
            let linkText = links.reduce(0) { $0 + DOM.text($1).count }
            if Double(linkText) >= 0.7 * Double(DOM.text(p).count) { DOM.remove(p) }
        }
    }

    // MARK: captionBlocks

    private static let captionClass = P("caption", caseInsensitive: true)
    private static let captionToggle = P("^(?:hide|show|toggle) caption$", caseInsensitive: true)

    /// A caption drawn beside its picture rather than in a <figure> (NPR: `div.imagewrap` then `div.credit-caption`,
    /// whose credit also repeats in a second span): the two become a <figure> with one <figcaption>, so the caption
    /// reads as a caption, not as the first paragraph.
    static func captionBlocks(_ root: Element) {
        for box in DOM.select(root, "div, span, p") {
            guard DOM.isConnected(box), DOM.closest(box, "figure") == nil, DOM.first(box, "img, picture, video") == nil,
                  DOM.classTokens(box).contains(where: { captionClass.test($0) }) || captionClass.test(DOM.attr(box, "id") ?? ""),
                  let pic = try? box.previousElementSibling(), DOM.closest(pic, "figure") == nil,
                  DOM.select(pic, "img").count == 1, DOM.text(pic).isEmpty,
                  let parent = box.parent(), DOM.closest(parent, "[class*=caption]") == nil else { continue }
            // The words once each (a credit repeated in a second span goes), without the show/hide control.
            var seen: Set<String> = []
            for el in DOM.select(box, "*") where DOM.isConnected(el) && DOM.children(el).allSatisfy({ DOM.text($0).isEmpty }) {
                let t = DOM.text(el)
                guard !t.isEmpty else { continue }
                if seen.contains(t) || captionToggle.test(t) { DOM.remove(el) } else { seen.insert(t) }
            }
            let caption = DOM.text(box)
            guard !placeholderText.test(caption), let img = DOM.first(pic, "picture") ?? DOM.first(pic, "img") else { continue }
            DOM.remove(box)
            DOM.replace(pic, withHTML: "<figure>\(DOM.outerHTML(img))<figcaption>\(DOM.escapeHTML(caption))</figcaption></figure>")
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

    // MARK: resolveStreamedBoundaries

    private static let streamedMove = P("\\$R([CS])\\(\"([BSP]:\\d+)\",\"([BSP]:\\d+)\"\\)")

    /// React's streamed server rendering (Next.js, Yahoo) sends a Suspense boundary's content after the page shell, in
    /// `<div hidden id="S:n">`, with a script that moves it into place: `$RC("B:n","S:n")` replaces the loading
    /// fallback after `<template id="B:n">` (up to the `<!--/$-->` comment), `$RS("S:n","P:n")` replaces
    /// `<template id="P:n">`. No script runs here and Readability skips hidden elements, so make the moves.
    static func resolveStreamedBoundaries(_ root: Element) {
        let scripts = DOM.select(root, "script:not([src])").map { $0.data() }.filter { $0.contains("$R") }
        guard !scripts.isEmpty else { return }
        for script in scripts {
            for m in streamedMove.allMatches(script) {
                guard let kind = m[1], let a = m[2], let b = m[3] else { continue }
                let (target, source) = kind == "C" ? (a, b) : (b, a)
                guard let template = DOM.first(root, "template[id=\"\(target)\"]"),
                      let content = DOM.first(root, "div[hidden][id=\"\(source)\"]"), let parent = template.parent() else { continue }
                if kind == "C" {
                    // The fallback runs from the template to the boundary's closing comment.
                    var fallback: [Node] = []
                    var node = template.nextSibling()
                    while let cur = node, !((cur as? Comment)?.getData() == "/$") {
                        fallback.append(cur)
                        node = cur.nextSibling()
                    }
                    if node != nil { fallback.forEach(DOM.remove) }
                }
                let index = template.siblingIndex
                _ = try? parent.insertChildren(index, content.getChildNodes())
                DOM.remove(template)
                DOM.remove(content)
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

    /// Readability only understands <img>: a wrapper holding just a <video>, an inline <svg> chart or an embedded post
    /// scores as empty.
    /// Stand each one in as a placeholder <img> while Readability runs; restoreMedia puts the originals back.
    static func protectMedia(_ root: Element) -> [String] {
        var saved: [String] = []
        protectEmbeds(root, saved: &saved)
        // An embedded post's blockquote is mostly a link, which Readability drops with the box it sits in.
        // Its wrappers go with it, so a class like WordPress's `is-provider-bluesky-social` can't get it thrown out.
        for el in DOM.select(root, "blockquote") where DOM.isConnected(el) && EmbeddedPosts.post(of: el) != nil {
            var box: Element = el
            while let p = box.parent(), !(p is Document), !DOM.isTag(p, ["body", "html", "main", "article"]),
                  DOM.children(p).filter({ !DOM.isTag($0, ["script", "style", "noscript"]) }).count == 1,
                  DOM.text(p) == DOM.text(box) { box = p }
            guard let img = DOM.createElement("img", near: box) else { continue }
            DOM.setAttr(img, "src", "\(placeholder)\(saved.count)")
            DOM.setAttr(img, "alt", "")
            saved.append(DOM.outerHTML(el))
            DOM.replace(box, with: img)
        }
        protectFigures(root, &saved)
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
            guard DOM.first(fig, figureMedia) == nil else { continue }
            // No caption either: a slot the page's script fills (openai.com's `data-figure-content` charts, Wired's
            // Flourish maps). Only a figure built around such a slot says so; an empty <figure> is just dropped.
            guard let caption = DOM.first(fig, "figcaption") else {
                guard DOM.text(fig).isEmpty, let slot = DOM.first(fig, "[id], [data-figure-content], [data-testid], [style*=height]") else { continue }
                let href = DOM.attr(slot, "id").map { "\(pageURL.split(separator: "#").first.map(String.init) ?? pageURL)#\(DOM.encodeURIComponent($0))" } ?? pageURL
                _ = try? fig.append("<p><em>Interactive figure not shown here. View it in the <a href=\"\(DOM.escapeAttr(href))\">original article</a>.</em></p>")
                continue
            }
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
    static let authorHref = P("/(authors?|author-profile|people|staff|contributors?)/", caseInsensitive: true)
    private static let avatarSrc = P("gravatar\\.com|/avatars?/|[?&]s=(?:[1-9]\\d?|1[0-2]\\d)(?:&|$)", caseInsensitive: true)
    private static let avatarClass = P("\\b(avatar|author)", caseInsensitive: true)
    /// Logos, avatars, a site's default share picture (NPR's facebook-default-wide) and a social card with the title
    /// set in it (openai.com's …-social.png): none is a picture of the story.
    static let genericLead = P("logo|favicon|\\bicon|avatar|gravatar|placeholder|default[-_]?(?:og|share|social)|(?:facebook|twitter|social|share|og)[-_]default|[-_](?:social|og|share)(?:[-_]image)?\\.(?:png|jpe?g|webp)(?:[?#]|$)", caseInsensitive: true)
    private static let logoWords = P("(?:^|[\\s/_.-])(?:tag[-_]?)?(?:logo|shield|icon|badge)(?:[\\s/_.-]|$)", caseInsensitive: true)

    /// An <img> named or labeled as a logo or icon.
    static func isLogo(_ el: Element) -> Bool {
        DOM.tag(el) == "img" && (logoWords.test(DOM.attr(el, "alt") ?? "") || logoWords.test(URL(string: DOM.attr(el, "src") ?? "")?.lastPathComponent ?? ""))
    }

    /// A rule drawn as a picture (ESPN's _end_rule.png).
    private static let dividerSrc = P("[/_-](?:end[-_]?)?(?:rule|divider|spacer|separator)\\.(?:png|gif|jpe?g|svg)(?:[?#]|$)", caseInsensitive: true)

    /// Avatar-sized (both sides declared small, or one side declared small and the other not at all: ESPN's
    /// 31px-wide team logos, which `width: auto` would draw at full size), an avatar by address or class, or a divider.
    static func isTinyImg(_ img: Element) -> Bool {
        let w = DOM.jsNumber(DOM.attr(img, "width"))
        let h = DOM.jsNumber(DOM.attr(img, "height"))
        if w > 0 && h > 0 && w <= tinyImg && h <= tinyImg { return true }
        if (w > 0 && w <= tinyImg && DOM.attr(img, "height") == nil) || (h > 0 && h <= tinyImg && DOM.attr(img, "width") == nil) { return true }
        let src = DOM.attr(img, "src") ?? ""
        return avatarSrc.test(src) || dividerSrc.test(src) || avatarClass.test(DOM.attr(img, "class") ?? "")
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
        guard let u, !u.isEmpty, !genericLead.test(u), !LeadImage.isGenericCard(u) else { return nil }
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
                if isTinyImg(img) || isBadge(img) || (w > 0 && w < 400) || genericLead.test(src) || isSmallThumbURL(src) { continue }
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
        // The heading of a related-stories box whose links Readability dropped ("Read More on NFL").
        P("^(?:read|see) more (?:on|from|about|in) [^.]{1,40}$", caseInsensitive: true),
        P("^(?:hide|show|toggle) caption$", caseInsensitive: true),
        // A related-story card's reading time once its headline is gone ("4 MIN READ", AP).
        P("^\\d+ min(?:ute)?s? read$", caseInsensitive: true),
        P("^edited by [^.]{2,60}$", caseInsensitive: true),
        // AP's rule before its end matter, and the line pointing to the rest of its coverage.
        P("^(?:_{3,}|-{3,}|\\*{3,})$"),
        P("^see (?:ap's|our) (?:full |complete |more )?[^.]{1,60} coverage(?: here)?\\.?$", caseInsensitive: true),
        P("^audio will be available later(?: today)?\\.?$", caseInsensitive: true),
        // A date line, with its labels and reading time ("Updated on: October 28, 2026 / 8:27 PM EDT / CBS News",
        // "Oct. 29, 2026, 12:05 p.m. ET", "29 Oct 2026", "Oct 29, 2026 at 8:01 am ET • 2 min read").
        P("^(?:(?:updated|published|posted)(?: on)?:? )?(?:[a-z]{3,9}\\.? \\d{1,2},? \\d{4}|\\d{1,2} [a-z]{3,9}\\.? \\d{4})(?:(?:,| at| /|\\s)\\s*\\d{1,2}:\\d{2}(?:\\s*[ap]\\.?m\\.?)?(?:\\s*[a-z]{2,4})?)?(?:\\s*[/•·|]\\s*(?:\\d+ min(?:ute)?s? read|[\\p{L} ]{2,30}))?$", caseInsensitive: true),
        P("^(?:\\d{1,2}:\\d{2}\\s*[ap]\\.?m\\.?(?:\\s*[a-z]{2,4})?\\s*[·•|,]\\s*)(?:[a-z]{3,9}\\.? \\d{1,2},? \\d{4}|\\d{1,2} [a-z]{3,9}\\.? \\d{4})$", caseInsensitive: true),
        P("^(?:by|close|play|watch|topics)$", caseInsensitive: true),
        // WordPress's feed footer and syndication leftovers (ClutchPoints on Yahoo).
        P("^(?:the post )?.{5,200} appeared first on [^.]{2,60}\\.?(?:\\s+add [^.]{1,40} as a(?: preferred source)?(?: on google)?\\s*\\.?)?$", caseInsensitive: true),
        P("^add [^.]{1,40} as a(?: preferred source)?(?: on google)?\\s*\\.?$", caseInsensitive: true),
        P("^watch [^.]{1,40} live (?:with|on) [^.]{1,30}(?:\\(free trial\\))?\\.?$", caseInsensitive: true),
        P("^click (?:above|here|below) to (?:subscribe|follow)\\b.{0,80}$", caseInsensitive: true),
        P("^[—–-]*\\s*[^.]{0,60}\\bfree coverage\\b[^.]{0,80}[—–-]*$", caseInsensitive: true),
        // Newsletter and follow prompts: "— Sign up for OnSI's Free Bills Newsletter —", "Add us as a preferred source
        // on Google", "Follow @ThePanthersWire on Twitter/X for more Panthers content."
        P("^[—–-]*\\s*(?:sign up|subscribe|enjoy|get)\\b[^.]{0,100}\\bnewsletters?\\b[^.]{0,40}[—–-]*$", caseInsensitive: true),
        P("^add us as a preferred source(?: on google)?\\.?$", caseInsensitive: true),
        P("^follow @\\w+ on (?:twitter|x|twitter/x|threads|bluesky|instagram)\\b.{0,60}$", caseInsensitive: true),
        P("^(?:questions or comments\\?|thanks for subscribing to)\\b.{0,160}$", caseInsensitive: true),
        // CBS News' "Add CBS News on Google" (a preferred-source link).
        P("^add [^.]{1,40} (?:on|to) google$", caseInsensitive: true),
        // An ad slot's label left behind when the ad itself is gone (Yahoo's "Advertisement" between paragraphs).
        P("^(?:advertisement|advertising|ad|sponsored|(?:the )?(?:story|article) continues (?:below|after)(?: (?:this )?(?:advertisement|ad))?|continue reading below)$",
          caseInsensitive: true),
    ]
    private static let followLine = P("^follow (?:the )?(?:topics?|authors?)\\b.{0,160}$", caseInsensitive: true)
    static let maxFollowItem = 60
    private static let personName = P("^(?:[A-Z][\\p{L}’'.-]+ ){1,3}[A-Z][\\p{L}’'.-]+\\s*,?$")
    private static let moreLabel = P("^(?:more|related|read more|also read|read also|see also|don't miss):\\s*", caseInsensitive: true)
    private static let promo = P("\\bpromo code\\b|\\bbonus bets\\b|\\bsportsbook (?:promo|bonus)|\\b(?:bet|wager) \\$\\d+,? get \\$\\d+", caseInsensitive: true)
    private static let inlineTags: Set<String> = ["a", "span", "em", "i", "strong", "b", "small", "time"]
    private static let tagLabel = P("^(?:in|tags?|topics?|filed under|more about):?$", caseInsensitive: true)
    private static let relatedLine = P("^(?:related|recommended) (?:articles?|stories|posts|reading|content):?$", caseInsensitive: true)
    private static let affiliate = P("\\bwhen you (?:buy|purchase|shop|click)\\b.{0,80}\\b(?:we|us|our)\\b.{0,40}\\b(?:commission|earn|compensat)|\\b(?:links?|purchases?|buy|shop)\\b.{0,80}\\bwe (?:may |might |could )?(?:earn|receive|get) (?:a |an )?(?:small |affiliate )?(?:commission|share of (?:the )?(?:sales?|revenue))\\b|\\bwe (?:may |might |could )?(?:earn|receive|get) (?:a |an )?(?:small |affiliate )?(?:commission|share of (?:the )?(?:sales?|revenue))\\b.{0,80}\\b(?:links?|purchases?|buy|shop)|\\b(?:this|our) (?:post|article|page|site|story|newsletter) (?:may )?(?:contains?|includes?|uses?) affiliate links\\b", caseInsensitive: true)
    private static let quotation = P("[\"“”«»]")
    private static let cfEmail = P("\\[email ?protected\\]", caseInsensitive: true)
    private static let bioLead = P("^(?:[A-Z][\\p{L}’'.-]+ ){0,3}[A-Z][\\p{L}’'.-]+ (?:is|was|covers|writes|reports|joined|has (?:been|covered|written|reported|worked|spent))\\b")
    /// A bio whose name was a separate element: "is a news writer focused on…" (The Verge's byline card).
    private static let namelessBio = P("^(?:is|was|has (?:been|worked|spent|covered|written)) (?:an? |the )?[^.]{0,80}\\b(?:reporter|writer|editor|journalist|correspondent|contributor|columnist|analyst)\\b")
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

    /// The outermost ancestor (below root) holding exactly the same text: the block a line sits in. A box that also
    /// holds a picture or player is more than the line (a caption's wrapper, a video with its fallback text).
    static func lineBlock(_ el: Element, root: Element) -> Element {
        let t = DOM.text(el)
        var b = el
        while let p = b.parent(), p !== root, !(p is Document), DOM.text(p) == t, !DOM.matches(p, contentMedia), DOM.first(p, contentMedia) == nil { b = p }
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
        for el in DOM.select(root, "p, li, div, section, aside, a, span, em, small, b, strong, h2, h3, h4, h5, h6") {
            guard DOM.isConnected(el) else { continue }
            let t = DOM.text(el)
            guard !t.isEmpty, boilerplateLines.contains(where: { $0.test(t) }) else { continue }
            // A line, not words inside one: a dated link in a sentence or a quoted post's byline stays.
            let block = lineBlock(el, root: root)
            if DOM.isTag(block, inlineTags), let parent = block.parent(), DOM.text(parent) != t { continue }
            DOM.remove(block)
        }
        // A tag list at the end: a short label ("In:", "Tags:") and a list of nothing but short links (CBS News).
        for el in DOM.select(root, "p, div, span, strong, b, h2, h3, h4, h5, h6") {
            guard DOM.isConnected(el), tagLabel.test(DOM.text(el)) else { continue }
            let block = lineBlock(el, root: root)
            guard let next = nextContent(block, root: root) as? Element,
                  let list = DOM.isTag(next, ["ul", "ol"]) ? next : DOM.closest(next, "ul, ol") else { continue }
            let items = DOM.select(list, "li")
            guard !items.isEmpty, items.allSatisfy({ li in
                DOM.text(li).count <= maxFollowItem && DOM.select(li, "a[href]").count == 1
                    && DOM.text(DOM.first(li, "a[href]")) == DOM.text(li)
            }) else { continue }
            DOM.remove(list)
            DOM.remove(block)
        }
        // "Follow topics and authors from this story…" (The Verge), and the list of follow buttons after it.
        for el in DOM.select(root, "p, div, section, aside, span, strong, b") {
            guard DOM.isConnected(el), followLine.test(DOM.text(el)) else { continue }
            let block = lineBlock(el, root: root)
            if let next = nextContent(block, root: root) as? Element,
               let list = DOM.isTag(next, ["ul", "ol"]) ? next : DOM.closest(next, "ul, ol"),
               DOM.select(list, "li").allSatisfy({ DOM.text($0).count <= maxFollowItem }) {
                DOM.remove(list)
            }
            DOM.remove(block)
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
        // "MORE: <a>Another story</a>" (The Big Lead): a label and one link, nothing else.
        for p in ps() where moreLabel.test(DOM.text(p)) {
            let links = DOM.select(p, "a[href]")
            guard links.count == 1, let label = moreLabel.firstMatch(DOM.text(p))?[0] else { continue }
            if DOM.squash(String(DOM.text(p).dropFirst(label.count))) == DOM.text(links[0]) { DOM.remove(lineBlock(p, root: root)) }
        }
        // Sportsbook promotions (CBS Sports' "Claim the best Kalshi promo code…"): a short block goes, and in a longer
        // paragraph the bold link that carries it.
        for el in DOM.select(root, "p, li") where DOM.isConnected(el) && promo.test(DOM.text(el)) {
            if DOM.text(el).count <= 300 { DOM.remove(lineBlock(el, root: root)); continue }
            for inline in DOM.select(el, "strong, b, a") where DOM.isConnected(inline) && promo.test(DOM.text(inline)) {
                let gone = (inline.parent().map { DOM.isTag($0, ["strong", "b"]) && DOM.text($0) == DOM.text(inline) } ?? false) ? inline.parent()! : inline
                // The colon that introduced the next line ("…promo code CBSSPORTS55 here: Cardinals vs. Cowboys").
                if let t = gone.nextSibling() as? TextNode, let r = t.getWholeText().range(of: "^\\s*:\\s*", options: .regularExpression) {
                    t.text(String(t.getWholeText()[r.upperBound...]))
                }
                DOM.remove(gone)
            }
        }
        // A byline drawn as a list of names before the story (ESPN: "Matt Bowen, Kalyn Kahler, …").
        if let first = DOM.select(root, "p, ul, ol, h2, h3, h4, blockquote, figure").first(where: hasMediaOrText), DOM.isTag(first, ["ul", "ol"]) {
            let items = DOM.select(first, "li")
            if !items.isEmpty, items.allSatisfy({ personName.test(DOM.text($0)) }) { DOM.remove(lineBlock(first, root: root)) }
        }
        // A bio whose name sat in another element, at either end of the article.
        let blocks = ps()
        for p in blocks.prefix(3) + blocks.suffix(3) where DOM.isConnected(p) && DOM.text(p).count <= 600 && namelessBio.test(DOM.text(p)) {
            DOM.remove(lineBlock(p, root: root))
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

    /// Author photos, found while the page still has its class names (`post-authors-list__author-thumb`): Readability
    /// strips classes, and an unsized avatar then passes for a content image. Wrappers it alone filled go too, so no
    /// empty list item is left behind as a stray bullet.
    static func removeAvatars(_ root: Element) {
        for img in DOM.select(root, "img") where DOM.isConnected(img) && isTinyImg(img) {
            var gone: Element = img
            while let p = gone.parent(), p !== root, !(p is Document), !DOM.isTag(p, ["body", "html"]),
                  DOM.children(p).count == 1, DOM.text(p).isEmpty { gone = p }
            DOM.remove(gone)
        }
    }

    // MARK: captionAttributes

    private static let placeholderText = P("^[.…\\s]*$")
    static let maxCaptionDepth = 3

    /// Images that carry their caption in a `caption` attribute and draw it with script (Newsweek: the server sends
    /// "..." where the caption goes). The image and that placeholder become a <figure> with a real <figcaption>.
    static func captionAttributes(_ root: Element) {
        for img in DOM.select(root, "img[caption]") {
            let caption = DOM.squash(DOM.attr(img, "caption"))
            guard DOM.isConnected(img), !caption.isEmpty else { continue }
            if let fig = DOM.closest(img, "figure"), DOM.first(fig, "figcaption") != nil { continue }
            var box: Element = img
            for _ in 0..<maxCaptionDepth {
                guard let p = box.parent(), p !== root, !(p is Document), !DOM.isTag(p, ["body", "html", "figure"]),
                      DOM.select(p, "img").count == 1, placeholderText.test(DOM.text(p)) else { break }
                box = p
            }
            DOM.removeAttr(img, "caption")
            DOM.replace(box, withHTML: "<figure>\(DOM.outerHTML(img))<figcaption>\(DOM.escapeHTML(caption))</figcaption></figure>")
        }
    }

    // MARK: tidyFigures

    /// Figures as the page's styling left them: a credit drawn both over the picture and in the caption (Ars Technica's
    /// "Credit: Google" twice) keeps only the caption's; a figure with nothing to show (a chart its script never
    /// drew, Wired) goes; links around nothing go.
    static func tidyFigures(_ root: Element) {
        for fig in DOM.select(root, "figure") where DOM.isConnected(fig) {
            if !hasMediaOrText(fig) { DOM.remove(fig); continue }
            // A video card whose player never came (CBS News: a link with the clip's title and length, then the title
            // again as a heading and "(03:01)"): only a link is left, and the repeat after it goes too.
            if DOM.first(fig, contentMedia) == nil, DOM.first(fig, "blockquote") == nil, let link = DOM.first(fig, "a[href]"), DOM.text(link) == DOM.text(fig) {
                let words = DOM.text(fig)
                if let next = nextContent(fig, root: root) as? Element, !DOM.isTag(next, ["p"]) || duration.test(DOM.text(next)) {
                    let block = lineBlock(next, root: root)
                    let heading = DOM.first(block, "h1, h2, h3, h4, h5, h6").map(DOM.text) ?? DOM.text(block)
                    if !heading.isEmpty, words.contains(heading), DOM.textLen(DOM.text(block)) <= heading.count + 12 { DOM.remove(block) }
                }
                DOM.remove(fig)
                continue
            }
            guard let caption = DOM.first(fig, "figcaption") else { continue }
            let words = DOM.text(caption)
            guard !words.isEmpty else { continue }
            for el in DOM.select(fig, "p, div, span, small, cite") where DOM.isConnected(el) {
                guard DOM.closest(el, "figcaption") == nil, DOM.first(el, contentMedia) == nil else { continue }
                let t = DOM.text(el)
                if !t.isEmpty, words.contains(t) { DOM.remove(el) }
            }
        }
        for a in DOM.select(root, "a") where DOM.isConnected(a) && !hasMediaOrText(a) { DOM.remove(a) }
    }

    /// "<strong>Image Credits:</strong>Wabi" reads as "Image Credits:Wabi": put the space back.
    static func spaceAfterLabels(_ root: Element) {
        for b in DOM.select(root, "strong, b") where DOM.text(b).hasSuffix(":") {
            if let t = b.nextSibling() as? TextNode, let c = t.getWholeText().first, !c.isWhitespace, !c.isPunctuation {
                t.text(" " + t.getWholeText())
            }
        }
    }

    /// The still of a player that isn't there (Yahoo's "Video Player Cover").
    private static let playerCover = P("^(?:video )?player (?:cover|poster|thumbnail)$", caseInsensitive: true)
    private static let duration = P("^\\(?\\d{1,2}:\\d{2}(?::\\d{2})?\\)?$")

    // MARK: promoteBoldHeadings

    static let maxBoldHeading = 70
    private static let sentenceEnd = P("[.!?:;,…\"”)]$")

    /// A paragraph that is nothing but a short bold phrase, followed by a paragraph, is a section heading drawn with
    /// bold text (press releases, rich-text editors: "Transaction details"). It becomes an <h3>, so it reads as one.
    static func promoteBoldHeadings(_ root: Element) {
        for p in DOM.select(root, "p") where DOM.isConnected(p) {
            let kids = p.getChildNodes().filter { !(($0 as? TextNode).map { DOM.squash($0.getWholeText()).isEmpty } ?? false) }
            guard kids.count == 1, let bold = kids.first as? Element, DOM.isTag(bold, ["b", "strong"]),
                  DOM.children(bold).allSatisfy({ DOM.isTag($0, ["em", "i", "br"]) }) else { continue }
            let t = DOM.text(bold)
            guard !t.isEmpty, t.count <= maxBoldHeading, !sentenceEnd.test(t),
                  let next = try? p.nextElementSibling(), DOM.isTag(next, ["p", "ul", "ol"]) else { continue }
            guard let h = DOM.createElement("h3", near: p) else { continue }
            _ = try? h.text(t)
            DOM.replace(p, with: h)
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
        unshieldCaptionLinks(root)
        removeScreenReaderText(root)
        removePlayerChrome(root)
        removeDeadMedia(root)
        for el in DOM.select(root, "div, section, aside, p, figure") {
            guard DOM.isConnected(el) else { continue }
            if DOM.rawText(el).trimmingCharacters(in: .whitespacesAndNewlines).count > 400 { continue }
            let hasAvatar = DOM.select(el, "img").contains(where: isTinyImg)
            let hasAuthorLink = hasAuthorCardLink(el)
            // A card with a heading is content with a small logo in it (Fox Sports' team rankings), not an author card.
            if hasAuthorLink || (hasAvatar && DOM.first(el, "h1, h2, h3, h4, h5, h6") == nil) { DOM.remove(el) }
        }
        // After author cards: their profile links are what identifies them.
        removeBoilerplate(root)
        removeRecirculationText(root, base: base)
        removeInterfaceBlocks(root, base: base)
        for img in DOM.select(root, "img") where isTinyImg(img) || playerCover.test(DOM.attr(img, "alt") ?? "") { DOM.remove(img) }
        for svg in DOM.select(root, "svg") where DOM.isConnected(svg) && isIconSvg(svg) { DOM.remove(svg) }
        removeDividerImages(root)
        dedupeAdjacentImages(root)
        fullWidthImages(root)
        tidyFigures(root)
        tidyCaptions(root)
        promoteBoldHeadings(root)
        for p in DOM.select(root, "p") where DOM.isConnected(p) && !hasMediaOrText(p) && DOM.first(p, "br") == nil { DOM.remove(p) }
        spaceAfterLabels(root)
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
            // A table's column heads (SB Nation's picks) follow one another without being empty sections.
            if DOM.isTag(el, DOM.headingTags) { return DOM.closest(el, "th, td") == nil }
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
    static let sideToken = P("comment|repl|related|sidebar|footer|header|nav|menu|teaser|card|excerpt|summary|preview|promo|widget|share|caption|meta|author|bio|tag", caseInsensitive: true)
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
            var seen = Set<String>()
            for t in DOM.classTokens(el) {
                guard contentToken.test(t), !sideToken.test(t), !utilityClass.test(t) else { continue }
                let key = t.lowercased()
                // class="post post" (Ghost) lists an element twice; it would then be "merged" into itself and deleted.
                guard seen.insert(key).inserted else { continue }
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
        resolveStreamedBoundaries(root)
        prepareStructure(root)
        promoteLazyImages(root)
        absolutize(root, base: base)
        normalizeEmbeds(root)
        embeds(root, pageURL: pageURL)
        removeScreenReaderText(root)
        removePlayerChrome(root)
        unwrapZoomButtons(root)
        unwrapImageButtons(root)
        removeInterface(root)
        removeRecirculation(root, pageURL: pageURL)
        removePageInterface(root, pageURL: pageURL)
        normalizeCodeBlocks(root)
        dropDarkVariants(root)
        removeAvatars(root)
        captionAttributes(root)
        captionBlocks(root)
        captionFigures(root)
        rebuildYouTube(root)
        unlinkHeadings(root)
        upgradePictureFallbacks(root)
        collapsePictures(root)
        removeSamePageNav(root, pageURL: pageURL)
        restoreFigures(root)
        markClientRenderedFigures(root, pageURL: pageURL)
        placePayloadVideos(root, videos)
    }
}
