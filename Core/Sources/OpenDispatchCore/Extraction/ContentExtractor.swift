import Foundation

/// Full-text extraction (port of src/lib/extract.ts: Readability via a hidden WKWebView, cleanup, sanitizing,
/// 403 retry with browser headers, feed-content fallback, Jina Reader fallback). Owner: Extraction agent.
/// Implementation: `DefaultContentExtractor` in Extraction/DefaultContentExtractor.swift
/// (keep the type name and `init(parser: any FeedParser)`). Caching is done by ContentService, not here.
public protocol ContentExtractor: Sendable {
    /// extractArticle(url, feed?): `feed` is passed for rss sources so an unfetchable page can fall back to the feed's HTML.
    /// Returns sanitized HTML safe to show in the reader's WKWebView, plus a lead image.
    func extractArticle(url: String, feed: FeedRef?) async throws -> ExtractResult

    /// extractPodcastNotes(url, feed): the episode's show notes from the feed, never the episode page. No lead image.
    func extractPodcastNotes(url: String, feed: FeedRef) async throws -> ExtractResult
}
