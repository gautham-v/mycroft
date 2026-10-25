import Foundation

/// Every service the app uses, wired together. Owner: Foundation.
///
///     let db = try AppDatabase.openDefault()
///     let services = OpenfeedServices.live(database: db)
///     try await services.refresh.refreshAll(force: false)
///
/// `live` constructs the Default* implementations by their fixed names and initializers, so agents
/// replacing a Default* file never need to touch this one.
public struct OpenfeedServices: Sendable {
    public let database: AppDatabase
    public let feedParser: any FeedParser
    public let scraper: any PageScraper
    public let detector: any FeedDetector
    public let extractor: any ContentExtractor
    public let opml: any OPMLCoding
    public let integrations: any IntegrationService
    public let refresh: any RefreshService
    public let content: ContentService

    public init(
        database: AppDatabase, feedParser: any FeedParser, scraper: any PageScraper, detector: any FeedDetector,
        extractor: any ContentExtractor, opml: any OPMLCoding, integrations: any IntegrationService, refresh: any RefreshService
    ) {
        self.database = database
        self.feedParser = feedParser
        self.scraper = scraper
        self.detector = detector
        self.extractor = extractor
        self.opml = opml
        self.integrations = integrations
        self.refresh = refresh
        self.content = ContentService(database: database, extractor: extractor)
    }

    public static func live(database: AppDatabase) -> OpenfeedServices {
        let parser = DefaultFeedParser()
        let scraper = DefaultPageScraper()
        return OpenfeedServices(
            database: database,
            feedParser: parser,
            scraper: scraper,
            detector: DefaultFeedDetector(parser: parser, scraper: scraper),
            extractor: DefaultContentExtractor(parser: parser),
            opml: DefaultOPMLCoder(),
            integrations: DefaultIntegrationService(database: database),
            refresh: DefaultRefreshService(database: database, parser: parser, scraper: scraper))
    }

    /// POST /api/sources: normalize → detect → insert (or return the existing source) → fetch it once.
    /// The fetch's error is recorded on the source and not thrown. Throws SourceURLError or the detector's error.
    public func addSource(url input: String, group: String? = nil) async throws -> (source: Source, existed: Bool) {
        let url = try SourceURL.normalize(input)
        let found = try await detector.detect(url)
        let (created, existed) = try await database.insertSource(found, group: group)
        if existed { return (created, true) }
        _ = try? await refresh.refreshSource(id: created.id)
        return ((try? await database.source(id: created.id)) ?? created, false)
    }

    /// GET /api/opml: the whole subscription list as OPML.
    public func exportOPML(now: Date = Date()) async throws -> String {
        let (sources, folders) = try await database.sourcesAndFolders()
        return opml.serialize(folders: folders, sources: sources, now: now)
    }

    /// POST /api/opml.
    public func importOPML(xml: String) async throws -> OPMLImportResult {
        let doc = try opml.parse(xml)
        return try await database.importOPML(doc)
    }
}
