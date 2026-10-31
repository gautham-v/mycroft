import Foundation

/// Every service the app uses, wired together. Owner: Foundation.
///
///     let db = try AppDatabase.openDefault()
///     let services = OpenDispatchServices.live(database: db)
///     try await services.refresh.refreshAll(force: false)
///
/// `live` constructs the Default* implementations by their fixed names and initializers, so agents
/// replacing a Default* file never need to touch this one.
public struct OpenDispatchServices: Sendable {
    public let database: AppDatabase
    public let feedParser: any FeedParser
    public let scraper: any PageScraper
    public let detector: any FeedDetector
    public let extractor: any ContentExtractor
    public let opml: any OPMLCoding
    public let integrations: any IntegrationService
    public let refresh: any RefreshService
    public let search: any SourceSearching
    public let content: ContentService
    public let copy: CopyService
    public let sponsorBlock: any SponsorBlockFetching
    public let explore: any ExploreSearching
    public let discussions: any DiscussionLoading
    public let articles: any ArticleSearching
    public let xAccounts: any XAccountSearching
    public let socialAccounts: any SocialAccountSearching

    public init(
        database: AppDatabase, feedParser: any FeedParser, scraper: any PageScraper, detector: any FeedDetector,
        extractor: any ContentExtractor, opml: any OPMLCoding, integrations: any IntegrationService, refresh: any RefreshService,
        search: any SourceSearching = DefaultSourceSearch(), sponsorBlock: any SponsorBlockFetching = DefaultSponsorBlock(),
        explore: any ExploreSearching = DefaultExploreSearch(), discussions: any DiscussionLoading = DefaultDiscussions(),
        articles: any ArticleSearching = DefaultArticleSearch(), xAccounts: any XAccountSearching = DefaultXAccounts(),
        socialAccounts: any SocialAccountSearching = DefaultSocialAccounts()
    ) {
        self.database = database
        self.feedParser = feedParser
        self.scraper = scraper
        self.detector = detector
        self.extractor = extractor
        self.opml = opml
        self.integrations = integrations
        self.refresh = refresh
        self.search = search
        self.sponsorBlock = sponsorBlock
        self.explore = explore
        self.discussions = discussions
        self.articles = articles
        self.xAccounts = xAccounts
        self.socialAccounts = socialAccounts
        self.content = ContentService(database: database, extractor: extractor)
        self.copy = CopyService(database: database, content: content, transcripts: DefaultTranscriptFetcher(parser: feedParser))
    }

