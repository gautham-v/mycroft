import Foundation

public enum ExtractionError: Error, LocalizedError, Equatable {
    case unsupportedContentType(String)
    case feedStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedContentType(let ct): "Unsupported content type: \(ct)"
        case .feedStatus(let code): "Feed returned HTTP \(code)"
        }
    }
}

/// Full-text extraction (port of extractArticle / extractPodcastNotes in src/lib/extract.ts).
///
/// Order for an article: X posts first (status page data, then oEmbed); otherwise the page is fetched (403/401 retried
/// once with browser headers unless Cloudflare's challenge) and run through `ArticleExtraction` (pre-passes,
/// Readability in WebKit, cleanup, sanitize) while the feed's own content:encoded copy is fetched alongside (rss
/// sources, not hnrss). A fuller feed copy (`preferFeed`) beats a cut-short page; when the page fails the feed copy
/// wins; then Jina Reader's rendered copy (`rendered: true`); then the page error is thrown.
/// Caching is done by ContentService.
public struct DefaultContentExtractor: ContentExtractor {
    let parser: any FeedParser
    let extraction: ArticleExtraction
    let session: URLSession

    /// Page fetch timeout (the web used 10 s under a 20 s serverless cap; the native app has no such cap).
    static let extractTimeout: TimeInterval = 15
    static let totalBudget: TimeInterval = 30
    static let renderTimeout: TimeInterval = 12
    static let minRender: TimeInterval = 2
    static let feedTimeout: TimeInterval = 4
    /// Once the page has an article, how much longer the feed copy may take to be weighed against it.
    static let feedGrace: TimeInterval = 0.75
    static let podcastFeedTimeout: TimeInterval = 15

    public init(parser: any FeedParser) {
        self.init(parser: parser, readability: WebKitReadability.shared)
    }

    /// Inject a Readability engine (tests) and a URLSession.
    public init(parser: any FeedParser, readability: any ReadabilityEngine, session: URLSession = HTTP.session) {
        self.parser = parser
        self.extraction = ArticleExtraction(readability: readability)
        self.session = session
    }

    // MARK: ContentExtractor

