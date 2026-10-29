import Foundation
import SwiftSoup

/// Posts embedded in an article: X, Bluesky, Mastodon, Threads, Instagram, LinkedIn and TikTok. A page carries each
/// network's fallback (a blockquote with the text and a link to the post, or an iframe; `ArticlePasses.normalizeEmbeds`
/// turns every kind into a blockquote ending with the post's address) and the network's script draws the real post.
/// The reader has no script, so each is replaced by the post as the reader shows posts (`.x-post`), set in the article
/// as a card (`.x-embed`): author row with the network's mark, text, photos or video playing in place, and a footer
/// with the date (and for X the likes and replies) and "Open on <network>".
/// - X: its public embed data (the syndication endpoint its widget uses; no account).
/// - Bluesky, Mastodon, Threads, Instagram, LinkedIn: `SocialPosts`, as when such a post is opened on its own.
/// - TikTok: its oEmbed for the author and caption, and its embeddable player for the video.
/// A post that can't be read keeps its blockquote.
public enum EmbeddedPosts {
    private typealias DOM = ExtractionDOM
    typealias T = TweetExtraction

    static let maxPosts = 16
    static let timeout: TimeInterval = 6
    /// A blockquote with more text than this is a quotation that cites a post, not an embed.
    static let maxEmbedText = 1200
    /// The widest video rendition fetched for a card: a 700pt column has no use for 1080p at 10 Mbit/s.
    static let maxVideoWidth = 1280

    public typealias Fetch = @Sendable (_ url: String, _ headers: [String: String]) async -> (Data, HTTPURLResponse)?

    enum Post: Hashable {
        case x(user: String, id: String)
        case social(url: String)
        case tiktok(url: String, id: String)
    }

