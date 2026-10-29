import OpenDispatchCore
import SwiftUI
import WebKit

/// Builds the reader page around sanitized article HTML (see Resources/reader.css for the contract).
enum ReaderHTML {
    struct Appearance: Equatable {
        var font: ReaderFontSetting
        var size: TextSizeSetting
        var leading: LineSpacingSetting
        /// nil follows the system appearance (prefers-color-scheme).
        var theme: ThemeSetting
        /// 32pt side padding (md+ in the web) instead of 20pt.
        var wide: Bool
        /// Text column cap in points; nil fills the view (Fill window).
        var columnWidth: CGFloat?
        /// Settings → Reader → Links (reader.css data-links).
        var links: LinkStyleSetting = .underlined
        /// The themes' colors over reader.css's own (`AppSettings.readerThemeCSS`); nil keeps them.
        var themeCSS: String? = nil

        /// The `--column` value reader.css caps the article at.
        var columnCSS: String { columnWidth.map { "\(Int($0))px" } ?? "none" }
    }

    /// A post's author row shows its age and its network's icon (reader.css reads them as --post-age and
    /// --post-icon). Generated content, so the highlight index and read aloud never see the age change.
    struct Post: Equatable {
        var published: Date
        /// The post's host ("x.com"), for the network's favicon.
        var host: String?

        var css: String {
            let icon = host.flatMap { URLHost.faviconURL(host: $0) }.map { "; --post-icon: url('\($0.absoluteString)')" } ?? ""
            return "; --post-age: '· \(RelativeTime.format(published))'\(icon)"
        }
    }

