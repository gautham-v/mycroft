import Foundation
import Network
import OpenDispatchCore
import WebKit

/// Reads ahead so the next articles open instantly. After the article you opened has loaded, the next
/// few items in the direction you're moving get their text extracted (cached by ContentService) and the
/// nearest ones their images loaded into the reader's HTTP cache (`ReaderWebSupport.articleDataStore`).
/// Saved items get their text in the background so they read offline.
///
/// One job at a time, and only after the open article has its content. Opening anything stops the
/// rest (the job for that very item keeps going and the reader waits on it). On cellular, Low Data
/// Mode or Low Power Mode only the next item's text is fetched, and saved items wait.
@MainActor
final class ArticlePrefetcher {
    /// Items ahead whose text is fetched, and how many of those also get their images.
    static let textAhead = 4
    static let imagesAhead = 2
    /// Saved items without text fetched per launch (or per Save).
    static let savedBatch = 50
    /// Reading ahead waits this long after the article opens, so the article's own images go first and
    /// flicking through with j/k doesn't start (and stop) a fetch per item.
    static let settle: Duration = .seconds(1)

    private struct Job {
        let id: Int64
        let images: Bool
    }

    private let services: OpenDispatchServices
    /// Called with each fetched result, so the list shows the item as having content.
    var onFetched: (Int64, ExtractResult) -> Void = { _, _ in }

    private var ahead: [Job] = []
    private var saved: [Job] = []
    private var worker: Task<Void, Never>?
    /// Bumped by `stop`, so a stopped worker finishing up leaves its successor alone.
    private var generation = 0
    private var running: (id: Int64, task: Task<ExtractResult, any Error>)?
    /// This launch: items whose extraction failed (not retried until you open them) and whose images
    /// are already in the cache.
    private var failed: Set<Int64> = []
    private var warmed: Set<Int64> = []
    private let network = NetworkConditions()
    private let images = ArticleImageWarmer()

    init(services: OpenDispatchServices) {
        self.services = services
    }