    static let tiktokURL = ExtractionDOM.Pattern(#"^https?://(?:www\.|m\.)?tiktok\.com/@([^/?#]+)/video/(\d+)"#, caseInsensitive: true)

    /// The post a blockquote embeds: its last link, when that is a post's address.
    static func post(of blockquote: Element) -> Post? {
        guard DOM.textLen(DOM.text(blockquote)) <= maxEmbedText, let link = DOM.select(blockquote, "a[href]").last,
              let href = DOM.attr(link, "href") else { return nil }
        return post(at: href)
    }

    static func post(at href: String) -> Post? {
        if let m = T.tweetURL.firstMatch(href), let user = m[1], let id = m[2] { return .x(user: user, id: id) }
        if let m = tiktokURL.firstMatch(href), let user = m[1], let id = m[2] {
            return .tiktok(url: "https://www.tiktok.com/@\(user)/video/\(id)", id: id)
        }
        if SocialPosts.network(of: href) != nil { return .social(url: href) }
        return nil
    }

    /// X's embed data for a post. The endpoint wants a token but doesn't check it.
    static func dataURL(id: String) -> String {
        "https://cdn.syndication.twimg.com/tweet-result?id=\(id)&lang=en&token=a"
    }

    /// `html` with each embedded post (up to `maxPosts`) drawn as a card; unchanged when there are none.
    public static func expand(_ html: String, fetch: @escaping Fetch) async -> String {
        guard html.contains("<blockquote") else { return html }
        let found: [Post] = DOM.withFragment(html) { body in
            DOM.select(body, "blockquote").compactMap(post(of:))
        } ?? []
        guard !found.isEmpty else { return html }
        var cards: [Post: String] = [:]
        await withTaskGroup(of: (Post, String?).self) { group in
            for post in Array(NSOrderedSet(array: found).array.compactMap { $0 as? Post }.prefix(maxPosts)) {
                group.addTask { (post, await card(for: post, fetch: fetch)) }
            }
            for await (post, card) in group { if let card { cards[post] = card } }
        }
        guard !cards.isEmpty else { return html }
        return DOM.withFragment(html) { body -> String in
            for quote in DOM.select(body, "blockquote") {
                guard let post = post(of: quote), let card = cards[post] else { continue }
                DOM.replace(quote, withHTML: card)
            }
            return DOM.innerHTML(body)
        } ?? html
    }

    static func card(for post: Post, fetch: Fetch) async -> String? {
        switch post {
        case let .x(user, id):
            guard let (data, res) = await fetch(dataURL(id: id), SocialPosts.jsonHeaders), (200..<300).contains(res.statusCode) else { return nil }
            return card(from: data, canonical: "https://x.com/\(user)/status/\(id)")
        case let .social(url):
            guard let network = SocialPosts.network(of: url),
                  let html = await SocialPosts.extract(url: url, fetch: fetch)?.contentHtml else { return nil }
            // Truth Social runs Mastodon; it goes by its own name.
            let name = URL(string: url)?.host()?.hasSuffix("truthsocial.com") == true ? "Truth Social" : network.name
            return decorated(html, network: name, href: url)
        case let .tiktok(url, id):
            let oembed = "https://www.tiktok.com/oembed?url=\(DOM.encodeURIComponent(url))"
            var json: [String: Any] = [:]
            if let (data, res) = await fetch(oembed, SocialPosts.jsonHeaders), (200..<300).contains(res.statusCode) {
                json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            }
            return tiktokCard(json, url: url, id: id)
        }
    }

    /// A post the reader already draws (`SocialPost.render`) made a card: the network's mark in its author row and
    /// "Open on <network>" in its footer.
    static func decorated(_ html: String, network: String, href: String) -> String? {
        DOM.withFragment(html) { body -> String? in
            guard let post = DOM.first(body, ".x-post") else { return nil }
            DOM.setAttr(post, "class", "x-post x-embed")
            let host = URL(string: href)?.host() ?? ""
            if let who = DOM.first(post, ".x-who"), let icon = URLHost.faviconURL(host: host) {
                _ = try? who.append("<img class=\"x-net\" src=\"\(DOM.escapeAttr(icon.absoluteString))\" alt=\"\">")
            }
            let foot = DOM.first(post, ".x-foot") ?? {
                _ = try? post.append("<div class=\"x-foot\"></div>")
                return DOM.first(post, ".x-foot")
            }()
            _ = try? foot?.append("<a class=\"x-link\" href=\"\(DOM.escapeAttr(href))\">Open on \(DOM.escapeHTML(network))</a>")
            return ArticleSanitizer.sanitize(DOM.outerHTML(post))
        } ?? nil
    }

    /// TikTok's own player (portrait), with the author and caption from its oEmbed when it answered.
    static func tiktokCard(_ oembed: [String: Any], url: String, id: String) -> String {
        let name = (oembed["author_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let handle = (oembed["author_unique_id"] as? String) ?? tiktokURL.firstMatch(url)?[1] ?? nil
        let who = handle.map { h in
            "<div class=\"x-who\"><span class=\"x-name\">\(DOM.escapeHTML(name ?? h))</span><a class=\"x-handle\" href=\"https://www.tiktok.com/@\(DOM.escapeAttr(h))\">@\(DOM.escapeHTML(h))</a><img class=\"x-net\" src=\"\(DOM.escapeAttr(URLHost.faviconURL(host: "www.tiktok.com")?.absoluteString ?? ""))\" alt=\"\"></div>"
        } ?? ""
        let caption = (oembed["title"] as? String).map { DOM.squash($0) }.flatMap { $0.isEmpty ? nil : $0 }
        let body = caption.map { "<div class=\"x-body\"><p>\(DOM.escapeHTML($0))</p></div>" } ?? ""
        let player = "<div class=\"x-media x-tall\"><iframe src=\"https://www.tiktok.com/player/v1/\(id)?description=0&amp;music_info=0&amp;rel=0\" allow=\"fullscreen\" allowfullscreen></iframe></div>"
        let foot = "<div class=\"x-foot\"><a class=\"x-link\" href=\"\(DOM.escapeAttr(url))\">Open on TikTok</a></div>"
        return ArticleSanitizer.sanitize("<div class=\"x-post x-embed\">\(who)\(body)\(player)\(foot)</div>")
    }

    /// The card for a post from its embed data, or nil when the data isn't a readable post.
    static func card(from data: Data, canonical: String) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = json["text"] as? String, let u = json["user"] as? [String: Any],
              let name = u["name"] as? String, let handle = u["screen_name"] as? String else { return nil }
        let avatar = (u["profile_image_url_https"] as? String).map { $0.replacingOccurrences(of: "_normal.", with: "_bigger.") }
        let entities = json["entities"] as? [String: Any]
        var links: T.Links = [:]
        for l in (entities?["urls"] as? [[String: Any]]) ?? [] {
            if let url = l["url"] as? String, let display = l["display_url"] as? String, let expanded = l["expanded_url"] as? String {
                links[url] = (display, expanded)
            }
        }
        let media = mediaItems(json["mediaDetails"] as? [[String: Any]] ?? [])
        let body = T.bodyHTML(T.withoutMediaLinks(decodedEntities(text), links: links), links: links)
        let who = T.whoHTML(T.User(name: name, handle: handle, avatar: avatar), date: nil)
            .replacingOccurrences(of: "</div>", with: "<span class=\"x-net\"></span></div>")
        let date = (json["created_at"] as? String).flatMap(ISO8601.date(from:))
        var foot: [String] = date.map { [DOM.escapeHTML(T.stampLine($0))] } ?? []
        if let likes = json["favorite_count"] as? Int, likes > 0 { foot.append(count(likes, "like")) }
        if let replies = json["conversation_count"] as? Int, replies > 0 { foot.append(count(replies, "reply", plural: "replies")) }
        let footHTML = "<div class=\"x-foot\">\(foot.map { "<span>\($0)</span>" }.joined())<a class=\"x-link\" href=\"\(DOM.escapeAttr(canonical))\">Open on X</a></div>"
        let html = "<div class=\"x-post x-embed\">\(who)\(body)\(T.mediaHTML(media))\(quotedHTML(json["quoted_tweet"] as? [String: Any]))\(footHTML)</div>"
        return ArticleSanitizer.sanitize(html)
    }

    /// Photos at their large size; videos and GIFs as the widest MP4 up to `maxVideoWidth`, with their still.
    static func mediaItems(_ details: [[String: Any]]) -> [T.Media] {
        details.compactMap { m in
            guard let kind = (m["type"] as? String).flatMap(T.Media.Kind.init(rawValue:)),
                  let image = m["media_url_https"] as? String else { return nil }
            let info = m["original_info"] as? [String: Any]
            let width = info?["width"] as? Int, height = info?["height"] as? Int
            if kind == .photo { return T.Media(kind: kind, url: "\(image)?name=large", width: width, height: height) }
            let mp4s = (((m["video_info"] as? [String: Any])?["variants"] as? [[String: Any]]) ?? [])
                .filter { $0["content_type"] as? String == "video/mp4" }
                .compactMap { v -> (url: String, width: Int, bitrate: Int)? in
                    guard let url = v["url"] as? String else { return nil }
                    return (url, variantWidth(url) ?? 0, v["bitrate"] as? Int ?? 0)
                }
            let fitting = mp4s.filter { $0.width <= maxVideoWidth }
            guard let best = (fitting.isEmpty ? mp4s : fitting).max(by: { ($0.width, $0.bitrate) < ($1.width, $1.bitrate) }) else { return nil }
            return T.Media(kind: kind, url: best.url, poster: image, width: width, height: height)
        }
    }

    private static let variantSize = ExtractionDOM.Pattern("/(\\d{2,4})x(\\d{2,4})/")

    /// The width in a rendition's address (…/vid/avc1/1280x720/…).
    static func variantWidth(_ url: String) -> Int? {
        variantSize.firstMatch(url)?[1].flatMap { Int($0) }
    }

    private static func count(_ n: Int, _ one: String, plural: String? = nil) -> String {
        "\(n.formatted(.number.notation(.compactName))) \(n == 1 ? one : plural ?? one + "s")"
    }
}