    public static func live(database: AppDatabase) -> OpenDispatchServices {
        let parser = DefaultFeedParser()
        let scraper = DefaultPageScraper()
        return OpenDispatchServices(
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
    /// `fetch: false` returns as soon as the source is stored; the caller fetches it.
    public func addSource(url input: String, group: String? = nil, fetch: Bool = true) async throws -> (source: Source, existed: Bool) {
        let url = try SourceURL.normalize(input)
        let found = try await detector.detect(url)
        let (created, existed) = try await database.insertSource(found, group: group)
        if existed || !fetch { return (created, existed) }
        _ = try? await refresh.refreshSource(id: created.id)
        return ((try? await database.source(id: created.id)) ?? created, false)
    }

    /// A link typed into a new tab: normalize it, then return it as an item (OpenedLinks), reading the
    /// page for its title and the rest the first time. A page that can't be read is still stored, with its
    /// address as the title, and the reader shows why it can't be shown. An Apple Podcasts episode and a
    /// link to an audio file become episodes the reader plays. Throws SourceURLError for text that isn't a
    /// web address.
    public func openLink(_ input: String) async throws -> FeedItem {
        let typed = try SourceURL.normalize(input)
        let videoID = OpenedLinks.youTubeVideoID(typed)
        let apple = videoID == nil ? ApplePodcastEpisode.link(typed) : nil
        let url = apple.map(ApplePodcastEpisode.canonicalURL) ?? OpenedLinks.canonicalURL(typed, videoID: videoID)
        let feedUrl = videoID != nil ? OpenedLinks.videosFeedURL
            : apple != nil || OpenedLinks.isAudioURL(url) ? OpenedLinks.episodesFeedURL : OpenedLinks.linksFeedURL
        if let opened = try await database.openedLink(feedUrl: feedUrl, url: url) { return opened }

        if let apple, let episode = await ApplePodcastEpisode.resolve(
            apple, fetch: ApplePodcastEpisode.liveFetch(timeout: 10), pageTitle: { await pageTitle(url) }) {
            return try await database.insertOpenedLink(episode)
        }
        if OpenedLinks.isAudioURL(url) { return try await database.insertOpenedLink(OpenedLinks.audioItem(url: url)) }
        // An audio file without an extension is only known by its response; asked before the page is read in full.
        if apple == nil, videoID == nil, await isAudio(url) {
            if let opened = try await database.openedLink(feedUrl: OpenedLinks.episodesFeedURL, url: url) { return opened }
            return try await database.insertOpenedLink(OpenedLinks.audioItem(url: url))
        }

        // Reddit refuses the link scraper; its post is read through the hidden web view.
        if RedditPages.isThread(url), let post = await DiscussionContent.redditItem(url: url) {
            if let opened = try await database.openedLink(feedUrl: OpenedLinks.linksFeedURL, url: post.url) { return opened }
            return try await database.insertOpenedLink(post)
        }
        guard var item = await scraper.fetchLinkItem(url: url, videoID: videoID, timeout: 10) else {
            return try await database.insertOpenedLink(OpenedLinks.fallbackItem(url: url, videoID: videoID))
        }
        item.title = OpenedLinks.cleanedTitle(item.title, url: url) ?? OpenedLinks.fallbackItem(url: url, videoID: videoID).title
        return try await database.insertOpenedLink(item)
    }

    /// An Explore video as an opened video (OpenedLinks), so it plays in the reader. Stored under the same address as the
    /// pasted link, from its watch page like `openLink` does (the description is only there), but the search hit stands in for
    /// what the page doesn't give: if it can't be read in time the video still opens with its title, channel and length,
    /// not as "YouTube video".
    public func openExploreVideo(_ video: ExploreVideo) async throws -> FeedItem {
        let url = OpenedLinks.canonicalURL(video.watchUrl, videoID: video.id)
        if let opened = try await database.openedLink(feedUrl: OpenedLinks.videosFeedURL, url: url) { return opened }
        let hit = OpenedLinks.item(video: video)
        guard var item = await scraper.fetchLinkItem(url: url, videoID: video.id, timeout: 6) else {
            return try await database.insertOpenedLink(hit)
        }
        item.title = OpenedLinks.cleanedTitle(item.title, url: url).flatMap { $0 == url ? nil : $0 } ?? hit.title
        item.author = item.author.flatMap { $0.isEmpty ? nil : $0 } ?? hit.author
        item.durationSec = item.durationSec ?? hit.durationSec
        return try await database.insertOpenedLink(item)
    }

    /// An Explore episode as an opened episode (OpenedLinks), played by the podcast player. The search hit has everything the
    /// Apple link's lookup would give, so it is stored as it is, with no request. A hit without an audio URL goes through
    /// `openLink`, which finds the episode in the show's feed.
    public func openExploreEpisode(_ episode: ExploreEpisode) async throws -> FeedItem {
        guard let item = ApplePodcastEpisode.item(explore: episode) else { return try await openLink(episode.appleUrl) }
        if let opened = try await database.openedLink(feedUrl: OpenedLinks.episodesFeedURL, url: item.guid) { return opened }
        return try await database.insertOpenedLink(item)
    }

    /// An Explore post (Reddit, X, Bluesky, Hacker News) as an opened link, from what the search result shows, with no
    /// request: the reader reads the post and its comments when it opens.
    public func openExplorePost(_ post: DiscussionPost) async throws -> FeedItem {
        let item = OpenedLinks.item(post: post)
        if let opened = try await database.openedLink(feedUrl: OpenedLinks.linksFeedURL, url: item.url) { return opened }
        return try await database.insertOpenedLink(item)
    }

    /// An Explore article as an opened link, from what the search result shows, with no request: the reader reads the page when
    /// it opens, and shows its paywall banner if only a teaser can be read. A result that is a video or an audio file goes
    /// through `openLink`, which plays it.
    public func openExploreArticle(_ article: ExploreArticle) async throws -> FeedItem {
        let url = article.url
        if OpenedLinks.youTubeVideoID(url) != nil || ApplePodcastEpisode.link(url) != nil || OpenedLinks.isAudioURL(url) { return try await openLink(url) }
        if let opened = try await database.openedLink(feedUrl: OpenedLinks.linksFeedURL, url: url) { return opened }
        return try await database.insertOpenedLink(OpenedLinks.item(article: article))
    }

    /// The title of a page, for matching an Apple Podcasts episode to its show's feed.
    private func pageTitle(_ url: String) async -> String? {
        guard let item = await scraper.fetchLinkItem(url: url, videoID: nil, timeout: 10) else { return nil }
        return OpenedLinks.cleanedTitle(item.title, url: url)
    }

    /// The link answers with an `audio/*` content type. A server that refuses HEAD counts as not audio.
    private func isAudio(_ url: String) async -> Bool {
        guard let (_, res) = try? await HTTP.fetch(url, timeout: 3, method: "HEAD"), (200..<300).contains(res.statusCode) else { return false }
        return OpenedLinks.isAudioContentType(res.value(forHTTPHeaderField: "Content-Type"))
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
