import Foundation
import SwiftSoup

/// Passes for body images: finding the real address of a lazy picture, drawing it at the column's width and at the
/// page's best resolution, keeping one copy of a responsive pair, and keeping Readability from throwing a figure away.
extension ArticlePasses {
    // MARK: promoteLazyImages

    /// Lazy-load markup `absolutize` doesn't know: PCMag keeps the address in `data-image-loader` under an SVG
    /// placeholder, IGN's `<img>` is a 1px GIF inside a link to the picture, and DW's `data-url` is a template
    /// (`…/79790860_${formatId}.jpg`; its lead image uses format 6). Runs before `absolutize`, which would take the
    /// template verbatim.
    static func promoteLazyImages(_ root: Element) {
        for img in DOM.select(root, "img") {
            if let url = DOM.attr(img, "data-url"), url.contains("${formatId}") {
                DOM.setAttr(img, "data-url", url.replacingOccurrences(of: "${formatId}", with: "6"))
            }
            guard isPlaceholderSrc(DOM.attr(img, "src")), firstAttr(img, lazySrc) == nil, DOM.attr(img, "srcset") == nil,
                  DOM.attr(img, "data-srcset") == nil else { continue }
            if let loader = firstAttr(img, ["data-image-loader"]) {
                DOM.setAttr(img, "src", loader)
            } else if let link = img.parent().flatMap({ DOM.closest($0, "a[href]") }), let href = DOM.attr(link, "href"),
                      linkedImage.test(href) {
                DOM.setAttr(img, "src", href)
            }
        }
    }

    private static let linkedImage = P("\\.(?:jpe?g|png|webp|avif|gif)(?:[?#]|$)", caseInsensitive: true)

    // MARK: unwrapImageButtons

    /// A picture inside a button that opens it larger (The Conversation's `<a role=button aria-haspopup=dialog>`) is
    /// no control to drop with the "Zoom" buttons: the button goes, the picture stays. A button with words of its own
    /// is still removed whole, and so is a video's play button over its thumbnail (Vice's YouTube facade): the
    /// thumbnail alone would be a picture that doesn't play.
    static func unwrapImageButtons(_ root: Element) {
        for el in DOM.select(root, "button, [role=button][aria-haspopup], [role=button][aria-expanded]") where DOM.isConnected(el) {
            guard DOM.text(el).isEmpty, DOM.first(el, "svg, video, iframe") == nil,
                  DOM.select(el, "img").contains(where: { !isTinyImg($0) && !isLogo($0) && !videoThumbnail.test(DOM.attr($0, "src") ?? "") && !playAlt.test(DOM.attr($0, "alt") ?? "") })
            else { continue }
            _ = try? el.unwrap()
        }
    }

    private static let videoThumbnail = P("(?:img\\.youtube\\.com|i\\.ytimg\\.com|i\\.vimeocdn\\.com)/|[-_/]poster[-_.]", caseInsensitive: true)
    private static let playAlt = P("^\\s*(?:play|watch)\\b", caseInsensitive: true)

    // MARK: upgradePictureFallbacks

    /// What a srcset candidate or an image address asks for, in pixels: a `w` descriptor, else `width`/`w` times `dpr`
    /// in the query (the Guardian's `?width=700&dpr=2`), else an `x` density against `base`.
    static func requestedWidth(_ url: String, descriptor: String = "", base: Double = 0) -> Double {
        let d = DOM.jsParseFloat(descriptor) ?? 0
        if d > 0 { return descriptor.hasSuffix("x") ? d * base : d }
        guard let items = URLComponents(string: url)?.queryItems else { return 0 }
        func q(_ names: [String]) -> Double? { items.first { names.contains($0.name) }?.value.flatMap(Double.init) }
        return (q(["width", "w"]) ?? 0) * (q(["dpr"]) ?? 1)
    }

