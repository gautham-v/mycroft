import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// Runs Mozilla Readability over a prepared page and returns `article.content` (nil when it finds no article).
/// The production engine is `WebKitReadability`; tests inject a fake (see ArticleExtraction).
public protocol ReadabilityEngine: Sendable {
    /// `html`: the whole prepared document. `baseURL`: absolute URL relative links resolve against.
    func articleContent(html: String, baseURL: String) async throws -> String?
}

public enum ReadabilityError: Error, LocalizedError, Equatable {
    case scriptMissing
    case unavailable
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .scriptMissing: "Readability.js is missing from the app bundle"
        case .unavailable: "Article parser is unavailable"
        case .timedOut: "Article parsing timed out"
        case .failed(let why): "Article parsing failed: \(why)"
        }
    }
}

/// Readability.js in a hidden, non-persistent WKWebView on the main actor.
///
/// The web view loads an empty page once; Readability.js is injected as a user script into a private content world
/// (the page's own JavaScript is disabled). Each call parses the prepared HTML with `DOMParser` inside that world
/// (no scripts run, no subresources load), adds a `<base href>` so relative URLs resolve against the article URL,
/// and runs `new Readability(doc, { charThreshold: 200 }).parse()`. Calls may overlap: JavaScript runs them one at
/// a time on the web view's thread. If the web content process dies, the next call builds a new web view.
///
/// Needs a running app (WebKit's helper processes); under `swift test` use a fake engine.
public struct WebKitReadability: ReadabilityEngine {
    public static let shared = WebKitReadability()
    /// Upper bound for one Readability run (large pages take well under a second).
    public var timeout: TimeInterval = 10

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func articleContent(html: String, baseURL: String) async throws -> String? {
        #if canImport(WebKit)
        return try await ReadabilityWebView.shared.run(html: html, baseURL: baseURL, timeout: timeout)
        #else
        throw ReadabilityError.unavailable
        #endif
    }
}

#if canImport(WebKit)
@MainActor
final class ReadabilityWebView: NSObject, WKNavigationDelegate {
    static let shared = ReadabilityWebView()

    private var webView: WKWebView?
    private var loaded = false
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    private static let world = WKContentWorld.world(name: "OpenfeedReadability")

    /// The per-call function body (callAsyncJavaScript); `html` and `base` arrive as arguments.
    private static let runScript = """
    if (typeof Readability !== "function") { throw new Error("Readability not loaded"); }
    const doc = new DOMParser().parseFromString(html, "text/html");
    doc.querySelectorAll("base").forEach((b) => b.remove());
    const baseEl = doc.createElement("base");
    baseEl.setAttribute("href", base);
    (doc.head || doc.documentElement).prepend(baseEl);
    const article = new Readability(doc, { charThreshold: 200 }).parse();
    return article && article.content ? String(article.content) : null;
    """

    func run(html: String, baseURL: String, timeout: TimeInterval) async throws -> String? {
        let view = try await readyWebView()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, any Error>) in
            var finished = false
            let finish: @MainActor (Result<String?, any Error>) -> Void = { result in
                guard !finished else { return }
                finished = true
                cont.resume(with: result)
            }
            // The Objective-C entry point (`__callAsyncJavaScript`), not the Swift overlay's Result-based
            // one: the overlay lives in libswiftWebKit.dylib, which iOS 18 doesn't ship, so building with
            // the iOS 26 SDK and calling it makes the app fail to launch on iOS 18 ("Library missing").
            view.__callAsyncJavaScript(Self.runScript, arguments: ["html": html, "base": baseURL], inFrame: nil, in: Self.world) { value, error in
                MainActor.assumeIsolated {
                    if let error {
                        finish(.failure(ReadabilityError.failed(error.localizedDescription)))
                    } else if let s = value as? String, !s.isEmpty {
                        finish(.success(s))
                    } else {
                        finish(.success(nil))
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard !finished else { return }
                    finish(.failure(ReadabilityError.timedOut))
                    // A stuck run would block later ones: start over with a fresh web view.
                    self?.reset()
                }
            }
        }
    }

    private func readyWebView() async throws -> WKWebView {
        if let webView, loaded { return webView }
        if webView == nil { try makeWebView() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            if loaded { cont.resume() } else { waiters.append(cont) }
        }
        guard let webView else { throw ReadabilityError.unavailable }
        return webView
    }

    private func makeWebView() throws {
        guard let script = BundledResources.readabilityJS() else { throw ReadabilityError.scriptMissing }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world)
        )
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view.navigationDelegate = self
        webView = view
        loaded = false
        view.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>", baseURL: nil)
        // An empty page loads in milliseconds; never leave callers waiting on one that doesn't.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view, self.webView === view, !self.loaded else { return }
                self.reset()
            }
        }
    }

    private func reset() {
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        loaded = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(throwing: ReadabilityError.unavailable) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard webView === self.webView else { return }
            loaded = true
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { if webView === self.webView { reset() } }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { if webView === self.webView { reset() } }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { if webView === self.webView { reset() } }
    }
}
#endif
