import OpenDispatchCore
import SwiftUI
import WebKit

/// Builds the reader page around sanitized article HTML (see Resources/reader.css for the contract).
enum ReaderHTML {
    struct Appearance: Equatable {
        var font: ReaderFontSetting
        var size: TextSizeSetting
        /// nil follows the system appearance (prefers-color-scheme).
        var theme: ThemeSetting
        /// 32pt side padding (md+ in the web) instead of 20pt.
        var wide: Bool
        /// Text column cap in points; nil fills the view (Fill window).
        var columnWidth: CGFloat?

        /// The `--column` value reader.css caps the article at.
        var columnCSS: String { columnWidth.map { "\(Int($0))px" } ?? "none" }
    }

    /// reader.css from the app bundle, read once.
    @MainActor static let stylesheet: String = {
        guard let url = Bundle.main.url(forResource: "reader", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return css
    }()

    /// The full document. `hero` is an image URL shown above the content (already de-duplicated by the caller).
    @MainActor static func document(body: String, hero: String?, appearance a: Appearance) -> String {
        let themeAttr: String = switch a.theme {
        case .system: ""
        case .light: " data-theme=\"light\""
        case .dark: " data-theme=\"dark\""
        }
        let heroTag = hero.map { "<img src=\"\(ReaderWebSupport.escapeAttribute($0))\" alt=\"\">" } ?? ""
        return """
        <!doctype html>
        <html\(themeAttr)>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>\(stylesheet)</style>
        </head>
        <body>
        <article class="prose-opendispatch" style="--column: \(a.columnCSS)" data-font="\(a.font.rawValue)" data-size="\(a.size.rawValue)" data-wide="\(a.wide ? "1" : "0")">\(heroTag)<div>\(body)</div></article>
        </body>
        </html>
        """
    }

    /// Script run in our own content world: reports the article's height (for fitting the view) whenever
    /// it changes, e.g. as images load or the width changes, and applies appearance changes in place.
    static let fitScript = """
    (function () {
      var last = -1;
      function report() {
        var a = document.querySelector('article');
        if (!a) return;
        var r = a.getBoundingClientRect();
        var h = Math.ceil(r.bottom + window.scrollY);
        if (h !== last) { last = h; window.webkit.messageHandlers.openDispatchHeight.postMessage(h); }
      }
      var a = document.querySelector('article');
      if (a && window.ResizeObserver) new ResizeObserver(report).observe(a);
      window.addEventListener('load', report);
      document.addEventListener('load', report, true);
      report();
    })();
    """

    static func applyAppearanceScript(_ a: Appearance) -> String {
        let theme: String = switch a.theme {
        case .system: "null"
        case .light: "'light'"
        case .dark: "'dark'"
        }
        return """
        (function () {
          var t = \(theme);
          if (t) document.documentElement.setAttribute('data-theme', t); else document.documentElement.removeAttribute('data-theme');
          var a = document.querySelector('article');
          if (!a) return;
          a.setAttribute('data-font', '\(a.font.rawValue)');
          a.setAttribute('data-size', '\(a.size.rawValue)');
          a.setAttribute('data-wide', '\(a.wide ? "1" : "0")');
          a.style.setProperty('--column', '\(a.columnCSS)');
        })();
        """
    }
}

/// The article body: a WKWebView sized to its content so it scrolls with the native header inside the
/// reader's ScrollView. Links open in the system browser; text is selectable; follows dark mode.
/// On the Mac its right-click menu adds Open Original, Copy Link, Copy as Markdown (`onCopyMarkdown`) and
/// Reload Article (`onReload`).
struct ReaderArticleWebView: View {
    let html: String
    let hero: String?
    let baseURL: URL?
    let appearance: ReaderHTML.Appearance
    var onReload: (() -> Void)? = nil
    var onCopyMarkdown: (() -> Void)? = nil

    @State private var height: CGFloat = 0

    var body: some View {
        ReaderArticleWebViewRepresentable(html: html, hero: hero, baseURL: baseURL, appearance: appearance, onReload: onReload, onCopyMarkdown: onCopyMarkdown) { h in
            if abs(h - height) > 0.5 { height = h }
        }
        .frame(height: max(height, 1))
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Article")
    }
}

@MainActor
final class ReaderArticleCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var onHeight: (CGFloat) -> Void
    var loadedKey: String?
    var appearance: ReaderHTML.Appearance?
    var documentURL: URL?
    var onReload: (() -> Void)?
    var onCopyMarkdown: (() -> Void)?

