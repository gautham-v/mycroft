import Foundation

/// One HTTP GET made by the scraper. `headOnly` asks for the body only up to `</head>` (or
/// `PageMeta.maxHeadBytes`), and no body at all for non-2xx or non-HTML responses.
public struct PageFetchRequest: Sendable, Hashable {
    public var url: String
    public var timeout: TimeInterval
    public var headers: [String: String]
    public var headOnly: Bool

    public init(url: String, timeout: TimeInterval, headers: [String: String] = [:], headOnly: Bool = false) {
        self.url = url
        self.timeout = timeout
        self.headers = headers
        self.headOnly = headOnly
    }
}

/// The scraper's transport: returns the body and the final response (its `url` is the URL after redirects).
/// Does not throw on non-2xx. The default is `DefaultPageScraper.liveFetch` (HTTP.session); tests inject fakes.
public typealias PageScraperFetch = @Sendable (PageFetchRequest) async throws -> (Data, HTTPURLResponse)

public enum PageScraperError: Error, LocalizedError, Equatable {
    case noArticleLinks

    public var errorDescription: String? {
        switch self {
        case .noArticleLinks: "No article links found on the page"
        }
    }
}

/// Scraped-page sources and page share images (port of src/lib/scrape.ts `scrapePage` and
/// src/lib/page-meta.ts `fetchPageImage`). Pure parsing lives in `PageScraping` and `PageMeta`.
public struct DefaultPageScraper: PageScraper {
    static let listingTimeout: TimeInterval = 15
    static let articleTimeout: TimeInterval = 10
    static let concurrency = 4
    /// Stop starting new article fetches after this; the rest are picked up next refresh.
    static let defaultBudget: TimeInterval = 25
    static let scrapeAccept = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5"

    private let fetch: PageScraperFetch

    public init() {
        self.fetch = DefaultPageScraper.liveFetch
    }

    /// Inject a transport (tests, previews).
    public init(fetch: @escaping PageScraperFetch) {
        self.fetch = fetch
    }

    // MARK: - Pure

    public func findArticleLinks(html: String, pageURL: String) -> [String] {
        PageScraping.findArticleLinks(html: html, pageURL: pageURL)
    }

    public func listingTitle(html: String, pageURL: String) -> String {
        PageScraping.listingTitle(html: html, pageURL: pageURL)
    }

    // MARK: - Scrape

    private static var htmlHeaders: [String: String] {
        ["Accept": scrapeAccept, "Accept-Language": "en-US,en;q=0.9"]
    }

    private enum ArticleOutcome: Sendable {
        /// Built an item.
        case item(ParsedItem)
        /// Handled without an item (not an article, gone, not HTML): mark seen.
        case skipped
        /// Temporary failure (timeout, network, 5xx): retry next refresh.
        case retry
    }

    /// Scrape a listing page: find article links, then fetch only those not in `known` (bounded
    /// concurrency and time budget) and turn them into items. Items without a date get the
    /// first-seen time, offset by page order so the listing order holds.
    public func scrape(listingURL: String, known: Set<String>, budget: TimeInterval?) async throws -> ScrapeResult {
        let (data, res) = try await fetch(PageFetchRequest(url: listingURL, timeout: Self.listingTimeout, headers: Self.htmlHeaders))
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        let finalURL = res.url?.absoluteString ?? listingURL
        let links = PageScraping.findArticleLinks(html: HTTP.text(data, response: res), pageURL: finalURL)
        guard !links.isEmpty else { throw PageScraperError.noArticleLinks }

        let todo = links.filter { !known.contains($0) }
        let deadline = Date().addingTimeInterval(budget ?? Self.defaultBudget)
        let now = Date()
        var order: [String: Int] = [:]
        for (i, l) in links.enumerated() where order[l] == nil { order[l] = i }
        let fetch = self.fetch

        let outcomes = await withTaskGroup(of: (String, ArticleOutcome).self) { group -> [String: ArticleOutcome] in
            var next = 0
            func startNext() -> Bool {
                guard next < todo.count, Date() < deadline else { return false }
                let url = todo[next]
                let fallbackDate = now.addingTimeInterval(-Double(order[url] ?? 0))
                next += 1
                group.addTask { (url, await Self.article(url, fallbackDate: fallbackDate, now: now, fetch: fetch)) }
                return true
            }
            for _ in 0..<min(Self.concurrency, todo.count) where !startNext() { break }
            var out: [String: ArticleOutcome] = [:]
            while let (url, outcome) = await group.next() {
                out[url] = outcome
                _ = startNext()
            }
            return out
        }

        var items: [ParsedItem] = []
        var processed: [String] = []
        for url in todo {
            switch outcomes[url] {
            case .item(let item):
                items.append(item)
                processed.append(url)
            case .skipped:
                processed.append(url)
            case .retry, nil:
                break
            }
        }
        return ScrapeResult(listingUrl: finalURL, links: links, items: items, processed: processed)
    }

