import Foundation
import SwiftSoup

/// The HTML allowlist for reader content (port of `SANITIZE` / `sanitizeArticle` / `embedSrc` in src/lib/extract.ts,
/// which used sanitize-html). Disallowed tags are unwrapped (their text kept) except raw-text ones, whose content goes too.
public enum ArticleSanitizer {
    private typealias DOM = ExtractionDOM

    // Inline SVG: shapes and presentation attributes only (no <use>, <image>, <foreignObject>, href, style, handlers).
    // SwiftSoup lowercases names; both spellings are listed like the web's `withLower`.
    private static func withLower(_ names: [String]) -> Set<String> {
        Set(names.flatMap { [$0, $0.lowercased()] })
    }

    static let svgTags = withLower([
        "svg", "g", "path", "circle", "ellipse", "line", "polyline", "polygon", "rect", "text", "tspan",
        "defs", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "marker",
    ])

    static let svgAttrs = withLower([
        "id", "viewBox", "width", "height", "preserveAspectRatio", "role", "aria-label", "aria-hidden",
        "d", "cx", "cy", "r", "rx", "ry", "x", "y", "x1", "y1", "x2", "y2", "dx", "dy", "points", "offset",
        "transform", "opacity", "fill", "fill-opacity", "fill-rule", "clip-rule", "clip-path", "mask",
        "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-dasharray",
        "stroke-dashoffset", "stroke-miterlimit", "vector-effect", "stop-color", "stop-opacity",
        "gradientUnits", "gradientTransform", "spreadMethod", "clipPathUnits", "maskUnits",
        "marker-start", "marker-mid", "marker-end", "markerWidth", "markerHeight", "markerUnits", "refX", "refY", "orient",
        "text-anchor", "dominant-baseline", "alignment-baseline", "font-size", "font-family", "font-weight", "font-style",
        "letter-spacing", "textLength",
    ])

    static let allowedTags: Set<String> = Set([
        "p", "br", "hr", "b", "strong", "i", "em", "u", "s", "sub", "sup", "small", "mark",
        "a", "img", "pre", "code", "kbd", "samp",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "dl", "dt", "dd",
        "blockquote", "figure", "figcaption", "picture", "video", "source", "iframe",
        "table", "thead", "tbody", "tr", "th", "td", "span", "div",
    ]).union(svgTags)

    /// Tags whose content is dropped along with them when disallowed (sanitize-html nonTextTags).
    static let nonTextTags: Set<String> = ["script", "style", "textarea", "option", "xmp"]

    static let allowedAttributes: [String: Set<String>] = {
        var map: [String: Set<String>] = [
            "a": ["href", "title", "target", "rel"],
            "img": ["src", "srcset", "sizes", "alt", "title", "width", "height", "loading"],
            "video": ["src", "controls", "poster", "width", "height", "autoplay", "loop", "muted", "playsinline", "preload"],
            "source": ["src", "srcset", "sizes", "media", "type", "width", "height"],
            "iframe": ["src", "width", "height", "allow", "allowfullscreen", "frameborder"],
            "code": ["class"],
            "pre": ["class"],
            "th": ["colspan", "rowspan"],
            "td": ["colspan", "rowspan"],
        ]
        for t in svgTags { map[t] = svgAttrs }
        // allowedClasses implicitly allows `class` on these, filtered to x-* tokens.
        for t in classFilteredTags { map[t, default: []].insert("class") }
        return map
    }()

    /// Posts from X are rendered as x-* markup the reader styles.
    static let classFilteredTags: Set<String> = ["div", "span", "a", "img"]

    static let allowedSchemes: Set<String> = ["http", "https", "mailto", "tel"]
    /// TikTok's player is only ever put in by `EmbeddedPosts` (an article's own TikTok embed is a blockquote).
    /// Chart hosts (Datawrapper, Flourish) are `ArticlePasses.chartHosts`.
    static let allowedIframeHosts: Set<String> = Set(["www.youtube-nocookie.com", "player.vimeo.com", "www.tiktok.com", "embed.tidal.com"]).union(ArticlePasses.chartHosts)
    static let schemeCheckedAttributes: Set<String> = ["href", "src", "cite", "poster"]
    /// Attributes that may be present with an empty value (boolean attributes plus alt).
    static let emptyAllowed: Set<String> = ["alt", "controls", "autoplay", "loop", "muted", "playsinline", "allowfullscreen"]