    init(onHeight: @escaping (CGFloat) -> Void) { self.onHeight = onHeight }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "openDispatchHeight" else { return }
        let value: CGFloat? = (message.body as? NSNumber).map { CGFloat($0.doubleValue) }
        if let h = value, h.isFinite, h >= 0 { onHeight(h) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(ReaderWebSupport.policy(for: navigationAction, documentURL: documentURL))
    }

    /// target="_blank" links: open externally, never a new web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { ReaderWebSupport.openExternally(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Reload on the next update.
        loadedKey = nil
        webView.reload()
    }

    func makeWebView() -> WKWebView {
        let config = ReaderWebSupport.configuration(autoplay: false)
        let world = WKContentWorld.defaultClient
        let controller = config.userContentController
        controller.add(ReaderWeakScriptHandler(self), contentWorld: world, name: "openDispatchHeight")
        controller.addUserScript(WKUserScript(source: ReaderHTML.fitScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: world))
        let webView = ReaderFittedWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        #if os(macOS)
        webView.allowsMagnification = false
        webView.extraMenuItems = { [weak self] in self?.menuItems() ?? [] }
        #else
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        #endif
        if #available(macOS 13.3, iOS 16.4, *) { webView.isInspectable = true }
        ReaderWebSupport.makeTransparent(webView)
        return webView
    }

    #if os(macOS)
    /// The article's own actions for the right-click menu (the headline's context menu has the same).
    private func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let url = documentURL {
            items.append(ReaderMenuItem("Open Original") { ReaderWebSupport.openExternally(url) })
            items.append(ReaderMenuItem("Copy Link") { ReaderPasteboard.copy(url) })
        }
        if let onCopyMarkdown {
            let copy = ReaderMenuItem("Copy as Markdown", action: onCopyMarkdown)
            copy.keyEquivalent = "c"
            copy.keyEquivalentModifierMask = [.command, .shift]
            items.append(copy)
        }
        if let onReload {
            let reload = ReaderMenuItem("Reload Article", action: onReload)
            reload.keyEquivalent = "r"
            reload.keyEquivalentModifierMask = [.command, .shift]
            items.append(reload)
        }
        return items
    }
    #endif

    func update(_ webView: WKWebView, html: String, hero: String?, baseURL: URL?, appearance: ReaderHTML.Appearance) {
        let key = "\(baseURL?.absoluteString ?? "")\n\(hero ?? "")\n\(html.count)\n\(html.hashValue)"
        if key != loadedKey {
            loadedKey = key
            self.appearance = appearance
            documentURL = baseURL
            webView.loadHTMLString(ReaderHTML.document(body: html, hero: hero, appearance: appearance), baseURL: baseURL)
        } else if appearance != self.appearance {
            self.appearance = appearance
            // ObjC entry point: the Swift overlay variant needs libswiftWebKit.dylib, absent on iOS 18.
            webView.__evaluateJavaScript(ReaderHTML.applyAppearanceScript(appearance), inFrame: nil, in: .defaultClient) { _, _ in }
        }
    }
}

#if os(macOS)
private struct ReaderArticleWebViewRepresentable: NSViewRepresentable {
    let html: String
    let hero: String?
    let baseURL: URL?
    let appearance: ReaderHTML.Appearance
    let onReload: (() -> Void)?
    let onCopyMarkdown: (() -> Void)?
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> ReaderArticleCoordinator { ReaderArticleCoordinator(onHeight: onHeight) }

    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.onReload = onReload
        context.coordinator.onCopyMarkdown = onCopyMarkdown
        context.coordinator.update(view, html: html, hero: hero, baseURL: baseURL, appearance: appearance)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: ReaderArticleCoordinator) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
}
#else
private struct ReaderArticleWebViewRepresentable: UIViewRepresentable {
    let html: String
    let hero: String?
    let baseURL: URL?
    let appearance: ReaderHTML.Appearance
    let onReload: (() -> Void)?
    let onCopyMarkdown: (() -> Void)?
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> ReaderArticleCoordinator { ReaderArticleCoordinator(onHeight: onHeight) }

    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView() }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.onReload = onReload
        context.coordinator.onCopyMarkdown = onCopyMarkdown
        context.coordinator.update(view, html: html, hero: hero, baseURL: baseURL, appearance: appearance)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: ReaderArticleCoordinator) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
}
#endif