    /// A <picture> whose <img> is the small default (the Guardian's 445px fallback, drawn at 445pt and soft) while its
    /// <source>s offer a much bigger rendition: the <img> takes the biggest one, since `collapsePictures` keeps only
    /// the <img>. The column is at most ~700pt wide, so anything under 600px declared is a fallback, not the design.
    static func upgradePictureFallbacks(_ root: Element) {
        for pic in DOM.select(root, "picture") where DOM.isConnected(pic) {
            guard let img = DOM.first(pic, "img"), DOM.attr(img, "srcset") == nil, !isPlaceholderSrc(DOM.attr(img, "src")) else { continue }
            let src = DOM.attr(img, "src") ?? ""
            let declared = DOM.jsNumber(DOM.attr(img, "width"))
            let own = declared > 0 ? declared : requestedWidth(src)
            guard own > tinyImg, own < 600 else { continue }
            var best: (url: String, w: Double)?
            for source in DOM.select(pic, "source") where !(DOM.attr(source, "media") ?? "").lowercased().contains("prefers-color-scheme") {
                for c in parseSrcset(DOM.attr(source, "srcset") ?? "") {
                    let w = requestedWidth(c.url, descriptor: c.descriptor, base: own)
                    if w > (best?.w ?? 0) { best = (c.url, w) }
                }
            }
            guard let best, best.w >= 1.5 * own, let url = DOM.absURL(best.url, base: DOM.attr(img, "src") ?? best.url) else { continue }
            DOM.setAttr(img, "src", url)
            for a in ["width", "height", "sizes"] { DOM.removeAttr(img, a) }
        }
    }

    // MARK: placeApolloImages

    private static let apolloImageKey = P("\"(Image:[^\"]+)\":\\{")
    private static let paddingTop = P("padding-top:\\s*(\\d+(?:\\.\\d+)?)%")

    /// E! Online (site-specific): its photos are drawn client-side, so the server HTML has an empty
    /// `<span class="thumb" style="padding-top:61%">` and the photo's agency credit, and the pictures are only in
    /// `window.__APOLLO_STATE__` (`"Image:1539194": {uri, agency, sourceWidth, sourceHeight}`). The slots and the
    /// state's images run in the same order, so each slot takes the next image with its agency and aspect ratio.
    static func placeApolloImages(_ root: Element, html: String) {
        let slots = DOM.select(root, "span.thumb[data-hook=thumb]")
        guard !slots.isEmpty, let marker = html.range(of: "__APOLLO_STATE__") else { return }
        let tail = Array(html[marker.upperBound...].utf8)
        guard let open = tail.firstIndex(of: UInt8(ascii: "{")), open < 16 else { return }
        let end = ExtractionPayload.balancedEnd(tail, open)
        guard end > open, let state = (try? JSONSerialization.jsonObject(with: Data(tail[open..<end]))) as? [String: Any] else { return }
        let text = String(decoding: tail[open..<end], as: UTF8.self)
        let photos: [(uri: String, agency: String, ratio: Double, title: String)] = apolloImageKey.allMatches(text).compactMap { m in
            guard let key = m[1], let v = state[key] as? [String: Any], let uri = v["uri"] as? String,
                  let w = (v["sourceWidth"] as? String).flatMap(Double.init), let h = (v["sourceHeight"] as? String).flatMap(Double.init), w > 0
            else { return nil }
            return (uri, DOM.squash(v["agency"] as? String), 100 * h / w, DOM.squash(v["title"] as? String))
        }
        var next = 0
        for slot in slots {
            let ratio = paddingTop.firstMatch(DOM.attr(slot, "style") ?? "").flatMap { $0[1] }.flatMap(Double.init)
            let agency = slot.parent().flatMap { DOM.first($0, "[data-hook=adp-photo-agency]") }.map { DOM.squash(DOM.text($0)) } ?? ""
            guard let i = photos[next...].firstIndex(where: { $0.agency == agency && abs($0.ratio - (ratio ?? $0.ratio)) <= 1.5 }),
                  let img = DOM.createElement("img", near: slot) else { continue }
            DOM.setAttr(img, "src", photos[i].uri)
            DOM.setAttr(img, "alt", photos[i].title)
            DOM.replace(slot, with: img)
            next = i + 1
        }
    }

