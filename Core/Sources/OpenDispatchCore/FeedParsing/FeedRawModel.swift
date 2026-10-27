import Foundation

extension FeedParsingSupport {
    /// The fields parse.ts reads from rss-parser's output, read the same way rss-parser reads them
    /// (RSS 0.9x/2.0 `<rss><channel>`, RSS 1.0 `<rdf:RDF>`, Atom `<feed>`), plus parse.ts's custom fields.
    struct RawFeed {
        var title: String?
        var link: String?
        var itunesImage: String?
        var channelImage: String?
        var hasItunesTags = false
        var items: [RawItem] = []
    }

    struct RawEnclosure {
        var url: String?
        var type: String?
    }

    struct RawItem {
        var title: String?
        var link: String?
        var guid: String?
        var id: String?
        var pubDate: String?
        var creator: String?
        var author: String?
        /// RSS: the description's content; Atom: the entry content (rss-parser `content`).
        var content: String?
        var contentSnippet: String?
        /// Atom summary.
        var summary: String?
        /// The `<description>` element (custom field).
        var description: String?
        var contentEncoded: String?
        var comments: String?
        var enclosure: RawEnclosure?
        var videoID: String?
        var mediaContents: [[String: String]] = []
        var mediaThumbnail: String?
        var groupThumbnail: String?
        var groupDescription: String?
        var itunesDuration: String?
        var itunesImage: String?
        var itunesSummary: String?
        var itunesAuthor: String?
        /// Every `podcast:transcript` element, in document order.
        var transcripts: [FeedTranscriptTrack] = []
    }

    static func rawFeed(_ root: XMLElementNode) throws -> RawFeed {
        switch root.localName.lowercased() {
        case "rss":
            guard let channel = root.child("channel") else { throw FeedParserError.invalidFeed("RSS without a channel") }
            var feed = rssChannel(channel)
            feed.items = channel.children("item").map(rssItem)
            return feed
        case "rdf":
            let channel = root.child("channel")
            var feed = channel.map(rssChannel) ?? RawFeed()
            feed.items = (root.children("item") + (channel?.children("item") ?? [])).map(rssItem)
            return feed
        case "feed":
            var feed = RawFeed()
            feed.title = textual(root.child("title"))
            feed.link = atomLink(root.children("link"), rel: "alternate")
            applyItunes(root, to: &feed)
            feed.items = root.children("entry").map(atomEntry)
            return feed
        default:
            throw FeedParserError.invalidFeed("Feed not recognized as RSS 1 or 2.")
        }
    }

    private static func rssChannel(_ channel: XMLElementNode) -> RawFeed {
        var feed = RawFeed()
        feed.title = channel.child("title")?.trimmedText
        feed.link = channel.child("link")?.trimmedText
        feed.channelImage = channel.child("image")?.child("url")?.trimmedText
        applyItunes(channel, to: &feed)
        return feed
    }

    private static func applyItunes(_ node: XMLElementNode, to feed: inout RawFeed) {
        let image = node.child("itunes:image")
        feed.itunesImage = nonEmpty(image?.attributes["href"]) ?? image?.trimmedText
        feed.hasItunesTags = ["itunes:image", "itunes:author", "itunes:owner", "itunes:category", "itunes:type"].contains { name in
            guard let e = node.child(name) else { return false }
            return !e.attributes.isEmpty || !e.elements.isEmpty || e.trimmedText != nil
        }
    }

    private static func rssItem(_ e: XMLElementNode) -> RawItem {
        var item = RawItem()
        item.title = e.child("title")?.trimmedText ?? e.child("dc:title")?.trimmedText
        item.link = e.child("link")?.trimmedText
        item.guid = e.child("guid")?.trimmedText
        item.pubDate = e.child("pubDate")?.trimmedText ?? e.child("dc:date")?.trimmedText
        item.creator = e.child("dc:creator")?.trimmedText
        item.author = e.child("author").flatMap(textual)
        if let d = e.child("description") {
            let c = d.content
            item.content = c
            item.contentSnippet = snippet(c)
            item.description = c
        }
        item.contentEncoded = e.child("content:encoded")?.content
        item.comments = e.child("comments")?.trimmedText
        if let enc = e.child("enclosure") {
            item.enclosure = RawEnclosure(url: enc.attributes["url"], type: enc.attributes["type"])
        }
        applyCustom(e, to: &item)
        return item
    }

    private static func atomEntry(_ e: XMLElementNode) -> RawItem {
        var item = RawItem()
        item.title = textual(e.child("title"))
        let links = e.children("link")
        item.link = atomLink(links, rel: "alternate")
        item.pubDate = e.child("published")?.trimmedText ?? e.child("updated")?.trimmedText
        item.author = e.child("author")?.child("name")?.trimmedText
        if let c = e.child("content") {
            let html = c.content
            item.content = html
            item.contentSnippet = snippet(html)
        }
        item.summary = e.child("summary")?.content
        item.id = e.child("id")?.trimmedText
        item.description = e.child("description")?.content
        item.comments = e.child("comments")?.trimmedText
        if let enc = links.first(where: { $0.attributes["rel"] == "enclosure" }) {
            item.enclosure = RawEnclosure(url: enc.attributes["href"], type: enc.attributes["type"])
        }
        applyCustom(e, to: &item)
        return item
    }

    /// parse.ts customFields: media:group, yt:videoId, media:thumbnail, media:content (all), itunes:*.
    private static func applyCustom(_ e: XMLElementNode, to item: inout RawItem) {
        if let group = e.child("media:group") {
            item.groupThumbnail = nonEmpty(group.child("media:thumbnail")?.attributes["url"])
            item.groupDescription = group.child("media:description")?.content
        }
        item.videoID = e.child("yt:videoId")?.trimmedText
        item.mediaThumbnail = nonEmpty(e.child("media:thumbnail")?.attributes["url"])
        item.mediaContents = e.children("media:content").map(\.attributes)
        item.itunesDuration = e.child("itunes:duration")?.trimmedText
        let image = e.child("itunes:image")
        item.itunesImage = nonEmpty(image?.attributes["href"]) ?? image?.trimmedText
        item.itunesSummary = e.child("itunes:summary")?.trimmedText
        item.itunesAuthor = e.child("itunes:author")?.trimmedText
        item.transcripts = e.elements.filter { $0.localName == "transcript" && $0.name.contains(":") }.compactMap { t in
            guard let url = nonEmpty(t.attributes["url"]) else { return nil }
            return FeedTranscriptTrack(url: url, type: nonEmpty(t.attributes["type"]), language: nonEmpty(t.attributes["language"]),
                                       rel: nonEmpty(t.attributes["rel"]))
        }
    }

    /// rss-parser getLink: the first link with this rel (a link without rel counts as "alternate"), else the first link.
    private static func atomLink(_ links: [XMLElementNode], rel: String) -> String? {
        let match = links.first { ($0.attributes["rel"] ?? "alternate") == rel } ?? links.first
        return nonEmpty(match?.attributes["href"]) ?? match?.trimmedText
    }

    /// Text of a title-like element; inline markup (type="xhtml") reduced to its text.
    private static func textual(_ e: XMLElementNode?) -> String? {
        guard let e else { return nil }
        if e.elements.isEmpty { return e.trimmedText }
        return nonEmpty(snippet(e.innerXML).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