    public func extractArticle(url: String, feed: FeedRef?) async throws -> ExtractResult {
        if TweetExtraction.tweetURL.test(url) {
            if let t = try? await TweetExtraction.extract(url: url, timeout: Self.extractTimeout, session: session) { return t }
        } else if SocialPosts.network(of: url) != nil {
            let session = session
            let post = await SocialPosts.extract(url: url) { u, h in
                try? await HTTP.fetch(u, timeout: Self.extractTimeout, headers: h, session: session)
            }
            if let post { return post }
        }
        let started = Date()
        // The feed's copy is fetched alongside the page: the fallback when the page fails and the yardstick for a page
        // extraction that came out cut short. hnrss items carry only points and comments, so their feed is skipped.
        let fromFeed: Task<ExtractResult?, Never>? = feed.flatMap { f in
            Self.isHNFeed(f.feedUrl) ? nil : Task { try? await self.extractFromFeed(url: url, feed: f, timeout: Self.feedTimeout) }
        }
        var plain: ExtractResult?
        var plainError: (any Error)?
        do {
            plain = try await extractPlain(url: url)
        } catch {
            plainError = error
        }
        if let page = plain, let pageHTML = page.contentHtml {
            // The page worked: the feed only gets a short grace period.
            if let task = fromFeed, let f = await Self.value(of: task, within: Self.feedGrace),
               Self.preferFeedResult(pageHTML: pageHTML, feed: f) {
                return ExtractResult(contentHtml: f.contentHtml, leadImage: page.leadImage ?? f.leadImage, rendered: f.rendered)
            }
            fromFeed?.cancel()
            return page
        }
        // The page failed or had no article: the feed's full-content HTML beats a rendered copy.
        if let task = fromFeed, let f = await task.value {
            return ExtractResult(contentHtml: f.contentHtml, leadImage: plain?.leadImage ?? f.leadImage, rendered: f.rendered)
        }
        let remaining = Self.totalBudget - Date().timeIntervalSince(started)
        let ms = min(Self.renderTimeout, remaining)
        if url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://"), ms >= Self.minRender {
            if let r = try? await extractRendered(url: url, timeout: ms), let html = r.contentHtml {
                return ExtractResult(contentHtml: html, leadImage: plain?.leadImage ?? r.leadImage ?? ArticlePasses.firstImage(html), rendered: true)
            }
        }
        if let plainError { throw plainError }
        return plain ?? ExtractResult(contentHtml: nil, leadImage: nil)
    }

    /// A podcast episode's show notes from the feed, never the episode page. No lead image.
    public func extractPodcastNotes(url: String, feed: FeedRef) async throws -> ExtractResult {
        let (data, res) = try await HTTP.fetch(feed.feedUrl, timeout: Self.podcastFeedTimeout, headers: ["Accept": HTTP.feedAccept], session: session)
        guard (200..<300).contains(res.statusCode) else { throw ExtractionError.feedStatus(res.statusCode) }
        guard let html = parser.itemHTML(in: data, guid: feed.guid, url: url) else { return ExtractResult(contentHtml: nil, leadImage: nil) }
        return ArticleExtraction.podcastNotes(html, pageURL: url)
    }

    // MARK: Steps

    static let pageAccept = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5"
    private static let htmlOrXML = ExtractionDOM.Pattern("html|xml", caseInsensitive: true)

    func extractPlain(url: String) async throws -> ExtractResult {
        var (data, res) = try await HTTP.fetch(url, timeout: Self.extractTimeout, headers: ["Accept": Self.pageAccept], session: session)
        // Some sites refuse bot User-Agents; retry once as a browser. Cloudflare's JavaScript challenge passes no header
        // change (the Jina fallback handles those).
        if res.statusCode == 401 || res.statusCode == 403, res.value(forHTTPHeaderField: "cf-mitigated") != "challenge" {
            (data, res) = try await HTTP.fetch(url, timeout: Self.extractTimeout, headers: HTTP.browserHeaders, session: session)
        }
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        let ct = res.value(forHTTPHeaderField: "Content-Type") ?? ""
        if !ct.isEmpty && !Self.htmlOrXML.test(ct) { throw ExtractionError.unsupportedContentType(ct) }
        let html = HTTP.text(data, response: res)
        return try await extraction.extract(html: html, pageURL: res.url?.absoluteString ?? url)
    }

    func extractFromFeed(url: String, feed: FeedRef, timeout: TimeInterval) async throws -> ExtractResult? {
        let (data, res) = try await HTTP.fetch(feed.feedUrl, timeout: timeout, headers: ["Accept": HTTP.feedAccept], session: session)
        guard (200..<300).contains(res.statusCode), let html = parser.itemHTML(in: data, guid: feed.guid, url: url) else { return nil }
        let out = ArticleExtraction.extractFromFeedHTML(html, pageURL: url)
        return out.contentHtml == nil ? nil : out
    }

    /// Render a JavaScript-only page via Jina Reader (returns the rendered DOM as HTML) and extract from it.
    func extractRendered(url: String, timeout: TimeInterval) async throws -> ExtractResult? {
        var headers = ["Accept": "text/html", "X-Return-Format": "html"]
        if let key = ProcessInfo.processInfo.environment["JINA_API_KEY"], !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        let (data, res) = try await HTTP.fetch("https://r.jina.ai/\(url)", timeout: timeout, headers: headers, session: session)
        guard (200..<300).contains(res.statusCode) else { return nil }
        let out = try await extraction.extract(html: HTTP.text(data, response: res), pageURL: url)
        guard let html = out.contentHtml, !ArticleExtraction.isLoginWall(html) else { return nil }
        return ExtractResult(contentHtml: html, leadImage: out.leadImage, rendered: true)
    }

    // MARK: Helpers

    static func preferFeedResult(pageHTML: String, feed: ExtractResult) -> Bool {
        ArticleExtraction.preferFeed(pageHTML: pageHTML, feedHTML: feed.contentHtml)
    }

    /// hnrss.org feeds (isHnFeed in parse.ts).
    static func isHNFeed(_ feedURL: String) -> Bool {
        guard let host = ExtractionDOM.hostname(feedURL)?.lowercased() else { return false }
        return host == "hnrss.org" || host.hasSuffix(".hnrss.org")
    }

    /// The task's value, or nil if it hasn't finished within `seconds` (the task is then cancelled).
    static func value<T: Sendable>(of task: Task<T?, Never>, within seconds: TimeInterval) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
