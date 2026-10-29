import Foundation
import SwiftSoup

/// Embeds that arrive as something other than an iframe or a blockquote: charts drawn by a script (Datawrapper), charts
/// whose iframe sits in the page's data (CNBC), click-to-play facades with the player in a <template> (Vice), videos
/// the page's script mounts (CNBC, MLB), and Substack's own tweet and post cards. `embeds` runs in `prepare`, while the
/// page's scripts and classes are intact; `protectEmbeds` runs with `protectMedia`, because Readability drops every
/// iframe that isn't a video player and a card that is all link.
extension ArticlePasses {
    /// Chart hosts the reader draws: their pages are self-contained and script-free on our side.
    static let chartHosts: Set<String> = ["datawrapper.dwcdn.net", "flo.uri.sh", "public.flourish.studio"]
    static let defaultChartHeight = 450
    private static let minChartHeight = 120.0

    static func embeds(_ root: Element, pageURL: String) {
        substackEmbeds(root)
        templateVideos(root)
        datawrapperContainers(root)
        chartFrames(root)
        cnbcEmbeds(root)
        mlbVideos(root)
        scriptDocumentFrames(root, pageURL: pageURL)
    }

    static func isChartFrame(_ el: Element) -> Bool {
        guard DOM.tag(el) == "iframe", let src = DOM.attr(el, "src"), let host = DOM.hostname(src) else { return false }
        return chartHosts.contains(host.lowercased())
    }

    /// Stand chart frames and link cards in as placeholders while Readability runs (see `protectMedia`).
    static func protectEmbeds(_ root: Element, saved: inout [String]) {
        for el in DOM.select(root, "iframe[src], a.x-card") where DOM.isConnected(el) {
            let isFrame = DOM.tag(el) == "iframe"
            guard isFrame ? isChartFrame(el) : DOM.closest(el, ".x-post") == nil,
                  let img = DOM.createElement("img", near: el) else { continue }
            DOM.setAttr(img, "src", "\(placeholder)\(saved.count)")
            DOM.setAttr(img, "alt", "")
            let html = DOM.outerHTML(el)
            let inFigure = el.parent().map { DOM.tag($0) == "figure" } ?? false
            saved.append(isFrame && !inFigure ? "<figure>\(html)</figure>" : html)
            DOM.replace(el, with: img)
        }
    }

    // MARK: Chart frames

    /// A chart's frame gets a height: the page's script resized it as the chart reported its size, and the reader's
    /// 16:9 box would cut a tall table (or leave a short one floating).
    static func chartFrames(_ root: Element) {
        for frame in DOM.select(root, "iframe[src]") where isChartFrame(frame) {
            let declared = DOM.jsNumber(DOM.attr(frame, "height"))
            DOM.setAttr(frame, "height", String(declared >= minChartHeight ? Int(declared) : defaultChartHeight))
        }
    }

    private static let datawrapperID = P("^datawrapper-vis-([A-Za-z0-9]+)$")
    private static let minHeight = P("min-height\\s*:\\s*(\\d+)px", caseInsensitive: true)

    /// Datawrapper's embed script fills `<div id="datawrapper-vis-ID" style="min-height:423px">` (Business Insider, which
    /// ships no iframe): the chart's own page is the iframe.
    static func datawrapperContainers(_ root: Element) {
        for box in DOM.select(root, "div[id^=datawrapper-vis-]") where DOM.isConnected(box) && DOM.first(box, "iframe") == nil {
            guard let id = datawrapperID.firstMatch(DOM.attr(box, "id") ?? "")?[1] else { continue }
            let height = minHeight.firstMatch(DOM.attr(box, "style") ?? "")?[1] ?? nil
            // Its <noscript> still image and the wrapper's script go with it.
            let wrapper = box.parent().flatMap { DOM.matches($0, ".vendor-datawrapper, [data-component-type=vendor-datawrapper]") ? $0 : nil }
            let frame = "<iframe src=\"https://datawrapper.dwcdn.net/\(id)/\" height=\"\(height ?? String(defaultChartHeight))\"></iframe>"
            DOM.replace(wrapper ?? box, withHTML: frame)
        }
    }

