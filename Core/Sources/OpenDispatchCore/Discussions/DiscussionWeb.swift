import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if os(iOS)
import UIKit
#endif

/// The sites a signed-in session counts for. The app's web views share one persistent data store
/// (`WKWebsiteDataStore.default()`), so signing in on the sign-in sheet signs the hidden views in too.
public enum WebAccount: String, Sendable, CaseIterable, Identifiable {
    case x, reddit

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .x: "X"
        case .reddit: "Reddit"
        }
    }

    /// Where the sign-in sheet starts.
    public var signInURL: URL {
        switch self {
        case .x: URL(string: "https://x.com/i/flow/login")!
        case .reddit: URL(string: "https://www.reddit.com/login/")!
        }
    }

    /// The cookie a signed-in session has, and the domains it lives on.
    var sessionCookie: String {
        switch self {
        case .x: "auth_token"
        case .reddit: "reddit_session"
        }
    }

    var domains: [String] {
        switch self {
        case .x: ["x.com", "twitter.com"]
        case .reddit: ["reddit.com"]
        }
    }

    /// The user agent the sign-in sheet and the hidden view present: Safari's, which X expects of a browser it lets sign in.
    public static var browserUserAgent: String {
        #if os(iOS)
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
        #else
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        #endif
    }
}

#if canImport(WebKit)
extension WebAccount {
    /// The data store every OpenDispatch web view that should share a sign-in uses.
    @MainActor public static var dataStore: WKWebsiteDataStore { .default() }

    /// A session cookie for the site is in the app's data store.
    @MainActor public func isSignedIn() async -> Bool {
        let cookies = await Self.dataStore.httpCookieStore.allCookies()
        return cookies.contains { cookie in
            cookie.name == sessionCookie && !cookie.value.isEmpty && domains.contains { cookie.domain.hasSuffix($0) }
                && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
    }

    /// Removes everything the site stored (cookies, storage), which signs the app out of it.
    @MainActor public func signOut() async {
        let store = Self.dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let mine = records.filter { r in domains.contains { r.displayName.hasSuffix($0) } }
        await store.removeData(ofTypes: types, for: mine)
        DiscussionWeb.shared.forget(self)
    }
}

/// Hidden web views that read Reddit and X the way a browser does, for the sites that refuse everything else.
///
/// Reddit: one view sits on reddit.com. Reddit answers a new visitor with a JavaScript challenge, which the view passes
/// by loading a page; after that, pages are fetched from inside it (`fetch` in an isolated content world, so the page's
/// cookies go along and its scripts can't interfere) and handed back as HTML for `RedditPages`. A blocked answer (Reddit's
/// block page, a 403 or 429) loads a page again once before giving up.
///
/// X: X draws everything in the browser, so the view opens the search or the post itself, waits for posts to appear,
/// scrolls a few times (X keeps only the cells near the viewport) and hands back the timeline's cells for `XPages`. It
/// needs the user signed in to X in the app (`WebAccount.x`); one page at a time.
///
/// Images, media and fonts are never loaded. Everything here runs on the main actor; the views are made on first use.
@MainActor
public final class DiscussionWeb: NSObject {
    public static let shared = DiscussionWeb()

    private var reddit: SiteView?
    private var redditReady = false
    /// Post pages fetched in the last few minutes: the reader asks for a post's body and its comments separately.
    private var redditPages: [String: (at: Date, html: String)] = [:]
    private static let pageLifetime: TimeInterval = 180
    private var x: SiteView?
    private var xQueue: Task<Void, Never>?
    private var rules: WKContentRuleList?
    private var rulesLoaded = false

    private static let world = WKContentWorld.world(name: "OpenDispatchDiscussions")

    /// Drops a site's view, so the next use starts fresh (after signing in or out).
    public func forget(_ account: WebAccount) {
        switch account {
        case .reddit:
            reddit = nil
            redditReady = false
        case .x:
            x = nil
        }
    }

    // MARK: Reddit

    /// The HTML at `path` on reddit.com; a POST of `form` (with Reddit's CSRF token added) when it is given.
    func redditHTML(_ path: String, form: [String: String]? = nil) async throws -> String {
        try Self.requireForeground()
        let cached = form == nil && RedditPages.isThread(RedditPages.origin + path)
        if cached, let page = redditPages[path], Date().timeIntervalSince(page.at) < Self.pageLifetime { return page.html }
        for attempt in 0..<2 {
            let view = try await redditView(warmingWith: path, force: attempt > 0)
            let answer = try await fetch(path, form: form, in: view)
            if !Self.isRedditBlock(status: answer.status, text: answer.text) {
                if answer.status == 404 { throw DiscussionError.notFound }
                if cached {
                    redditPages = redditPages.filter { Date().timeIntervalSince($0.value.at) < Self.pageLifetime }
                    redditPages[path] = (Date(), answer.text)
                }
                return answer.text
            }
            redditReady = false
        }
        throw DiscussionError.blocked(.reddit)
    }

