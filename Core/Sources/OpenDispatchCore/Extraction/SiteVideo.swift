import Foundation
import SwiftSoup
#if canImport(WebKit)
import WebKit
#endif

/// A page whose story is a video the site's own player loads with script (NFL.com's /videos/ pages): the server HTML
/// has a poster and a blurb, and the stream comes from a token-protected API, signed and good for a few hours. The
/// extraction keeps the blurb and marks the content; the reader shows the poster with a play button and, on play,
/// `SiteVideoResolver` opens the page in a hidden web view, lets the site's player fetch the stream, and plays it.
public enum SiteVideo {
    private typealias DOM = ExtractionDOM
    private typealias P = ExtractionDOM.Pattern

    /// Leads the content of a site video page. A comment, so anything that doesn't know it shows just the blurb.
    public static let marker = "<!--opendispatch:site-video-->"
    /// More extracted text than this is an article that happens to sit under /video/.
    static let maxText = 600

    private static let videoPath = P("/videos?/", caseInsensitive: true)
    private static let videoType = P("^video\\b", caseInsensitive: true)

    public static func isMarked(_ html: String?) -> Bool { html?.hasPrefix(marker) == true }

    /// The page is a video page (a /video/ or /videos/ address, or og:type video.*) with a poster, and neither the
    /// page (`pagePlayer`: a <video> with a file, checked before the extraction's passes) nor the extraction has a
    /// player of its own, and the extraction has little text.
    static func isVideoPage(_ document: Element, pageURL: String, pagePlayer: Bool, content: String?, poster: String?) -> Bool {
        guard poster != nil, !pagePlayer else { return false }
        let ogType = DOM.first(document, "meta[property=og:type]").flatMap { DOM.attr($0, "content") } ?? ""
        let path = URL(string: pageURL)?.path ?? ""
        guard videoPath.test(path) || videoType.test(ogType) else { return false }
        if let content, content.contains("<video") || content.contains("<iframe") { return false }
        return DOM.plainText(content).count <= maxText
    }

    /// The page has a <video> that plays a file without script.
    static func hasPagePlayer(_ document: Element) -> Bool {
        DOM.select(document, "video[src], video source[src]").contains { !(DOM.attr($0, "src") ?? "").hasPrefix("blob:") }
    }

    /// The page's own description of the video: JSON-LD `description` (HTML), else og:description.
    static func description(_ document: Element) -> String? {
        for script in DOM.select(document, "script[type=application/ld+json]") {
            guard let data = script.data().data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let objects = (json as? [[String: Any]]) ?? [json as? [String: Any]].compactMap { $0 }
            for o in objects {
                if let d = o["description"] as? String, !DOM.plainText(d).isEmpty { return d }
            }
        }
        let og = DOM.first(document, "meta[property=og:description]").flatMap { DOM.attr($0, "content") }
            ?? DOM.first(document, "meta[name=description]").flatMap { DOM.attr($0, "content") }
        guard let og, !DOM.squash(og).isEmpty else { return nil }
        return "<p>\(DOM.escapeHTML(DOM.squash(og)))</p>"
    }

