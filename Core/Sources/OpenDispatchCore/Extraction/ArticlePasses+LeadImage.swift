import Foundation
import SwiftSoup

/// The article's lead image: which URL the reader draws above the body, and whether the body already shows it.
/// Shared by the extractor (which picks the page's lead) and the app (`ReaderText.contentHasHero`, which decides
/// per item whether to draw it), so both apply one rule.
public enum LeadImage {
    typealias P = ExtractionDOM.Pattern

    // MARK: Is the lead already in the body?

    /// The body shows `hero` when it holds the same file (whatever the CDN size, crop or proxy), leads with the same
    /// picture, or opens with a video.
    public static func contentHasHero(_ html: String, hero: String) -> Bool {
        if html.contains(hero) || html.contains(hero.replacingOccurrences(of: "&", with: "&amp;")) { return true }
        // The same file anywhere in the body, in another size or through another proxy: MacRumors' /2000x/ vs /400x0/,
        // Fox's /1200/675/, Engadget's l-intro-N vs intro-N, futurecdn's -2560-80, Medium's resize:fit:, a CDN that
        // wraps the original in ?url= or a path. A standfirst or byline may come first, so not only the first image.
        let srcs = imageSrcs(html)
        let heroKeys = withoutSharedFolderIDs(keys(hero), srcs: srcs)
        if !heroKeys.isEmpty, srcs.contains(where: { !keys($0).isDisjoint(with: heroKeys) }) { return true }
        // The first image by its looser name (WordPress -1024x576, -e1790…, -scaled, -1) when nothing precedes it.
        if let first = leadingPictureSrc(html, maxTextBefore: 0), let a = looseStem(first), let b = looseStem(hero), a == b { return true }
        // The same picture stored twice by the CMS (Business Insider's ids minted seconds apart) as the body's picture.
        if let first = leadingPictureSrc(html, maxTextBefore: leadingTextBudget), sameUpload(first, hero) { return true }
        // The article's banner under another name (Hugging Face's thumbnail.jpg vs header.jpg in the post's folder).
        if let first = leadingPictureSrc(html, maxTextBefore: leadingTextBudget), sameBanner(first, hero) { return true }
        // A social card (1200x630 crop with a logo, og:image named social_share) stands in for the page's own picture,
        // which the body leads with, so the card would only repeat it.
        if isCardLike(hero), let first = leadingPictureSrc(html, maxTextBefore: leadingTextBudget), sameSite(first, hero) { return true }
        return leadingVideo.test(html) || leadsWithPlayer(html)
    }

    /// Text allowed before the body's leading picture: a standfirst, a byline, a "Back to Articles" link.
    static let leadingTextBudget = 400

    private static let imgTag = P("<img\\b[^>]*>", caseInsensitive: true)
    private static let srcAttr = P("\\bsrc\\s*=\\s*[\"']([^\"']+)[\"']", caseInsensitive: true)
    private static let widthAttr = P("\\bwidth\\s*=\\s*[\"']?(\\d+)", caseInsensitive: true)
    private static let notAPicture = P("avatar|gravatar|logo|icon|emoji|placeholder|badge|/spacer|pixel", caseInsensitive: true)
    /// The content opens with a player (a wrapper div or two may come first): the video is the lead.
    private static let leadingVideo = P("^\\s*(?:<(?:div|p|figure|span|section)\\b[^>]*>\\s*)*<(?:iframe|video)\\b", caseInsensitive: true)

    private static func unescape(_ s: String) -> String { s.replacingOccurrences(of: "&amp;", with: "&") }

    /// Every <img> src in the content.
    static func imageSrcs(_ html: String) -> [String] {
        imgTag.allMatches(html).compactMap { tag in tag[0].flatMap { srcAttr.firstMatch($0)?[1] }.map(unescape) }
    }

