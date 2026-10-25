import Foundation

/// Feed discovery for "Add source" (port of src/lib/feed-detect.ts): YouTube channel URLs (/@handle,
/// /channel/UC…, channelId in page HTML), Apple Podcasts / Spotify shows, the URL as a feed itself,
/// <link rel="alternate"> feeds in HTML, www-alternate retry, and finally a scraped-page source.
/// Owner: Detection agent. Implementation: `DefaultFeedDetector` in Detection/DefaultFeedDetector.swift
/// (keep the type name and `init(parser: any FeedParser, scraper: any PageScraper)`).
public protocol FeedDetector: Sendable {
    /// `url` is already normalized with SourceURL.normalize. Throws an error whose `localizedDescription`
    /// is a user-facing message (shown in the Add Source dialog) when nothing usable is found.
    func detect(_ url: String) async throws -> DetectedFeed
}

/// OPML 2.0 import/export (port of src/lib/opml.ts). Owner: Detection agent.
/// Implementation: `DefaultOPMLCoder` in Detection/DefaultOPMLCoder.swift (keep the type name and `init()`).
/// Database side of import (folder matching, skipping known feeds) is Queries.importOPML.
public protocol OPMLCoding: Sendable {
    /// Parse an OPML file. Nested outlines with children become folders; top-level feeds are unfiled.
    func parse(_ xml: String) throws -> OPMLDocument

    /// Serialize every source, folders in the given order, with the `openfeed:kind` attribute.
    /// `folders` are in sidebar order; `sources` in (position, title) order.
    func serialize(folders: [Folder], sources: [Source], now: Date) -> String
}
