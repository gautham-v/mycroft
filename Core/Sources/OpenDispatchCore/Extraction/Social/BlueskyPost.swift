import Foundation

/// A post on Bluesky, from the public AppView's `getPostThread` (no account; the post's author may be a handle
/// or a DID in the address). Text carries its links, mentions and tags as byte-ranged facets; the embed is
/// images, a link card, a video (HLS playlist and still), a quoted post, or a quoted post with media.
enum BlueskyPost {
    typealias DOM = ExtractionDOM
    typealias Media = SocialPost.Media

    private static let appView = "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread"

    static func load(url: String, fetch: SocialPosts.Fetch) async -> SocialPost? {
        guard let m = SocialPosts.blueskyURL.firstMatch(url), let actor = m[1], let rkey = m[2] else { return nil }
        let uri = DOM.encodeURIComponent("at://\(actor)/app.bsky.feed.post/\(rkey)")
        guard let (data, res) = await fetch("\(appView)?uri=\(uri)&depth=0&parentHeight=0", SocialPosts.jsonHeaders),
              (200..<300).contains(res.statusCode) else { return nil }
        return parse(data, canonical: "https://bsky.app/profile/\(actor)/post/\(rkey)")
    }

    /// The post in a `getPostThread` response; nil for a missing, blocked or deleted post.
    static func parse(_ data: Data, canonical: String) -> SocialPost? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let post = (root["thread"] as? [String: Any])?["post"] as? [String: Any],
              let record = post["record"] as? [String: Any], let author = author(post["author"]) else { return nil }
        var out = SocialPost(network: .bluesky, url: canonical, author: author,
                             paragraphs: paragraphs(record), date: SocialPosts.date(record["createdAt"]))
        if let embed = post["embed"] as? [String: Any] { apply(embed, to: &out) }
        return out
    }

    private static func author(_ v: Any?) -> SocialPost.Author? {
        guard let a = v as? [String: Any], let handle = a["handle"] as? String else { return nil }
        let name = (a["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(name: name?.isEmpty == false ? name! : handle, handle: handle, avatar: a["avatar"] as? String,
                     profile: "https://bsky.app/profile/\(handle)")
    }

    // MARK: Embeds

    private static func apply(_ embed: [String: Any], to post: inout SocialPost) {
        switch embed["$type"] as? String {
        case "app.bsky.embed.images#view", "app.bsky.embed.video#view":
            post.media += media(embed)
        case "app.bsky.embed.external#view":
            guard let ext = embed["external"] as? [String: Any], let uri = ext["uri"] as? String else { return }
            // A GIF from the picker is an external embed of the animation itself.
            if DOM.hostname(uri) == "media.tenor.com" {
                post.media.append(Media(kind: .photo, url: uri, alt: ext["title"] as? String))
            } else if let title = (ext["title"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? DOM.hostname(uri) {
                post.card = .init(href: uri, title: title, domain: DOM.hostname(uri), image: ext["thumb"] as? String)
            }
        case "app.bsky.embed.record#view":
            post.quote = quote(embed["record"])
        case "app.bsky.embed.recordWithMedia#view":
            if let m = embed["media"] as? [String: Any] { apply(m, to: &post) }
            post.quote = quote((embed["record"] as? [String: Any])?["record"])
        default:
            break
        }
    }

    /// The photos or video of an images or video embed view.
    private static func media(_ embed: [String: Any]) -> [Media] {
        func size(_ o: [String: Any]) -> (Int?, Int?) {
            let r = o["aspectRatio"] as? [String: Any]
            return (r?["width"] as? Int, r?["height"] as? Int)
        }
        if embed["$type"] as? String == "app.bsky.embed.video#view" {
            guard let playlist = embed["playlist"] as? String else { return [] }
            let (w, h) = size(embed)
            return [Media(kind: .video, url: playlist, poster: embed["thumbnail"] as? String, width: w, height: h)]
        }
        return ((embed["images"] as? [[String: Any]]) ?? []).compactMap { i in
            guard let full = i["fullsize"] as? String else { return nil }
            let (w, h) = size(i)
            return Media(kind: .photo, url: full, width: w, height: h, alt: (i["alt"] as? String).flatMap { $0.isEmpty ? nil : $0 }, thumb: i["thumb"] as? String)
        }
    }

    /// A quoted post's view; nil for one that is missing, blocked, detached or not a post (a feed, a list).
    private static func quote(_ v: Any?) -> SocialPost.Quote? {
        guard let r = v as? [String: Any], r["$type"] as? String == "app.bsky.embed.record#viewRecord",
              let author = author(r["author"]), let value = r["value"] as? [String: Any], let uri = r["uri"] as? String,
              let rkey = uri.split(separator: "/").last else { return nil }
        var media: [Media] = []
        for e in (r["embeds"] as? [[String: Any]]) ?? [] {
            switch e["$type"] as? String {
            case "app.bsky.embed.images#view", "app.bsky.embed.video#view": media += Self.media(e)
            case "app.bsky.embed.recordWithMedia#view": if let m = e["media"] as? [String: Any] { media += Self.media(m) }
            default: break
            }
        }
        return .init(author: author, paragraphs: paragraphs(value), media: media,
                     href: "https://bsky.app/profile/\(author.handle)/post/\(rkey)", date: SocialPosts.date(value["createdAt"]))
    }

    // MARK: Text

    /// The post text as inline HTML paragraphs, its facets (byte ranges of the UTF-8 text) turned into links.
    static func paragraphs(_ record: [String: Any]) -> [String] {
        let text = (record["text"] as? String) ?? ""
        let bytes = Array(text.utf8)
        func slice(_ from: Int, _ to: Int) -> String { String(decoding: bytes[from..<to], as: UTF8.self) }
        let facets = ((record["facets"] as? [[String: Any]]) ?? []).compactMap { f -> (Int, Int, String)? in
            guard let idx = f["index"] as? [String: Any], let s = idx["byteStart"] as? Int, let e = idx["byteEnd"] as? Int,
                  s >= 0, e <= bytes.count, s < e,
                  let href = (f["features"] as? [[String: Any]])?.lazy.compactMap(href).first else { return nil }
            return (s, e, href)
        }.sorted { $0.0 < $1.0 }
        var html = "", pos = 0
        for (s, e, href) in facets where s >= pos {
            html += DOM.escapeHTML(slice(pos, s))
            html += "<a href=\"\(DOM.escapeAttr(href))\">\(DOM.escapeHTML(slice(s, e)))</a>"
            pos = e
        }
        html += DOM.escapeHTML(slice(pos, bytes.count))
        return SocialPost.paragraphs(fromInline: html)
    }

    private static func href(_ feature: [String: Any]) -> String? {
        switch feature["$type"] as? String {
        case "app.bsky.richtext.facet#link": return feature["uri"] as? String
        case "app.bsky.richtext.facet#mention": return (feature["did"] as? String).map { "https://bsky.app/profile/\($0)" }
        case "app.bsky.richtext.facet#tag": return (feature["tag"] as? String).map { "https://bsky.app/hashtag/\(DOM.encodeURIComponent($0))" }
        default: return nil
        }
    }
}
