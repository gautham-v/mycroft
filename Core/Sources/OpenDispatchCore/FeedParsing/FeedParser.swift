import Foundation

public enum FeedParserError: Error, LocalizedError, Equatable {
    case invalidFeed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFeed(let why): "Not a feed: \(why)"
        }
    }
}

/// RSS/Atom/YouTube/podcast feed parsing (port of src/lib/parse.ts). Owner: FeedParsing agent.
/// Implementation: `DefaultFeedParser` in FeedParsing/DefaultFeedParser.swift (keep the type name and `init()`).
public protocol FeedParser: Sendable {
    /// parseFeedXml(xml, kind, feedUrl): normalize every entry into ParsedItem (YouTube thumbnails/video ids,
    /// HN points/comments, podcast audio/duration, thumbnails from media:* / enclosure / first <img>), plus feed
    /// title, link, isPodcast and show art. Throws FeedParserError.invalidFeed for non-feed input.
    func parse(_ data: Data, kind: SourceKind, feedURL: String) throws -> ParsedFeed

    /// findFeedItemHtml(xml, {guid, url}): the matching entry's full HTML (content:encoded, then description/summary),
    /// or nil. Used by the extractor's feed fallback and podcast show notes.
    func itemHTML(in data: Data, guid: String, url: String) -> String?
}