    // MARK: shieldFigures

    /// Words in a class that make Readability discard an element or lower its score (`img-share`, `hds-media`), minus
    /// ad words, which stay a reason to lose a box.
    private static let adToken = P("(?:^|[-_])(?:ad|ads|advert\\w*|sponsor\\w*|promo\\w*|banner)(?:[-_]|$)", caseInsensitive: true)
    private static let captionLinkAttr = "data-od-href"

    /// The text of `el` outside its captions: a figure's wrapper holds only the picture when this is empty.
    private static func textBesideCaptions(_ el: Element) -> Int {
        DOM.textLen(DOM.text(el)) - DOM.select(el, "figcaption").reduce(0) { $0 + DOM.textLen(DOM.text($1)) }
    }

    /// Stand-ins for a picture or a player (DeepMind's `video_poster_fallback_light.jpg`, a video's poster): Readability
    /// is right to drop them.
    private static let standIn = P("fall-?back|placeholder|[-_/]poster|spacer|blank\\.|[-_]loading", caseInsensitive: true)

    /// A picture that is the article's, not the page's: in a figure, or declared/offered at a width a photo has.
    private static func isContentPicture(_ img: Element) -> Bool {
        guard !isTinyImg(img), !isPlaceholderSrc(DOM.attr(img, "src")), !standIn.test(DOM.attr(img, "src") ?? "") else { return false }
        // A figure's alt text may say "logo" (Apple: "…against a glowing M6 logo"); a loose image's name is the evidence.
        if DOM.closest(img, "figure") != nil { return true }
        guard !isLogo(img) else { return false }
        if DOM.jsNumber(DOM.attr(img, "width")) >= 300 { return true }
        return parseSrcset(DOM.attr(img, "srcset") ?? "").contains { requestedWidth($0.url, descriptor: $0.descriptor) >= 600 }
    }

    /// Before Readability, on a picture of the article:
    /// - Its own classes lose the words it throws elements out for (Daily Mail's `img-share`: the shareable picture was
    ///   cut as a share button).
    /// - So do the wrappers holding only it and its caption (NASA's `hds-media`, which scores the box below zero;
    ///   Apple's `image-sharesheet`, cut as a share widget).
    /// - An <aside> that holds only the picture (Quanta's floated guest portrait) is a <div>: Readability drops asides.
    /// - An `aria-hidden` picture in a figure is no longer hidden from it (IGN's, set on a presentational `<img>`).
    /// - A caption's links turn into spans (restored by `unshieldCaptionLinks`): "Source: <a>Ober et al.</a>" is nothing
    ///   but link text, and Readability drops a box that is mostly links together with the chart in it (Substack).
    static func shieldFigures(_ root: Element) {
        func drop(_ el: Element) { dropClassTokens(el) { readabilityJunk($0) && !adToken.test($0) && $0 != "hidden" } }
        let wrapperTags: Set<String> = ["figure", "div", "span", "a", "section", "aside"]
        func climb(from start: Element?, text: Int, depth: Int) {
            var wrapper = start
            var left = depth
            while let w = wrapper, left > 0, DOM.isTag(w, wrapperTags), textBesideCaptions(w) == text {
                drop(w)
                if DOM.tag(w) == "aside" { _ = try? w.tagName("div") }
                wrapper = w.parent()
                left -= 1
            }
        }
        for img in DOM.select(root, "img") where isContentPicture(img) {
            let fig = DOM.closest(img, "figure")
            if DOM.attr(img, "aria-hidden") == "true", fig != nil { DOM.removeAttr(img, "aria-hidden") }
            drop(img)
            climb(from: img.parent(), text: 0, depth: 6)
            // A figure is the picture's box whatever else it holds (a credit line outside the caption); the boxes
            // around it count only if they hold nothing more.
            if let fig {
                drop(fig)
                climb(from: fig.parent(), text: textBesideCaptions(fig), depth: 4)
            }
        }
        for link in DOM.select(root, "figure figcaption a[href]") {
            guard let href = DOM.attr(link, "href") else { continue }
            DOM.setAttr(link, captionLinkAttr, href)
            DOM.removeAttr(link, "href")
            _ = try? link.tagName("span")
        }
    }

