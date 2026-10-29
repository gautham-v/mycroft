import Foundation
import SwiftSoup

/// Lead image, round 2: ids that name a site rather than a picture, Google's `=w1440` sizes, a player under a series
/// banner, generated card routes and logo files, and a srcset that holds the real picture behind a 200px src.
extension LeadImage {
    // MARK: Ids

    /// The ids that name the image: one in its file name ("id:"), and one in the last two folders above it (size, crop
    /// and signature segments don't count): "id:" when the file is named for the folder (Nature's d41586-…/d41586-…_5389,
    /// the Times' 00dc-chips-01-zhpm/00dc-chips-01-zhpm-articleLarge), else "dir:", which says less. A UUID further up
    /// (Ghost's storage.ghost.io/c/a0/4c/<site uuid>/content/…: Platformer, sidbala) names the site and every image on it.
    static func idKeys(_ segments: [String]) -> Set<String> {
        guard let file = segments.last else { return [] }
        let name = file.lowercased()
        // Nature's article folder d41586-026-03386-4 reads as a size (letter, digits, dashes) but holds a five-digit run.
        let folders = Array(segments.dropLast().filter { !isSizeSegment($0) || $0.split(whereSeparator: { !$0.isNumber }).contains { $0.count >= 5 } }.suffix(2))
        var out = Set(idTokens([file]).map { "id:\($0)" })
        for id in idTokens(folders) { out.insert(name.hasPrefix(id) ? "id:\(id)" : "dir:\(id)") }
        return out
    }

    /// `keys` without the folder ids that name a site or an account: one carried by two or more different pictures of
    /// the body (Webflow's /<site id>/, Hugging Face's /uploads/<user id>/) never says the lead is one of them.
    static func withoutSharedFolderIDs(_ heroKeys: Set<String>, srcs: [String]) -> Set<String> {
        let dirs = heroKeys.filter { $0.hasPrefix("dir:") }
        guard !dirs.isEmpty else { return heroKeys }
        let bodyKeys = srcs.map(keys)
        var out = heroKeys
        for dir in dirs {
            // The same picture twice has one file key; different pictures have different ones.
            let files = Set(bodyKeys.filter { $0.contains(dir) }.flatMap { $0.filter { !$0.hasPrefix("id:") && !$0.hasPrefix("dir:") && !$0.hasPrefix("toi:") } })
            if files.count > 1 { out.remove(dir) }
        }
        return out
    }

    private static let cropAndHash = ExtractionDOM.Pattern("-\\d{1,2}x\\d{1,2}-[0-9a-f]{32}$")

    /// A file name with the parts that only pick a size: Google's image hosts size a picture with `=w1440-h810-n-nu` or
    /// `=s1600` after the id; Dotdash Meredith (Allrecipes) names each crop <id>-<slug>-2x1-<hash> and -4x3-<hash>.
    static func sameFileName(_ name: String, host: String) -> String {
        if host.hasSuffix("googleusercontent.com"), let i = name.lastIndex(of: "=") { return String(name[..<i]) }
        return cropAndHash.replacing(name, with: "")
    }

    // MARK: A player leads

    private static let playerTag = ExtractionDOM.Pattern("<(?:video\\b|iframe\\b[^>]*\\bsrc\\s*=\\s*[\"'][^\"']*(?:youtube|youtu\\.be|vimeo|wistia|loom|dailymotion|brightcove|jwplayer|player\\.))", caseInsensitive: true)
    private static let imgTagAny = ExtractionDOM.Pattern("<img\\b[^>]*>", caseInsensitive: true)
    private static let fileDims = ExtractionDOM.Pattern("_(\\d{2,5})x(\\d{2,5})\\.[a-z]+[\"'?#]", caseInsensitive: true)
    private static let attrW = ExtractionDOM.Pattern("\\bwidth\\s*=\\s*[\"']?(\\d+)", caseInsensitive: true)
    private static let attrH = ExtractionDOM.Pattern("\\bheight\\s*=\\s*[\"']?(\\d+)", caseInsensitive: true)