    private static func isHTMLish(_ res: HTTPURLResponse) -> Bool {
        guard let ct = res.value(forHTTPHeaderField: "Content-Type"), !ct.isEmpty else { return true }
        let l = ct.lowercased()
        return l.contains("html") || l.contains("xml")
    }

    private static func article(_ url: String, fallbackDate: Date, now: Date, fetch: PageScraperFetch) async -> ArticleOutcome {
        do {
            let (data, res) = try await fetch(PageFetchRequest(url: url, timeout: articleTimeout, headers: htmlHeaders))
            guard (200..<300).contains(res.statusCode) else {
                // Gone or forbidden: don't retry every refresh. 5xx: try again next time.
                return res.statusCode < 500 ? .skipped : .retry
            }
            guard isHTMLish(res) else { return .skipped }
            let m = PageScraping.extractArticleMeta(html: HTTP.text(data, response: res), pageURL: res.url?.absoluteString ?? url, now: now)
            // A category/landing page that slipped past the link heuristic.
            if let type = m.ogType, type != "article", m.publishedAt == nil { return .skipped }
            return .item(ParsedItem(
                guid: url,
                url: url,
                title: m.title ?? url,
                summary: m.summary,
                author: m.author,
                publishedAt: m.publishedAt ?? fallbackDate,
                thumbnailUrl: m.thumbnailUrl,
                quoteAvatarUrl: m.quoteAvatarUrl
            ))
        } catch {
            return .retry  // timeout / network: retry next refresh
        }
    }

    // MARK: - Page image

    private static func transient(_ status: Int) -> Bool { status == 429 || status >= 500 }

    /// The share image (og:image and friends) of an article page, reading only its <head>.
    /// 401/403 (bot walls) fall back to Jina Reader's metadata. Never throws: a timeout or network
    /// error is a final miss, so slow sites aren't retried forever.
    public func fetchPageImage(url: String, timeout: TimeInterval) async -> PageImageResult {
        let deadline = Date().addingTimeInterval(timeout)
        var headers = HTTP.browserHeaders
        headers["Accept"] = Self.scrapeAccept
        do {
            let (data, res) = try await fetch(PageFetchRequest(url: url, timeout: timeout, headers: headers, headOnly: true))
            if res.statusCode == 401 || res.statusCode == 403 {
                return try await jinaImage(url, deadline: deadline)
            }
            guard (200..<300).contains(res.statusCode) else {
                return PageImageResult(image: nil, final: !Self.transient(res.statusCode))
            }
            guard Self.isHTMLish(res) else { return PageImageResult(image: nil, final: true) }
            let image = PageMeta.imageFromHTML(HTTP.text(data, response: res), pageURL: res.url?.absoluteString ?? url)
            return PageImageResult(image: image, final: true)
        } catch {
            return PageImageResult(image: nil, final: true)
        }
    }