    private static let externalURLRef = DOM.Pattern("url\\(\\s*['\"]?\\s*(?!#)", caseInsensitive: true)
    private static let posterPlaceholder = DOM.Pattern("fallback|placeholder", caseInsensitive: true)
    private static let validAttrName = DOM.Pattern("^[^\\s\"'>/=\\x00-\\x1F\\x7F]+$")
    private static let schemePattern = DOM.Pattern("^([a-zA-Z][a-zA-Z0-9.\\-+]*):")
    private static let controlChars = DOM.Pattern("[\\x00-\\x20]+")
    private static let htmlComment = DOM.Pattern("<!--.*?-->")

    /// sanitizeArticle(html).
    public static func sanitize(_ html: String) -> String {
        // Word joiners left where a link's "opens in a new window" icon was (openai.com) only get in the way.
        DOM.withFragment(html.replacingOccurrences(of: "\u{2060}", with: "")) { body in
            // An id stays only where a link in the article points (a footnote and its marker): in-page jumps.
            let anchors = Set(DOM.select(body, "a[href^=#]").compactMap { DOM.attr($0, "href").map { String($0.dropFirst()) } })
            clean(children: body, anchors: anchors)
            return DOM.innerHTML(body)
        } ?? ""
    }

    private static func clean(children parent: Element, anchors: Set<String>) {
        for node in parent.getChildNodes() {
            if let el = node as? Element {
                cleanElement(el, anchors: anchors)
            } else if node is TextNode {
                continue
            } else {
                // Comments, data nodes, doctype: dropped.
                DOM.remove(node)
            }
        }
    }

    private static func cleanElement(_ el: Element, anchors: Set<String>) {
        let name = DOM.tag(el)
        guard allowedTags.contains(name) else {
            if nonTextTags.contains(name) {
                DOM.remove(el)
                return
            }
            clean(children: el, anchors: anchors)
            _ = try? el.unwrap()
            return
        }
        let anchorID = DOM.attr(el, "id").flatMap { anchors.contains($0) ? $0 : nil }
        transform(el, name: name)
        filterAttributes(el, name: name)
        if let anchorID { DOM.setAttr(el, "id", anchorID) }
        // exclusiveFilter: an iframe whose src was refused (or never had one) would be an empty 16:9 box.
        if name == "iframe" {
            // Inside <svg> a browser parses <iframe> as a foreign element (not an embed) whose content is markup,
            // while SwiftSoup keeps that content as raw text; drop it so the two parsers can never disagree.
            if DOM.attr(el, "src") == nil || hasSVGAncestor(el) {
                DOM.remove(el)
                return
            }
            // SwiftSoup stores iframe content as unescaped raw text and writes it back verbatim; fallback content
            // is never needed, so none survives.
            el.empty()
            return
        }
        clean(children: el, anchors: anchors)
        // An icon drawn with <use> (not allowed) is left an empty box the width of the column (CBS News' logo).
        if name == "svg", DOM.first(el, drawable) == nil { DOM.remove(el) }
    }

    private static let bareVar = ExtractionDOM.Pattern("var\\(\\s*(--[\\w-]+)\\s*\\)")
    private static let autoSizes = ExtractionDOM.Pattern("^\\s*auto\\s*(?:,\\s*)?(.*)$", caseInsensitive: true)
    private static let drawable = "path, circle, ellipse, line, polyline, polygon, rect, text"

    /// The element, or the <svg> it is in, carries classes the page's stylesheet painted it by.
    private static func styledByClass(_ el: Element) -> Bool {
        var current: Element? = el
        while let c = current {
            if DOM.attr(c, "class") != nil { return true }
            if c.tagName().lowercased() == "svg" { return false }
            current = c.parent()
        }
        return false
    }