    /// src of the first picture of content size (not an avatar, logo or placeholder), when at most `maxTextBefore`
    /// characters of text come before it.
    static func leadingPictureSrc(_ html: String, maxTextBefore: Int) -> String? {
        let ns = html as NSString
        for m in imgTag.regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let src = srcAttr.firstMatch(tag)?[1].map(unescape), !notAPicture.test(src) else { continue }
            if let w = widthAttr.firstMatch(tag)?[1].flatMap({ Int($0) }), w < 300 { continue }
            let before = TextFormat.stripHTML(ns.substring(to: m.range.location)).trimmingCharacters(in: .whitespacesAndNewlines)
            return before.count <= maxTextBefore ? src : nil
        }
        return nil
    }

    // MARK: Image identity

    private static let sizeSegment = P("^[a-z]{0,3}\\d+(?:x\\d*)?(?:[-_][a-z]{0,3}\\d+(?:x\\d*)?)*$", caseInsensitive: true)
    private static let hostSegment = P("^(?:[a-z0-9-]+\\.)+[a-z]{2,}$", caseInsensitive: true)
    private static let imageExt = P("\\.(?:jpe?g|png|gif|webp|avif|svg|bmp|heic)$", caseInsensitive: true)
    private static let sizeSuffix = P("(?:[-_]\\d{1,5}x\\d{1,5}|[-_]\\d{3,5}-(?:[5-9]\\d|100)|-e\\d{6,}|-scaled)$")
    private static let renditionPart = P("\\.(?:width|height|max|min|fill|scale|format)-[^.]*")
    private static let toiID = P("msid-(\\d{6,})", caseInsensitive: true)
    private static let objectID = P("^[0-9a-f]{24}$", caseInsensitive: true)

    /// Names a file in a CDN-independent way: the original's host and path (proxy wrappers and size/crop/signature
    /// segments removed) plus its file name without size suffixes, and any id in it. Empty when the URL names nothing.
    static func keys(_ url: String) -> Set<String> {
        guard let (host, segments) = unwrap(unescape(url)), let file = segments.last else { return [] }
        var out = Set<String>()
        if let id = toiID.firstMatch(url)?[1] { out.insert("toi:\(id)") }
        var name = file.lowercased()
        name = renditionPart.replacing(name, with: "")
        name = imageExt.replacing(name, with: "")
        name = sameFileName(name, host: host)
        while sizeSuffix.test(name) { name = sizeSuffix.replacing(name, with: "") }
        // "l-intro-1793300458" is the large rendition of "intro-1793300458".
        if name.count > 8, name.first?.isLetter == true, name.dropFirst().first == "-" { name.removeFirst(2) }
        if name.count >= 4 {
            out.insert(host + "/" + segments.dropLast().filter { !isSizeSegment($0) }.joined(separator: "/").lowercased() + "/" + name)
        }
        out.formUnion(idKeys(segments))
        return out
    }

    /// Host and path segments of the image itself: a proxy's `?url=`/`?href=` target, an embedded `https://…` in the
    /// path (cdn-cgi/image/…/https://cdn…, Substack's fetch/…/https%3A%2F%2F…) or a host-first path (i0.wp.com/site/…,
    /// a57.foxnews.com/static.foxnews.com/foxnews.com/…) stands in for the URL.
    private static func unwrap(_ url: String, depth: Int = 0) -> (host: String, segments: [String])? {
        guard depth < 4, let comps = URLComponents(string: url), let host = comps.host?.lowercased() else { return nil }
        if let inner = comps.queryItems?.lazy.compactMap(\.value).first(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") }) {
            return unwrap(inner, depth: depth + 1)
        }
        let path = comps.path
        if let r = path.range(of: "https://") ?? path.range(of: "http://") {
            return unwrap(String(path[r.lowerBound...]), depth: depth + 1)
        }
        var segments = path.split(separator: "/").map(String.init)
        // Cloudflare's resizer: /cdn-cgi/image/<options>/<file>.
        if segments.count > 3, segments[0] == "cdn-cgi", segments[1] == "image" { segments.removeFirst(3) }
        guard !segments.isEmpty else { return nil }
        var site = host
        if let i = segments.indices.dropLast().last(where: { hostSegment.test(segments[$0]) && !imageExt.test(segments[$0]) }) {
            site = segments[i].lowercased()
            segments = Array(segments[(i + 1)...])
        }
        return (site.hasPrefix("www.") ? String(site.dropFirst(4)) : site, segments)
    }

    /// A path segment that picks a size, crop, format or signature rather than naming the image: /2000x/, /400x0/,
    /// /1200/675/, /q60/, /c800x450-w800-q80/, /resize:fit:1400/, MacRumors' /t/<signature=>/.
    static func isSizeSegment(_ s: String) -> Bool {
        if s.contains(where: { "=,:$!".contains($0) }) { return true }
        // A year or a month is a folder, not a size.
        if s.allSatisfy(\.isNumber) { return s.count >= 3 && !(s.count == 4 && (s.hasPrefix("19") || s.hasPrefix("20"))) }
        return sizeSegment.test(s)
    }

    /// Segments (or file-name parts) that are ids: 12+ characters with digits (UUIDs, hashes, Yle's
    /// …/39-17192056ac644117ddf4), never a size or a folder of sizes.
    static func idTokens(_ segments: [String]) -> Set<String> {
        Set(segments.map { String($0.split(separator: ".").first ?? Substring($0)) }.filter { seg in
            seg.count >= 12 && !seg.contains(",") && !seg.contains("=") && seg.filter(\.isNumber).count >= 4
        }.map { $0.lowercased() })
    }

    /// The first image's name without WordPress duplicate/size suffixes: -1024x576, -e1790…, -scaled, -1.
    private static let looseSuffix = P("(?:-e\\d{6,}|-\\d{2,5}x\\d{2,5}|-scaled|-\\d)$")

    private static func looseStem(_ url: String) -> String? {
        guard let (host, segments) = unwrap(unescape(url)), let file = segments.last else { return nil }
        var name = imageExt.replacing(file.lowercased(), with: "")
        while looseSuffix.test(name) { name = looseSuffix.replacing(name, with: "") }
        guard name.count >= 4 else { return nil }
        return host + "/" + segments.dropLast().joined(separator: "/").lowercased() + "/" + name
    }

    /// Two 24-hex object ids (Business Insider's i.insider.com/<id>) minted within two minutes on one host: the CMS
    /// stored one upload as a 16:9 crop and as the original.
    private static func sameUpload(_ a: String, _ b: String) -> Bool {
        guard let ua = unwrap(unescape(a)), let ub = unwrap(unescape(b)), ua.host == ub.host,
              let idA = ua.segments.first(where: { objectID.test($0) }), let idB = ub.segments.first(where: { objectID.test($0) }),
              let ta = UInt32(idA.prefix(8), radix: 16), let tb = UInt32(idB.prefix(8), radix: 16) else { return false }
        // The same id twice is a shared folder (Webflow's site id), not one upload stored twice.
        return idA != idB && abs(Int(ta) - Int(tb)) <= 120
    }

    private static let bannerName = P("^(?:thumbnail|thumb|header|banner|cover|hero|featured|preview|og|social)(?:[-_.]\\w+)*$", caseInsensitive: true)

    /// Two banner-named files (thumbnail, header, cover, …) in one folder named for the post (a slug of three or more
    /// words), on one site: the article's lead art saved under two names.
    private static func sameBanner(_ a: String, _ b: String) -> Bool {
        guard let ua = unwrap(unescape(a)), let ub = unwrap(unescape(b)), registrable(ua.host) == registrable(ub.host),
              let fa = ua.segments.last, let fb = ub.segments.last,
              bannerName.test(imageExt.replacing(fa, with: "")), bannerName.test(imageExt.replacing(fb, with: "")) else { return false }
        let slugs = { (segs: [String]) in Set(segs.dropLast().filter { $0.count >= 16 && $0.split(separator: "-").count >= 3 }) }
        return !slugs(ua.segments).isDisjoint(with: slugs(ub.segments))
    }

    /// Same site: the last two host labels (three under a co.uk-style suffix), after proxies are unwrapped.
    private static func sameSite(_ a: String, _ b: String) -> Bool {
        guard let ha = unwrap(unescape(a))?.host, let hb = unwrap(unescape(b))?.host else { return false }
        return registrable(ha) == registrable(hb)
    }

    private static func registrable(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let n = ["co", "com", "org", "net", "ac", "gov"].contains(labels[labels.count - 2]) && labels[labels.count - 1].count == 2 ? 3 : 2
        return labels.suffix(n).joined(separator: ".")
    }

    // MARK: Social variants

    /// A site's og:image that is a social-sharing crop with a logo or watermark stamped on it, rewritten to the
    /// page's own picture: Guardian's overlay-*, ABC Australia's wcms_watermark_news, SCMP's og_image style, NBC's
    /// 1200x630 transform, a Sanity or Substack crop of a cover, a WordPress/Hearst crop= that cuts the subject.
    public static func clean(_ url: String) -> String {
        guard var comps = URLComponents(string: url), let host = comps.host?.lowercased() else { return url }
        var items = comps.queryItems ?? []
        if host.hasSuffix("i.guim.co.uk") {
            // The signature covers the card's parameters; the page's own images use s=none.
            guard items.contains(where: { $0.name.hasPrefix("overlay") }) else { return url }
            items = [("width", "1200"), ("dpr", "1"), ("s", "none"), ("crop", "none")].map { URLQueryItem(name: $0.0, value: $0.1) }
        } else if host.hasSuffix("abc-cdn.net.au") {
            items = items.map { $0.name == "impolicy" && $0.value == "wcms_watermark_news" ? URLQueryItem(name: "impolicy", value: "wcms_crop_resize") : $0 }
        } else if host == "ichef.bbci.co.uk" {
            // branded_news is the sharing variant with the BBC News badge; standard is the picture.
            comps.path = comps.path.replacingOccurrences(of: "/ace/branded_news/1200/", with: "/ace/standard/976/")
        } else if host.hasSuffix("i-scmp.com") {
            comps.path = comps.path.replacingOccurrences(of: "/styles/og_image_scmp_generic/", with: "/styles/1280x720/")
        } else if host.hasSuffix("s-nbcnews.com") {
            comps.path = P("t_nbcnews-fp-\\d+-\\d+").replacing(comps.path, with: "t_fit-1500w")
        } else if host == "img.semafor.com" || host == "cdn.sanity.io" {
            // A crop of a graphic with a transparent background (dark text on dark in the reader): the whole picture,
            // flattened onto white.
            guard items.contains(where: { $0.name == "rect" }) else { return url }
            items.removeAll { ["rect", "h", "fit", "auto"].contains($0.name) }
            items += [URLQueryItem(name: "fm", value: "jpg"), URLQueryItem(name: "bg", value: "fff")]
        } else if host == "substackcdn.com" {
            // fill + h_ crops a cover to the card; the page's own images are c_limit.
            comps.percentEncodedPath = P(",h_\\d+,c_fill|,g_auto").replacing(comps.percentEncodedPath) { $0[0] == ",g_auto" ? "" : ",c_limit" }
        } else {
            // A crop to the sharing card's shape: WordPress Photon / Hearst crop=…&resize=1200,630 (or only
            // resize=1200,628), imgix w=1200&h=630&fit=crop. The picture at the same width, uncropped.
            func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
            let size = value("resize").flatMap { P("^(\\d+)(?:,|%2C)(\\d+)$").firstMatch($0) }
            if let resize = value("resize"), value("crop") != nil {
                items.removeAll { $0.name == "crop" || $0.name == "resize" }
                if let width = P("^(\\d+)").firstMatch(resize)?[1] { items.append(URLQueryItem(name: "w", value: width)) }
            } else if let size, isCardCrop(width: Int(size[1] ?? ""), height: Int(size[2] ?? "")) {
                items.removeAll { $0.name == "resize" }
                items.append(URLQueryItem(name: "w", value: size[1]))
            } else if value("fit") == "crop", isCardCrop(width: value("w").flatMap { Int($0) }, height: value("h").flatMap { Int($0) }) {
                items.removeAll { ["h", "fit", "crop", "ar"].contains($0.name) }
            } else {
                return url
            }
        }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url?.absoluteString ?? url
    }

    /// A file named for what it is, not for the article: og, og-image, opengraph-image, social-card, social-share-card,
    /// social-preview-v3, share, twitter-card (not a bare og.jpg, nor IIIF's default.jpg).
    private static let cardName = P("^(?:og(?=[-_])|opengraph|social|share|twitter)(?:[-_](?:og|opengraph|social|share|twitter|default|image|img|card|preview))*(?:[-_]?v?\\d+)?$", caseInsensitive: true)
    private static let cardDir = P("/og[-_ ]?images?/|/opengraph[-_]?images?/", caseInsensitive: true)

    /// The site's own sharing card, not the article's picture: GitHub's repo card, og-image.png, social-card.png,
    /// social-share-card.jpg, share.png, opengraph-image.png, a blob folder of "OG Images". Better no lead than these.
    static func isGenericCard(_ url: String) -> Bool {
        guard let comps = URLComponents(string: url), let host = comps.host?.lowercased() else { return false }
        if host == "opengraph.githubassets.com" || (host.hasSuffix("githubassets.com") && comps.path.contains("og-image")) { return true }
        let path = comps.path
        if cardDir.test(path) || isCardRoute(path) { return true }
        let file = path.split(separator: "/").last.map(String.init) ?? ""
        return cardName.test(imageExt.replacing(file, with: "")) || isLogoFile(file)
    }

    private static let cardLikeURL = P("social[-_]?share|overlay-|watermark|(?:^|[^\\d])1200(?:x|-|_|,|%2C)\\s*6(?:30|28)(?:[^\\d]|$)|w1200-h630|width=1200&height=630|opengraph|og[-_]image", caseInsensitive: true)

    /// The URL of a social-sharing crop (1200x630, overlay, social_share): the page's own picture is better when it has one.
    static func isCardLike(_ url: String) -> Bool { cardLikeURL.test(url) }

    /// An og:image declared 1200x630 (or 628): the 1.91:1 sharing crop, not the picture itself.
    static func isCardCrop(width: Int?, height: Int?) -> Bool {
        guard let w = width, let h = height, h > 0, w >= 1000 else { return false }
        return abs(Double(w) / Double(h) - 1.91) < 0.06
    }

    /// The lead the reader draws for a stored thumbnail or extracted lead: a social variant rewritten to the page's
    /// picture, the site's own card dropped.
    public static func display(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        let cleaned = clean(url)
        return isGenericCard(cleaned) ? nil : cleaned
    }
}