    // MARK: Interactive documents

    /// An iframe that carries its page in `srcdoc` (Liquid AI's charts: 14 documents of 140 KB to 1.3 MB each, with
    /// their fonts and scripts inline, and no size but a fixed height) is not kept: it would run the article's own script
    /// and put megabytes in every cached copy. Its place says so, as a figure the page draws client-side does.
    static func scriptDocumentFrames(_ root: Element, pageURL: String) {
        let page = pageURL.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? pageURL
        for frame in DOM.select(root, "iframe[srcdoc]") where DOM.isConnected(frame) && (DOM.attr(frame, "src") ?? "").isEmpty {
            let title = DOM.squash(DOM.attr(frame, "title"))
            let name = title.isEmpty ? "" : " \u{201C}\(DOM.escapeHTML(title))\u{201D}"
            DOM.replace(frame, withHTML: "<p><em>Interactive figure\(name) not shown here. View it in the <a href=\"\(DOM.escapeAttr(page))\">original article</a>.</em></p>")
        }
    }

    // MARK: Click-to-play facades

    private static let playerHost = P("^(?:www\\.|m\\.)?youtube(?:-nocookie)?\\.com$|^player\\.vimeo\\.com$", caseInsensitive: true)

    /// A thumbnail and a play button whose real player waits in a <template> (Vice's `youtube-placeholder`, which also
    /// repeats it in a <noscript>): the player replaces the facade, as a plain embed that doesn't start itself.
    static func templateVideos(_ root: Element) {
        for template in DOM.select(root, "template") where DOM.isConnected(template) {
            guard let frame = DOM.select(template, "iframe[src]").first(where: { f in
                      DOM.hostname(DOM.attr(f, "src") ?? "").map { playerHost.test($0) } ?? false
                  }), let src = DOM.attr(frame, "src") else { continue }
            // The facade is the template's parent when that holds only a thumbnail, a button and the player.
            var facade: Element = template
            if let parent = template.parent(), !DOM.isTag(parent, ["body", "html", "article", "main"]), !(parent is Document),
               DOM.first(parent, "p, h1, h2, h3, h4, h5, h6, li, blockquote") == nil,
               DOM.first(parent, "button, picture, img") != nil { facade = parent }
            // The page's own size is the facade's (a 4:3 box for a 16:9 video); the reader sets its own.
            let title = DOM.attr(frame, "title").map { " title=\"\(DOM.escapeAttr($0))\"" } ?? ""
            let embed = ArticleSanitizer.embedSrc(src, watchable: true)
            DOM.replace(facade, withHTML: "<figure><iframe src=\"\(DOM.escapeAttr(embed))\"\(title) allow=\"fullscreen; picture-in-picture\" allowfullscreen></iframe></figure>")
        }
    }

    // MARK: Substack

