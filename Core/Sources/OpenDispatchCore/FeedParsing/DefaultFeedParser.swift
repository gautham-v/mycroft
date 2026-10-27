import Foundation

/// Port of src/lib/parse.ts: RSS 0.9x/1.0/2.0 and Atom (YouTube channel feeds, hnrss, podcasts, blogs)
/// normalized into `ParsedItem`s. XML is read into a qualified-name element tree (see FeedXMLTree.swift)
/// so the field rules can follow rss-parser + parse.ts exactly; a malformed feed gets one repaired retry.
public struct DefaultFeedParser: FeedParser {
    public init() {}

    public func parse(_ data: Data, kind: SourceKind, feedURL: String) throws -> ParsedFeed {
        try parse(data, kind: kind, feedURL: feedURL, now: Date())
    }

    /// parseFeedXml with a fixed "now" for items whose date is missing or unreadable.
    public func parse(_ data: Data, kind: SourceKind, feedURL: String, now: Date) throws -> ParsedFeed {
        let raw = try Self.rawFeed(data)
        let link = raw.link
        let imageUrl = FeedParsingSupport.absolutize(raw.itunesImage ?? raw.channelImage, base: link ?? feedURL)
        let items = raw.items.compactMap {
            Self.normalizeItem($0, kind: kind, feedURL: feedURL, feedLink: link, showArt: imageUrl, now: now)
        }
        let audioCount = items.filter { $0.audioUrl != nil }.count
        let isPodcast = kind != .youtube
            && FeedParsingSupport.feedLooksLikePodcast(hasItunesTags: raw.hasItunesTags, itemCount: items.count, audioCount: audioCount)
        return ParsedFeed(title: raw.title, link: link, isPodcast: isPodcast, imageUrl: imageUrl, items: items)
    }

    /// findFeedItemHtml: the entry's full HTML (content:encoded, then content/description, then itunes:summary),
    /// matched by guid (or Atom id) across every entry first, then by link. Links keep their query; only the
    /// fragment and a trailing slash are ignored.
    public func itemHTML(in data: Data, guid: String, url: String) -> String? {
        guard let match = Self.rawItem(in: data, guid: guid, url: url) else { return nil }
        return match.contentEncoded ?? match.content ?? match.itunesSummary
    }

    /// The entry's `<podcast:transcript>` tracks, matched like `itemHTML`; urls are as written (the caller
    /// resolves relative ones against the feed URL).
    public func itemTranscripts(in data: Data, guid: String, url: String) -> [FeedTranscriptTrack] {
        Self.rawItem(in: data, guid: guid, url: url)?.transcripts ?? []
    }

    // MARK: - Internals

    /// The entry with this guid (or Atom id) across every entry first, then by link, then by audio enclosure
    /// (an opened Apple Podcasts episode knows its audio URL but not the feed's guid or link).
    static func rawItem(in data: Data, guid: String, url: String) -> FeedParsingSupport.RawItem? {
        guard let raw = try? rawFeed(data) else { return nil }
        let key = FeedParsingSupport.linkMatchKey(url)
        return raw.items.first { ($0.guid ?? $0.id) == guid }
            ?? raw.items.first { item in item.link.map { FeedParsingSupport.linkMatchKey($0) == key } ?? false }
            ?? raw.items.first { item in item.enclosure?.url.map { FeedParsingSupport.linkMatchKey($0) == key } ?? false }
    }

    static func rawFeed(_ data: Data) throws -> FeedParsingSupport.RawFeed {
        guard data.contains(where: { $0 > 0x20 }) else { throw FeedParserError.invalidFeed("empty response") }
        let root: FeedParsingSupport.XMLElementNode
        do {
            root = try FeedParsingSupport.parseXMLTree(data)
        } catch {
            throw FeedParserError.invalidFeed("not valid XML")
        }
        return try FeedParsingSupport.rawFeed(root)
    }

    /// normalizeItem in parse.ts. nil when the entry has no usable URL.
    static func normalizeItem(_ raw: FeedParsingSupport.RawItem, kind: SourceKind, feedURL: String, feedLink: String?,
                              showArt: String?, now: Date) -> ParsedItem? {
        typealias S = FeedParsingSupport
        let base = feedLink ?? feedURL
        let audio = kind == .youtube
            ? nil
            : S.absolutize(S.audioEnclosure(url: raw.enclosure?.url, type: raw.enclosure?.type), base: feedURL)
        // Episodes often have no <link> and an opaque guid: fall back to the show page, then the audio.
        let url: String?
        if let audio {
            let guidURL = (raw.guid?.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil)
                ? S.absolutize(raw.guid, base: base) : nil
            url = S.absolutize(raw.link, base: base) ?? guidURL ?? S.absolutize(feedLink, base: feedURL) ?? audio
        } else {
            url = S.absolutize(raw.link, base: base) ?? S.absolutize(raw.guid, base: base)
        }
        guard let url else { return nil }
        let guid = raw.guid ?? raw.id ?? url
        // Titles are plain text, but WordPress feeds (The Verge) put HTML entities inside CDATA: `&#8216;revolutionize`.
        let title = S.nonEmpty(raw.title.map(S.decodeHTMLEntities)) ?? "(untitled)"
        let author = S.nonEmpty(raw.creator) ?? S.displayAuthor(raw.author, fallback: raw.itunesAuthor)
        let publishedAt = S.date(from: raw.pubDate) ?? now

        if kind == .youtube {
            let videoID = raw.videoID ?? raw.id.flatMap { $0.hasPrefix("yt:video:") ? S.nonEmpty(String($0.dropFirst(9))) : nil }
            return ParsedItem(
                guid: guid, url: url, title: title,
                summary: raw.groupDescription.flatMap { S.stripHTML($0, max: 600) },
                author: author, publishedAt: publishedAt,
                thumbnailUrl: videoID.map { S.youtubeThumbnail(videoID: $0) },
                videoId: videoID
            )
        }

        let html = raw.contentEncoded ?? raw.content ?? raw.description ?? raw.summary ?? raw.itunesSummary

        if S.isHNFeed(feedURL) {
            let hn = S.parseHNDescription(raw.description ?? raw.content)
            return ParsedItem(
                guid: guid, url: url, title: title, author: author, publishedAt: publishedAt,
                hnPoints: hn.points, hnComments: hn.comments, hnCommentsUrl: raw.comments
            )
        }

        let mediaContentImage = raw.mediaContents.first { a in
            guard let u = S.nonEmpty(a["url"]) else { return false }
            return a["medium"] == "image" || (a["type"] ?? "").hasPrefix("image/")
                || u.range(of: #"\.(jpe?g|png|webp|gif)(\?|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
        }?["url"]
        let enclosureImage = (raw.enclosure?.type ?? "").hasPrefix("image/") ? S.nonEmpty(raw.enclosure?.url) : nil
        // Episodes: the episode's own art, then the show's, before any image in the show notes (often a sponsor logo).
        let thumb = S.nonEmpty(mediaContentImage) ?? raw.mediaThumbnail ?? raw.groupThumbnail ?? enclosureImage
            ?? raw.itunesImage ?? (audio != nil ? showArt : nil) ?? S.firstImage(html)

        let snippet = (raw.contentSnippet?.isEmpty == false) ? raw.contentSnippet : html
        return ParsedItem(
            guid: guid, url: url, title: title,
            summary: S.stripHTML(snippet),
            author: author, publishedAt: publishedAt,
            thumbnailUrl: S.absolutize(thumb, base: url),
            durationSec: audio != nil ? S.parseDuration(raw.itunesDuration) : nil,
            audioUrl: audio
        )
    }
}