extension ArticlePasses {
    /// A small thumbnail named in the URL itself (Springer's w215h120): never a hero.
    private static let thumbSize = P("(?:^|[/_-])w(\\d{2,3})h(\\d{2,3})(?:[/_.-]|$)", caseInsensitive: true)
    private static let heroClass = P("hero|lede|lead|featured", caseInsensitive: true)

    static func isSmallThumbURL(_ url: String) -> Bool {
        guard let m = thumbSize.firstMatch(url), let w = Int(m[1] ?? "") else { return false }
        return w < 400
    }

    /// The article page's own lead picture: the first large image inside the article, main or a figure that the page
    /// marks as its hero (fetchpriority=high, a hero/lede/featured class) or shows in a figure at 600px or more. Read
    /// before `prepare`, which removes page chrome. Used when the og:image is missing or a sharing card.
    static func pageLeadImage(_ document: Element, base: String) -> String? {
        for img in DOM.select(document, "img") {
            if DOM.closest(img, "nav, footer, aside, [role=navigation], [role=complementary]") != nil { continue }
            guard DOM.closest(img, "article, main, [role=main], figure") != nil else { continue }
            var src = DOM.attr(img, "src")
            if src == nil || src!.hasPrefix("data:") {
                src = DOM.attr(img, "data-src") ?? DOM.attr(img, "srcset")?.split(separator: ",").first?.split(separator: " ").first.map(String.init)
            }
            if let s = src { src = fullSizeSource(img, src: s) }
            guard let src, !src.hasPrefix("data:"), let url = DOM.absURL(src, base: base),
                  !isSmallThumbURL(url), !isBadge(img), !isTinyImg(img) else { continue }
            let w = DOM.jsNumber(DOM.attr(img, "width"))
            let marked = DOM.attr(img, "fetchpriority")?.lowercased() == "high" || heroClass.test(DOM.attr(img, "class") ?? "")
            guard marked || DOM.closest(img, "figure") != nil, w >= 600 || (marked && w == 0) else { continue }
            return url
        }
        return nil
    }

    /// og:image (or twitter:image) as the reader should draw it: a sharing crop rewritten to the page's picture, the
    /// site's own card dropped, and the page's own lead picture preferred when the og:image is missing or a 1.91:1
    /// sharing card that `clean` could not turn back into the picture.
    static func chooseLead(_ document: Element, base: String) -> String? {
        func meta(_ selector: String) -> String? { DOM.first(document, selector).flatMap { DOM.attr($0, "content") } }
        let og = DOM.absURL(meta("meta[property=og:image]") ?? meta("meta[name=twitter:image]"), base: base)
        let cleaned = og.map(LeadImage.clean)
        var lead = usableLead(cleaned)
        let crop = LeadImage.isCardCrop(width: meta("meta[property=og:image:width]").flatMap { Int($0) },
                                        height: meta("meta[property=og:image:height]").flatMap { Int($0) })
        if lead == nil || (cleaned == og && (crop || lead.map(LeadImage.isCardLike) == true)), let hero = pageLeadImage(document, base: base) {
            lead = hero
        }
        if let hero = pageImageNamedByAlt(document, base: base, ogAlt: meta("meta[property=og:image:alt]"), current: lead) { lead = hero }
        return lead
    }
}
