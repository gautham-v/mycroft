import Foundation
import SwiftSoup

/// Figures that our own passes, or Readability, lose although the page has them: pictures behind a zoom button, images
/// whose class says "share", captions with a source link, pictures whose address only the page's data has, and players
/// the page's script mounts.
extension ArticlePasses {
    // MARK: unwrapZoomButtons

    /// A picture inside a lightbox trigger (The Conversation's `<a role="button" aria-haspopup="dialog">` around a
    /// figure's image) is not page chrome, but removeInterface drops every short "button" with the trigger. The
    /// trigger goes, the picture stays. (A real <button> may hold a play overlay, so only role=button links and boxes.)
    static func unwrapZoomButtons(_ root: Element) {
        for el in DOM.select(root, "a[role=button], div[role=button], span[role=button]") where DOM.isConnected(el) {
            guard DOM.matches(el, "[aria-haspopup], [aria-expanded]"), DOM.text(el).count <= maxButtonText,
                  DOM.select(el, "img").contains(where: isContentImage) else { continue }
            _ = try? el.unwrap()
        }
    }

    private static func isContentImage(_ img: Element) -> Bool {
        guard !isTinyImg(img), !isLogo(img), !isPlaceholderSrc(DOM.attr(img, "src")) || DOM.attr(img, "srcset") != nil else { return false }
        return URL(string: DOM.attr(img, "src") ?? "")?.pathExtension.lowercased() != "svg"
    }

    // MARK: restoreFigures

    /// Run before markClientRenderedFigures, which would otherwise call a figure whose picture arrives late an
    /// interactive one.
    static func restoreFigures(_ root: Element) {
        imagesFromImageLinks(root)
        dropShareClassFromImages(root)
        neutralizeFigureWrappers(root)
        substackVideos(root)
        embedSlotsFromPageData(root)
        eonlineGalleryImages(root)
    }

    // MARK: imagesFromImageLinks

    private static let imageFile = P("\\.(?:jpe?g|png|webp|gif|avif)(?:[?#]|$)", caseInsensitive: true)

    /// An <img> that is only a 1x1 placeholder, in a link to the picture itself (IGN's `progressive-image` inside
    /// `<a href=…webp>`): the link is the only address the page has, and Readability deletes the placeholder.
    static func imagesFromImageLinks(_ root: Element) {
        for img in DOM.select(root, "a[href] > img") {
            guard isPlaceholderSrc(DOM.attr(img, "src")), firstAttr(img, lazySrc) == nil, firstAttr(img, lazySrcset) == nil,
                  (DOM.attr(img, "srcset") ?? "").isEmpty, let a = img.parent(),
                  let href = DOM.attr(a, "href"), imageFile.test(href) else { continue }
            DOM.setAttr(img, "src", href)
            DOM.removeAttr(img, "aria-hidden")
        }
    }

    // MARK: dropShareClassFromImages

    private static let shareToken = P("(?:\\b|_)(?:share|sharedaddy)(?:\\b|_)", caseInsensitive: true)
    private static let pictureWord = P("img|image|photo|pic|thumb|media", caseInsensitive: true)

    /// Readability deletes any short element whose class says "share" (a row of share buttons), a picture too: the
    /// Daily Mail's `img-share` marks pictures that open the share dialog, and all its photos went.
    static func dropShareClassFromImages(_ root: Element) {
        for img in DOM.select(root, "img, picture") where !isTinyImg(img) && !isLogo(img) {
            dropClassTokens(img) { shareToken.test($0) && pictureWord.test($0) }
        }
    }

    // MARK: neutralizeFigureWrappers

    private static let wrapperNegative = P("media|meta|header|extra|masthead|legends|remark|cover-wrap|scroll", caseInsensitive: true)

