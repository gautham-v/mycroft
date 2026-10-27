import Foundation
import SwiftSoup

/// A post on LinkedIn, from its public post page (served without a login). The commentary, the author's name
/// and profile link, the video sources or images are in the page's markup and the date in its JSON-LD. Short
/// lnkd.in links are followed to the post. LinkedIn gives logged-out readers no profile picture.
enum LinkedInPost {
    typealias DOM = ExtractionDOM
    typealias Media = SocialPost.Media

    static func load(url: String, fetch: SocialPosts.Fetch) async -> SocialPost? {
        guard let (data, res) = await fetch(url, ["Accept": HTTP.htmlAccept]), (200..<300).contains(res.statusCode) else { return nil }
        let final = res.url?.absoluteString ?? url
        // A short link that led somewhere other than a post.
        guard SocialPosts.linkedinURL.test(final), !final.lowercased().contains("lnkd.in/") else { return nil }
        return parse(html: HTTP.text(data, response: res), pageURL: final)
    }

    /// The address as stored: no tracking query (utm_*, rcm), no fragment.
    static func canonicalURL(_ url: String) -> String {
        guard var c = URLComponents(string: url) else { return url }
        c.query = nil
        c.fragment = nil
        return c.string ?? url
    }

    static func parse(html: String, pageURL: String) -> SocialPost? {
        guard let doc = DOM.parseDocument(html, baseURI: pageURL) else { return nil }
        let meta = PageMeta.meta(in: doc)
        let commentary = DOM.first(doc, "[data-test-id=main-feed-activity-card__commentary]")
        let paragraphs = commentary.map(paragraphs) ?? SocialPost.paragraphs(fromPlain: meta("og:description") ?? "")
        let actor = DOM.first(doc, "[data-test-id=main-feed-activity-card__entity-lockup] a[data-tracking-control-name=public_post_feed-actor-name]")
        let ld = ldPost(doc)
        let name = actor.map { DOM.text($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? creatorName(ld)
        guard let name, !paragraphs.isEmpty || DOM.first(doc, "video[data-sources]") != nil else { return nil }
        let profile = actor.flatMap { DOM.attr($0, "href") }.map(canonicalURL)
        let canonical = canonicalURL(pageURL)
        let avatar = DOM.first(doc, "[data-test-id=main-feed-activity-card__entity-lockup] img").flatMap { img in
            (DOM.attr(img, "data-delayed-url") ?? DOM.attr(img, "src")).flatMap { $0.contains("static.licdn.com") ? nil : $0 }
        }
        var post = SocialPost(
            network: .linkedin, url: canonical,
            author: .init(name: name, handle: handle(profile: profile, postURL: canonical), avatar: avatar, profile: profile),
            paragraphs: paragraphs, date: PageMeta.toDate(ScrapingText.str(ld?["datePublished"])))
        post.media = media(doc, meta: meta)
        return post
    }

    // MARK: Parts

    /// The account's slug: `gautham-v` in linkedin.com/in/gautham-v, or the start of /posts/gautham-v_title-….
    static func handle(profile: String?, postURL: String) -> String {
        if let p = profile.flatMap({ URLComponents(string: $0)?.path.split(separator: "/") }), p.count >= 2 { return String(p[1]) }
        let slug = URLComponents(string: postURL)?.path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
        return slug.split(separator: "_", maxSplits: 1).first.map(String.init) ?? "linkedin"
    }

    /// The post's JSON-LD node (a VideoObject, or a SocialMediaPosting for others), not the comments inside it.
    private static func ldPost(_ doc: Document) -> [String: Any]? {
        for s in DOM.select(doc, "script[type=application/ld+json]") {
            guard let data = (try? s.data())?.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let nodes = (json as? [[String: Any]]) ?? (json as? [String: Any]).map { [$0] } ?? []
            if let node = nodes.first(where: { $0["datePublished"] != nil }) { return node }
        }
        return nil
    }

    private static func creatorName(_ ld: [String: Any]?) -> String? {
        let c = (ld?["creator"] ?? ld?["author"]) as? [String: Any]
        return ScrapingText.str(c?["name"])
    }

    /// Commentary text (plain, with its links) as paragraphs. `linkedin.com/redir/redirect?url=` wrappers are
    /// opened to their targets; hashtags (which LinkedIn links to its sign-up page) point at LinkedIn's hashtag page.
    private static func paragraphs(_ el: Element) -> [String] {
        var html = ""
        for node in el.getChildNodes() {
            if let t = node as? TextNode {
                html += DOM.escapeHTML(t.getWholeText())
            } else if let e = node as? Element {
                let text = DOM.rawText(e)
                if DOM.tag(e) == "br" { html += "\n" }
                else if DOM.tag(e) == "a", let href = linkTarget(DOM.attr(e, "href"), text: text) {
                    html += "<a href=\"\(DOM.escapeAttr(href))\">\(DOM.escapeHTML(text))</a>"
                } else { html += DOM.escapeHTML(text) }
            }
        }
        return SocialPost.paragraphs(fromInline: html)
    }

    /// Where a link in the commentary goes, or nil to show its text unlinked.
    static func linkTarget(_ href: String?, text: String) -> String? {
        guard let href, let c = URLComponents(string: href), let host = c.host?.lowercased() else { return nil }
        guard host == "linkedin.com" || host.hasSuffix(".linkedin.com") else { return href }
        if c.path == "/redir/redirect" {
            return c.queryItems?.first { $0.name == "url" }?.value.flatMap { URL(string: $0)?.scheme?.hasPrefix("http") == true ? $0 : nil }
        }
        if c.path.hasPrefix("/signup") || c.path.hasPrefix("/uas/") || c.path.contains("hashtag") {
            guard text.hasPrefix("#") else { return nil }
            return "https://www.linkedin.com/feed/hashtag/?keywords=\(DOM.encodeURIComponent(String(text.dropFirst())))"
        }
        var clean = c
        clean.query = nil
        return clean.string
    }

    /// The post's video (the best of its MP4 sources, with its cover) or photos. A post with neither, but a share
    /// image (an article's picture), shows that.
    private static func media(_ doc: Document, meta: PageMeta.Reader) -> [Media] {
        if let v = DOM.first(doc, "video[data-sources]"),
           let sources = (DOM.attr(v, "data-sources")?.data(using: .utf8)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [[String: Any]] {
            let best = sources.filter { ($0["type"] as? String) == "video/mp4" }
                .max { ($0["data-bitrate"] as? Int ?? 0) < ($1["data-bitrate"] as? Int ?? 0) }
            if let url = best?["src"] as? String {
                var width: Int?, height: Int?
                if let r = DOM.attr(v, "data-aspect-ratio").flatMap({ Double($0) }), r > 0 { width = Int((r * 720).rounded()); height = 720 }
                return [Media(kind: .video, url: url, poster: DOM.attr(v, "data-poster-url"), width: width, height: height)]
            }
        }
        let photos = DOM.select(doc, "[data-test-id=feed-images-content] img").compactMap { img -> Media? in
            guard let src = DOM.attr(img, "data-delayed-url") ?? DOM.attr(img, "src"), !src.contains("static.licdn.com") else { return nil }
            return Media(kind: .photo, url: src, alt: DOM.attr(img, "alt").flatMap { $0 == "Image" ? nil : $0 })
        }
        if !photos.isEmpty { return photos }
        if let og = meta("og:image"), og.contains("media.licdn.com"), !og.contains("profile-displayphoto") {
            return [Media(kind: .photo, url: og)]
        }
        return []
    }
}