    /// Jina Reader's JSON output carries the page's meta tags as `metadata`; targeting <head> keeps the
    /// response to a few KB. Used for pages that refuse plain fetches (Cloudflare 403).
    private func jinaImage(_ url: String, deadline: Date) async throws -> PageImageResult {
        let headers = ["Accept": "application/json", "X-Target-Selector": "head", "X-Retain-Images": "none"]
        let remaining = max(0.001, deadline.timeIntervalSinceNow)
        let (data, res) = try await fetch(PageFetchRequest(url: "https://r.jina.ai/\(url)", timeout: remaining, headers: headers))
        guard (200..<300).contains(res.statusCode) else {
            return PageImageResult(image: nil, final: !Self.transient(res.statusCode))
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let payload = body?["data"] as? [String: Any]
        guard let meta = payload?["metadata"] as? [String: Any] else { return PageImageResult(image: nil, final: true) }
        let image = PageMeta.imageFromMetaMap(meta, pageURL: ScrapingText.str(payload?["url"]) ?? url)
        return PageImageResult(image: image, final: true)
    }

    // MARK: - Transport

    /// The live transport: HTTP.fetch for full bodies; a streamed read that stops at `</head>` for `headOnly`.
    public static let liveFetch: PageScraperFetch = { req in
        guard req.headOnly else {
            return try await HTTP.fetch(req.url, timeout: req.timeout, headers: req.headers)
        }
        return try await withDeadline(req.timeout) { try await fetchHead(req) }
    }

    private static func fetchHead(_ req: PageFetchRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: req.url), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw HTTPError.invalidURL(req.url)
        }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: req.timeout)
        r.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in req.headers { r.setValue(v, forHTTPHeaderField: k) }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await HTTP.session.bytes(for: r)
        } catch let e as URLError where e.code == .timedOut {
            throw HTTPError.timedOut
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.notHTTP }
        guard (200..<300).contains(http.statusCode), isHTMLish(http) else {
            bytes.task.cancel()
            return (Data(), http)
        }
        var buf: [UInt8] = []
        buf.reserveCapacity(32_768)
        do {
            for try await b in bytes {
                buf.append(b)
                if b == UInt8(ascii: ">"), let end = headEnd(buf) {
                    buf.removeSubrange(end...)
                    break
                }
                if buf.count >= PageMeta.maxHeadBytes { break }
            }
        } catch let e as URLError where e.code == .timedOut {
            if buf.isEmpty { throw HTTPError.timedOut }
        }
        bytes.task.cancel()
        return (Data(buf), http)
    }

    /// When `buf` ends with `</head\s*>`, the index where `</head` starts.
    static func headEnd(_ buf: [UInt8]) -> Int? {
        var i = buf.count - 2  // before the ">"
        while i >= 0, [0x20, 0x09, 0x0A, 0x0D, 0x0C].contains(buf[i]) { i -= 1 }
        let tag = Array("</head".utf8)
        let start = i - tag.count + 1
        guard start >= 0 else { return nil }
        for j in 0..<tag.count {
            var c = buf[start + j]
            if c >= 0x41 && c <= 0x5A { c += 0x20 }
            if c != tag[j] { return nil }
        }
        return start
    }

    /// Run `body`, throwing HTTPError.timedOut if it hasn't finished within `seconds` (headers and body).
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw HTTPError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw HTTPError.timedOut }
            return first
        }
    }
}

/// One `fetchPageImages` result.
public struct PageImageFetch: Sendable, Hashable {
    public var target: ThumbnailTarget
    public var result: PageImageResult

    public init(target: ThumbnailTarget, result: PageImageResult) {
        self.target = target
        self.result = result
    }
}

extension PageScraper {
    /// fetchPageImages (page-meta.ts): share images for `targets` with bounded concurrency, stopping new
    /// fetches once `budget` is spent. Unstarted targets are left out of the result (they count as untried).
    /// Results are in completion order.
    public func fetchPageImages(
        _ targets: [ThumbnailTarget], concurrency: Int = 4, timeout: TimeInterval = PageMeta.thumbTimeout, budget: TimeInterval = 20
    ) async -> [PageImageFetch] {
        let stopAt = Date().addingTimeInterval(budget)
        return await withTaskGroup(of: PageImageFetch.self) { group in
            var next = 0
            func startNext() -> Bool {
                guard next < targets.count, Date() < stopAt else { return false }
                let t = targets[next]
                next += 1
                group.addTask { PageImageFetch(target: t, result: await self.fetchPageImage(url: t.url, timeout: timeout)) }
                return true
            }
            for _ in 0..<min(max(1, concurrency), targets.count) where !startNext() { break }
            var out: [PageImageFetch] = []
            while let r = await group.next() {
                out.append(r)
                _ = startNext()
            }
            return out
        }
    }
}