    private func redditView(warmingWith path: String, force: Bool) async throws -> SiteView {
        let view = await siteView(.reddit)
        if redditReady && !force { return view }
        // A page load passes the challenge; the page asked for is as good as any.
        let page = path.hasPrefix("/svc/") ? "/" : path
        try await view.load(URL(string: RedditPages.origin + page)!)
        try await view.waitUntil(timeout: 15) { view in
            let state = try await view.call("""
                return document.readyState === "complete" && !document.querySelector("input[name=solution]") && location.hostname.endsWith("reddit.com")
                """, in: Self.world)
            return state as? Bool == true
        }
        redditReady = true
        return view
    }

    nonisolated static func isRedditBlock(status: Int, text: String) -> Bool {
        // The challenge is a small page that solves a puzzle into a "solution" field; every real page also names the
        // challenge in its scripts, so the name alone says nothing.
        status == 403 || status == 429 || text.contains("blocked by network security")
            || (text.utf8.count < 30_000 && text.contains("\"solution\""))
    }

    private func fetch(_ path: String, form: [String: String]?, in view: SiteView) async throws -> (status: Int, text: String) {
        let script = """
            const options = { credentials: "include" };
            if (post) {
              const csrf = (document.cookie.match(/(?:^|; )csrf_token=([^;]+)/) || [])[1] || "";
              const body = new URLSearchParams(form);
              body.set("csrf_token", csrf);
              options.method = "POST";
              options.headers = { "content-type": "application/x-www-form-urlencoded" };
              options.body = body.toString();
            }
            const r = await fetch(path, options);
            return { status: r.status, text: await r.text() };
            """
        let value = try await view.call(script, arguments: ["path": path, "post": form != nil, "form": form ?? [:]], in: Self.world, timeout: 20)
        guard let dict = value as? [String: Any], let text = dict["text"] as? String else { throw DiscussionError.blocked(.reddit) }
        return ((dict["status"] as? NSNumber)?.intValue ?? 0, text)
    }

    // MARK: X

    /// The timeline cells of an X page, after waiting for posts and scrolling `scrolls` times.
    func xCells(_ url: String, scrolls: Int) async throws -> [String] {
        try Self.requireForeground()
        guard await WebAccount.x.isSignedIn() else { throw DiscussionError.signInRequired(.x) }
        let previous = xQueue
        let task = Task { @MainActor () throws -> [String] in
            _ = await previous?.value
            return try await self.readX(url, scrolls: scrolls)
        }
        xQueue = Task { _ = try? await task.value }
        return try await task.value
    }

    private func readX(_ url: String, scrolls: Int) async throws -> [String] {
        let view = await siteView(.x)
        try await view.load(URL(string: url)!)
        var found: [String] = []
        var seen = Set<String>()
        let collect = """
            const wall = location.pathname.startsWith("/i/flow/login") || !!document.querySelector("[data-testid=loginButton]");
            const cells = [...document.querySelectorAll("[data-testid=cellInnerDiv]")].map((c) => {
              const copy = c.cloneNode(true);
              copy.querySelectorAll("svg, style, script, video").forEach((n) => n.remove());
              return copy.outerHTML;
            });
            const empty = !!document.querySelector("[data-testid=emptyState], [data-testid=error-detail]");
            return { wall, empty, cells, posts: document.querySelectorAll("article[data-testid=tweet]").length };
            """
        var wall = false
        var empty = false
        try await view.waitUntil(timeout: 15) { view in
            let r = try await view.call(collect, in: Self.world) as? [String: Any]
            wall = r?["wall"] as? Bool == true
            empty = r?["empty"] as? Bool == true
            return wall || empty || ((r?["posts"] as? NSNumber)?.intValue ?? 0) > 0
        }
        if wall { throw DiscussionError.signInRequired(.x) }
        for step in 0...scrolls {
            if step > 0 {
                _ = try? await view.call("window.scrollBy(0, window.innerHeight * 2); return true;", in: Self.world)
                try await Task.sleep(nanoseconds: 1_200_000_000)
            }
            let r = try await view.call(collect, in: Self.world) as? [String: Any]
            // Cells are keyed by the post they hold; an empty cell (a group's end) by the post before it.
            var last = "start"
            for cell in r?["cells"] as? [String] ?? [] {
                let key = Self.statusKey(cell).map { "post:" + $0 } ?? "after:" + last
                if let id = Self.statusKey(cell) { last = id }
                if seen.insert(key).inserted { found.append(cell) }
            }
        }
        return found
    }

