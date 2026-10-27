import Foundation
import SwiftSoup

/// A post on any Mastodon server, from its status API (`/api/v1/statuses/<id>`, public on servers that don't
/// require a login to read). The address shape `https://<instance>/@user/<id>` is how they are told apart from
/// other sites; a server that isn't Mastodon, or locks its API, simply answers no.
enum MastodonPost {
    typealias DOM = ExtractionDOM
    typealias Media = SocialPost.Media

    static func load(url: String, fetch: SocialPosts.Fetch) async -> SocialPost? {
        guard let m = SocialPosts.mastodonURL.firstMatch(url), let host = m[1], let user = m[2], let id = m[3] else { return nil }
        guard let (data, res) = await fetch("https://\(host)/api/v1/statuses/\(id)", SocialPosts.jsonHeaders),
              (200..<300).contains(res.statusCode) else { return nil }
        return parse(data, host: host, canonical: "https://\(host)/\(user)/\(id)")
    }

    /// The post in a status response served by `host`.
    static func parse(_ data: Data, host: String, canonical: String) -> SocialPost? {
        guard let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], s["id"] != nil,
              let author = author(s["account"], host: host) else { return nil }
        let quoted = quote(s["quote"], host: host)
        var paragraphs = paragraphs(s["content"] as? String ?? "", emojis: s["emojis"], dropQuoteLine: quoted != nil)
        // A content warning leads, as the line shown before the text is revealed.
        if let cw = (s["spoiler_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !cw.isEmpty {
            paragraphs.insert("<strong>\(DOM.escapeHTML(cw))</strong>", at: 0)
        }
        var out = SocialPost(network: .mastodon, url: canonical, author: author, paragraphs: paragraphs,
                             date: SocialPosts.date(s["created_at"]), media: media(s["media_attachments"]), quote: quoted)
        if let c = s["card"] as? [String: Any], let href = c["url"] as? String,
           let title = (c["title"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
            out.card = .init(href: href, title: title, domain: (c["provider_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                             image: c["image"] as? String)
        }
        return out
    }

    private static let shortcode = DOM.Pattern(#":([A-Za-z0-9_]+):"#)

    private static func author(_ v: Any?, host: String) -> SocialPost.Author? {
        guard let a = v as? [String: Any], let acct = a["acct"] as? String else { return nil }
        // A local account is "name"; the handle also says where it lives.
        let handle = acct.contains("@") ? acct : "\(acct)@\(host)"
        var name = (a["display_name"] as? String) ?? ""
        // Custom emoji in a name are images; without them the shortcodes are dropped.
        name = shortcode.replacing(name, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(name: name.isEmpty ? (a["username"] as? String ?? acct) : name, handle: handle,
                     avatar: (a["avatar_static"] as? String) ?? (a["avatar"] as? String), profile: a["url"] as? String)
    }

    private static func media(_ v: Any?) -> [Media] {
        ((v as? [[String: Any]]) ?? []).compactMap { a in
            guard let url = a["url"] as? String, let type = a["type"] as? String else { return nil }
            let original = (a["meta"] as? [String: Any])?["original"] as? [String: Any]
            let w = original?["width"] as? Int, h = original?["height"] as? Int
            let preview = a["preview_url"] as? String
            let alt = (a["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            switch type {
            case "image": return Media(kind: .photo, url: url, width: w, height: h, alt: alt, thumb: preview)
            case "video": return Media(kind: .video, url: url, poster: preview, width: w, height: h, alt: alt)
            case "gifv": return Media(kind: .gif, url: url, poster: preview, width: w, height: h, alt: alt)
            default: return nil  // audio and unknown kinds
            }
        }
    }

    /// An accepted quote (servers that support them): the quoted status.
    private static func quote(_ v: Any?, host: String) -> SocialPost.Quote? {
        guard let q = v as? [String: Any], q["state"] as? String == "accepted", let s = q["quoted_status"] as? [String: Any],
              let author = author(s["account"], host: host), let url = s["url"] as? String else { return nil }
        return .init(author: author, paragraphs: paragraphs(s["content"] as? String ?? "", emojis: s["emojis"], dropQuoteLine: false),
                     media: media(s["media_attachments"]), href: url, date: SocialPosts.date(s["created_at"]))
    }

    // MARK: Text

    /// The status HTML as inline-HTML paragraphs. Links read as Mastodon's page shows them (the hidden parts of a long
    /// address dropped, an ellipsis where it is cut), custom emoji become images, and the "RE: link" line a quote
    /// post starts with goes when the quote is shown below.
    static func paragraphs(_ html: String, emojis: Any?, dropQuoteLine: Bool) -> [String] {
        let out: [String] = DOM.withFragment(html) { body in
            if dropQuoteLine { for p in DOM.select(body, "p.quote-inline") { DOM.remove(p) } }
            for s in DOM.select(body, "span:not(.invisible):not(.ellipsis)") { _ = try? s.unwrap() }
            for a in DOM.select(body, "a") {
                for (key, _) in a.getAttributes()?.asList().map({ ($0.getKey(), $0.getValue()) }) ?? [] where key != "href" { DOM.removeAttr(a, key) }
                let cut = !DOM.select(a, "span.ellipsis").isEmpty
                for s in DOM.select(a, "span.invisible") { DOM.remove(s) }
                _ = try? a.text(DOM.text(a) + (cut ? "…" : ""))
            }
            let ps = DOM.children(body).filter { DOM.tag($0) == "p" }
            return (ps.isEmpty ? [DOM.innerHTML(body)] : ps.map(DOM.innerHTML)).map { $0.replacingOccurrences(of: "<br />", with: "<br>") }
        } ?? []
        let custom = ((emojis as? [[String: Any]]) ?? []).compactMap { e -> (String, String)? in
            guard let code = e["shortcode"] as? String, let url = (e["static_url"] as? String) ?? (e["url"] as? String) else { return nil }
            return (":\(code):", "<img class=\"x-emoji\" src=\"\(DOM.escapeAttr(url))\" alt=\":\(code):\">")
        }
        return out.map { p in custom.reduce(p) { $0.replacingOccurrences(of: $1.0, with: $1.1) } }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
