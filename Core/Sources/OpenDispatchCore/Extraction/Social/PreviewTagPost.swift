import Foundation

/// A post on Threads or Instagram, from the preview tags (Open Graph and Twitter) their pages give link-preview
/// crawlers: the author and the text or caption, and the post's picture. Both gate their pages behind a login for
/// a browser, so this is the only no-account source; it reads no avatar, and Threads gives no date. A video is its
/// still. When a network stops serving the tags the post can't be read and the reader says so.
enum PreviewTagPost {
    typealias DOM = ExtractionDOM
    typealias Media = SocialPost.Media

    static func load(url: String, fetch: SocialPosts.Fetch) async -> SocialPost? {
        guard let network = SocialPosts.network(of: url), network == .threads || network == .instagram,
              let canonical = canonicalURL(url, network: network),
              let (data, res) = await fetch(canonical, SocialPosts.crawlerHeaders), (200..<300).contains(res.statusCode) else { return nil }
        guard var post = parse(html: HTTP.text(data, response: res), canonical: canonical, network: network) else { return nil }
        // The embed page adds what the preview tags lack: the author's picture, and Threads' date. Best effort.
        let embed = network == .threads ? canonical + "/embed" : canonical + "embed/captioned/"
        if let (data, res) = await fetch(embed, SocialPosts.crawlerHeaders), (200..<300).contains(res.statusCode) {
            let extra = parseEmbed(html: HTTP.text(data, response: res))
            post.author.avatar = extra.avatar
            post.date = post.date ?? extra.date
        }
        return post
    }

    /// The author's picture and, on a Threads embed ("5:01 PM · Sep 16, 2025"), the day it was posted.
    static func parseEmbed(html: String) -> (avatar: String?, date: Date?) {
        guard let doc = DOM.parseDocument(html) else { return (nil, nil) }
        let avatar = DOM.first(doc, ".AvatarContainer img, a.Avatar img").flatMap { DOM.attr($0, "src") }
        let stamp = DOM.first(doc, ".Timestamp").map { DOM.text($0) }
        let day = stamp.flatMap { ScrapingText.firstGroups(threadsDay, $0)?[1] }
        return (avatar, day.flatMap { shortDayFormatter.date(from: $0) }.map { $0.addingTimeInterval(12 * 3600) })
    }

    static func canonicalURL(_ url: String, network: SocialPost.Network) -> String? {
        switch network {
        case .threads:
            return SocialPosts.threadsURL.firstMatch(url).flatMap { m in
                m[1].flatMap { u in m[2].map { "https://www.threads.com/@\(u)/post/\($0)" } }
            }
        case .instagram:
            return SocialPosts.instagramURL.firstMatch(url).flatMap { m in
                m[2].flatMap { kind in m[3].map { "https://www.instagram.com/\(kind.lowercased())/\($0)/" } }
            }
        default:
            return nil
        }
    }

    private static let threadsTitle = ScrapingText.regex(#"^(.*?)\s*\(@([^)\s]+)\)\s+on Threads$"#, [.dotMatchesLineSeparators])
    private static let instagramTitle = ScrapingText.regex(#"^(.*?)\s*\(@([^)\s]+)\)\s+•\s+Instagram"#, [.dotMatchesLineSeparators])
    /// "272K likes, 771 comments - nasa on May 26, 2025: "caption"." (the counts are missing on a post without any).
    private static let instagramDescription = ScrapingText.regex(#"^(?:.*? - )?([A-Za-z0-9._]+) on ([A-Z][a-z]+ \d{1,2}, \d{4}): "(.*)"\.?\s*$"#, [.dotMatchesLineSeparators])
    /// Instagram's profile pictures live under /t51.2885-19/.
    private static let profilePicture = "t51.2885-19"

    private static let threadsDay = ScrapingText.regex(#"([A-Z][a-z]{2} \d{1,2}, \d{4})\s*$"#)

    private static func makeDayFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
    private static let dayFormatter = makeDayFormatter("MMMM d, yyyy")
    private static let shortDayFormatter = makeDayFormatter("MMM d, yyyy")

    static func parse(html: String, canonical: String, network: SocialPost.Network) -> SocialPost? {
        guard let doc = DOM.parseDocument(html) else { return nil }
        let meta = PageMeta.meta(in: doc)
        var name: String?, handle: String?, text: String?, date: Date?
        switch network {
        case .threads:
            guard let m = meta("og:title").flatMap({ ScrapingText.firstGroups(threadsTitle, $0) }) else { return nil }
            name = m[1]; handle = m[2]
            text = meta("og:description", "description")
        case .instagram:
            let d = meta("og:description", "description").flatMap { ScrapingText.firstGroups(instagramDescription, $0) }
            let t = meta("twitter:title", "og:title").flatMap { ScrapingText.firstGroups(instagramTitle, $0) }
            guard let handle0 = t?[2] ?? d?[1] else { return nil }
            name = t?[1]; handle = handle0
            text = d?[3]
            date = d?[2].flatMap { dayFormatter.date(from: $0) }.map { $0.addingTimeInterval(12 * 3600) }
        default:
            return nil
        }
        guard let handle, !handle.isEmpty else { return nil }
        let paragraphs = SocialPost.paragraphs(fromPlain: text ?? "")
        var media: [Media] = []
        if let image = meta("og:image"), !image.contains(profilePicture) { media = [Media(kind: .photo, url: image)] }
        guard !paragraphs.isEmpty || !media.isEmpty else { return nil }
        let profile = network == .threads ? "https://www.threads.com/@\(handle)" : "https://www.instagram.com/\(handle)/"
        return SocialPost(network: network, url: canonical, author: .init(name: name ?? handle, handle: handle, profile: profile),
                          paragraphs: paragraphs, date: date, media: media)
    }
}
