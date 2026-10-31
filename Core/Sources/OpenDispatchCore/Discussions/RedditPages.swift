import Foundation
import SwiftSoup

/// Reddit's own pages, read as the website draws them. Reddit refuses its JSON (and often its pages) to anything that isn't a
/// browser, so `DiscussionWeb` fetches these from inside a hidden web view on reddit.com and this reads the HTML that comes
/// back: the search page (`search-sdui-post` units), a post page (`shreddit-post` and its `shreddit-comment`s) and the
/// "more comments" partials (`/svc/shreddit/more-comments/…`, posted with the partial's `cursor`).
///
/// A post page carries the top comments with few replies under them; each "N more replies" and the trailing "more
/// comments" is a `faceplate-partial` that becomes a `DiscussionMore` whose token is the partial's address and cursor.
enum RedditPages {
    static let origin = "https://www.reddit.com"
    private static let threadURL = ExtractionDOM.Pattern(
        #"^https?://(?:(?:www|old|new|np|m|sh)\.)?reddit\.com(/r/[^/?#]+/comments/[A-Za-z0-9]+)(?:/([^/?#]*))?"#, caseInsensitive: true)

    /// A post's address on any Reddit host.
    static func isThread(_ url: String) -> Bool { threadURL.test(url) }

    /// The post at `url` as www.reddit.com/r/<sub>/comments/<id>/<slug>/; nil for anything else.
    static func canonicalURL(_ url: String) -> String? {
        guard let m = threadURL.firstMatch(url), let path = m[1] else { return nil }
        let slug = m[2].flatMap { $0.isEmpty ? nil : $0 }
        return origin + path + "/" + (slug.map { $0 + "/" } ?? "")
    }

    /// The search for posts (not communities or comments) from the last `range` ("week", "month"), by relevance or `sort` ("new").
    /// A query of several words is searched as a phrase unless it already has quotes.
    static func searchPath(_ query: String, range: String, sort: String = "relevance") -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = q.contains(" ") && !q.contains("\"") ? "\"\(q)\"" : q
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#;\"")
        let encoded = (phrase.addingPercentEncoding(withAllowedCharacters: allowed) ?? phrase)
        return "/search/?q=\(encoded)&type=link&sort=\(sort)&t=\(range)"
    }

    // MARK: Search