    /// The marked content: the marker, then the description.
    static func content(_ document: Element) -> String {
        let blurb = description(document).map { ArticleSanitizer.sanitize($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return marker + blurb
    }
}

#if canImport(WebKit)
/// Finds the stream a site's own player plays: the page loads in a hidden web view (muted, autoplay allowed, the
/// app's shared data store) with a script that watches the page's requests and responses for an HLS playlist or a
/// video file. A playlist URL named in an API response is the master; otherwise the first playlist the player fetches.
/// Ad servers are ignored. Nil when nothing turns up within the timeout.
@MainActor
public final class SiteVideoResolver: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    public static let defaultTimeout: TimeInterval = 25
    /// After a lesser find (a bare request or a <video> file), how long to wait for a playlist named in a response.
    static let settle: TimeInterval = 1.5

    enum Origin: String, Comparable {
        case body, manifest, request, media
        var rank: Int { [.body: 0, .manifest: 1, .request: 2, .media: 3][self] ?? 4 }
        static func < (a: Origin, b: Origin) -> Bool { a.rank < b.rank }
    }

    private static let handlerName = "odSiteVideo"
    private static let script = """
    (() => {
      if (window.__odSiteVideo) return; window.__odSiteVideo = true;
      const ads = /doubleclick|googlesyndication|googlevideo|imasdk|2mdn\\.net|adsrvr|innovid|springserve|serving-sys|moatads|fwmrm|tremorhub|adnxs|amazon-adsystem/i;
      const playlist = /\\.m3u8(?:[?#]|$)/i;
      const file = /\\.(?:mp4|m4v|mov)(?:[?#]|$)/i;
      const seen = new Set();
      const post = (u, from) => {
        try { u = new URL(u, location.href).href; } catch (e) { return; }
        if (!/^https?:/i.test(u) || ads.test(u) || seen.has(from + u)) return;
        seen.add(from + u);
        try { window.webkit.messageHandlers.\(handlerName).postMessage({ url: u, from }); } catch (e) {}
      };
      const scan = (text) => {
        if (typeof text !== "string" || text.length > 2000000) return;
        if (text.startsWith("#EXTM3U")) return;
        for (const m of text.matchAll(/https?:(?:\\\\?\\/){2}[^"'\\s<>]+?\\.m3u8[^"'\\s<>]*/gi)) post(m[0].replace(/\\\\\\//g, "/"), "body");
      };
      const seeResponse = (url, text) => {
        if (typeof text !== "string") return;
        if (text.startsWith("#EXTM3U")) post(url, "manifest"); else scan(text);
      };
      const ofetch = window.fetch;
      if (ofetch) window.fetch = function (input, init) {
        const u = typeof input === "string" ? input : (input && input.url) || String(input);
        if (playlist.test(u)) post(u, "request");
        return ofetch.apply(this, arguments).then((r) => {
          try {
            const ct = r.headers.get("content-type") || "";
            if (/json|text|mpegurl|javascript/i.test(ct)) r.clone().text().then((t) => seeResponse(r.url || u, t)).catch(() => {});
          } catch (e) {}
          return r;
        });
      };
      const oopen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        try {
          const u = String(url);
          if (playlist.test(u)) post(u, "request");
          this.addEventListener("load", () => {
            try { if (this.responseType === "" || this.responseType === "text") seeResponse(this.responseURL || u, this.responseText); } catch (e) {}
          });
        } catch (e) {}
        return oopen.apply(this, arguments);
      };
      // The view is never on screen: players that wait to be scrolled into view, for a frame or for a visible page
      // would never start.
      try {
        Object.defineProperty(Document.prototype, "visibilityState", { get: () => "visible", configurable: true });
        Object.defineProperty(Document.prototype, "hidden", { get: () => false, configurable: true });
      } catch (e) {}
      window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16);
      window.cancelAnimationFrame = (id) => clearTimeout(id);
      const IO = window.IntersectionObserver;
      if (IO) window.IntersectionObserver = class extends IO {
        constructor(cb, options) { super(cb, options); this.__odCallback = cb; }
        observe(target) {
          super.observe(target);
          setTimeout(() => {
            try {
              const r = target.getBoundingClientRect();
              this.__odCallback([{ target, isIntersecting: true, intersectionRatio: 1, boundingClientRect: r,
                                   intersectionRect: r, rootBounds: null, time: performance.now() }], this);
            } catch (e) {}
          }, 0);
        }
      };
      const oplay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () { this.muted = true; return oplay.apply(this, arguments); };
      setInterval(() => {
        try {
          for (const e of performance.getEntriesByType("resource")) if (playlist.test(e.name)) post(e.name, "request");
          for (const v of document.querySelectorAll("video, video source")) {
            const s = v.currentSrc || v.src;
            if (s && !s.startsWith("blob:") && (playlist.test(s) || file.test(s))) post(s, "media");
            if (v.muted === false) v.muted = true;
          }
        } catch (e) {}
      }, 400);
    })();
    """

    /// The stream for `page`, or nil.
    public static func stream(for page: URL, timeout: TimeInterval = defaultTimeout) async -> URL? {
        let resolver = SiteVideoResolver()
        return await resolver.run(page, timeout: timeout)
    }

    private var webView: WKWebView?
    private var best: (url: URL, origin: Origin)?
    private var continuation: CheckedContinuation<URL?, Never>?
    private var settleWork: DispatchWorkItem?

    private func run(_ page: URL, timeout: TimeInterval) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            continuation = cont
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WebAccount.dataStore
            config.mediaTypesRequiringUserActionForPlayback = []
            #if os(iOS)
            config.allowsInlineMediaPlayback = true
            #endif
            let controller = config.userContentController
            controller.add(ReaderWeakHandler(self), contentWorld: .page, name: Self.handlerName)
            controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: .page))
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
            view.customUserAgent = WebAccount.browserUserAgent
            view.navigationDelegate = self
            webView = view
            view.load(URLRequest(url: page))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish() }
            }
        }
    }

    private func finish() {
        guard let cont = continuation else { return }
        continuation = nil
        settleWork?.cancel()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
        cont.resume(returning: best?.url)
    }

    nonisolated public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let s = body["url"] as? String, let url = URL(string: s),
              let origin = (body["from"] as? String).flatMap(Origin.init(rawValue:)) else { return }
        MainActor.assumeIsolated { found(url, origin) }
    }

    private func found(_ url: URL, _ origin: Origin) {
        guard continuation != nil else { return }
        if best == nil || origin < best!.origin { best = (url, origin) }
        switch best!.origin {
        case .body, .manifest:
            finish()
        case .request, .media:
            guard settleWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finish() } }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finish() }
    }

    nonisolated public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { finish() }
    }
}

/// Holds the resolver weakly: a user content controller retains its handlers.
private final class ReaderWeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
#endif