    /// The body opens with a video player after only a series banner (a strip three or more times wider than tall, like
    /// Lenny's "How I AI" header) and a line of title: the player is the lead, and the lead art (the episode's card or the
    /// video's own thumbnail) would only sit above it.
    static func leadsWithPlayer(_ html: String) -> Bool {
        guard let player = playerTag.regex.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) else { return false }
        let before = (html as NSString).substring(to: player.range.location)
        let imgs = imgTagAny.allMatches(before).compactMap { $0[0] }
        guard !imgs.isEmpty, imgs.allSatisfy(isStrip), TextFormat.stripHTML(before).trimmingCharacters(in: .whitespacesAndNewlines).count <= 160 else { return false }
        return true
    }

    private static func isStrip(_ tag: String) -> Bool {
        var w = attrW.firstMatch(tag)?[1].flatMap { Double($0) }, h = attrH.firstMatch(tag)?[1].flatMap { Double($0) }
        if w == nil || h == nil, let d = fileDims.firstMatch(tag) { w = d[1].flatMap { Double($0) }; h = d[2].flatMap { Double($0) } }
        guard let w, let h, h > 0 else { return false }
        return w / h >= 3
    }

    // MARK: Cards that are not a picture

    /// A route that draws the page's sharing card (Next.js-style /<post>/image/16x9, /opengraph-image): a headline and a
    /// chart again, never the article's picture.
    private static let cardRoute = ExtractionDOM.Pattern("/image/\\d+x\\d+/?$|/(?:opengraph|twitter)-image(?:-[a-z0-9]+)?(?:\\.[a-z]+)?$", caseInsensitive: true)
    /// A file that is a site's logo, by its name alone (Blogger's default thumbnail is googlelogo_color_200x200.png); a logo named
    /// inside a photo's slug or credit (Quanta's "…-Lede-LOGO", Android Police's "3d-youtube-premium-logo-…") is a picture.
    private static let logoFile = ExtractionDOM.Pattern("^(?:google|site[-_]|brand[-_])?logo(?:[^a-z]|$)", caseInsensitive: true)

    static func isCardRoute(_ path: String) -> Bool { cardRoute.test(path) }

    static func isLogoFile(_ file: String) -> Bool {
        logoFile.test(imageExtension.replacing(file, with: ""))
    }
    private static let imageExtension = ExtractionDOM.Pattern("\\.(?:jpe?g|png|gif|webp|avif|svg|bmp|heic)$", caseInsensitive: true)
}

extension ArticlePasses {
    private static let srcSizeToken = P("(?:width|w)[-_=:](\\d{2,3})(?!\\d)", caseInsensitive: true)

    /// A hero whose src is a 200px placeholder (DeepMind's header.width-200.format-webp.webp) but whose srcset holds the
    /// real sizes: the candidate nearest 1200 wide, so the lead isn't an upscaled thumbnail.
    static func fullSizeSource(_ img: Element, src: String) -> String {
        guard let m = srcSizeToken.firstMatch(src), let w = Int(m[1] ?? ""), w < 400, let set = DOM.attr(img, "srcset") ?? DOM.attr(img, "data-srcset") else { return src }
        let candidates: [(url: String, width: Int)] = set.split(separator: ",").compactMap { part in
            let bits = part.split(whereSeparator: \.isWhitespace)
            guard bits.count == 2, bits[1].hasSuffix("w"), let w = Int(bits[1].dropLast()) else { return nil }
            return (String(bits[0]), w)
        }
        let best = candidates.filter { $0.width >= 1200 }.min { $0.width < $1.width } ?? candidates.max { $0.width < $1.width }
        guard let best, best.width >= 600 else { return src }
        return best.url
    }

    /// The page's own picture when the og:image's alt text is that picture's alt and the files differ: the site swapped the
    /// sharing file (BBC News' og:image became another shot of the scene, alt unchanged) while the article still opens with
    /// the original. The og:image then repeats the page's picture, so the page's own file is the lead.
    static func pageImageNamedByAlt(_ document: Element, base: String, ogAlt: String?, current: String?) -> String? {
        let alt = (ogAlt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard alt.count >= 25, let current else { return nil }
        for img in DOM.select(document, "article img, main img, [role=main] img, figure img") {
            guard (DOM.attr(img, "alt") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == alt,
                  DOM.closest(img, "nav, footer, aside, [role=navigation], [role=complementary]") == nil,
                  !isBadge(img), !isTinyImg(img), let src = DOM.attr(img, "src"), !src.hasPrefix("data:"),
                  let url = DOM.absURL(fullSizeSource(img, src: src), base: base), !isSmallThumbURL(url) else { continue }
            return url != current && LeadImage.keys(url).isDisjoint(with: LeadImage.keys(current)) ? url : nil
        }
        return nil
    }
}
