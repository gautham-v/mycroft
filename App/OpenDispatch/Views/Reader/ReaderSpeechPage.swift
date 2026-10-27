import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One sentence of an article, as the page's script found it.
struct ReaderSpeechSentence: Equatable, Sendable {
    var text: String
    /// Last sentence of its paragraph, list item or heading: a longer pause follows.
    var endsBlock: Bool
}

/// Where the highlighted sentence is, in the web view's coordinates (the page never scrolls itself).
struct ReaderSpeechRect: Equatable, Sendable {
    var top: CGFloat
    var bottom: CGFloat
    var firstLineBottom: CGFloat
}

/// The speech side of one article web view: runs `ReaderSpeechScript` in it, hears its messages (a
/// click on a sentence, whether text is selected) and scrolls the enclosing reader to follow along.
/// `ReaderItemView` makes one per article and `ReaderArticleWebView` installs it in the web view.
@MainActor
final class ReaderSpeechPage: NSObject, WKScriptMessageHandler {
    private(set) weak var webView: WKWebView?
    /// The page's script is loaded, so sentences can be read.
    private(set) var isReady = false
    /// Text is selected in the page (the right-click / edit menu offers Read Aloud from Here).
    private(set) var hasSelection = false
    /// A click or tap on a sentence while listening (index into the sentences `extract` returned).
    var onJump: ((Int) -> Void)?
    /// The document was replaced or went away: whatever is being read from it is gone.
    var onInvalidate: (() -> Void)?
    /// Read Aloud from Here was chosen in the selection's menu.
    var onReadAloudFromSelection: (() -> Void)?
    let scroller = ReaderSpeechScroller()

    /// Adds the script and its message handler to a web view's configuration.
    func install(in controller: WKUserContentController, world: WKContentWorld) {
        controller.add(ReaderWeakScriptHandler(self), contentWorld: world, name: ReaderSpeechScript.handlerName)
        controller.addUserScript(WKUserScript(source: ReaderSpeechScript.source, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: world))
    }

    func attach(_ webView: WKWebView) { self.webView = webView }

    /// A new document is loading into the web view (or it is going away).
    func documentWillChange() {
        isReady = false
        hasSelection = false
        onInvalidate?()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready": isReady = true
        case "selection": hasSelection = body["value"] as? Bool ?? false
        case "jump": if let index = (body["index"] as? NSNumber)?.intValue { onJump?(index) }
        default: break
        }
    }

    // MARK: Script calls

    /// Runs script in the article's world. Results come back as JSON text, which crosses actors safely.
    private func evaluate(_ script: String) async -> String? {
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            // ObjC entry point: the Swift overlay variant needs libswiftWebKit.dylib, absent on iOS 18.
            webView.__evaluateJavaScript(script, inFrame: nil, in: .defaultClient) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    private static func literal(_ string: String?) -> String {
        guard let string, let data = try? JSONEncoder().encode(string), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    /// The article's opening text, to tell its language from.
    func sampleText() async -> String {
        await evaluate("String((document.querySelector('article') || document.body).innerText).slice(0, 800)") ?? ""
    }

    /// The sentences in reading order, minus a copy of `title` at the top. `language` ("en") picks the
    /// segmenter's rules.
    func extract(title: String?, language: String?) async -> [ReaderSpeechSentence] {
        let script = "JSON.stringify(odSpeech.extract(\(Self.literal(title)), \(Self.literal(language))))"
        guard let json = await evaluate(script), let data = json.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] else { return [] }
        return rows.compactMap { row in
            guard row.count == 2, let text = row[0] as? String else { return nil }
            return ReaderSpeechSentence(text: text, endsBlock: (row[1] as? NSNumber)?.intValue == 1)
        }
    }

    /// The sentence the selection starts in, nil without a selection.
    func selectionIndex() async -> Int? {
        guard let text = await evaluate("String(odSpeech.selectionIndex())"), let index = Int(text), index >= 0 else { return nil }
        return index
    }

    /// Highlights sentence `index` (none for nil) and says where it is.
    func show(_ index: Int?) async -> ReaderSpeechRect? {
        let script = index.map { "JSON.stringify(odSpeech.show(\($0)))" } ?? "odSpeech.clear(); 'null'"
        guard let json = await evaluate(script), let data = json.data(using: .utf8),
              let v = (try? JSONSerialization.jsonObject(with: data)) as? [NSNumber], v.count == 3 else { return nil }
        return ReaderSpeechRect(top: CGFloat(v[0].doubleValue), bottom: CGFloat(v[1].doubleValue),
                                firstLineBottom: CGFloat(v[2].doubleValue))
    }

    /// Turns click-to-jump on or off; off also drops the highlight.
    func setActive(_ on: Bool) {
        webView?.__evaluateJavaScript("window.odSpeech && odSpeech.setActive(\(on))", inFrame: nil, in: .defaultClient) { _, _ in }
    }
}

