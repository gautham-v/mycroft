import Foundation

/// How `DefaultContentExtractor` reads a site the reader has signed in to: whether a URL's site is one, and the page's HTML as
/// that sign-in sees it (nil when it couldn't be loaded). Injected so tests need no WebKit.
public struct SignedInReader: Sendable {
    public var isSignedIn: @Sendable (String) -> Bool
    public var html: @Sendable (String) async -> String?

    public init(isSignedIn: @escaping @Sendable (String) -> Bool, html: @escaping @Sendable (String) async -> String?) {
        self.isSignedIn = isSignedIn
        self.html = html
    }

    /// The sites in `SiteSignIns`, read in a hidden web view (`SignedInPages`). Without WebKit nothing is signed in.
    public static let live = SignedInReader(
        isSignedIn: { SiteSignIns.contains(url: $0) },
        html: { url in
            #if canImport(WebKit)
            await SignedInPages.shared.html(of: url)
            #else
            nil
            #endif
        })
}

#if canImport(WebKit)
import WebKit

/// A hidden web view that opens an article the way the reader's browser would: on the app's shared web data store, so the
/// sign-in from the sign-in sheet goes along, with JavaScript on (paywall scripts often swap the content in after the page
/// loads, so the page is given a moment to settle). Images, media and fonts are never loaded. One view is reused and pages are
/// read one at a time; each waits its turn inside its own timeout.
@MainActor
public final class SignedInPages {
    public static let shared = SignedInPages()

    /// How long after the page finishes loading its scripts get before the DOM is read.
    static let settle: TimeInterval = 1
    /// The longest a page may take to load and settle, from the moment it is its turn.
    static let timeout: TimeInterval = 15

    private var view: SiteView?
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    /// The page's DOM as HTML once it has loaded and settled, or nil when it didn't load in time.
    public func html(of url: String) async -> String? {
        guard let target = URL(string: url), let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        let view = await currentView()
        do {
            let started = Date()
            try await view.load(target, timeout: Self.timeout)
            let rest = min(Self.settle, Self.timeout - Date().timeIntervalSince(started))
            if rest > 0 { try await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000)) }
            let out = try await view.call("return document.documentElement.outerHTML", in: .page, timeout: 5)
            // Leave the page, so a paywall script doesn't keep running in the background.
            view.webView.load(URLRequest(url: URL(string: "about:blank")!))
            return (out as? String).flatMap { $0.isEmpty ? nil : $0 }
        } catch {
            return nil
        }
    }

    /// Drops the view, so the next page starts with whatever sign-in the data store has now (after signing in or out).
    public func forget() { view = nil }

    private func currentView() async -> SiteView {
        if let view, !view.terminated { return view }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebAccount.dataStore
        #if os(iOS)
        config.allowsInlineMediaPlayback = false
        #endif
        config.mediaTypesRequiringUserActionForPlayback = .all
        if let rules = await DiscussionWeb.shared.contentRules() { config.userContentController.add(rules) }
        let made = SiteView(configuration: config, userAgent: WebAccount.browserUserAgent)
        view = made
        return made
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }
}
#endif