    static func unshieldCaptionLinks(_ root: Element) {
        for span in DOM.select(root, "[\(captionLinkAttr)]") {
            guard let href = DOM.attr(span, captionLinkAttr) else { continue }
            DOM.setAttr(span, "href", href)
            DOM.removeAttr(span, captionLinkAttr)
            _ = try? span.tagName("a")
        }
    }

    // MARK: fullWidthImages

    private static let sizesMediaCondition = P("^\\s*(?:\\([^)]*\\)\\s*(?:and|or)?\\s*)+")
    private static let sizesLength = P("^\\s*(\\d+(?:\\.\\d+)?)(px|vw)\\s*$")

    /// An image with a srcset of widths whose `sizes` draws it in a narrow slot at some width and a wide one at
    /// another (`(max-width: 1023px) 50vw, 700px`; `(min-width: 48rem) 450px, … 1000px`). The page's layout honors the
    /// narrow slot and the reader's single column doesn't: with `width: auto` the browser uses that size as the
    /// picture's own and draws it small and low-res (Vox's panel photo, Billboard's figure). Dropping `sizes` makes it
    /// the window's width, which the column caps. A `sizes` with no wide slot (a thumbnail by design) or no narrow one
    /// (already the column's width) stays, and so does an image whose srcset tops out under the column.
    static func fullWidthImages(_ root: Element) {
        relabelSrcsetOfSrc(root)
        for img in DOM.select(root, "img[sizes][srcset]") {
            guard let sizes = DOM.attr(img, "sizes") else { continue }
            let declared = DOM.jsNumber(DOM.attr(img, "width"))
            if declared > 0 && declared < 500 { continue }
            let widths = parseSrcset(DOM.attr(img, "srcset") ?? "").map { $0.descriptor.hasSuffix("w") ? DOM.jsParseFloat($0.descriptor) ?? 0 : 0 }
            guard (widths.max() ?? 0) >= 640 else { continue }
            var narrow = false, wide = false
            for slot in splitSizes(sizes).map({ sizesMediaCondition.replacing($0, with: "") }) {
                guard let m = sizesLength.firstMatch(slot), let n = m[1].flatMap(Double.init), let unit = m[2] else { continue }
                if unit == "px" { if n >= 600 { wide = true } else { narrow = true } } else if n < 100 { narrow = true }
            }
            if narrow && wide { DOM.removeAttr(img, "sizes") }
        }
    }

    /// A srcset whose entry for the `src` file claims another width than the file's own `w` parameter (Billboard's
    /// `…?w=942&h=628&crop=1 1800w`): the browser sizes the picture by the claimed density, so a 942px file drawn as
    /// 1800 wide comes out at about half the column. The entry takes the width the address asks for.
    static func relabelSrcsetOfSrc(_ root: Element) {
        for img in DOM.select(root, "img[srcset][src]") {
            guard let src = DOM.attr(img, "src"), let w = URLComponents(string: src)?.queryItems?.first(where: { $0.name == "w" || $0.name == "width" })
                .flatMap({ $0.value.flatMap(Double.init) }), w > 0 else { continue }
            let set = parseSrcset(DOM.attr(img, "srcset") ?? "")
            guard let i = set.firstIndex(where: { $0.url == src && $0.descriptor.hasSuffix("w") && DOM.jsParseFloat($0.descriptor) != w }) else { continue }
            var fixed = set
            fixed[i].descriptor = "\(Int(w))w"
            DOM.setAttr(img, "srcset", fixed.map { "\($0.url) \($0.descriptor)" }.joined(separator: ", "))
        }
    }