    /// Cellular, Low Data Mode or Low Power Mode.
    private var isLimited: Bool { network.isLimited || ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// The extraction already running for `id`, for the reader to wait on instead of starting its own.
    func inFlight(_ id: Int64) -> Task<ExtractResult, any Error>? {
        running?.id == id ? running?.task : nil
    }

    /// The reader is opening `id`: stop everything else so it has the network to itself.
    func stop(except id: Int64) {
        ahead = []
        saved = []
        if let running, running.id != id { running.task.cancel() }
        worker?.cancel()
        worker = nil
        generation += 1
        images.stop()
    }

    /// The article `id` has loaded: read ahead from it in `items`, `step` (1 down the list, -1 up).
    func readAhead(from id: Int64, in items: [FeedItem], step: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let limited = isLimited
        let textCount = limited ? 1 : Self.textAhead
        let imageCount = limited ? 0 : Self.imagesAhead
        var jobs: [Job] = []
        var index = i + (step < 0 ? -1 : 1)
        while jobs.count < textCount, items.indices.contains(index) {
            let item = items[index]
            index += step < 0 ? -1 : 1
            guard item.source.kind != .youtube, !failed.contains(item.id) else { continue }
            let wantsImages = jobs.count < imageCount && item.source.kind != .podcast && !warmed.contains(item.id)
            if item.hasContent && !wantsImages { continue }
            jobs.append(Job(id: item.id, images: wantsImages))
        }
        ahead = jobs
        start(after: Self.settle)
        // Opening the article dropped the saved items still waiting; they follow the ones ahead.
        if !limited { Task { await queueSaved() } }
    }

    /// Saved items without text, newest first.
    func queueSaved() async {
        guard !isLimited else { return }
        let ids = (try? await services.database.reader.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT i.id FROM items i JOIN sources s ON s.id = i.source_id
                WHERE i.is_saved = 1 AND i.content_html IS NULL AND s.kind != 'youtube'
                ORDER BY i.published_at DESC LIMIT ?
                """, arguments: [Self.savedBatch])
        }) ?? []
        saved = ids.filter { !failed.contains($0) && $0 != running?.id }.map { Job(id: $0, images: false) }
        start(after: Self.settle)
    }

    private func start(after delay: Duration = .zero) {
        guard worker == nil, !ahead.isEmpty || !saved.isEmpty else { return }
        let gen = generation
        worker = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            await self?.work()
            guard let self, gen == generation else { return }
            worker = nil
            images.stop()
        }
    }

    private func next() -> Job? {
        if !ahead.isEmpty { return ahead.removeFirst() }
        if !saved.isEmpty { return saved.removeFirst() }
        return nil
    }

    private func work() async {
        while !Task.isCancelled, let job = next() {
            let content = services.content
            let task = Task { try await content.content(forItem: job.id) }
            running = (job.id, task)
            let result = try? await task.value
            if running?.task == task { running = nil }
            guard let result, result.contentHtml != nil else {
                if !Task.isCancelled { failed.insert(job.id) }
                continue
            }
            onFetched(job.id, result)
            guard job.images, !Task.isCancelled, let html = result.contentHtml,
                  let item = try? await services.database.feedItem(id: job.id) else { continue }
            await images.warm(html: html, hero: Self.hero(item, html: html, lead: result.leadImage), baseURL: URL(string: item.item.url))
            if !Task.isCancelled { warmed.insert(job.id) }
        }
    }

    /// The hero the reader will draw above `html` (ReaderView.visibleHero), so it is cached too.
    private static func hero(_ item: FeedItem, html: String, lead: String?) -> String? {
        guard !TextFormat.isXPost(item.item.url) else { return nil }
        let art = item.item.thumbnailUrl.flatMap { $0.isEmpty ? nil : $0 } ?? lead
        guard let art, !ReaderText.contentHasHero(html, hero: art) else { return nil }
        return art
    }
}

/// Loads an article's images in a hidden web view on the reader's data store, so the reader finds them
/// in the HTTP cache. The page is the reader's own document at the reader's width, so `srcset` picks
/// the same image; lazy images are made eager, and embeds, video and audio are left out.
@MainActor
final class ArticleImageWarmer: NSObject, WKNavigationDelegate {
    /// The article web view's width, which `srcset` and `sizes` are resolved against.
    static var viewportWidth: CGFloat = 800
    /// A page whose images never finish (a hung host) is given up on after this long.
    static let timeout: Duration = .seconds(20)

    private var webView: WKWebView?
    private var done: CheckedContinuation<Void, Never>?
    private var page = 0

    private static let embeds = try? NSRegularExpression(pattern: #"<(iframe|video|audio)\b[\s\S]*?</\1\s*>"#, options: .caseInsensitive)

    func warm(html: String, hero: String?, baseURL: URL?) async {
        let view = webView ?? makeWebView()
        let width = Self.viewportWidth
        if view.frame.width != width { view.frame = CGRect(x: 0, y: 0, width: width, height: 1000) }
        var body = html.replacingOccurrences(of: "loading=\"lazy\"", with: "loading=\"eager\"")
        if let embeds = Self.embeds {
            body = embeds.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
        }
        // Layout doesn't matter: `srcset` and `sizes` depend only on the width.
        let appearance = ReaderHTML.Appearance(font: .serif, size: .m, leading: .normal, theme: .system, wide: true, columnWidth: nil)
        view.loadHTMLString(ReaderHTML.document(body: body, hero: hero, appearance: appearance), baseURL: baseURL)
        page += 1
        let current = page
        await withCheckedContinuation { cont in
            done = cont
            Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                if let self, page == current { finish() }
            }
        }
    }

    /// Frees the web view (and its web content process) once the queue is done or stopped.
    func stop() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        finish()
    }

    private func finish() {
        done?.resume()
        done = nil
    }

    private func makeWebView() -> WKWebView {
        let config = ReaderWebSupport.configuration(autoplay: false, dataStore: ReaderWebSupport.articleDataStore)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.viewportWidth, height: 1000), configuration: config)
        view.navigationDelegate = self
        webView = view
        return view
    }

    // The load event waits for the images.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { stop() }

    /// Nothing in the page navigates: no scripts run and nothing is clicked.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
    }
}

/// Cellular or Low Data Mode, from the system's current network path.
@MainActor
private final class NetworkConditions {
    private(set) var isLimited = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let limited = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.isLimited = limited }
        }
        monitor.start(queue: .global(qos: .utility))
    }
}
