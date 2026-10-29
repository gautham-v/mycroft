import Foundation
import SwiftSoup

/// The pure (no network) half of src/lib/extract.ts: extractFromHtml, extractFromFeedHtml, preferFeed, podcast-notes
/// formatting, hero videos and the headline-region rescue. Readability itself is the injected `ReadabilityEngine`.
public struct ArticleExtraction: Sendable {
    private typealias DOM = ExtractionDOM
    private typealias Passes = ArticlePasses

    public let readability: any ReadabilityEngine

    public init(readability: any ReadabilityEngine = WebKitReadability.shared) {
        self.readability = readability
    }

    /// Feed HTML shorter than this is a summary, not the article.
    public static let minFeedText = 500
    /// A headline-region extraction shorter than this is a dek or a teaser, not the story.
    static let regionMinText = 500
    static let regionMinProse = 400
    static let feedWinRatio = 1.5
    static let feedWinMinExtra = 500
    static let heroMaxEmbeds = 3
    static let heroMaxTextBefore = 200
    static let videoEmbed = "iframe[src*=player.vimeo.com/video/], iframe[src*=youtube.com/embed/], iframe[src*=youtube-nocookie.com/embed/], video"

    // MARK: extractFromHtml

    /// Extract the main article from raw page HTML. Readability over the whole page (after split containers are
    /// joined) wins by default; a Readability run scoped to the headline's region replaces it when the first pick lies
    /// outside that region and the scoped run keeps at least 500 characters and half as much text.
    public func extract(html: String, pageURL: String) async throws -> ExtractResult {
        guard let document = DOM.parseDocument(html, baseURI: pageURL) else { return ExtractResult(contentHtml: nil, leadImage: nil) }
        let base = DOM.absURL(DOM.first(document, "base[href]").flatMap { DOM.attr($0, "href") }, base: pageURL) ?? pageURL
        let og = DOM.first(document, "meta[property=og:image]").flatMap { DOM.attr($0, "content") }
            ?? DOM.first(document, "meta[name=twitter:image]").flatMap { DOM.attr($0, "content") }
        let lead = Passes.usableLead(DOM.absURL(og, base: base))
        Passes.prepare(document, base: base, pageURL: pageURL, videos: ExtractionPayload.videos(in: html))
        Passes.placeApolloImages(document, html: html)
        Self.removePreHeadlineMeta(document)
        let picture = Passes.pictureStory(document)
        let audio = SiteAudio.take(document)
        let pagePlayer = SiteVideo.hasPagePlayer(document)
        let heroes = Self.findHeroVideos(document)
        let media = Passes.protectMedia(document)
        Passes.neutralizeReadabilityClasses(document)
        Passes.shieldFigures(document)
        Passes.mergeSplitContainers(document)
        Passes.keepArticleContent(document)
        let regionHTML = Self.headlineRegion(document).map(DOM.outerHTML)
        let title = DOM.first(document, "title").map { (try? $0.text()) ?? "" } ?? ""
        let pageHTML = (try? document.outerHtml()) ?? html

        var clean = try await runReadability(pageHTML, media: media, base: base)
        if let regionHTML, clean == nil || Self.pickedOutsideRegion(contentHTML: clean ?? "", regionHTML: regionHTML) {
            let scoped = "<!doctype html><html><head><title>\(DOM.escapeHTML(title))</title></head><body>\(regionHTML)</body></html>"
            let alt = try await runReadability(scoped, media: media, base: base)
            let n = DOM.plainText(alt).count
            if let alt, n >= Self.regionMinText, Double(n) >= 0.5 * Double(DOM.plainText(clean).count) { clean = alt }
        }
        if let picture, clean.map({ !Passes.containsPicture($0, of: picture) }) ?? true {
            clean = Self.finish(readabilityContent: picture, media: [], base: base)
        }
        if SiteVideo.isVideoPage(document, pageURL: pageURL, pagePlayer: pagePlayer, content: clean, poster: lead) {
            return ExtractResult(contentHtml: SiteVideo.content(document), leadImage: lead)
        }
        let titles = [DOM.first(document, "meta[property=og:title]").flatMap { DOM.attr($0, "content") }, title]
        clean = clean.map { Self.dropTitleHeading($0, titles: titles.compactMap { $0 }) }
        if let audio {
            // The story is the audio; the text beside it may be a line or nothing.
            let text = clean ?? SiteVideo.description(document).map { ArticleSanitizer.sanitize($0) } ?? ""
            return ExtractResult(contentHtml: SiteAudio.marker(audio) + text, leadImage: lead)
        }
        guard let found = clean else { return ExtractResult(contentHtml: nil, leadImage: lead) }
        let withHero = Self.heroVideoFirst(found, heroes: heroes)
        return ExtractResult(contentHtml: withHero, leadImage: lead ?? Passes.firstImage(withHero))
    }

