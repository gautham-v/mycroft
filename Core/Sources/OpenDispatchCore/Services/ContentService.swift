import Foundation

/// Reader content for an item (port of GET /api/items/:id/content). Owner: Foundation.
/// YouTube items have no body; cached content is served unless `refresh`; podcasts use show notes from the feed;
/// other items go through the extractor (rss items with a feed fallback). Fresh results are cached.
/// An opened Apple Podcasts episode (OpenedLinks) has its show's feed looked up first; an opened audio file has no notes.
public struct ContentService: Sendable {
    public let database: AppDatabase
    public let extractor: any ContentExtractor
    /// How the iTunes lookup for an opened episode's show is fetched. Tests answer from fixtures.
    var lookup: ApplePodcastEpisode.Fetch = ApplePodcastEpisode.liveFetch()

    public init(database: AppDatabase, extractor: any ContentExtractor) {
        self.database = database
        self.extractor = extractor
    }

    /// Throws QueryError.notFound for an unknown id; extraction errors propagate (show "Extraction failed: …").
    public func content(forItem id: Int64, refresh: Bool = false) async throws -> ExtractResult {
        let pair = try await database.reader.read { db -> (Item, Source)? in
            guard let item = try Queries.itemRecord(db, id: id), let src = try Queries.source(db, id: item.sourceId) else { return nil }
            return (item, src)
        }
        guard let (item, source) = pair else { throw QueryError.notFound("Item") }
        let lead = item.thumbnailUrl
        if source.kind == .youtube { return ExtractResult(contentHtml: nil, leadImage: lead) }
        if let html = item.contentHtml, !refresh {
            return ExtractResult(contentHtml: html, leadImage: lead, rendered: item.contentRendered)
        }
        let feed = FeedRef(feedUrl: source.feedUrl, guid: item.guid)
        let out: ExtractResult
        if source.isOpenedLinks, source.kind == .podcast {
            // The feed entry is found by the audio URL, the one thing the opened item shares with it.
            guard let feedUrl = await OpenedLinks.episodeFeedURL(for: item, fetch: lookup), let audio = item.audioUrl else {
                return ExtractResult(contentHtml: nil, leadImage: lead)
            }
            out = try await extractor.extractPodcastNotes(url: audio, feed: FeedRef(feedUrl: feedUrl, guid: item.guid))
        } else if source.kind == .podcast {
            out = try await extractor.extractPodcastNotes(url: item.url, feed: feed)
        } else {
            out = try await extractor.extractArticle(url: item.url, feed: source.kind == .rss ? feed : nil)
        }
        try await database.cacheContent(itemId: id, result: out)
        return ExtractResult(contentHtml: out.contentHtml, leadImage: lead ?? out.leadImage, rendered: out.rendered)
    }
}
