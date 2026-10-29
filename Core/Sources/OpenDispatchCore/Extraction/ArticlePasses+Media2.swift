import Foundation
import SwiftSoup

/// Images and embeds the first round of fixes left missing or broken (the second audit): players a page's script mounts
/// from data in the page (a Next.js payload, an `ex.co` push, a Mux or Cloudflare Stream id), facades whose player
/// is an empty iframe, lightbox buttons around a captioned picture, posters in the wrong place, and placeholders that
/// would draw as empty boxes. `media2Embeds` runs in `prepare` before `embeds`, while the page's scripts and
/// classes are intact; `media2Tidy` runs at the end of `prepare`.
extension ArticlePasses {
    static func media2Embeds(_ root: Element, base: String) {
        teaserPlayers(root)
        lightboxFigures(root)
        consentNotices(root)
        noscriptVideos(root)
        jsonLDVideoTitles(root)
        emptyYouTubeFrames(root)
        playButtonThumbnails(root)
        payloadYouTubeEmbeds(root)
        eaterInstagramEmbeds(root)
        videoEmbedPushes(root)
        muxPlayers(root)
        cloudflareStreamFrames(root)
        lazyVideoPosters(root, base: base)
        darkChartFrames(root)
    }

    static func media2Tidy(_ root: Element) {
        portraitPosters(root)
        posterStillsBesideVideos(root)
        duplicateVideos(root)
        responsiveCaptionTwins(root)
        unwrapPictureGroups(root)
        sourcelessImages(root)
    }

    // MARK: Helpers

