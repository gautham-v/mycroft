import Foundation

/// A post on a social network other than X (Bluesky, Mastodon, LinkedIn, Threads, Instagram), read from the
/// network's public data. It renders as the same x-* post markup a post on X does, and gives the opened-link
/// item its list fields: the first paragraph as the title, the author as "Name (@handle)", the post's date.
struct SocialPost {
    typealias DOM = ExtractionDOM
    typealias Media = TweetExtraction.Media

    enum Network: String, CaseIterable {
        case bluesky, mastodon, linkedin, threads, instagram

        var name: String {
            switch self {
            case .bluesky: "Bluesky"
            case .mastodon: "Mastodon"
            case .linkedin: "LinkedIn"
            case .threads: "Threads"
            case .instagram: "Instagram"
            }
        }
    }

    struct Author: Equatable {
        var name: String
        /// Shown after "@": a handle, an account at an instance, a profile slug.
        var handle: String
        var avatar: String?
        var profile: String?
    }

    struct Card: Equatable {
        var href: String
        var title: String
        var domain: String?
        var image: String?
    }

    /// A quoted post, shown as a bordered card under the text.
    struct Quote: Equatable {
        var author: Author
        var paragraphs: [String]
        var media: [Media] = []
        var href: String
        var date: Date?
    }

    var network: Network
    /// The post's canonical address (the stored item's url).
    var url: String
    var author: Author
    /// The text as inline HTML (escaped; links, line breaks), one entry per paragraph.
    var paragraphs: [String]
    var date: Date?
    var media: [Media] = []
    var card: Card?
    var quote: Quote?

    // MARK: Item fields

    private static let headlineLimit = 140

    /// The first paragraph as plain text; a post of only media is named for it ("Photo", "Video").
    var title: String? {
        let first = paragraphs.lazy.map { TextFormat.stripHTML($0.replacingOccurrences(of: "<br>", with: " ")) }.first { !$0.isEmpty }
        if let first { return ScrapingText.clip(first, Self.headlineLimit) }
        switch media.first?.kind {
        case .photo: return "Photo"
        case .video: return "Video"
        case .gif: return "GIF"
        case nil: return quote.map { "Quoting \($0.author.name)" }
        }
    }

    /// "Name (@handle)", the form the app splits back into name and handle.
    var authorLine: String {
        let name = author.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "@\(author.handle)" : "\(name) (@\(author.handle))"
    }

    /// The first photo or video still, small where the network has a small size.
    var leadImage: String? { media.first.map { $0.thumb ?? $0.poster ?? $0.url } }

    /// A quote is named in the list the way a quoting post on X is: "Quoting Name: first line".
    private var quoteSummary: String? {
        guard let quote else { return nil }
        let line = quote.paragraphs.lazy.map { TextFormat.stripHTML($0.replacingOccurrences(of: "<br>", with: " ")) }.first { !$0.isEmpty }
        return ScrapingText.clip("Quoting \(quote.author.name): \(line ?? "")", 200)
    }

    func item(now: Date = Date()) -> ParsedItem {
        ParsedItem(
            guid: url, url: url, title: title ?? "Post by @\(author.handle) on \(network.name)", summary: quoteSummary,
            author: authorLine, publishedAt: date ?? now, thumbnailUrl: leadImage, quoteAvatarUrl: quote?.author.avatar)
    }

    // MARK: Markup

    private func user(_ a: Author) -> TweetExtraction.User { .init(name: a.name.isEmpty ? a.handle : a.name, handle: a.handle, avatar: a.avatar) }

    private static func bodyHTML(_ paragraphs: [String]) -> String {
        paragraphs.isEmpty ? "" : "<div class=\"x-body\">\(paragraphs.map { "<p>\($0)</p>" }.joined())</div>"
    }

    /// The reader markup: author row, text, media, the quoted post, the link card, a footer.
    func render() -> ExtractResult? {
        var quoted = ""
        if let q = quote {
            quoted = "<div class=\"x-quote\">\(TweetExtraction.whoHTML(user(q.author), date: q.date.map(TweetExtraction.dateLine), profile: q.author.profile))\(Self.bodyHTML(q.paragraphs))\(TweetExtraction.mediaHTML(q.media))<a class=\"x-quote-link\" href=\"\(DOM.escapeAttr(q.href))\">View post</a></div>"
        }
        var cardHTML = ""
        if let c = card { cardHTML = TweetExtraction.cardHTML(href: c.href, title: c.title, domain: c.domain, image: c.image) }
        guard !paragraphs.isEmpty || !media.isEmpty || quote != nil || card != nil else { return nil }
        let foot = TweetExtraction.footHTML(date: date.map(TweetExtraction.dateLine), canonical: url, network: network.name)
        let html = ArticleSanitizer.sanitize(
            "<div class=\"x-post\">\(TweetExtraction.whoHTML(user(author), date: nil, profile: author.profile))\(Self.bodyHTML(paragraphs))\(TweetExtraction.mediaHTML(media))\(quoted)\(cardHTML)\(foot)</div>"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return html.isEmpty ? nil : ExtractResult(contentHtml: html, leadImage: leadImage)
    }

    // MARK: Text

    private static let blankLines = DOM.Pattern(#"\n[ \t]*\n\s*"#)
    private static let bareURL = DOM.Pattern(#"https?://[^\s<>"]+"#)

    /// HTML paragraphs from escaped inline HTML holding blank-line breaks and "\n" line breaks.
    static func paragraphs(fromInline html: String) -> [String] {
        let marker = "\u{1F}"
        return blankLines.replacing(html, with: marker).components(separatedBy: marker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "<br>") }
            .filter { !$0.isEmpty }
    }

    /// Plain post text as paragraphs, bare URLs linked (trailing punctuation left outside the link).
    static func paragraphs(fromPlain text: String) -> [String] {
        paragraphs(fromInline: linkify(text))
    }

    static func linkify(_ text: String) -> String {
        let ns = text as NSString
        var out = "", last = 0
        for m in bareURL.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += DOM.escapeHTML(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            var url = ns.substring(with: m.range)
            var tail = ""
            while let c = url.last, ".,;:!?)]}\u{2019}".contains(c) { tail.insert(c, at: tail.startIndex); url.removeLast() }
            out += "<a href=\"\(DOM.escapeAttr(url))\">\(DOM.escapeHTML(url))</a>\(DOM.escapeHTML(tail))"
            last = m.range.location + m.range.length
        }
        return out + DOM.escapeHTML(ns.substring(from: last))
    }
}