    func runReadability(_ html: String, media: [String], base: String) async throws -> String? {
        guard let content = try await readability.articleContent(html: html, baseURL: base), !content.isEmpty else { return nil }
        return Self.finish(readabilityContent: content, media: media, base: base)
    }

    /// Readability output → restored media → cleanArticle → sanitize. Nil when nothing is left.
    static func finish(readabilityContent content: String, media: [String], base: String) -> String? {
        let out = ArticleSanitizer.sanitize(Passes.cleanArticle(Passes.restoreMedia(content, media), base: base))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    // MARK: Feed copy

    /// The rule for page vs. feed: the feed's content:encoded wins only when its text is at least 1.5× the page
    /// extraction's and 500 characters longer (and is itself a full article).
    public static func preferFeed(pageHTML: String?, feedHTML: String?) -> Bool {
        let f = Double(DOM.plainText(feedHTML).count)
        let p = Double(DOM.plainText(pageHTML).count)
        return f >= Double(minFeedText) && f >= p * feedWinRatio && f - p >= Double(feedWinMinExtra)
    }

    /// Article HTML that came from the feed itself (content:encoded). No Readability. Nil content when a teaser.
    public static func extractFromFeedHTML(_ html: String, pageURL: String, minText: Int = minFeedText) -> ExtractResult {
        let prepared = DOM.withFragment("<div id=\"__root\">\(html)</div>") { body -> String? in
            guard let root = DOM.first(body, "#__root") else { return nil }
            Passes.prepare(root, base: pageURL, pageURL: pageURL)
            return DOM.innerHTML(root)
        } ?? nil
        guard let prepared else { return ExtractResult(contentHtml: nil, leadImage: nil) }
        let clean = ArticleSanitizer.sanitize(Passes.cleanArticle(prepared, base: pageURL))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if DOM.plainText(clean).count < minText { return ExtractResult(contentHtml: nil, leadImage: nil) }
        return ExtractResult(contentHtml: clean, leadImage: Passes.firstImage(clean))
    }

    private static let anyTag = ExtractionDOM.Pattern("<[a-z][^>]*>", caseInsensitive: true)
    private static let blankLine = ExtractionDOM.Pattern("\\n\\s*\\n")

    /// Podcast show notes: plain-text notes (no tags) keep their line breaks as paragraphs; any length counts.
    public static func podcastNotes(_ html: String, pageURL: String) -> ExtractResult {
        let notes: String
        if anyTag.test(html) {
            notes = html
        } else {
            let marker = "\u{1F}"
            notes = blankLine.replacing(html, with: marker).components(separatedBy: marker).map {
                "<p>\(DOM.escapeHTML($0.trimmingCharacters(in: .whitespacesAndNewlines)).replacingOccurrences(of: "\n", with: "<br>"))</p>"
            }.joined()
        }
        return ExtractResult(contentHtml: extractFromFeedHTML(notes, pageURL: pageURL, minText: 1).contentHtml, leadImage: nil)
    }

    // MARK: Headline region

    /// The article's title <h1>: the one matching og:title / <title>, or the page's only <h1>.
    static func headline(_ document: Element) -> Element? {
        let og = DOM.first(document, "meta[property=og:title]").flatMap { DOM.attr($0, "content") }
        let title = DOM.norm(og ?? DOM.first(document, "title").map { DOM.rawText($0) })
        let h1s = DOM.select(document, "h1").filter { !DOM.norm(DOM.text($0)).isEmpty }
        if !title.isEmpty, let match = h1s.first(where: { title.contains(DOM.norm(DOM.text($0))) || DOM.norm(DOM.text($0)).contains(title) }) {
            return match
        }
        return h1s.count == 1 ? h1s[0] : nil
    }

    /// The nearest ancestor of the title <h1> that holds real prose; nil when unidentified or the whole page.
    static func headlineRegion(_ document: Element) -> Element? {
        var el = headline(document)?.parent()
        while let cur = el, !(cur is Document), !DOM.isTag(cur, ["body", "html"]) {
            if DOM.proseLen(cur) >= regionMinProse { return cur }
            el = cur.parent()
        }
        return nil
    }

    static let preHeadlineMaxText = 150
    /// How many leading blocks may hold the headline again.
    static let titleHeadingReach = 3
    private static let titleSuffix = DOM.Pattern("\\s+[|–—:-]\\s+[^|–—:-]{1,40}$")

    /// The reader draws the title itself; a heading near the top that repeats it (NPR's audio module title, a
    /// template's own <h1>) goes. Matched ignoring case, punctuation and a " | Site" suffix.
    static func dropTitleHeading(_ html: String, titles: [String]) -> String {
        func key(_ s: String) -> String { DOM.norm(s).filter { $0.isLetter || $0.isNumber } }
        let keys = Set(titles.flatMap { [key($0), key(titleSuffix.replacing($0, with: ""))] }.filter { $0.count >= 12 })
        guard !keys.isEmpty else { return html }
        return DOM.withFragment(html) { body -> String in
            let blocks = DOM.select(body, "h1, h2, h3, h4, h5, h6, p").filter { !DOM.text($0).isEmpty }
            for h in blocks.prefix(titleHeadingReach) where DOM.isTag(h, DOM.headingTags) && keys.contains(key(DOM.text(h))) {
                DOM.remove(h)
            }
            return DOM.innerHTML(body)
        } ?? html
    }

    /// The kicker and date line a template sets just above the title <h1> in the article column (TechCrunch's
    /// "In Brief" and "Posted: 9:42 AM PDT"): Readability keeps them when it picks that column. Short siblings before
    /// the headline with no media go; a featured image there stays.
    static func removePreHeadlineMeta(_ document: Element) {
        guard let h1 = headline(document) else { return }
        var el = try? h1.previousElementSibling()
        while let cur = el {
            el = try? cur.previousElementSibling()
            let media = (DOM.matches(cur, Passes.contentMedia) ? [cur] : []) + DOM.select(cur, Passes.contentMedia)
            // A section's logo beside a breadcrumb (Bleacher Report's NFL shield) is no featured image.
            if DOM.textLen(DOM.text(cur)) > preHeadlineMaxText || media.contains(where: { !Passes.isLogo($0) }) { continue }
            DOM.remove(cur)
        }
    }

    /// Paragraph texts (long enough to be distinctive).
    static func paragraphTexts(_ root: Element) -> [String] {
        DOM.select(root, "p").map { DOM.norm(DOM.text($0)) }.filter { $0.count >= 40 }
    }

    /// True when Readability's pick lies outside the headline's region and doesn't contain it either.
    public static func pickedOutsideRegion(contentHTML: String, regionHTML: String) -> Bool {
        guard let (pickedText, pickedParas) = DOM.withFragment(contentHTML, { (DOM.norm(DOM.text($0)), paragraphTexts($0)) }),
              let (regionText, regionParas) = DOM.withFragment(regionHTML, { (DOM.norm(DOM.text($0)), paragraphTexts($0)) }) else { return false }
        if pickedParas.isEmpty || regionParas.isEmpty { return false }
        let inside = Double(pickedParas.filter { regionText.contains($0) }.count) / Double(pickedParas.count)
        let covered = Double(regionParas.filter { pickedText.contains($0) }.count) / Double(regionParas.count)
        return inside < 0.3 && covered < 0.5
    }

    // MARK: Hero videos

    struct HeroVideo: Sendable {
        var html: String
        /// What identifies the video in extracted HTML (a Vimeo/YouTube id, or the file URL).
        var key: String
        /// Paragraph texts before and after it: the whole article body must come after a hero.
        var before: Set<String>
        var after: Set<String>
    }

    private static let embedID = ExtractionDOM.Pattern("(?:player\\.vimeo\\.com/video|/embed)/([\\w-]+)")

    static func videoKey(_ el: Element) -> String? {
        if DOM.tag(el) == "video" {
            let src = DOM.attr(el, "src") ?? DOM.first(el, "source[src]").flatMap { DOM.attr($0, "src") }
            guard let src, !src.hasPrefix("data:") else { return nil }
            return src
        }
        return embedID.firstMatch(DOM.attr(el, "src") ?? "")?[1] ?? nil
    }

    /// A video in the header around the headline (OpenAI's hero Vimeo clip), which Readability drops with the header.
    static func findHeroVideos(_ document: Element) -> [HeroVideo] {
        guard let h1 = headline(document) else { return [] }
        let order = DOM.documentOrder(document)
        func at(_ el: Element) -> Int { order[ObjectIdentifier(el)] ?? -1 }
        let paras = DOM.select(document, "p")
        var out: [HeroVideo] = []
        for el in DOM.select(document, videoEmbed) {
            if out.count >= heroMaxEmbeds || DOM.closest(el, "nav, footer, aside") != nil { continue }
            guard let key = videoKey(el), !DOM.contains(h1, el) else { continue }
            if at(el) < at(h1) && Passes.between(el, h1).text > heroMaxTextBefore { continue }
            let box = DOM.closest(el, "figure") ?? el
            let end = at(box) + DOM.descendantCount(box)
            var before = Set<String>(), after = Set<String>()
            for p in paras {
                let t = DOM.norm(DOM.text(p))
                guard t.count >= 40 else { continue }
                if at(p) < at(box) { before.insert(t) } else if at(p) > end { after.insert(t) }
            }
            if after.isEmpty { continue }
            out.append(HeroVideo(html: DOM.outerHTML(el), key: key, before: before, after: after))
        }
        return out
    }

    /// Put the hero video first when the whole extraction comes after it on the page and doesn't have it already.
    static func heroVideoFirst(_ clean: String, heroes: [HeroVideo]) -> String {
        guard !heroes.isEmpty, let first = DOM.withFragment(clean, { paragraphTexts($0).first }) ?? nil else { return clean }
        guard let hero = heroes.first(where: { $0.after.contains(first) && !$0.before.contains(first) && !clean.contains($0.key) }) else {
            return clean
        }
        let html = ArticleSanitizer.sanitize(hero.html).trimmingCharacters(in: .whitespacesAndNewlines)
        return html.isEmpty ? clean : html + clean
    }

    // MARK: Login walls

    private static let loginWall = ExtractionDOM.Pattern("\\b(log ?in|sign ?in|sign ?up)\\b.{0,40}\\b(sign ?up|continue|to (?:see|view|read))", caseInsensitive: true)
    /// A bot check's page (DataDome on Reuters: "Please enable JS and disable any ad blocker").
    private static let botWall = ExtractionDOM.Pattern("\\b(?:enable (?:js|javascript)\\b.{0,40}\\b(?:ad ?blocker|cookies)|verify(?:ing)? (?:that )?you are (?:a )?human|are you a robot|checking your browser|captcha)", caseInsensitive: true)

    static let minProseParagraph = 120

    /// Some paragraph reads as prose (a sentence of `minProseParagraph`+ characters), not only links and labels.
    static func hasProse(_ html: String) -> Bool {
        DOM.withFragment(html) { body in
            DOM.select(body, "p, li, blockquote, td").contains { DOM.textLen(DOM.text($0)) >= minProseParagraph }
                || DOM.textLen(DOM.text(body)) >= 4 * minProseParagraph
        } ?? false
    }

    /// Rendered pages behind an auth wall or a bot check come back as a short page about logging in or proving
    /// you're a person.
    static func isLoginWall(_ html: String) -> Bool {
        let text = ExtractionDOM.Pattern("[\\s]+").replacing(ExtractionDOM.Pattern("<[^>]+>").replacing(html, with: " "), with: " ")
        return text.count < 2500 && (loginWall.test(text) || (text.count < 600 && botWall.test(text)))
    }
}
