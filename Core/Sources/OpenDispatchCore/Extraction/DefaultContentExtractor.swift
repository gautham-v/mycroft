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
/// Order for an article: X posts first (status page data, then oEmbed), a Reddit post or Hacker News item from
/// `DiscussionContent`, an MSN article from its content API (`MSNArticle`), an Apple documentation page from its DocC JSON
/// (`AppleDocumentation`), a Stack Exchange question from the sites' API (`StackExchangeQuestion`), an arXiv PDF link as its
/// abstract page; otherwise the page is fetched (403/401 retried
/// once with browser headers unless Cloudflare's challenge) and run through `ArticleExtraction` (pre-passes,
/// Readability in WebKit, cleanup, sanitize) while the feed's own content:encoded copy is fetched alongside (rss
/// sources, not hnrss). A fuller feed copy (`preferFeed`) beats a cut-short page; when the page fails the feed copy
/// wins; then Jina Reader's rendered copy (`rendered: true`); then the page error is thrown.
/// A site the reader has signed in to (`SiteSignIns`) is read first in a hidden web view that carries the sign-in
/// (`SignedInPages`); a full article from it is the result, anything else carries on with the steps above. The page and a
/// rendered copy are checked by `PaywallDetection` and come back `paywalled` when they are only the teaser; the feed's own copy
/// and posts never do.
/// Caching is done by ContentService.
public struct DefaultContentExtractor: ContentExtractor {
    let parser: any FeedParser
    let extraction: ArticleExtraction
    let session: URLSession
    let signedIn: SignedInReader

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

    /// Inject a Readability engine (tests), a URLSession and how signed-in sites are read.
    public init(parser: any FeedParser, readability: any ReadabilityEngine, session: URLSession = HTTP.session,
                signedIn: SignedInReader = .live) {
        self.parser = parser
        self.extraction = ArticleExtraction(readability: readability)
        self.session = session
        self.signedIn = signedIn
    }

    // MARK: ContentExtractor

    public func extractArticle(url: String, feed: FeedRef?) async throws -> ExtractResult {
        var out = try await extractArticleContent(url: url, feed: feed)
        // Posts embedded in the article (X, Bluesky, Instagram, TikTok…) are drawn as posts, video and all (`EmbeddedPosts`).
        if let html = out.contentHtml, !Self.isPost(url) {
            let session = session
            out.contentHtml = await EmbeddedPosts.expand(html) { u, headers in
                try? await HTTP.fetch(u, timeout: EmbeddedPosts.timeout, headers: headers, session: session)
            }
        }
        return out
    }

    static func isPost(_ url: String) -> Bool {
        TweetExtraction.tweetURL.test(url) || SocialPosts.network(of: url) != nil
            || DiscussionPlace.thread(of: url).map { $0 == .reddit || $0 == .hackerNews } == true
    }