    /// Substack's own tweet embed (`div.twitter-embed`, its data in `data-attrs`) becomes the blockquote Twitter's
    /// widget leaves, which `EmbeddedPosts` draws as an X card. Its post embed (`div.embedded-post-wrap`) is a link card.
    static func substackEmbeds(_ root: Element) {
        for el in DOM.select(root, ".twitter-embed[data-attrs]") where DOM.isConnected(el) {
            guard let json = attrsJSON(el), let url = json["url"] as? String, EmbeddedPosts.post(at: url) != nil,
                  let text = json["full_text"] as? String else { continue }
            let name = (json["name"] as? String) ?? ""
            let handle = (json["username"] as? String).map { "@\($0)" } ?? ""
            let when = (json["date"] as? String).flatMap(ISO8601.date(from:)).map { TweetExtraction.stampLine($0) } ?? "link"
            let who = [name, handle.isEmpty ? "" : "(\(handle))"].filter { !$0.isEmpty }.joined(separator: " ")
            let body = unescapedEntities(text).components(separatedBy: "\n\n").filter { !$0.isEmpty }
                .map { "<p>\(DOM.escapeHTML($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }.joined()
            DOM.replace(el, withHTML: "<blockquote>\(body)<p>\u{2014} \(DOM.escapeHTML(who)) <a href=\"\(DOM.escapeAttr(url))\">\(DOM.escapeHTML(when))</a></p></blockquote>")
        }
        for el in DOM.select(root, ".embedded-post-wrap[data-attrs]") where DOM.isConnected(el) {
            guard let json = attrsJSON(el), let url = json["url"] as? String, let title = json["title"] as? String, !title.isEmpty else { continue }
            let publication = json["publication_name"] as? String
            DOM.replace(el, withHTML: TweetExtraction.cardHTML(href: url, title: title, domain: publication, image: json["publication_logo_url"] as? String))
        }
    }

    private static func attrsJSON(_ el: Element) -> [String: Any]? {
        guard let data = DOM.attr(el, "data-attrs")?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A tweet's text carries HTML entities of its own (`&gt;`, `&amp;`).
    private static func unescapedEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Page data

    /// The JSON object that follows `marker` in one of the page's scripts.
    private static func scriptObject(after marker: String, in root: Element) -> Any? {
        for script in DOM.select(root, "script") {
            guard case let code = script.data(), let r = code.range(of: marker) else { continue }
            let bytes = Array(code[r.upperBound...].utf8)
            let end = ExtractionPayload.balancedEnd(bytes, 0)
            guard end > 0, let value = try? JSONSerialization.jsonObject(with: Data(bytes[0..<end])) else { continue }
            return value
        }
        return nil
    }

    // MARK: CNBC

    /// CNBC's body is in `window.__s_data`; the page draws charts (a "wildcard" holding the Datawrapper iframe) and
    /// videos with its script, leaving `div.lazyload-placeholder` and a thumbnail with "watch now". The charts go
    /// into their placeholders, found by the paragraph beside them; each video becomes the player with its mp4.
    static func cnbcEmbeds(_ root: Element) {
        guard DOM.first(root, ".lazyload-placeholder, .PlaceHolder-wrapper") != nil,
              let state = scriptObject(after: "window.__s_data=", in: root) else { return }
        var videos: [String: [String: Any]] = [:]
        var wildcards: [(frame: Element, before: String?, after: String?)] = []
        func walk(_ node: Any) {
            if let list = node as? [Any] {
                let items = list.compactMap { $0 as? [String: Any] }
                for (i, item) in items.enumerated() where ((item["data"] as? [String: Any])?["__typename"] as? String) == "wildcard" {
                    guard let cdata = firstString(forKey: "cdata", in: item),
                          let frame = DOM.withFragment(cdata, { body in DOM.first(body, "iframe[src]").map { (DOM.attr($0, "src") ?? "", DOM.attr($0, "height") ?? "", DOM.attr($0, "title") ?? "") } }) ?? nil,
                          let host = DOM.hostname(frame.0), chartHosts.contains(host.lowercased()),
                          let el = DOM.createElement("iframe", near: root) else { continue }
                    DOM.setAttr(el, "src", frame.0)
                    DOM.setAttr(el, "height", frame.1)
                    if !frame.2.isEmpty { DOM.setAttr(el, "title", frame.2) }
                    wildcards.append((el, i > 0 ? paragraphTexts(items[i - 1]).last : nil, i + 1 < items.count ? paragraphTexts(items[i + 1]).first : nil))
                }
                for x in list { walk(x) }
            } else if let dict = node as? [String: Any] {
                if dict["tagName"] as? String == "cnbcvideo", let attrs = dict["attributes"] as? [String: Any], let id = attrs["vcpsId"] {
                    videos["\(id)"] = (dict["data"] as? [String: Any] ?? [:]).merging(attrs) { a, _ in a }
                }
                for x in dict.values { walk(x) }
            }
        }
        walk(state)
        for w in wildcards {
            guard let slot = chartSlot(in: root, before: w.before, after: w.after) else { continue }
            DOM.replace(slot, with: w.frame)
        }
        for card in DOM.select(root, ".PlaceHolder-wrapper[data-vilynx-id]") where DOM.isConnected(card) {
            guard let data = videos[DOM.attr(card, "data-vilynx-id") ?? ""] else { continue }
            let poster = DOM.first(card, "img[src]").flatMap { DOM.attr($0, "src") }
            let title = (data["title"] as? String) ?? (data["headline"] as? String) ?? ""
            let caption = title.isEmpty ? "" : "<figcaption>\(DOM.escapeHTML(title))</figcaption>"
            let box = card.parent().flatMap { DOM.attr($0, "role") == "region" && DOM.children($0).count == 1 ? $0 : nil } ?? card
            if let mp4 = cnbcMP4(data["encodings"]) {
                let posterAttr = poster.map { " poster=\"\(DOM.escapeAttr($0))\"" } ?? ""
                DOM.replace(box, withHTML: "<figure><video src=\"\(DOM.escapeAttr(mp4))\"\(posterAttr) controls></video>\(caption)</figure>")
            } else if let page = data["url"] as? String, let poster {
                DOM.replace(box, withHTML: "<figure><a href=\"\(DOM.escapeAttr(page))\"><img src=\"\(DOM.escapeAttr(poster))\" alt=\"\(DOM.escapeAttr(title))\"></a>\(caption)</figure>")
            }
        }
    }

    private static let cnbcBitrate = P("^mpeg4_(\\d+)_Download$")
    /// The mp4 of about 1 Mbit/s (720x405): a column has no use for the 4.5 Mbit/s one.
    private static func cnbcMP4(_ encodings: Any?) -> String? {
        let files = (encodings as? [[String: Any]] ?? []).compactMap { e -> (url: String, rate: Int)? in
            guard let url = e["url"] as? String, url.hasSuffix(".mp4"), let name = e["formatName"] as? String,
                  let rate = cnbcBitrate.firstMatch(name)?[1].flatMap({ Int($0) }) else { return nil }
            return (url, rate)
        }
        let fitting = files.filter { $0.rate <= 1_100_000 }
        return (fitting.max { $0.rate < $1.rate } ?? files.min { $0.rate < $1.rate })?.url
    }

    private static func firstString(forKey key: String, in node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let s = dict[key] as? String { return s }
            for v in dict.values { if let s = firstString(forKey: key, in: v) { return s } }
        } else if let list = node as? [Any] {
            for v in list { if let s = firstString(forKey: key, in: v) { return s } }
        }
        return nil
    }

    /// Texts of the paragraphs and headings under a content item, in order.
    private static func paragraphTexts(_ node: Any) -> [String] {
        func flatten(_ n: Any) -> String {
            if let s = n as? String { return s }
            if let list = n as? [Any] { return list.map(flatten).joined() }
            if let dict = n as? [String: Any] { return flatten(dict["children"] ?? []) }
            return ""
        }
        if let dict = node as? [String: Any] {
            if let tag = dict["tagName"] as? String, ["p", "subtitle", "h2", "h3", "li"].contains(tag) {
                let t = DOM.norm(flatten(dict))
                return t.isEmpty ? [] : [t]
            }
            return paragraphTexts(dict["children"] ?? [])
        }
        if let list = node as? [Any] { return list.flatMap(paragraphTexts) }
        return []
    }

    /// The empty `lazyload-placeholder` right after the paragraph that `before` quotes or right before the one `after`
    /// quotes (compared by their first 40 characters).
    private static func chartSlot(in root: Element, before: String?, after: String?) -> Element? {
        let blocks = DOM.select(root, "p, h2, h3, li")
        func find(_ text: String?, last: Bool) -> Element? {
            guard let key = text.map({ String($0.prefix(40)) }), key.count >= 12 else { return nil }
            let hits = blocks.filter { DOM.norm(DOM.text($0)).hasPrefix(key) }
            return last ? hits.last : hits.first
        }
        let slot = ".lazyload-placeholder"
        if let p = find(before, last: true) {
            var el: Element = p
            for _ in 0..<4 {
                if let next = try? el.nextElementSibling(), DOM.matches(next, slot) { return next }
                guard let parent = el.parent(), (try? el.nextElementSibling()) == nil else { break }
                el = parent
            }
        }
        if let p = find(after, last: false) {
            var el: Element = p
            for _ in 0..<4 {
                if let prev = try? el.previousElementSibling(), DOM.matches(prev, slot) { return prev }
                guard let parent = el.parent(), (try? el.previousElementSibling()) == nil else { break }
                el = parent
            }
        }
        return nil
    }

    // MARK: MLB

    private static let mlbVideo = P(#""preferredPlaybackScenarioURL\(.{0,80}?\)":"(https://[^"]+?\.mp4)""#)
    private static let mlbSlug = P(#""slug":"([^"]+)""#)
    private static let mlbThumb = P(#""templateUrl":"([^"]*\{formatInstructions\}[^"]*)""#)
    private static let mlbTitle = P(#""title":("(?:[^"\\]|\\.)*"),"relativeSiteUrl""#)

    /// MLB's story videos are empty `#media-<slug>-wrapper` boxes its script fills; the page's data (an Apollo cache in
    /// a script) has each clip's mp4 and thumbnail. The box becomes the clip.
    static func mlbVideos(_ root: Element) {
        let boxes = DOM.select(root, "div[id^=media-][id$=-wrapper]").filter { DOM.isConnected($0) && DOM.first($0, "video, iframe") == nil }
        guard !boxes.isEmpty,
              let code = DOM.select(root, "script").lazy.map({ $0.data() }).first(where: { $0.contains("preferredPlaybackScenarioURL") })
        else { return }
        // A clip's fields follow its mp4 address, up to the next clip's: slug, then thumbnail, then title.
        let ns = code as NSString
        var clips: [String: (mp4: String, thumb: String?, title: String?)] = [:]
        var offset = 0
        while let hit = mlbVideo.firstMatchWithRange(code, from: offset), let mp4 = hit.groups[1] {
            offset = hit.range.location + hit.range.length
            var tail = ns.substring(with: NSRange(location: offset, length: min(8000, ns.length - offset)))
            if let next = tail.range(of: "preferredPlaybackScenarioURL") { tail = String(tail[..<next.lowerBound]) }
            guard let slug = mlbSlug.firstMatch(tail)?[1], clips[slug] == nil else { continue }
            let thumb = mlbThumb.firstMatch(tail)?[1].map { $0.replacingOccurrences(of: "{formatInstructions}", with: "c_fill,w_1280,h_720,f_jpg,q_auto") + ".jpg" }
            clips[slug] = (mp4, thumb, mlbTitle.firstMatch(tail)?[1].flatMap { ExtractionPayload.jsonString($0) })
        }
        for box in boxes {
            let id = DOM.attr(box, "id") ?? ""
            guard let clip = clips[String(id.dropFirst("media-".count).dropLast("-wrapper".count))] else { continue }
            let poster = clip.thumb.map { " poster=\"\(DOM.escapeAttr($0))\"" } ?? ""
            let caption = clip.title.map { "<figcaption>\(DOM.escapeHTML($0))</figcaption>" } ?? ""
            DOM.replace(box, withHTML: "<figure><video src=\"\(DOM.escapeAttr(clip.mp4))\"\(poster) controls></video>\(caption)</figure>")
        }
    }
}