    nonisolated private static let statusHref = ExtractionDOM.Pattern(#"href="(/[^/"]+/status/\d+)""#)

    /// The address of the post a cell holds: the first status link (the one around its time).
    nonisolated static func statusKey(_ cell: String) -> String? {
        guard cell.contains("data-testid=\"tweet\"") else { return nil }
        return statusHref.firstMatch(cell)?[1] ?? nil
    }

    /// A web view's pages don't run while an iPhone app is in the background (a background refresh), so don't start one.
    private static func requireForeground() throws {
        #if os(iOS)
        if UIApplication.shared.applicationState == .background { throw DiscussionError.unavailable }
        #endif
    }

    // MARK: Views

    private func siteView(_ account: WebAccount) async -> SiteView {
        let existing = account == .x ? x : reddit
        if let view = existing, !view.terminated { return view }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebAccount.dataStore
        #if os(iOS)
        config.allowsInlineMediaPlayback = false
        #endif
        config.mediaTypesRequiringUserActionForPlayback = .all
        if let rules = await contentRules() { config.userContentController.add(rules) }
        let view = SiteView(configuration: config, userAgent: account == .x ? WebAccount.browserUserAgent : nil)
        switch account {
        case .x: x = view
        case .reddit:
            reddit = view
            redditReady = false
        }
        return view
    }

    /// Blocks images, media and fonts in the hidden views; nil if WebKit won't compile the rules.
    private func contentRules() async -> WKContentRuleList? {
        if rulesLoaded { return rules }
        let json = #"[{"trigger":{"url-filter":".*","resource-type":["image","media","font"]},"action":{"type":"block"}}]"#
        rules = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "OpenDispatchDiscussions", encodedContentRuleList: json)
        rulesLoaded = true
        return rules
    }
}

/// What a script returned: property-list values (strings, numbers, arrays, dictionaries), which nothing else holds.
struct ScriptValue: @unchecked Sendable {
    let value: Any?
}

/// One hidden web view: loads a page and waits for it, and runs JavaScript with a timeout.
@MainActor
final class SiteView: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private(set) var terminated = false
    private var waiting: CheckedContinuation<Void, any Error>?
    private var loads = 0

    init(configuration: WKWebViewConfiguration, userAgent: String?) {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 1600), configuration: configuration)
        super.init()
        webView.customUserAgent = userAgent
        webView.navigationDelegate = self
    }

    /// Loads `url` and returns once the first page has finished (a challenge page may then move on by itself).
    func load(_ url: URL, timeout: TimeInterval = 20) async throws {
        waiting?.resume(throwing: CancellationError())
        waiting = nil
        loads += 1
        let load = loads
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            waiting = cont
            webView.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.loads == load else { return }
                    self.finish(DiscussionError.unavailable)
                }
            }
        }
    }

    private func finish(_ error: (any Error)?) {
        guard let cont = waiting else { return }
        waiting = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    /// Polls `ready` every 300 ms until it says so; throws after `timeout`.
    func waitUntil(timeout: TimeInterval, _ ready: (SiteView) async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await ready(self)) == true { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw DiscussionError.unavailable
    }

    /// Runs an async function body. The Objective-C entry point (`__callAsyncJavaScript`), as in `ReadabilityWebView`:
    /// the Swift overlay's isn't on iOS 18.
    func call(_ script: String, arguments: [String: Any] = [:], in world: WKContentWorld, timeout: TimeInterval = 10) async throws -> Any? {
        let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ScriptValue, any Error>) in
            var done = false
            webView.__callAsyncJavaScript(script, arguments: arguments, inFrame: nil, in: world) { value, error in
                MainActor.assumeIsolated {
                    guard !done else { return }
                    done = true
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: ScriptValue(value: value)) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated {
                    guard !done else { return }
                    done = true
                    cont.resume(throwing: DiscussionError.unavailable)
                }
            }
        }
        return result.value
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finish(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated {
            // A page that hands over to another before loading (a redirect by script) isn't a failure.
            if (error as NSError).code == NSURLErrorCancelled { return }
            finish(error)
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            terminated = true
            finish(DiscussionError.unavailable)
        }
    }
}
#endif