    /// An ancestor inside the <svg> sets the paint this element would inherit.
    private static func inheritsPaint(_ el: Element) -> Bool {
        var current = el.parent()
        while let p = current, p.tagName().lowercased() != "svg" {
            if DOM.attr(p, "fill") != nil || DOM.attr(p, "stroke") != nil { return true }
            current = p.parent()
        }
        return current.map { DOM.attr($0, "fill") != nil || DOM.attr($0, "stroke") != nil } ?? false
    }

    private static func hasSVGAncestor(_ el: Element) -> Bool {
        var current = el.parent()
        while let p = current {
            if p.tagName().lowercased() == "svg" { return true }
            current = p.parent()
        }
        return false
    }

    private static func attributeList(_ el: Element) -> [(String, String)] {
        guard let attrs = el.getAttributes() else { return [] }
        return attrs.asList().map { ($0.getKey(), $0.getValue()) }
    }

    /// transformTags.
    private static func transform(_ el: Element, name: String) {
        switch name {
        case "iframe":
            DOM.setAttr(el, "src", embedSrc(DOM.attr(el, "src")))
            for (k, v) in attributeList(el) where (k == "width" || k == "height") && v.contains("%") {
                DOM.removeAttr(el, k)
            }
        case "a":
            // An in-page link (a footnote marker) jumps in the article, not to a new window.
            if DOM.attr(el, "href")?.hasPrefix("#") == true { DOM.removeAttr(el, "target"); DOM.removeAttr(el, "rel"); break }
            DOM.setAttr(el, "target", "_blank")
            DOM.setAttr(el, "rel", "noopener noreferrer")
        case "img":
            DOM.setAttr(el, "loading", "lazy")
            // A vector image's candidates differ only in name; their w descriptors shrink its drawn size (an
            // openai.com diagram at 197px). One src is enough.
            if let src = DOM.attr(el, "src"), URL(string: src)?.pathExtension.lowercased() == "svg" {
                DOM.removeAttr(el, "srcset")
                DOM.removeAttr(el, "sizes")
            }
        case "video":
            // Looping figure animations often ship without controls and with preload=none.
            if let poster = DOM.attr(el, "poster"), posterPlaceholder.test(poster) { DOM.removeAttr(el, "poster") }
            DOM.setAttr(el, "controls", "")
            DOM.setAttr(el, "preload", "metadata")
        default:
            if svgTags.contains(name) {
                // A chart styled by the page's classes (Kadoa's line chart) loses that styling here, and an unstyled
                // shape is filled black: lines get drawn as lines, shapes and labels in the text color. Done from the
                // <svg>, while every class is still there.
                if name == "svg" {
                    for shape in [el] + DOM.select(el, "*") where styledByClass(shape) && !inheritsPaint(shape)
                        && DOM.attr(shape, "fill") == nil && DOM.attr(shape, "stroke") == nil {
                        let tag = DOM.tag(shape)
                        if ["path", "line", "polyline"].contains(tag) {
                            DOM.setAttr(shape, "fill", "none")
                            DOM.setAttr(shape, "stroke", "currentColor")
                        } else if ["rect", "circle", "ellipse", "polygon", "text", "tspan"].contains(tag) {
                            DOM.setAttr(shape, "fill", "currentColor")
                        }
                    }
                }
                // Paint/clip references may only point inside the document: url(#id).
                for (k, v) in attributeList(el) where externalURLRef.test(v) { DOM.removeAttr(el, k) }
                // Colors from the page's stylesheet (`fill="var(--color-chart-brand-1)"`, Mistral's charts) are
                // undefined here, and an undefined paint is black: fall back to the text color.
                for (k, v) in attributeList(el) where bareVar.test(v) { DOM.setAttr(el, k, bareVar.replacing(v, with: "var($1, currentColor)")) }
            }
        }
    }