    func extractArticleContent(url: String, feed: FeedRef?) async throws -> ExtractResult {
        let isPost = Self.isPost(url)
        if !isPost, signedIn.isSignedIn(url), let page = await extractSignedIn(url: url) { return page }
        if TweetExtraction.tweetURL.test(url) {
            if let t = try? await TweetExtraction.extract(url: url, timeout: Self.extractTimeout, session: session) { return t }
        } else if let place = DiscussionPlace.thread(of: url), place == .reddit || place == .hackerNews {
            let session = session
            let post = await DiscussionContent.extract(url: url) { u in
                let (data, res) = try await HTTP.fetch(u, timeout: Self.extractTimeout, headers: ["Accept": "application/json"], session: session)
                guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
                return data
            }
            if let post { return post }
        } else if SocialPosts.network(of: url) != nil {
            let session = session
            let post = await SocialPosts.extract(url: url) { u, h in
                try? await HTTP.fetch(u, timeout: Self.extractTimeout, headers: h, session: session)
            }
            if let post { return post }
        } else if let api = MSNArticle.apiURL(url) {
            if let (data, res) = try? await HTTP.fetch(api, timeout: Self.extractTimeout, headers: ["Accept": "application/json"], session: session),
               (200..<300).contains(res.statusCode), let article = MSNArticle.render(data, pageURL: url) { return article }
        } else if let api = AppleDocumentation.apiURL(url) {
            if let (data, res) = try? await HTTP.fetch(api, timeout: Self.extractTimeout, headers: ["Accept": "application/json"], session: session),
               (200..<300).contains(res.statusCode), let page = AppleDocumentation.render(data, pageURL: url) { return page }
        } else if StackExchangeQuestion.question(url) != nil {
            let session = session
            let post = await StackExchangeQuestion.extract(url: url) { u in
                let (data, res) = try await HTTP.fetch(u, timeout: Self.extractTimeout, headers: ["Accept": "application/json"], session: session)
                guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
                return data
            }
            if let post { return post }
        } else if let abstract = ArticlePasses.arxivAbstractURL(forPDF: url) {
            // A paper's PDF can't be read; its abstract page can.
            if let page = try? await extractPlain(url: abstract), page.contentHtml != nil { return page }
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
                // The page's audio (`SiteAudio`) still leads the feed's text.
                let audio = SiteAudio.audio(in: pageHTML).map(SiteAudio.marker) ?? ""
                return ExtractResult(contentHtml: f.contentHtml.map { audio + $0 }, leadImage: page.leadImage ?? f.leadImage, rendered: f.rendered)
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
                return ExtractResult(contentHtml: html, leadImage: plain?.leadImage ?? r.leadImage ?? ArticlePasses.firstImage(html), rendered: true,
                                     paywalled: r.paywalled)
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
        guard (200..<300).contains(res.statusCode) else {
            // The site's own "subscribers only" page (LWN answers 403), not a bot check: the article is walled.
            if [401, 402, 403].contains(res.statusCode), let wall = PaywallDetection.wallResponse(HTTP.text(data, response: res)) { return wall }
            throw HTTPError.status(res.statusCode)
        }
        let ct = res.value(forHTTPHeaderField: "Content-Type") ?? ""
        if !ct.isEmpty && !Self.htmlOrXML.test(ct) { throw ExtractionError.unsupportedContentType(ct) }
        let html = HTTP.text(data, response: res)
        let pageURL = res.url?.absoluteString ?? url
        var out = try await extraction.extract(html: html, pageURL: pageURL)
        out.paywalled = PaywallDetection.isWalled(pageHTML: html, articleHTML: out.contentHtml, url: url)
        // A story the page only starts and its scripts finish (`hasUnfilledPrivateContent`): the rendered copy is the story.
        if ArticlePasses.hasUnfilledPrivateContent(html), let r = try? await extractRendered(url: url, timeout: Self.renderTimeout),
           let full = r.contentHtml, ExtractionDOM.plainText(full).count > 2 * ExtractionDOM.plainText(out.contentHtml).count {
            return ExtractResult(contentHtml: full, leadImage: out.leadImage ?? r.leadImage, rendered: true, paywalled: r.paywalled)
        }
        return out
    }

    /// The article as the signed-in reader sees it, or nil when the page didn't load, has no article, or is still walled
    /// (the sign-in lapsed): the page is then fetched as for anyone.
    func extractSignedIn(url: String) async -> ExtractResult? {
        guard let html = await signedIn.html(url), let out = try? await extraction.extract(html: html, pageURL: url),
              out.contentHtml != nil, !PaywallDetection.isWalled(pageHTML: html, articleHTML: out.contentHtml, url: url) else { return nil }
        return out
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
        let page = HTTP.text(data, response: res)
        let out = try await extraction.extract(html: page, pageURL: url)
        // A bot check, a login wall, or only the page's footer (Reuters' rendered copy: "Apps Newsletters Advertise…").
        guard let html = out.contentHtml, !ArticleExtraction.isLoginWall(html), ArticleExtraction.hasProse(html) else { return nil }
        return ExtractResult(contentHtml: html, leadImage: out.leadImage, rendered: true,
                             paywalled: PaywallDetection.isWalled(pageHTML: page, articleHTML: html, url: url))
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
