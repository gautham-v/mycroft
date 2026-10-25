import Foundation

/// Port of `ScrapeResult` (scrape.ts).
public struct ScrapeResult: Sendable, Hashable {
    /// Final listing URL after redirects.
    public var listingUrl: String
    /// Article links found on the listing, in page order.
    public var links: [String]
    /// New items (links not in `known`), ready for Queries.upsertItems.
    public var items: [ParsedItem]
    /// Links fully handled this run (item built, or not an article / gone); mark them seen.
    public var processed: [String]

    public init(listingUrl: String, links: [String], items: [ParsedItem], processed: [String]) {
        self.listingUrl = listingUrl
        self.links = links
        self.items = items
        self.processed = processed
    }
}

/// Port of `PageImageResult` (page-meta.ts).
public struct PageImageResult: Sendable, Hashable {
    /// og:image / twitter:image / JSON-LD image, absolute; nil when none.
    public var image: String?
    /// True when the answer is definitive (page read, or 4xx); false for temporary misses (429, 5xx, timeout).
    public var final: Bool

    public init(image: String?, final: Bool) {
        self.image = image
        self.final = final
    }
}

/// Scraped-page sources and page metadata (port of src/lib/scrape.ts and src/lib/page-meta.ts). Owner: Scraping agent.
/// Implementation: `DefaultPageScraper` in Scraping/DefaultPageScraper.swift (keep the type name and `init()`).
public protocol PageScraper: Sendable {
    /// scrapePage(listingUrl, known, {budgetMs}): find article links, fetch only those not in `known`
    /// (bounded concurrency, time budget; default 25 s when nil) and build items from OG/JSON-LD metadata.
    /// Throws when the listing can't be fetched or has no article links.
    func scrape(listingURL: String, known: Set<String>, budget: TimeInterval?) async throws -> ScrapeResult

    /// findArticleLinks(html, pageUrl): canonical article URLs on a listing page, in page order (pure).
    func findArticleLinks(html: String, pageURL: String) -> [String]

    /// listingTitle(html, pageUrl): a title for a scraped-page source (pure).
    func listingTitle(html: String, pageURL: String) -> String

    /// fetchPageImage(url, timeoutMs): read the page head for a share image (thumbnail backfill).
    func fetchPageImage(url: String, timeout: TimeInterval) async -> PageImageResult
}