    /// reader.css from the app bundle, read once.
    @MainActor static let stylesheet: String = {
        guard let url = Bundle.main.url(forResource: "reader", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return css
    }()

    /// The full document. `hero` is an image URL shown above the content (already de-duplicated by the caller).
    /// `post` is set for posts; the age is as of loading.
    @MainActor static func document(body: String, hero: String?, appearance a: Appearance, post: Post? = nil) -> String {
        let themeAttr: String = switch a.theme {
        case .system: ""
        case .light: " data-theme=\"light\""
        case .dark: " data-theme=\"dark\""
        }
        let heroTag = hero.map { "<img src=\"\(ReaderWebSupport.escapeAttribute($0))\" alt=\"\">" } ?? ""
        // The page sends no Referer: X's media servers refuse one from another site (an embedded post's avatar, still and
        // video in an article). Embedded players still get the page's origin, which YouTube needs.
        let body = body.replacingOccurrences(of: "<iframe ", with: "<iframe referrerpolicy=\"strict-origin-when-cross-origin\" ")
        return """
        <!doctype html>
        <html\(themeAttr)>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <meta name="referrer" content="no-referrer">
        <style>\(stylesheet)</style>
        <style id="od-theme">\(a.themeCSS ?? "")</style>
        </head>
        <body>
        <article class="prose-opendispatch" style="\(ReaderWebSupport.escapeAttribute("--column: \(a.columnCSS)\(post?.css ?? "")"))" data-font="\(a.font.rawValue)" data-size="\(a.size.rawValue)" data-leading="\(a.leading.rawValue)" data-wide="\(a.wide ? "1" : "0")" data-links="\(a.links.rawValue)">\(heroTag)<div>\(body)</div></article>
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
      // Charts (Datawrapper, Flourish) report their height to the page that holds them; their script isn't here.
      window.addEventListener('message', function (e) {
        try {
          var d = typeof e.data === 'string' ? JSON.parse(e.data) : e.data, h = 0;
          if (d && d['datawrapper-height']) h = Object.values(d['datawrapper-height'])[0];
          else if (d && d.sender === 'Flourish' && d.context === 'iframe.resize') h = parseInt(d.height, 10);
          if (!(h > 100 && h < 5000)) return;
          var frames = document.querySelectorAll('iframe');
          for (var i = 0; i < frames.length; i++) if (frames[i].contentWindow === e.source) frames[i].style.height = Math.ceil(h) + 'px';
        } catch (err) {}
      });
      report();
    })();
    """

    static func applyAppearanceScript(_ a: Appearance) -> String {
        let theme: String = switch a.theme {
        case .system: "null"
        case .light: "'light'"
        case .dark: "'dark'"
        }
        let themeCSS = ReaderWebSupport.jsString(a.themeCSS ?? "")
        return """
        (function () {
          var t = \(theme);
          if (t) document.documentElement.setAttribute('data-theme', t); else document.documentElement.removeAttribute('data-theme');
          var s = document.getElementById('od-theme');
          if (s) s.textContent = \(themeCSS);
          var a = document.querySelector('article');
          if (!a) return;
          a.setAttribute('data-font', '\(a.font.rawValue)');
          a.setAttribute('data-size', '\(a.size.rawValue)');
          a.setAttribute('data-leading', '\(a.leading.rawValue)');
          a.setAttribute('data-wide', '\(a.wide ? "1" : "0")');
          a.setAttribute('data-links', '\(a.links.rawValue)');
          a.style.setProperty('--column', '\(a.columnCSS)');
        })();
        """
    }
}

/// The article body: a WKWebView sized to its content so it scrolls with the native header inside the
/// reader's ScrollView. Links open in the system browser; text is selectable; follows dark mode.
/// On the Mac its right-click menu adds Open Original, Copy Link, Copy as Markdown (`onCopyMarkdown`) and
/// Reload Article (`onReload`), and the highlight colors above them (ReaderHighlights.swift). A click on
/// a highlight or its note marker opens `HighlightPopover` under it.
struct ReaderArticleWebView: View {
    let html: String
    let hero: String?
    let baseURL: URL?
    let appearance: ReaderHTML.Appearance
    var post: ReaderHTML.Post? = nil
    var onReload: (() -> Void)? = nil
    var onCopyMarkdown: (() -> Void)? = nil
    /// Read aloud's bridge to this web view (ReaderSpeechPage.swift).
    var speechPage: ReaderSpeechPage? = nil

    @Environment(HighlightStore.self) private var highlights
    @Environment(\.highlightArticle) private var article
    @State private var height: CGFloat = 0
    @State private var bridge = ReaderHighlightBridge()
    /// Where the scroll marker sits in the article, for scrolling the reader to a highlight.
    @State private var markerY: CGFloat = 0

    /// This pane's popover, if a highlight in this article was clicked.
    private var popover: HighlightStore.Popover? {
        guard let article, let p = highlights.popover, p.pane == article.pane else { return nil }
        return p
    }

    var body: some View {
        ReaderArticleWebViewRepresentable(
            html: html, hero: hero, baseURL: baseURL, appearance: appearance, post: post, onReload: onReload,
            onCopyMarkdown: onCopyMarkdown, bridge: bridge,
            highlight: article.map { ReaderHighlightState(store: highlights, article: $0, highlights: highlights.highlights(forKey: $0.key)) },
            speechPage: speechPage
        ) { h in
            if abs(h - height) > 0.5 { height = h }
        }
        .frame(height: max(height, 1))
        .frame(maxWidth: .infinity)
        // The web view doesn't scroll itself, so the page reports where a highlight is and an invisible
        // marker is put there for the reader's ScrollView to scroll to.
        .overlay(alignment: .topLeading) {
            if let article {
                VStack(spacing: 0) {
                    Color.clear.frame(width: 1, height: markerY)
                    Color.clear.frame(width: 1, height: 1).id(HighlightScroll.markerID(pane: article.pane))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onChange(of: highlights.scrollRequest) { _, request in
            guard let request, let article, request.pane == article.pane else { return }
            bridge.locate(request.id) { y in
                guard let y else { return }
                markerY = y
                highlights.scrollIsReady(request)
                // Once the reader's scroll has landed.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    bridge.flash(request.id)
                }
            }
        }
        // The popover under a clicked highlight. The page reports the clicked line's rect in its own
        // coordinates, which are this view's: the web view is fitted to the article, so the reader's
        // ScrollView moves it and nothing inside scrolls.
        .popover(isPresented: Binding(
            get: { popover != nil },
            set: { if !$0 { highlights.closePopover() } }
        ), attachmentAnchor: .rect(.rect(popover?.rect ?? .zero)), arrowEdge: .bottom) {
            if let popover { HighlightPopover(id: popover.id, pane: popover.pane) }
        }
        // It is anchored to a spot in the page: scrolling the reader or resizing the pane moves that.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in highlights.closePopover() }
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
    let bridge: ReaderHighlightBridge
    var speechPage: ReaderSpeechPage?

    init(onHeight: @escaping (CGFloat) -> Void, bridge: ReaderHighlightBridge) {
        self.onHeight = onHeight
        self.bridge = bridge
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "openDispatchHeight" else { return }
        let value: CGFloat? = (message.body as? NSNumber).map { CGFloat($0.doubleValue) }
        if let h = value, h.isFinite, h >= 0 { onHeight(h) }
        if let width = message.webView?.bounds.width, width > 0 { ArticleImageWarmer.viewportWidth = width }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        bridge.pageDidLoad()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Reload on the next update; highlights repaint and read aloud stops, as for a new document.
        loadedKey = nil
        bridge.pageWillLoad()
        speechPage?.documentWillChange()
        webView.reload()
    }

    func makeWebView() -> WKWebView {
        let config = ReaderWebSupport.configuration(autoplay: false, dataStore: ReaderWebSupport.articleDataStore)
        let world = WKContentWorld.defaultClient
        let controller = config.userContentController
        controller.add(ReaderWeakScriptHandler(self), contentWorld: world, name: "openDispatchHeight")
        controller.addUserScript(WKUserScript(source: ReaderHTML.fitScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: world))
        bridge.install(in: config)
        speechPage?.install(in: controller, world: world)
        let webView = ReaderFittedWebView(frame: .zero, configuration: config)
        bridge.attach(webView)
        speechPage?.attach(webView)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        #if os(macOS)
        webView.allowsMagnification = false
        webView.extraMenuItems = { [weak self] in self?.menuItems() ?? [] }
        webView.topMenuItems = { [weak bridge] in bridge?.macMenuItems() ?? [] }
        #else
        webView.highlightMenu = { [weak bridge] in bridge?.editMenuElements() ?? [] }
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.extraMenuElements = { [weak self] in self?.speechPage?.menuElements() ?? [] }
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
        if speechPage?.hasSelection == true {
            items.append(ReaderMenuItem(ReaderSpeechMenu.title) { [weak self] in self?.speechPage?.onReadAloudFromSelection?() })
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

    func update(_ webView: WKWebView, html: String, hero: String?, baseURL: URL?, appearance: ReaderHTML.Appearance,
                post: ReaderHTML.Post?) {
        let key = "\(baseURL?.absoluteString ?? "")\n\(hero ?? "")\n\(html.count)\n\(html.hashValue)"
        if key != loadedKey {
            loadedKey = key
            self.appearance = appearance
            documentURL = baseURL
            bridge.pageWillLoad()
            speechPage?.documentWillChange()
            webView.loadHTMLString(ReaderHTML.document(body: html, hero: hero, appearance: appearance, post: post), baseURL: baseURL)
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
    let post: ReaderHTML.Post?
    let onReload: (() -> Void)?
    let onCopyMarkdown: (() -> Void)?
    let bridge: ReaderHighlightBridge
    let highlight: ReaderHighlightState?
    let speechPage: ReaderSpeechPage?
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> ReaderArticleCoordinator { ReaderArticleCoordinator(onHeight: onHeight, bridge: bridge) }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.speechPage = speechPage
        return context.coordinator.makeWebView()
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.onReload = onReload
        context.coordinator.onCopyMarkdown = onCopyMarkdown
        if let highlight { bridge.update(highlight) }
        context.coordinator.speechPage = speechPage
        context.coordinator.update(view, html: html, hero: hero, baseURL: baseURL, appearance: appearance, post: post)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: ReaderArticleCoordinator) {
        coordinator.speechPage?.documentWillChange()
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
    let post: ReaderHTML.Post?
    let onReload: (() -> Void)?
    let onCopyMarkdown: (() -> Void)?
    let bridge: ReaderHighlightBridge
    let highlight: ReaderHighlightState?
    let speechPage: ReaderSpeechPage?
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> ReaderArticleCoordinator { ReaderArticleCoordinator(onHeight: onHeight, bridge: bridge) }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.speechPage = speechPage
        return context.coordinator.makeWebView()
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.onReload = onReload
        context.coordinator.onCopyMarkdown = onCopyMarkdown
        if let highlight { bridge.update(highlight) }
        context.coordinator.speechPage = speechPage
        context.coordinator.update(view, html: html, hero: hero, baseURL: baseURL, appearance: appearance, post: post)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: ReaderArticleCoordinator) {
        coordinator.speechPage?.documentWillChange()
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
}
#endif