    private static func filterAttributes(_ el: Element, name: String) {
        let allowed = allowedAttributes[name] ?? []
        for (key, value) in attributeList(el) {
            guard validAttrName.test(key), allowed.contains(key) else { DOM.removeAttr(el, key); continue }
            if value.isEmpty && !emptyAllowed.contains(key) { DOM.removeAttr(el, key); continue }
            if schemeCheckedAttributes.contains(key) && naughtyHref(value) { DOM.removeAttr(el, key); continue }
            if name == "iframe" && key == "src" && !iframeAllowed(value) { DOM.removeAttr(el, key); continue }
            if key == "srcset" {
                let kept = ArticlePasses.parseSrcset(value).filter { !naughtyHref($0.url) }
                if kept.isEmpty { DOM.removeAttr(el, key) } else {
                    DOM.setAttr(el, key, kept.map { [$0.url, $0.descriptor].filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: ", "))
                }
                continue
            }
            // `sizes="auto, …"` sizes a lazy image by its laid-out width, and the reader's `width: auto` image has none
            // until it loads, so WebKit settles on the 300px default and picks a thumbnail from srcset (Ars charts).
            if key == "sizes", let rest = autoSizes.firstMatch(value).flatMap({ $0[1] }) {
                if rest.isEmpty { DOM.removeAttr(el, key) } else { DOM.setAttr(el, key, rest) }
                continue
            }
            if key == "class" && classFilteredTags.contains(name) {
                let kept = value.split(whereSeparator: { $0.isWhitespace }).filter { $0.hasPrefix("x-") }
                if kept.isEmpty { DOM.removeAttr(el, key) } else { DOM.setAttr(el, key, kept.joined(separator: " ")) }
            }
        }
    }

    /// sanitize-html's naughtyHref: a scheme outside http/https/mailto (protocol-relative and relative URLs pass).
    static func naughtyHref(_ href: String) -> Bool {
        let laundered = controlChars.replacing(htmlComment.replacing(href, with: ""), with: "")
        if laundered.hasPrefix("//") { return false }
        guard let m = schemePattern.firstMatch(laundered), let scheme = m[1] else { return false }
        return !allowedSchemes.contains(scheme.lowercased())
    }

    private static func iframeAllowed(_ src: String) -> Bool {
        guard let url = URL(string: src.trimmingCharacters(in: .whitespaces)), url.scheme != nil,
              let host = url.host(percentEncoded: false) else { return false }
        return allowedIframeHosts.contains(host)
    }

    // MARK: Embeds

    /// Player settings for a muted, looping, chrome-less background clip; the reader wants a video to watch.
    private static let backgroundPlayerParams: Set<String> = ["background", "controls", "autoplay", "muted", "mute", "loop", "playlist"]
    private static let youtubeHost = DOM.Pattern("^(?:www\\.|m\\.)?youtube(?:-nocookie)?\\.com$", caseInsensitive: true)
    private static let vimeoHost = DOM.Pattern("^player\\.vimeo\\.com$", caseInsensitive: true)

    /// embedSrc: YouTube embeds play from youtube-nocookie; background-clip players (Vimeo background=1, controls=0,
    /// muted autoplay) get their controls back. `watchable` forces that.
    public static func embedSrc(_ src: String?, watchable: Bool = false) -> String {
        guard let src, !src.isEmpty else { return "" }
        let resolvedString = DOM.absURL(src, base: "https://invalid.invalid/") ?? src
        guard var comps = URLComponents(string: resolvedString), let host = comps.host else { return src }
        let youtube = youtubeHost.test(host) && comps.path.hasPrefix("/embed/")
        let vimeo = vimeoHost.test(host)
        if !youtube && !vimeo { return src }
        let items = comps.queryItems ?? []
        func q(_ k: String) -> String? { items.first(where: { $0.name == k })?.value }
        let muted = q("muted") ?? q("mute") ?? ""
        let background = watchable || q("background") == "1" || q("controls") == "0" || (q("autoplay") == "1" && muted == "1")
        if background {
            var kept = items.filter { !backgroundPlayerParams.contains($0.name) }
            if vimeo { kept.append(URLQueryItem(name: "controls", value: "1")) }
            comps.queryItems = kept.isEmpty ? nil : kept
        }
        if youtube {
            comps.scheme = "https"
            comps.host = "www.youtube-nocookie.com"
        }
        guard background || youtube else { return src }
        return comps.string ?? src
    }
}