    private static func youTubeID(_ url: String) -> String? {
        guard let c = URLComponents(string: url), let host = c.host?.lowercased() else { return nil }
        let id: String?
        if host == "youtu.be" { id = String(c.path.dropFirst()) }
        else if host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") {
            id = c.path.hasPrefix("/embed/") ? String(c.path.dropFirst("/embed/".count)) : c.queryItems?.first { $0.name == "v" }?.value
        } else { id = nil }
        return id.flatMap { youTubeIDShape.test($0) ? $0 : nil }
    }

    private static let youTubeIDShape = P("^[A-Za-z0-9_-]{11}$")

    private static func youTubeFigure(_ id: String, title: String? = nil) -> String {
        let src = ArticleSanitizer.embedSrc("https://www.youtube.com/embed/\(id)", watchable: true)
        let t = title.flatMap { $0.isEmpty ? nil : " title=\"\(DOM.escapeAttr($0))\"" } ?? ""
        return "<figure><iframe src=\"\(DOM.escapeAttr(src))\"\(t) allow=\"fullscreen; picture-in-picture\" allowfullscreen></iframe></figure>"
    }

    private static func videoFigure(src: String, poster: String?, caption: String? = nil) -> String {
        let p = poster.map { " poster=\"\(DOM.escapeAttr($0))\"" } ?? ""
        let c = caption.flatMap { $0.isEmpty ? nil : "<figcaption>\(DOM.escapeHTML($0))</figcaption>" } ?? ""
        return "<figure><video src=\"\(DOM.escapeAttr(src))\"\(p) controls preload=\"none\" playsinline></video>\(c)</figure>"
    }

    /// An element and the wrappers it alone filled.
    private static func removeWithEmptyWrappers(_ el: Element, stop root: Element) {
        var gone = el
        while let p = gone.parent(), p !== root, !(p is Document), !DOM.isTag(p, ["body", "html", "article", "main"]),
              DOM.children(p).count == 1, DOM.text(p) == DOM.text(gone) { gone = p }
        DOM.remove(gone)
    }

    // MARK: Teaser cards

    /// A click-to-play facade in a related-post card (GitHub's `post-card`, its video in a <template>) is the card's
    /// thumbnail, not a player for the article: `templateVideos` would put a stranger's video in the story.
    private static let teaserBox = "[class*=post-card], [class*=teaser], [class*=tease-]"

    static func teaserPlayers(_ root: Element) {
        for t in DOM.select(root, "template") where DOM.isConnected(t) && DOM.first(t, "iframe") != nil && DOM.closest(t, teaserBox) != nil {
            DOM.remove(t)
        }
    }

    // MARK: Lightbox figures

    private static let imageCountLabel = P("^view (?:all )?\\d+ (?:images?|photos?|pictures?)$", caseInsensitive: true)

    /// A captioned picture inside a button that opens it larger (the Mirror's `image-group`, a `<button>` holding the
    /// figure, its "View 3 Images" label and its caption) is no control: the button goes, the figure stays.
    /// `unwrapImageButtons` only takes buttons with no words, and `removeInterface` drops the rest.
    static func lightboxFigures(_ root: Element) {
        for b in DOM.select(root, "button, [role=button]") where DOM.isConnected(b) {
            guard DOM.first(b, "img") != nil, DOM.first(b, "figcaption") != nil else { continue }
            for label in DOM.select(b, "div, span") where DOM.isConnected(label) && imageCountLabel.test(DOM.text(label)) && DOM.first(label, "img, picture, video, figure") == nil {
                DOM.remove(label)
            }
            _ = try? b.unwrap()
        }
    }

    // MARK: Consent and blocker notices

    private static let consentNotice = P("^(?:content cannot be displayed without consent|to display this content from [\\w ]+, you must enable advertisement tracking and audience measurement\\.?|one of your browser extensions seems to be blocking the video player from loading\\..{0,120})$", caseInsensitive: true)
    private static let playLabel = P("^play video$", caseInsensitive: true)

    /// What a page says where an embed would be when its player can't load (a consent wall, an ad blocker), and the
    /// "Play Video" label a JW Player poster leaves under it: the reader has no use for either.
    static func consentNotices(_ root: Element) {
        for el in DOM.select(root, "p, figcaption, div, span") where DOM.isConnected(el) {
            let text = DOM.text(el)
            if consentNotice.test(text), DOM.first(el, "p, div, img, video, iframe") == nil || DOM.tag(el) == "p" {
                // A figure that is only the notice and an icon goes whole.
                if let fig = el.parent(), DOM.tag(fig) == "figure", DOM.first(fig, "img, video, iframe, picture") == nil { DOM.remove(fig) }
                else { removeWithEmptyWrappers(el, stop: root) }
            } else if DOM.tag(el) == "p", playLabel.test(text), let prev = try? el.previousElementSibling(),
                      DOM.first(prev, "img") != nil || DOM.tag(prev) == "img" {
                DOM.remove(el)
            }
        }
    }

    /// A clip the page's script would mount sits in a <noscript> (Vogue's looping `responsive-clip__video` slides):
    /// with no picture beside it, the clip is the page's picture.
    static func noscriptVideos(_ root: Element) {
        for ns in DOM.select(root, "noscript") where DOM.isConnected(ns) {
            guard DOM.first(ns, "video[src], video source[src]") != nil, DOM.first(ns, "img") == nil,
                  ns.parent().map({ DOM.select($0, "img, picture").isEmpty }) ?? false else { continue }
            _ = try? ns.unwrap()
        }
    }

    /// A player the page's script draws (the Mirror's Primis lead video) leaves only its title as a line of text, while
    /// the page's JSON-LD describes the clip (`VideoObject`: name, contentUrl, thumbnailUrl). A short block that is exactly
    /// a clip's name, outside any caption, becomes the clip.
    static func jsonLDVideoTitles(_ root: Element) {
        var clips: [(name: String, url: String, poster: String?)] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if (dict["@type"] as? String) == "VideoObject", let name = dict["name"] as? String, let url = dict["contentUrl"] as? String, url.hasPrefix("http") {
                    clips.append((DOM.norm(name), url, dict["thumbnailUrl"] as? String))
                }
                for v in dict.values { walk(v) }
            } else if let list = node as? [Any] {
                for v in list { walk(v) }
            }
        }
        for script in DOM.select(root, "script[type=application/ld+json]") {
            if let data = script.data().data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) { walk(json) }
        }
        guard !clips.isEmpty else { return }
        for el in DOM.select(root, "p, span, div") where DOM.isConnected(el) {
            let text = DOM.norm(DOM.text(el))
            guard text.count >= 12, text.count <= 200, let clip = clips.first(where: { $0.name == text }),
                  DOM.first(el, "img, video, iframe") == nil,
                  DOM.closest(el, "figure, figcaption, blockquote, a, h1, h2, h3, h4, h5, h6, li") == nil else { continue }
            var box: Element = el
            while let p = box.parent(), !(p is Document), !DOM.isTag(p, ["body", "html", "article", "main"]), DOM.children(p).count == 1,
                  DOM.text(p) == DOM.text(box) { box = p }
            DOM.replace(box, withHTML: videoFigure(src: clip.url, poster: clip.poster))
            clips.removeAll { $0.name == text }
        }
    }

    // MARK: YouTube

    /// A facade whose player is an empty `<iframe src="">` the page's script fills on click (Smithsonian: a thumbnail
    /// with the video's title, "Watch on YouTube" and the id in `data-video-id`): the id makes it the plain player.
    static func emptyYouTubeFrames(_ root: Element) {
        for frame in DOM.select(root, "iframe") where DOM.isConnected(frame) && DOM.attr(frame, "src") == nil
            && DOM.attr(frame, "srcdoc") == nil && DOM.attr(frame, "data-src") == nil {
            guard let box = DOM.closest(frame, "figure") ?? frame.parent(), !(box is Document),
                  !DOM.isTag(box, ["body", "html", "article", "main"]), DOM.textLen(DOM.text(box)) <= 200 else { continue }
            var id = DOM.first(box, "[data-video-id]").flatMap { DOM.attr($0, "data-video-id") }.flatMap { youTubeIDShape.test($0) ? $0 : nil }
            if id == nil { id = DOM.select(box, "a[href]").lazy.compactMap { DOM.attr($0, "href").flatMap(youTubeID) }.first }
            if id == nil { id = DOM.select(box, "img[src]").lazy.compactMap { DOM.attr($0, "src").flatMap(thumbnailID) }.first }
            guard let id else { continue }
            DOM.replace(box, withHTML: youTubeFigure(id, title: DOM.attr(frame, "title")))
        }
    }


    private static let playWord = P("^\\s*(?:play|watch)\\b", caseInsensitive: true)

    /// A YouTube thumbnail with a play button over it and no player anywhere (Android Authority's `<img
    /// src=img.youtube.com/vi/ID/hqdefault.jpg>` and a button whose script would start it): the id in the thumbnail's address
    /// makes it the plain player. A thumbnail without a play button is a picture, and one beside a player of its own (a <template>) is that player's facade.
    static func playButtonThumbnails(_ root: Element) {
        for img in DOM.select(root, "img[src]") where DOM.isConnected(img) {
            guard let id = DOM.attr(img, "src").flatMap(thumbnailID), let box = img.parent(), !(box is Document),
                  !DOM.isTag(box, ["body", "html", "article", "main", "a", "figure", "picture"]), DOM.textLen(DOM.text(box)) <= 40, DOM.first(box, "template, iframe, noscript") == nil,
                  DOM.select(box, "button, [role=button]").contains(where: { playWord.test("\(DOM.attr($0, "aria-label") ?? "") \(DOM.text($0))") }) else { continue }
            DOM.replace(box, withHTML: youTubeFigure(id))
        }
    }

    private static let thumbnailPattern = P("(?:img\\.youtube\\.com|i\\.ytimg\\.com)/vi(?:_webp)?/([A-Za-z0-9_-]{11})/")

    private static func thumbnailID(_ src: String) -> String? { thumbnailPattern.firstMatch(src)?[1] ?? nil }

    private static let payloadYouTube = P(#"YoutubeEmbed\\?","id\\?":\\?"([^"\\]+)[\s\S]{0,600}?\\?"link\\?":\\?"(https?:[^"\\]+)"#)

    /// Placeholders a page's script turns into YouTube players (The Ringer's `data-module=youtube-embed`, empty but for
    /// a play button) while the page's own data lists the clips' addresses in the same order: the n-th placeholder is the
    /// n-th clip. Only when the counts agree.
    static func payloadYouTubeEmbeds(_ root: Element) {
        let slots = DOM.select(root, "[data-module=youtube-embed]").filter { DOM.isConnected($0) && DOM.first($0, "iframe, video") == nil }
        guard !slots.isEmpty else { return }
        var ids: [String] = []
        var seen = Set<String>()
        for script in DOM.select(root, "script") {
            let code = script.data()
            guard code.contains("YoutubeEmbed") else { continue }
            for m in payloadYouTube.allMatches(code) {
                guard let block = m[1], let link = m[2]?.replacingOccurrences(of: "\\/", with: "/"), let id = youTubeID(link), seen.insert(block).inserted else { continue }
                ids.append(id)
            }
        }
        guard ids.count == slots.count else { return }
        for (slot, id) in zip(slots, ids) { DOM.replace(slot, withHTML: youTubeFigure(id)) }
    }

    // MARK: Eater

    /// Eater's map entries carry an Instagram post in the page's data (`mapPoints[].ledeMedia.embedHtml`) its script
    /// draws under the entry's heading; the entry gets the blockquote Instagram's own embed leaves, which
    /// `EmbeddedPosts` draws as a post card.
    static func eaterInstagramEmbeds(_ root: Element) {
        guard let script = DOM.first(root, "script#__NEXT_DATA__"), let data = script.data().data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return }
        var posts: [String: String] = [:]
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let name = dict["name"] as? String, let media = dict["ledeMedia"] as? [String: Any], media["provider"] as? String == "instagram",
                   let html = media["embedHtml"] as? String, let permalink = instagramPermalink.firstMatch(html)?[1] {
                    posts[DOM.norm(name)] = permalink.components(separatedBy: "?")[0]
                }
                for v in dict.values { walk(v) }
            } else if let list = node as? [Any] {
                for v in list { walk(v) }
            }
        }
        walk(json)
        guard !posts.isEmpty else { return }
        for h in DOM.select(root, "h2, h3") where DOM.isConnected(h) {
            guard let href = posts[DOM.norm(DOM.text(h))] else { continue }
            // The heading's own row (title and a save button) is what the card follows.
            var anchor: Element = h
            if let p = h.parent(), DOM.first(p, "p, ul, ol, figure, blockquote") == nil, DOM.children(p).count <= 3, DOM.attr(p, "data-slug") == nil { anchor = p }
            _ = try? anchor.after("<blockquote><p><a href=\"\(DOM.escapeAttr(href))\">View this post on Instagram</a></p></blockquote>")
        }
    }

    private static let instagramPermalink = P("data-instgrm-permalink=\"([^\"]+)\"")

    // MARK: Players from ids and data in the page

    private static let videoEmbedStart = P("elemId:\\s*'([^']+)'\\s*,\\s*data:\\s*(?=\\{)")

    /// ex.co's players (Ziff Davis: PCMag) are mounted by `window.videoEmbeds.push({elemId, data: {url, thumbnail_url,
    /// title}})`; its container is a play-button SVG, a thumbnail and the logo. The container becomes the video.
    static func videoEmbedPushes(_ root: Element) {
        for script in DOM.select(root, "script") {
            let code = script.data()
            guard code.contains("videoEmbeds.push") else { continue }
            for m in videoEmbedStart.allMatches(code) {
                guard let id = m[1], let r = code.range(of: m[0] ?? "\u{0}") else { continue }
                let bytes = Array(code[r.upperBound...].utf8)
                let end = ExtractionPayload.balancedEnd(bytes, 0)
                guard end > 0, let data = (try? JSONSerialization.jsonObject(with: Data(bytes[0..<end]))) as? [String: Any],
                      let url = data["url"] as? String, url.hasPrefix("http"),
                      let el = DOM.first(root, "[id=\"\(id)\"]") else { continue }
                let box = DOM.closest(el, ".video-parent") ?? el
                DOM.replace(box, withHTML: videoFigure(src: url, poster: data["thumbnail_url"] as? String, caption: data["title"] as? String))
            }
        }
    }

    private static let muxThumbnail = P("image\\.mux\\.com/([A-Za-z0-9]+)/thumbnail\\.(?:jpg|png|webp)")

    /// Mux's player (`media-controller`, drawn by script) leaves a box with the thumbnail as its background; a public
    /// playback id streams from `stream.mux.com/<id>.m3u8`, the address that thumbnail is made from.
    static func muxPlayers(_ root: Element) {
        for box in DOM.select(root, ".media-controller[style*=image.mux.com]") where DOM.isConnected(box) {
            guard let id = muxThumbnail.firstMatch(DOM.attr(box, "style") ?? "")?[1] else { continue }
            let target = DOM.closest(box, "figure") ?? box
            DOM.replace(target, withHTML: videoFigure(src: "https://stream.mux.com/\(id).m3u8", poster: "https://image.mux.com/\(id)/thumbnail.jpg"))
        }
    }

    /// Cloudflare Stream's player iframe (`iframe.videodelivery.net/<id>`, `customer-x.cloudflarestream.com/<id>/iframe`)
    /// isn't an allowed frame; the same id streams as HLS from the same host, which a <video> plays.
    static func cloudflareStreamFrames(_ root: Element) {
        for frame in DOM.select(root, "iframe[src]") where DOM.isConnected(frame) {
            guard let src = DOM.attr(frame, "src"), let c = URLComponents(string: src), let host = c.host?.lowercased(),
                  host == "iframe.videodelivery.net" || host.hasSuffix(".cloudflarestream.com"),
                  let id = c.path.split(separator: "/").first.map(String.init), id.count >= 20 else { continue }
            let origin = host == "iframe.videodelivery.net" ? "https://videodelivery.net" : "https://\(host)"
            let poster = c.queryItems?.first { $0.name == "poster" }?.value ?? "\(origin)/\(id)/thumbnails/thumbnail.jpg"
            let box = DOM.closest(frame, "figure")
            // The page's own poster picture sits under its player.
            if let box { for img in DOM.select(box, "img") { removeWithEmptyWrappers(img, stop: box) } }
            DOM.replace(frame, withHTML: "<video src=\"\(DOM.escapeAttr("\(origin)/\(id)/manifest/video.m3u8"))\" poster=\"\(DOM.escapeAttr(poster))\" controls preload=\"none\" playsinline></video>")
        }
    }

    /// A video whose `poster` is a one-pixel placeholder and whose real picture is in another attribute (DW's
    /// `data-posterurl`).
    static func lazyVideoPosters(_ root: Element, base: String) {
        for v in DOM.select(root, "video[data-posterurl], video[data-poster-url]") {
            guard isPlaceholderSrc(DOM.attr(v, "poster")),
                  let url = DOM.absURL(DOM.attr(v, "data-posterurl") ?? DOM.attr(v, "data-poster-url"), base: base) else { continue }
            DOM.setAttr(v, "poster", url)
        }
    }

    /// Datawrapper's embed ships a dark and a light frame, one hidden by CSS: the light one stays.
    static func darkChartFrames(_ root: Element) {
        let frames = DOM.select(root, "iframe[src]").filter { isChartFrame($0) }
        func key(_ f: Element) -> String { (URLComponents(string: DOM.attr(f, "src") ?? "")).map { ($0.host ?? "") + $0.path } ?? "" }
        func dark(_ f: Element) -> Bool { URLComponents(string: DOM.attr(f, "src") ?? "")?.queryItems?.contains { $0.name == "dark" && $0.value == "true" } ?? false }
        for f in frames where dark(f) && frames.contains(where: { $0 !== f && key($0) == key(f) && !dark($0) }) {
            removeWithEmptyWrappers(f, stop: root)
        }
    }

    // MARK: Tidy

    /// MLB's portrait clips (`…_portrait.mp4`) have a 16:9 poster from the page's data: asked for at 9:16, it is
    /// the clip's shape, and the box doesn't stand taller than its picture.
    static func portraitPosters(_ root: Element) {
        for v in DOM.select(root, "video[poster*=mlbstatic.com]") {
            let src = DOM.attr(v, "src") ?? DOM.first(v, "source").flatMap { DOM.attr($0, "src") } ?? ""
            guard src.lowercased().contains("_portrait."), let poster = DOM.attr(v, "poster"), poster.contains("w_1280,h_720") else { continue }
            DOM.setAttr(v, "poster", poster.replacingOccurrences(of: "w_1280,h_720", with: "w_720,h_1280"))
        }
    }

    /// A still of the video (the non-video fallback, often the poster itself) after the player in the same figure.
    static func posterStillsBesideVideos(_ root: Element) {
        for v in DOM.select(root, "video[poster]") where DOM.isConnected(v) {
            guard let poster = DOM.attr(v, "poster"), let box = DOM.closest(v, "figure") else { continue }
            for img in DOM.select(box, "img[src]") where DOM.attr(img, "src") == poster { removeWithEmptyWrappers(img, stop: box) }
        }
    }

    /// Readability drops a block with several pictures and no paragraphs ("a gallery") unless it is inside a figure: the
    /// Daily Mail's `artSplitter` around its left and right photos, once `captionFigures` made them one figure, is such
    /// a block. A block that holds only a figure of several pictures is that figure.
    static func unwrapPictureGroups(_ root: Element) {
        for fig in DOM.select(root, "figure") where DOM.isConnected(fig) && DOM.select(fig, "img, picture").count >= 2 {
            var box: Element = fig
            while let p = box.parent(), p !== root, !(p is Document), DOM.isTag(p, ["div", "span", "section"]),
                  DOM.children(p).filter({ hasMediaOrText($0) }).count == 1 { box = p }
            guard box !== fig else { continue }
            _ = try? box.before(DOM.outerHTML(fig))
            DOM.remove(box)
        }
    }

    /// One video shown twice (DW embeds the same clip under the same heading at two places): the first copy stays,
    /// with its wrapper's heading, and the later ones go with theirs.
    static func duplicateVideos(_ root: Element) {
        var seen = Set<String>()
        for v in DOM.select(root, "video") where DOM.isConnected(v) {
            guard let src = DOM.attr(v, "src") ?? DOM.first(v, "source[src]").flatMap({ DOM.attr($0, "src") }), !src.isEmpty else { continue }
            if seen.insert(src).inserted { continue }
            var box: Element = v
            while let p = box.parent(), p !== root, !(p is Document), DOM.isTag(p, ["div", "p", "figure", "span"]), DOM.textLen(DOM.text(p)) <= 160,
                  DOM.select(p, "video").count == 1 { box = p }
            DOM.remove(box)
        }
    }

    private static func words(_ s: String) -> Set<String> {
        Set(DOM.norm(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// A figure that carries its caption twice, once per layout (Quanta's `m:hidden` and `s:hidden` pair, "(top)/(bottom)"
    /// and "(left)/(right)"): the first copy stays and takes whatever the second adds (the credit).
    static func responsiveCaptionTwins(_ root: Element) {
        for fig in DOM.select(root, "figure") where DOM.isConnected(fig) {
            let caps = DOM.select(fig, "figcaption").filter { DOM.closest($0.parent() ?? $0, "figure") === fig }
            guard caps.count >= 2, let first = caps.first else { continue }
            let firstWords = words(DOM.text(first))
            guard firstWords.count >= 6 else { continue }
            for twin in caps.dropFirst() {
                let w = words(DOM.text(twin))
                let shared = Double(firstWords.intersection(w).count) / Double(max(1, min(firstWords.count, w.count)))
                guard shared >= 0.7 else { continue }
                for p in DOM.select(twin, "p") where DOM.isConnected(p) {
                    let pw = words(DOM.text(p))
                    if pw.count >= 6, Double(firstWords.intersection(pw).count) / Double(pw.count) >= 0.7 { DOM.remove(p) }
                }
                for child in twin.getChildNodes() { _ = try? first.appendChild(child) }
                DOM.remove(twin)
            }
        }
    }

    /// A picture with no address (a `data:` placeholder the sanitizer would strip, nothing in a lazy attribute) draws as
    /// an empty bordered box: NY Post's player overlay, USA Today's gallery thumbnail.
    static func sourcelessImages(_ root: Element) {
        for img in DOM.select(root, "img") where DOM.isConnected(img) {
            guard isPlaceholderSrc(DOM.attr(img, "src")), DOM.attr(img, "srcset") == nil, firstAttr(img, lazySrc + lazySrcset) == nil,
                  DOM.attr(img, "alt") == nil, DOM.closest(img, "noscript, picture") == nil else { continue }
            removeWithEmptyWrappers(img, stop: root)
        }
    }

    // MARK: Podcast audio

    /// An `<audio data-role=podcast>` in the page (Quanta's episode pages: the player sits in an aside Readability
    /// drops, the transcript is the story) is the episode: its file leads the content as `SiteAudio` marks it.
    static func podcastAudio(_ document: Element) -> SiteAudio.Audio? {
        for audio in DOM.select(document, "audio[data-role=podcast]") {
            let src = DOM.attr(audio, "src") ?? DOM.first(audio, "source[src]").flatMap { DOM.attr($0, "src") }
            if let src, src.lowercased().hasPrefix("http") { return SiteAudio.Audio(url: src, duration: nil) }
        }
        return nil
    }
}

extension EmbeddedPosts {
    /// The syndication endpoint's text carries HTML entities of its own (`&amp;`, `&gt;`), once.
    static func decodedEntities(_ s: String) -> String {
        entity.replacing(s) { g in
            switch g[1] {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            default: return "'"
            }
        }
    }

    private static let entity = ExtractionDOM.Pattern("&(amp|lt|gt|quot|#39|#x27);")

    /// The post a post quotes, as the reader shows a quoted post (`.x-quote`): author, text, photos, a link to it.
    static func quotedHTML(_ quoted: [String: Any]?) -> String {
        guard let q = quoted, let u = q["user"] as? [String: Any], let name = u["name"] as? String,
              let handle = u["screen_name"] as? String, let text = q["text"] as? String else { return "" }
        var links: T.Links = [:]
        for l in ((q["entities"] as? [String: Any])?["urls"] as? [[String: Any]]) ?? [] {
            if let url = l["url"] as? String, let display = l["display_url"] as? String, let expanded = l["expanded_url"] as? String {
                links[url] = (display, expanded)
            }
        }
        let media = mediaItems(q["mediaDetails"] as? [[String: Any]] ?? [])
        let body = T.bodyHTML(T.withoutMediaLinks(decodedEntities(text), links: links), links: links)
        guard !media.isEmpty || !body.isEmpty else { return "" }
        let avatar = (u["profile_image_url_https"] as? String).map { $0.replacingOccurrences(of: "_normal.", with: "_bigger.") }
        let date = (q["created_at"] as? String).flatMap(ISO8601.date(from:)).map(T.dateLine)
        let href = (q["id_str"] as? String).map { "https://x.com/\(handle)/status/\($0)" } ?? "https://x.com/\(handle)"
        return "<div class=\"x-quote\">\(T.whoHTML(T.User(name: name, handle: handle, avatar: avatar), date: date))\(body)\(T.mediaHTML(media))<a class=\"x-quote-link\" href=\"\(ExtractionDOM.escapeAttr(href))\">View post</a></div>"
    }
}