    /// `sizes` entries split at the commas outside parentheses.
    private static func splitSizes(_ s: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var cur = ""
        for ch in s {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            if ch == "," && depth == 0 { out.append(cur); cur = "" } else { cur.append(ch) }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out
    }

    // MARK: dedupeAdjacentImages

    /// Parameters that choose a rendition of the file (size, crop, quality, format), not the file.
    private static let renditionParam = P("^(?:w|h|width|height|quality|q|strip|crop|fit|f|fm|format|dpr|auto|position|resize|ssl|s|fp-x|fp-y|zoom|gravity|sharp|dl)$", caseInsensitive: true)

    /// The file an <img> shows: its address without the rendition parameters (Vox's `?w=2400&crop=…`), but with the
    /// ones that name it (Cloudflare's `/_image?href=<file>&w=1430`).
    private static func imageKey(_ img: Element) -> String? {
        guard let src = DOM.attr(img, "src"), let c = URLComponents(string: src), let host = c.host else { return nil }
        let named = (c.queryItems ?? []).filter { !renditionParam.test($0.name) && Double($0.value ?? "") == nil }
            .map { "\($0.name)=\($0.value ?? "")" }.sorted()
        return host + c.path + (named.isEmpty ? "" : "?" + named.joined(separator: "&"))
    }

    /// How wide the picture can be drawn: the biggest of its declared width, srcset and address.
    private static func resolution(_ img: Element) -> Double {
        let sets = parseSrcset(DOM.attr(img, "srcset") ?? "").map { requestedWidth($0.url, descriptor: $0.descriptor) }
        return max(DOM.jsNumber(DOM.attr(img, "width")), requestedWidth(DOM.attr(img, "src") ?? ""), sets.max() ?? 0)
    }

    private static let betweenMedia = "video, audio, iframe, svg, canvas, table, pre"

    /// Two pictures with nothing between them that are one picture: the same file, or the same description (≥ 25
    /// characters). Responsive pages ship a copy per layout and hide one with CSS (Vox and Eater's mobile/desktop
    /// pair, SB Nation, Axios's fallback.png + apple.png variants of a chart). The wider copy stays.
    static func dedupeAdjacentImages(_ root: Element) {
        let order = DOM.documentOrder(root)
        let media = DOM.select(root, betweenMedia).compactMap { order[ObjectIdentifier($0)] }
        var last: Element?
        for img in DOM.select(root, "img") where DOM.isConnected(img) {
            guard let prev = last, DOM.isConnected(prev) else { last = img; continue }
            let alt = DOM.norm(DOM.attr(img, "alt"))
            let same = (imageKey(prev) != nil && imageKey(prev) == imageKey(img))
                || (alt.count >= 25 && alt == DOM.norm(DOM.attr(prev, "alt")))
            guard same, let a = order[ObjectIdentifier(prev)], let b = order[ObjectIdentifier(img)],
                  !media.contains(where: { $0 > a && $0 < b }), between(prev, img).text == 0 else { last = img; continue }
            if resolution(img) > resolution(prev) {
                DOM.remove(prev)
                last = img
            } else {
                DOM.remove(img)
            }
        }
    }

    // MARK: removeDividerImages

    private static let dividerName = P("line[-_]?break|divider|separator|flourish|squiggle|ornament|section[-_]?break", caseInsensitive: true)

    /// A decorative break drawn as a picture with no alt text (Ghost newsletters' `floating_linebreak_600px.png`),
    /// which would draw as a large figure. The figure around it goes when it holds nothing else.
    static func removeDividerImages(_ root: Element) {
        for img in DOM.select(root, "img") where DOM.isConnected(img) {
            guard DOM.attr(img, "alt") == nil, dividerName.test(URL(string: DOM.attr(img, "src") ?? "")?.lastPathComponent ?? "") else { continue }
            if let fig = img.parent(), DOM.isTag(fig, ["figure", "p", "div"]), DOM.text(fig).isEmpty, DOM.select(fig, "img").count == 1 {
                DOM.remove(fig)
            } else {
                DOM.remove(img)
            }
        }
    }
}