/// Keeps the sentence being read in view: the article web view is as tall as its text and sits in the
/// reader's ScrollView, so it is that scroll view that moves. It scrolls only when the sentence is
/// about to leave the visible area, and stops following once the reader scrolls by hand.
@MainActor
final class ReaderSpeechScroller: NSObject {
    /// Off after a manual scroll; on again at the next play, previous or next.
    var following = true
    /// How long our own scroll animations (and the layout shifts around them) are not taken for the reader's.
    private static let animationGrace: TimeInterval = 0.7
    /// Distance kept between the sentence and the edges of the visible area.
    private static let margin: CGFloat = 28
    private var ignoreScrollsUntil = Date.distantPast

    #if os(macOS)
    private weak var scrollView: NSScrollView?
    private weak var webView: WKWebView?
    private var observer: (any NSObjectProtocol)?
    private var lastOriginY: CGFloat = 0

    func attach(to webView: WKWebView) {
        detach()
        guard let scrollView = ReaderScrollKeys.verticalScrollView(enclosing: webView) else { return }
        self.scrollView = scrollView
        self.webView = webView
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        lastOriginY = clip.bounds.origin.y
        following = true
        ignoreScrollsUntil = Date().addingTimeInterval(Self.animationGrace)
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundsChanged() }
        }
    }

    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        scrollView = nil
        webView = nil
    }

    /// Any move of the clip view we did not make is the reader scrolling (wheel, trackpad, keys, scroller).
    /// Size changes alone (the player bar appearing, a resize) leave the origin where it was.
    private func boundsChanged() {
        guard let clip = scrollView?.contentView else { return }
        let y = clip.bounds.origin.y
        defer { lastOriginY = y }
        guard abs(y - lastOriginY) > 0.5, Date() >= ignoreScrollsUntil else { return }
        following = false
    }

    func reveal(_ rect: ReaderSpeechRect) {
        guard following, let scrollView, let webView else { return }
        let clip = scrollView.contentView
        let y = webView.isFlipped ? rect.top : webView.bounds.height - rect.bottom
        let inClip = clip.convert(NSRect(x: 0, y: y, width: 1, height: max(rect.bottom - rect.top, 1)), from: webView)
        // Distances from the top edge of the clip view's bounds, whichever way it is flipped.
        let top = clip.isFlipped ? inClip.minY - clip.bounds.minY : clip.bounds.maxY - inClip.maxY
        let bottom = top + inClip.height
        let insets = scrollView.contentInsets
        let delta = Self.scrollDelta(top: top, bottom: bottom, firstLineBottom: top + (rect.firstLineBottom - rect.top),
                                     visibleTop: insets.top, visibleBottom: clip.bounds.height - insets.bottom)
        guard delta != 0 else { return }
        scroll(by: delta)
    }

    func scrollToTop() {
        guard following, let scrollView, let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let target = clip.isFlipped ? doc.frame.minY - scrollView.contentInsets.top : doc.frame.maxY - clip.bounds.height + scrollView.contentInsets.top
        scroll(by: (clip.isFlipped ? target - clip.bounds.origin.y : clip.bounds.origin.y - target))
    }

    /// Scrolls the content up by `delta` points (down the article when positive).
    private func scroll(by delta: CGFloat) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y += clip.isFlipped ? delta : -delta
        origin = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        guard abs(origin.y - clip.bounds.origin.y) > 0.5 else { return }
        ignoreScrollsUntil = Date().addingTimeInterval(Self.animationGrace)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            clip.animator().setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clip)
    }
    #else
    private weak var scrollView: UIScrollView?
    private weak var webView: WKWebView?

    func attach(to webView: WKWebView) {
        detach()
        var view = webView.superview
        while let current = view, !(current is UIScrollView) { view = current.superview }
        guard let scrollView = view as? UIScrollView else { return }
        self.scrollView = scrollView
        self.webView = webView
        following = true
        ignoreScrollsUntil = Date().addingTimeInterval(Self.animationGrace)
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
    }

    func detach() {
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
        scrollView = nil
        webView = nil
    }

    /// A finger on the reader: stop following.
    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { following = false }
    }

    func reveal(_ rect: ReaderSpeechRect) {
        guard following, let scrollView, let webView else { return }
        let inScroll = scrollView.convert(CGRect(x: 0, y: rect.top, width: 1, height: max(rect.bottom - rect.top, 1)), from: webView)
        let inset = scrollView.adjustedContentInset
        let offset = scrollView.contentOffset.y
        let delta = Self.scrollDelta(top: inScroll.minY - offset, bottom: inScroll.maxY - offset,
                                     firstLineBottom: inScroll.minY - offset + (rect.firstLineBottom - rect.top),
                                     visibleTop: inset.top, visibleBottom: scrollView.bounds.height - inset.bottom)
        guard delta != 0 else { return }
        scroll(by: delta)
    }

    func scrollToTop() {
        guard following, let scrollView else { return }
        scroll(by: -scrollView.contentOffset.y - scrollView.adjustedContentInset.top)
    }

    private func scroll(by delta: CGFloat) {
        guard let scrollView else { return }
        let inset = scrollView.adjustedContentInset
        let lowest = -inset.top
        let highest = max(lowest, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        let target = min(max(scrollView.contentOffset.y + delta, lowest), highest)
        guard abs(target - scrollView.contentOffset.y) > 0.5 else { return }
        ignoreScrollsUntil = Date().addingTimeInterval(Self.animationGrace)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: true)
    }
    #endif

    /// How far to scroll, in points down the article, to keep a sentence in view; 0 while it is.
    /// All values are distances from the top of the scroll view. The sentence counts as visible while
    /// its top and the end of its first line are inside the visible area minus a margin, so a sentence
    /// taller than the screen is followed by its start.
    private static func scrollDelta(top: CGFloat, bottom: CGFloat, firstLineBottom: CGFloat,
                                    visibleTop: CGFloat, visibleBottom: CGFloat) -> CGFloat {
        let low = visibleTop + margin
        let high = visibleBottom - margin
        let visibleHeight = visibleBottom - visibleTop
        let needed = min(bottom, max(firstLineBottom, top + visibleHeight * 0.5))
        if top >= low && needed <= high { return 0 }
        // Put it a quarter of the way down, where the eye already is after reading the line above.
        return top - (visibleTop + visibleHeight * 0.25)
    }
}

/// The "Read Aloud from Here" item in the article's selection menu.
enum ReaderSpeechMenu {
    static let title = "Read Aloud from Here"
}

extension ReaderSpeechPage {
    #if os(iOS)
    /// Read Aloud from Here for the edit menu, while text is selected.
    func menuElements() -> [UIMenuElement] {
        guard hasSelection else { return [] }
        return [UIAction(title: ReaderSpeechMenu.title, image: UIImage(systemName: OFIcon.headphones.rawValue)) { [weak self] _ in
            self?.onReadAloudFromSelection?()
        }]
    }
    #endif
}