    /// The posts on a search page, in page order. Adult posts and posts in adult communities are left out.
    static func posts(inSearch html: String) -> [DiscussionPost] {
        guard let doc = ExtractionDOM.parseDocument(html, baseURI: origin) else { return [] }
        var seen = Set<String>()
        var out: [DiscussionPost] = []
        for unit in (try? doc.select("[view-events=\"search/view/post\"]").array()) ?? [] {
            let context = tracking(unit)
            let post = context?["post"] as? [String: Any]
            let sub = context?["subreddit"] as? [String: Any]
            if post?["nsfw"] as? Bool == true || sub?["nsfw"] as? Bool == true { continue }
            guard let link = try? unit.select("a[data-testid=post-title-text]").first(),
                  let href = try? link.attr("href"), let url = canonicalURL(absolute(href)), seen.insert(url).inserted else { continue }
            let title = ((try? link.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let numbers = ((try? unit.select("[data-testid=search-counter-row] faceplate-number").array()) ?? [])
                .compactMap { Int((try? $0.attr("number")) ?? "") }
            let community = (sub?["name"] as? String).map { "r/" + $0 }
            let icon = nonEmpty(try? unit.select("a[href^=\"/r/\"] img").first()?.attr("src"))
            let thumb = nonEmpty(try? unit.select("faceplate-img[data-testid=search_post_thumbnail]").first()?.attr("src"))
            let author = (context?["profile"] as? [String: Any])?["name"] as? String
            out.append(DiscussionPost(
                place: .reddit, url: url, title: title, author: author.map { "u/" + $0 }, handle: author, community: community,
                avatarUrl: icon, published: DiscussionDates.parse(try? unit.select("faceplate-timeago").first()?.attr("ts")),
                score: numbers.first, comments: numbers.count > 1 ? numbers[1] : nil,
                thumbnailUrl: thumb))
        }
        return out
    }

    private static func tracking(_ el: Element) -> [String: Any]? {
        guard let raw = try? el.attr("data-faceplate-tracking-context"), let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Post page

    /// A post as its page shows it.
    struct Post: Equatable {
        enum Kind: Equatable { case text, image, gallery, link, video, other }
        var url: String
        var title: String
        var author: String?
        var community: String?
        var published: Date?
        var score: Int?
        var comments: Int?
        var kind: Kind
        /// The image (image post) or the page it links to (link post).
        var contentHref: String?
        var images: [String]
        /// The body as HTML (a text post, or the text under a link or image post).
        var bodyHTML: String?
        /// A video Reddit hosts: its HLS playlist and still.
        var video: String?
        var poster: String?
        /// A link post's preview: the linked site, its picture and its description.
        var domain: String?
        var preview: Preview?
        var linkDescription: String?

        struct Preview: Equatable {
            var url: String
            var width: Int?
            var height: Int?
        }

        /// The picture a list and the reader's header use.
        var leadImage: String? {
            switch kind {
            case .image: contentHref
            case .video: poster
            case .link: preview?.url
            default: images.first
            }
        }
    }

    /// The post on a post page; nil when the page has none (a removed post, a block page).
    static func post(inThread html: String) -> Post? {
        guard let doc = ExtractionDOM.parseDocument(html, baseURI: origin) else { return nil }
        return withExtendedLifetime(doc) { post(in: doc) }
    }

    private static func post(in doc: Document) -> Post? {
        guard let el = try? doc.select("shreddit-post").first() else { return nil }
        func attr(_ name: String) -> String? {
            let v = (try? el.attr(name)) ?? ""
            return v.isEmpty ? nil : v
        }
        guard let permalink = attr("permalink"), let url = canonicalURL(absolute(permalink)) else { return nil }
        let kind: Post.Kind = switch attr("post-type") {
        case "text", "self": .text
        case "image": .image
        case "gallery", "multi_media": .gallery
        case "link": .link
        case "video": .video
        default: .other
        }
        var images: [String] = []
        if kind == .gallery {
            images = ((try? el.select("gallery-carousel img, shreddit-gallery img").array()) ?? [])
                .compactMap { nonEmpty(try? $0.attr("src")) ?? nonEmpty(try? $0.attr("data-lazy-src")) }
            var seen = Set<String>()
            images = images.filter { seen.insert($0).inserted }
        }
        // A link post's preview carries the site's description as an articleBody too, ahead of the poster's own text.
        let description = try? el.select("[data-link-preview-cta-row] [property=schema:articleBody]").first()
        let bodies = (try? el.select("[property=schema:articleBody]").array()) ?? []
        let body = bodies.first { $0 !== description } ?? (try? el.select("div[slot=text-body]").first())
        let player = try? el.select("shreddit-player[src]").first()
        return Post(
            url: url, title: attr("post-title") ?? "", author: attr("author"), community: attr("subreddit-prefixed-name"),
            published: DiscussionDates.parse(attr("created-timestamp")), score: attr("score").flatMap(Int.init),
            comments: attr("comment-count").flatMap(Int.init), kind: kind, contentHref: attr("content-href"), images: images,
            bodyHTML: body.flatMap { try? $0.html() }.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
            video: nonEmpty(try? player?.attr("src")).map(lastingPlaylist), poster: nonEmpty(try? player?.attr("poster")),
            domain: attr("domain"), preview: (try? el.select("img[data-post-media-primary]").first()).flatMap(preview) ?? attr("content-href").flatMap(youTubePreview),
            linkDescription: (description.flatMap { try? $0.text() }).flatMap { nonEmpty($0) })
    }

    /// A playlist's address without its signature, which runs out in a month while a read post is kept longer; v.redd.it answers without one.
    private static func lastingPlaylist(_ src: String) -> String {
        guard ExtractionDOM.hostname(src) == "v.redd.it", let query = src.firstIndex(of: "?") else { return src }
        return String(src[..<query])
    }

    /// A preview picture at its widest size.
    private static func preview(_ img: Element) -> Post.Preview? {
        let widest = previewCandidate.allMatches((try? img.attr("srcset")) ?? "")
            .compactMap { m -> (url: String, width: Int)? in
                guard let url = m[1], let width = m[2].flatMap({ Int($0) }) else { return nil }
                return (url, width)
            }
            .max { $0.width < $1.width }?.url
        guard let url = widest ?? nonEmpty(try? img.attr("src")) else { return nil }
        return Post.Preview(url: url, width: Int((try? img.attr("width")) ?? ""), height: Int((try? img.attr("height")) ?? ""))
    }
    /// Reddit shows a linked YouTube video in its own player and gives no preview for it.
    private static func youTubePreview(_ href: String) -> Post.Preview? {
        OpenedLinks.youTubeVideoID(href).map { Post.Preview(url: FeedParsingSupport.youtubeThumbnail(videoID: $0), width: 480, height: 360) }
    }
    private static let previewCandidate = ExtractionDOM.Pattern(#"(https?://\S+)\s+(\d+)w"#)

    /// The comments on a post page, and the post's comment count.
    static func thread(_ html: String) -> DiscussionThread {
        guard let doc = ExtractionDOM.parseDocument(html, baseURI: origin) else { return DiscussionThread(entries: []) }
        return withExtendedLifetime(doc) {
            let post = post(in: doc)
            return DiscussionThread(entries: entries(in: doc, author: post?.author), total: post?.comments)
        }
    }

    /// The comments a "more comments" partial answered with.
    static func moreEntries(_ html: String, author: String? = nil) -> [DiscussionEntry] {
        guard let doc = ExtractionDOM.parseDocument(html, baseURI: origin) else { return [] }
        return withExtendedLifetime(doc) { entries(in: doc, author: author) }
    }

    /// Comments and "more" partials in document order, which is reading order: a comment's partial for more replies comes
    /// after the replies it has.
    private static func entries(in doc: Document, author: String?) -> [DiscussionEntry] {
        let nodes = (try? doc.select("shreddit-comment, faceplate-partial[src*=\"/more-comments/\"]").array()) ?? []
        var out: [DiscussionEntry] = []
        var seen = Set<String>()
        for el in nodes {
            if el.tagName() == "shreddit-comment" {
                guard let c = comment(el, postAuthor: author), seen.insert(c.id).inserted else { continue }
                out.append(.comment(c))
            } else if let more = more(el) {
                out.append(.more(more))
            }
        }
        return out
    }

    private static func comment(_ el: Element, postAuthor: String?) -> DiscussionComment? {
        func attr(_ name: String) -> String? {
            let v = (try? el.attr(name)) ?? ""
            return v.isEmpty ? nil : v
        }
        guard let id = attr("thingid") ?? attr("thingId") else { return nil }
        let depth = attr("depth").flatMap(Int.init) ?? 0
        // The body is this comment's own slot, not a reply's.
        let slot = ((try? el.select("div[slot=comment]").array()) ?? []).first { nearestComment($0) === el }
        let body = slot.map { RichText.element($0, base: origin) } ?? RichText(paragraphs: [])
        let author = attr("author") ?? "[deleted]"
        if body.isEmpty, author == "[deleted]" {
            return DiscussionComment(id: id, author: "[deleted]", body: RichText.plain("[deleted]"), depth: depth)
        }
        return DiscussionComment(
            id: id, author: author, avatarUrl: attr("avatar"), body: body, published: DiscussionDates.parse(attr("created")),
            score: attr("score").flatMap(Int.init), depth: depth, url: attr("permalink").map(absolute),
            byAuthor: postAuthor != nil && author == postAuthor)
    }

    private static func nearestComment(_ el: Element) -> Element? {
        var node = el.parent()
        while let n = node {
            if n.tagName() == "shreddit-comment" { return n }
            node = n.parent()
        }
        return nil
    }

    /// A partial as a `DiscussionMore`: replies to its comment (one deeper), or more replies to the post.
    private static func more(_ el: Element) -> DiscussionMore? {
        guard let src = try? el.attr("src"), !src.isEmpty else { return nil }
        let cursor = nonEmpty(try? el.select("input[name=cursor]").first()?.attr("value")) ?? ""
        let count = nonEmpty(try? el.select("faceplate-number").first()?.attr("number")).flatMap(Int.init)
            ?? URLComponents(string: absolute(src))?.queryItems?.first { $0.name == "comments-remaining" }?.value.flatMap(Int.init)
        let parent = nearestComment(el)
        let depth = parent.flatMap { Int((try? $0.attr("depth")) ?? "") }.map { $0 + 1 } ?? 0
        return DiscussionMore(token: src + moreSeparator + cursor, depth: depth, count: count)
    }

    /// Between a partial's address and its cursor in a `DiscussionMore` token.
    static let moreSeparator = "\u{1F}"

    /// The address and cursor in a token.
    static func partial(_ token: String) -> (path: String, cursor: String) {
        let parts = token.components(separatedBy: moreSeparator)
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    static func absolute(_ href: String) -> String {
        href.hasPrefix("/") ? origin + href : href
    }

    // MARK: Reader content

    /// A post as reader markup: its text, its image, gallery or video, and for one that links elsewhere a card for the page, or
    /// `embed`, the linked post as the reader draws posts. Nil for a post with none of these (a title-only post, whose title
    /// the reader already shows).
    static func contentHTML(_ post: Post, embed: String? = nil) -> String? {
        var parts: [String] = []
        switch post.kind {
        case .image:
            if let src = post.contentHref { parts.append("<figure><img src=\"\(ExtractionDOM.escapeAttr(src))\" alt=\"\"></figure>") }
        case .gallery:
            parts += post.images.map { "<figure><img src=\"\(ExtractionDOM.escapeAttr($0))\" alt=\"\"></figure>" }
        case .link, .video:
            if let embed {
                parts.append(embed)
            } else if let video = post.video {
                parts.append(TweetExtraction.mediaHTML([.init(kind: .video, url: video, poster: post.poster)]))
            } else if let href = post.contentHref, !isThread(href) {
                parts.append(TweetExtraction.cardHTML(
                    href: href, title: post.linkDescription ?? "", domain: post.domain, image: post.preview?.url, large: true,
                    showsTitle: post.linkDescription != nil, imageSize: post.preview.flatMap { p in p.width.flatMap { w in p.height.map { (w, $0) } } }))
            }
        case .text, .other:
            break
        }
        if let body = post.bodyHTML { parts.append(body) }
        let html = ArticleSanitizer.sanitize(parts.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
        return html.isEmpty ? nil : html
    }
}

/// A community's or user's feed. Reddit answers a plain request for one about once a minute and with a 429 after that (adding a
/// source reads its feed twice), but gives a page it has let in a hundred requests, so a refused request is asked again from inside
/// the hidden web view.
enum RedditFeed {
    typealias Page = @Sendable (_ path: String) async throws -> String

    static let livePage: Page = { path in
        #if canImport(WebKit)
        return try await DiscussionWeb.shared.redditHTML(path)
        #else
        throw DiscussionError.unavailable
        #endif
    }

    /// The body `direct` reads, or for a Reddit address it was refused, the web view's; any other failure is `direct`'s.
    static func read(_ url: String, page: Page = livePage, direct: () async throws -> Data) async throws -> Data {
        do {
            return try await direct()
        } catch HTTPError.status(let code) where code == 403 || code == 429 {
            guard let path = path(of: url), let text = try? await page(path), FeedDetection.looksLikeFeed(text) else {
                throw HTTPError.status(code)
            }
            return Data(text.utf8)
        }
    }

    private static func path(of url: String) -> String? {
        guard let parts = URLComponents(string: url), let host = parts.host?.lowercased(),
              host == "reddit.com" || host.hasSuffix(".reddit.com") else { return nil }
        return parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?\($0)" } ?? "")
    }
}
