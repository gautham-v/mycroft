import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Helpers shared by the reader's two web views (article body and YouTube player).
@MainActor
enum ReaderWebSupport {
    /// Opens a URL in the system browser (or the app that handles it).
    static func openExternally(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// The article body's data store: its own, shared by every article so images come from the HTTP
    /// cache on a repeat view instead of downloading again. Nothing is shared with any other web view.
    /// Everything but the cache (cookies, local storage) is wiped once per launch.
    static let articleDataStore: WKWebsiteDataStore = {
        let store = WKWebsiteDataStore(forIdentifier: articleStoreID)
        var kept = WKWebsiteDataStore.allWebsiteDataTypes()
        kept.remove(WKWebsiteDataTypeDiskCache)
        kept.remove(WKWebsiteDataTypeMemoryCache)
        store.removeData(ofTypes: kept, modifiedSince: .distantPast) {}
        return store
    }()

    private static let articleStoreID = UUID(uuidString: "3EE244B9-7A6E-4805-87EF-3F780E1725DD")!

    /// Settings → Data → Clear: the article images go with the article text.
    static func clearArticleData() async {
        await articleDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// No cookies or caches shared with anything else (a throwaway data store unless `dataStore` is
    /// given), media can play inline.
    static func configuration(autoplay: Bool, dataStore: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore ?? .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = autoplay ? [] : .all
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.dataDetectorTypes = []
        #endif
        return config
    }

    /// Transparent background so the SwiftUI surface shows through before the page paints.
    static func makeTransparent(_ webView: WKWebView) {
        #if canImport(UIKit)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #else
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        #endif
    }

    /// HTML attribute escaping for values we interpolate into generated markup.
    static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Navigation rule for both web views: the document we loaded ourselves (`documentURL`, the base
    /// URL of loadHTMLString) and any sub-frame (embeds) load in place; every other main-frame
    /// navigation (a followed link, a script or meta redirect) opens in the system browser.
    static func policy(for action: WKNavigationAction, documentURL: URL?) -> WKNavigationActionPolicy {
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        guard isMainFrame else { return .allow }
        guard let url = action.request.url else { return .cancel }
        if action.navigationType != .linkActivated,
           url.absoluteString == "about:blank" || url.absoluteString == documentURL?.absoluteString {
            return .allow
        }
        // In-page anchors (#section) stay in the page.
        if let doc = documentURL, url.fragment != nil,
           url.absoluteString.split(separator: "#").first == doc.absoluteString.split(separator: "#").first {
            return .allow
        }
        openExternally(url)
        return .cancel
    }
}

/// Breaks the retain cycle WKUserContentController → handler → coordinator → web view.
final class ReaderWeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

#if os(macOS)
/// A WKWebView that hands vertical scroll-wheel events to the enclosing SwiftUI ScrollView, so a
/// height-fitted article scrolls with the rest of the reader. Horizontal scrolls (wide code blocks,
/// tables) stay with the page.
final class ReaderFittedWebView: WKWebView {
    var forwardsVerticalScroll = true
    /// The article's actions, added to WebKit's right-click menu above Inspect Element.
    var extraMenuItems: (() -> [NSMenuItem])?
    /// Items at the very top of the menu (the highlight colors), with their own trailing separator.
    var topMenuItems: (() -> [NSMenuItem])?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for (i, item) in (topMenuItems?() ?? []).enumerated() { menu.insertItem(item, at: i) }
        var extra = extraMenuItems?() ?? []
        guard !extra.isEmpty else { return }
        // WebKit's Reload would only reload the extracted HTML; Reload Article re-extracts.
        menu.items.removeAll { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" }
        // On a link WebKit already offers Open Link and Copy Link; keep only Reload Article.
        if menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink" }) {
            extra = extra.filter { $0.title == "Reload Article" || $0.title == ReaderSpeechMenu.title }
        }
        var at = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" } ?? menu.items.count
        if at > 0, !menu.items[at - 1].isSeparatorItem {
            menu.insertItem(.separator(), at: at)
            at += 1
        }
        for item in extra {
            menu.insertItem(item, at: at)
            at += 1
        }
        if at < menu.items.count, !menu.items[at].isSeparatorItem { menu.insertItem(.separator(), at: at) }
    }

    override func scrollWheel(with event: NSEvent) {
        if forwardsVerticalScroll, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// The view is as tall as its content, so WebKit has nothing to scroll for arrow keys, Space,
    /// Page Up/Down or Home/End and swallows them. Scroll the enclosing ScrollView instead.
    override func keyDown(with event: NSEvent) {
        if forwardsVerticalScroll, let scrollView = ReaderScrollKeys.verticalScrollView(enclosing: self),
           ReaderScrollKeys.scroll(scrollView, for: event) {
            return
        }
        super.keyDown(with: event)
    }
}

/// A menu item that runs a closure (the web view's right-click additions).
final class ReaderMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// Keyboard scrolling of the reader's (native) ScrollView, shared by the fitted article web view and
/// the feed key monitor (which handles keys after a click on the reader's native header).
@MainActor
enum ReaderScrollKeys {
    /// Nearest enclosing scroll view whose content is taller than its viewport (skips horizontal
    /// strips); the nearest one at all if none overflows yet.
    static func verticalScrollView(enclosing view: NSView) -> NSScrollView? {
        var first: NSScrollView?
        var current = view.enclosingScrollView
        while let sv = current {
            if first == nil { first = sv }
            if let doc = sv.documentView, doc.frame.height > sv.contentView.bounds.height + 1 { return sv }
            current = sv.enclosingScrollView
        }
        return first
    }

    /// Scrolls for Up/Down (one line), Space / Shift-Space and Page Up/Down (one page), Home/End.
    /// Returns false for any other key (or a modified one), which the caller then passes on.
    @discardableResult
    static func scroll(_ scrollView: NSScrollView, for event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.intersection([.command, .control, .option]).isEmpty { return false }
        let shift = flags.contains(.shift)
        let clip = scrollView.contentView
        let visible = clip.bounds.height
        let page = max(visible - 40, visible * 0.8)
        enum Move { case by(CGFloat), top, bottom }
        let move: Move
        switch event.keyCode {
        case 125 where !shift: move = .by(40)          // down arrow (Shift extends a text selection)
        case 126 where !shift: move = .by(-40)         // up arrow
        case 49: move = .by(shift ? -page : page)       // space
        case 121: move = .by(page)                      // page down
        case 116: move = .by(-page)                     // page up
        case 115: move = .top                           // home
        case 119: move = .bottom                        // end
        default: return false
        }
        guard let doc = scrollView.documentView else { return false }
        let flipped = clip.isFlipped
        let maxOffset = max(0, doc.frame.height - visible)
        // Offset from the top of the content, whatever the clip view's orientation.
        let current = flipped ? clip.bounds.origin.y - doc.frame.minY : doc.frame.maxY - clip.bounds.maxY
        let target: CGFloat = switch move {
        case .by(let d): min(max(current + d, 0), maxOffset)
        case .top: 0
        case .bottom: maxOffset
        }
        let y = flipped ? doc.frame.minY + target : doc.frame.maxY - visible - target
        let origin = NSPoint(x: clip.bounds.origin.x, y: y)
        if case .by(let d) = move, abs(d) <= 40 {
            clip.scroll(to: origin)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                clip.animator().setBoundsOrigin(origin)
            }
        }
        scrollView.reflectScrolledClipView(clip)
        return true
    }
}
#else
/// The article's web view on iOS: its text-selection edit menu gets Highlight and Add Note first and the
/// article's other actions (Read Aloud from Here) last.
final class ReaderFittedWebView: WKWebView {
    var highlightMenu: (() -> [UIMenuElement])?
    var extraMenuElements: (() -> [UIMenuElement])?

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context else { return }
        if let elements = highlightMenu?(), !elements.isEmpty {
            builder.insertChild(UIMenu(options: .displayInline, children: elements), atStartOfMenu: .standardEdit)
        }
        if let extra = extraMenuElements?(), !extra.isEmpty {
            builder.insertChild(UIMenu(options: .displayInline, children: extra), atEndOfMenu: .standardEdit)
        }
    }
}
#endif

/// Scrolling the reader's ScrollView to a highlight: the marker the article's web view places there.
enum HighlightScroll {
    static func markerID(pane: Int) -> String { "highlight-marker-\(pane)" }
}