    /// The boxes around a figure that hold nothing but its picture and caption (NASA's `hds-media` around
    /// `hds-cover-wrapper`): their layout words ("media", "cover-wrap") give them a negative score, and Readability
    /// deletes the box with the figure. neutralizeReadabilityClasses only clears boxes without a caption.
    static func neutralizeFigureWrappers(_ root: Element) {
        let stop: Set<String> = ["body", "html", "main", "article"]
        func bare(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        for fig in DOM.select(root, "figure") where DOM.first(fig, "img, picture") != nil {
            var node: Element? = fig
            var depth = 0
            while let el = node, !DOM.isTag(el, stop), depth < 6 {
                let caption = DOM.select(el, "figcaption").map { DOM.text($0) }.joined()
                guard bare(DOM.text(el)) == bare(caption) else { break }
                dropClassTokens(el) { $0 != "hidden" && wrapperNegative.test($0) }
                node = el.parent()
                depth += 1
            }
        }
    }

    // MARK: protectFigures

    /// Readability keeps only the iframes of a few video sites (YouTube, Vimeo, Dailymotion, ...) and deletes the rest.
    private static let readabilityVideoHost = P("^(?:www\\.)?(?:dailymotion|youtube|youtube-nocookie|bilibili)\\.com$|^player\\.vimeo\\.com$|^player\\.twitch\\.tv$", caseInsensitive: true)

    /// Stand-ins, as protectMedia makes for videos, for what Readability would delete from a figure: (1) a figure with
    /// a linked caption ("Source: <a>Ober et al.</a>") and no other text, which it scores as a link list together with the box around
    /// it, and the chart goes; (2) an iframe the sanitizer allows but Readability's video list does not (Tidal's
    /// player).
    static func protectFigures(_ root: Element, _ saved: inout [String]) {
        func stand(in el: Element) {
            guard el.parent() != nil, let img = DOM.createElement("img", near: el) else { return }
            DOM.setAttr(img, "src", "\(placeholder)\(saved.count)")
            DOM.setAttr(img, "alt", "")
            saved.append(DOM.outerHTML(el))
            DOM.replace(el, with: img)
        }
        for fig in DOM.select(root, "figure") where DOM.isConnected(fig) {
            guard DOM.first(fig, "img, picture") != nil, DOM.first(fig, "figcaption a[href]") != nil,
                  // Only a picture and its caption: some pages wrap the whole article header in a <figure>.
                  DOM.text(fig).filter({ !$0.isWhitespace }) == DOM.select(fig, "figcaption").map({ DOM.text($0) }).joined().filter({ !$0.isWhitespace })
            else { continue }
            stand(in: fig)
        }
        for frame in DOM.select(root, "iframe[src]") where DOM.isConnected(frame) {
            guard let host = URL(string: DOM.attr(frame, "src") ?? "")?.host(percentEncoded: false),
                  ArticleSanitizer.allowedIframeHosts.contains(host), !readabilityVideoHost.test(host) else { continue }
            stand(in: frame)
        }
    }

    // MARK: substackVideos

    private static let substackUpload = P("\"mediaUploadId\"\\s*:\\s*\"([\\w-]+)\"")

    /// A video uploaded to Substack is an empty box in the page (its player mounts in the browser), or an empty
    /// `native-video-embed` whose data-attrs name the upload. The upload's address redirects to the stream.
    static func substackVideos(_ root: Element) {
        for el in DOM.select(root, "[data-component-name=VideoEmbedPlayer][data-media-upload-id], [data-component-name=VideoPlaceholder][data-attrs]") where DOM.isConnected(el) {
            guard DOM.first(el, "video, iframe, source") == nil else { continue }
            let id = DOM.attr(el, "data-media-upload-id") ?? substackUpload.firstMatch(DOM.attr(el, "data-attrs") ?? "")?[1] ?? nil
            guard let id, !id.isEmpty, let video = DOM.createElement("video", near: el) else { continue }
            DOM.setAttr(video, "src", "https://substack.com/api/v1/video/upload/\(DOM.encodeURIComponent(id))/src?type=mp4")
            DOM.setAttr(video, "controls", "")
            DOM.setAttr(video, "preload", "metadata")
            DOM.replace(el, with: video)
        }
    }

    // MARK: embedSlotsFromPageData

    private static let inlineEmbed = P("\\[\"inline-embed\",\\{\"props\":\\{([^{}]*)\\}[^\\[\\]]*?\"type\":\"(?:iframe|video)\"\\}\\]")
    private static let propURL = P("\"url\":(\"(?:[^\"\\\\]|\\\\.)*\")")
    private static let propSize = P("\"(width|height)\":\"(\\d+)\"")

    /// Condé Nast sites (Pitchfork, Wired, The New Yorker) leave a `figure[data-testid=IframeEmbed]` empty in the page
    /// and mount the iframe in the browser; the embeds are listed, in page order, in the article's data
    /// (`["inline-embed",{"props":{"url":…},"type":"iframe"|"video"}]`). Filled only when the page has as many empty
    /// slots as the data has embeds, so an order that cannot be matched stays unfilled.
    static func embedSlotsFromPageData(_ root: Element) {
        let slots = DOM.select(root, "figure[data-testid=IframeEmbed]").filter { DOM.first($0, "iframe, video, img") == nil && DOM.text($0).isEmpty }
        guard !slots.isEmpty else { return }
        var embeds: [(src: String, width: String?, height: String?)] = []
        for script in DOM.select(root, "script") {
            let data = script.data()
            guard data.contains("\"inline-embed\"") else { continue }
            for m in inlineEmbed.allMatches(data) {
                guard let props = m[1], let raw = propURL.firstMatch(props)?[1], let url = ExtractionPayload.jsonString(raw),
                      url.hasPrefix("http") else { continue }
                var size: [String: String] = [:]
                for s in propSize.allMatches(props) { if let k = s[1], let v = s[2] { size[k] = v } }
                embeds.append((url, size["width"], size["height"]))
            }
            if !embeds.isEmpty { break }
        }
        guard embeds.count == slots.count else { return }
        for (slot, embed) in zip(slots, embeds) {
            guard let iframe = DOM.createElement("iframe", near: slot) else { continue }
            DOM.setAttr(iframe, "src", ArticleSanitizer.embedSrc(embed.src, watchable: true))
            DOM.setAttr(iframe, "allow", "fullscreen; picture-in-picture")
            DOM.setAttr(iframe, "allowfullscreen", "")
            if let w = embed.width, let h = embed.height { DOM.setAttr(iframe, "width", w); DOM.setAttr(iframe, "height", h) }
            _ = slot.empty()
            _ = try? slot.appendChild(iframe)
        }
    }

    // MARK: eonlineGalleryImages

    private static let apolloMarker = "window.__APOLLO_STATE__="

    /// E! Online (site-specific): a photo gallery's slides and an article's own photos are empty `span.thumb` boxes in
    /// the page; the pictures are in its Apollo state. A slide is matched to its `GalleryItem` by title, and a photo
    /// that is no slide by its credit (`agency`). The credit moves from beside the picture into the caption.
    static func eonlineGalleryImages(_ root: Element) {
        let slides = DOM.select(root, "figure[data-testid=adp-vgallery-item]")
        let loose = DOM.select(root, ".article-detail__image-wrap").filter { DOM.closest($0, "figure[data-testid=adp-vgallery-item]") == nil }
        guard !(slides.isEmpty && loose.isEmpty), let state = apolloState(root) else { return }
        func image(_ ref: Any?) -> (uri: String, agency: String?)? {
            guard let key = (ref as? [String: Any])?["__ref"] as? String, let node = state[key] as? [String: Any],
                  let uri = node["uri"] as? String, uri.hasPrefix("http") else { return nil }
            return (uri, node["agency"] as? String)
        }
        func text(_ html: Any?) -> String {
            guard let html = html as? String else { return "" }
            return DOM.norm(DOM.withFragment(html) { DOM.text($0) })
        }
        var byTitle: [String: String] = [:]
        var used: Set<String> = []
        for (_, value) in state {
            guard let gallery = value as? [String: Any] else { continue }
            for (k, v) in gallery where k.hasPrefix("galleryitems") {
                for node in (v as? [String: Any])?["nodes"] as? [[String: Any]] ?? [] {
                    guard let img = image(node.first(where: { $0.key.hasPrefix("image") })?.value) else { continue }
                    let title = text(node["title"])
                    if !title.isEmpty, byTitle[title] == nil { byTitle[title] = img.uri }
                    used.insert(img.uri)
                }
            }
        }
        var byAgency: [String: [String]] = [:]
        for key in state.keys where key.hasPrefix("Image:") {
            guard let img = image(["__ref": key]), let agency = img.agency, !used.contains(img.uri) else { continue }
            byAgency[DOM.norm(agency), default: []].append(img.uri)
        }
        func put(_ img: String, alt: String, into wrap: Element) {
            guard let thumb = DOM.first(wrap, "span.thumb"), let el = DOM.createElement("img", near: thumb) else { return }
            DOM.setAttr(el, "src", img)
            DOM.setAttr(el, "alt", alt)
            DOM.replace(thumb, with: el)
        }
        for slide in slides {
            guard let wrap = DOM.first(slide, ".article-detail__image-wrap"),
                  let title = DOM.first(slide, "[data-testid=adp-vgallery-title]").map({ DOM.norm(DOM.text($0)) }),
                  let uri = byTitle[title] else { continue }
            put(uri, alt: "", into: wrap)
            // The credit joins the caption; the picture's box and the figure's wrappers go.
            if let credit = DOM.first(wrap, "[data-hook=adp-photo-agency]"), let cap = DOM.first(slide, "figcaption"), !DOM.text(credit).isEmpty {
                _ = try? cap.append("<p>\(DOM.escapeHTML(DOM.text(credit)))</p>")
                DOM.remove(credit)
            }
        }
        for wrap in loose {
            guard let credit = DOM.first(wrap, "[data-hook=adp-photo-agency]").map({ DOM.text($0) }), DOM.first(wrap, "span.thumb") != nil,
                  var candidates = byAgency[DOM.norm(credit)], !candidates.isEmpty else { continue }
            let uri = candidates.removeFirst()
            byAgency[DOM.norm(credit)] = candidates
            DOM.replace(wrap, withHTML: "<figure><img src=\"\(DOM.escapeAttr(uri))\" alt=\"\"><figcaption>\(DOM.escapeHTML(credit))</figcaption></figure>")
        }
    }

    /// The `window.__APOLLO_STATE__= {…}` object of a page, parsed.
    private static func apolloState(_ root: Element) -> [String: Any]? {
        for script in DOM.select(root, "script") {
            let data = script.data()
            guard let r = data.range(of: apolloMarker) ?? data.range(of: "window.__APOLLO_STATE__ ="),
                  let start = data[r.upperBound...].firstIndex(of: "{") else { continue }
            let tail = Array(data[start...].utf8)
            let end = ExtractionPayload.balancedEnd(tail, 0)
            guard end > 0, let obj = (try? JSONSerialization.jsonObject(with: Data(tail[0..<end]))) as? [String: Any] else { continue }
            return obj
        }
        return nil
    }
}
