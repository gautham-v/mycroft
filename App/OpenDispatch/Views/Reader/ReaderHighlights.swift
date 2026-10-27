import OpenDispatchCore
import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The article a reader pane shows, for the views inside it that deal with its highlights (the article's
/// web view). Set by `highlightsPanel(item:pane:)` on the pane's scroll view.
struct ReaderHighlightArticle: Equatable {
    var item: FeedItem
    var pane: Int
    /// iPhone layout: the panel is a sheet, and a tap on a highlight opens a menu.
    var compact: Bool

    var key: String { HighlightStore.key(for: item) }
}

private struct ReaderHighlightArticleKey: EnvironmentKey {
    static let defaultValue: ReaderHighlightArticle? = nil
}

extension EnvironmentValues {
    var highlightArticle: ReaderHighlightArticle? {
        get { self[ReaderHighlightArticleKey.self] }
        set { self[ReaderHighlightArticleKey.self] = newValue }
    }
}

/// What the article web view's highlight bridge needs for one update.
struct ReaderHighlightState {
    var store: HighlightStore
    var article: ReaderHighlightArticle
    var highlights: [Highlight]
}

/// Highlights in the article web view: pushes the article's highlights to the page (Resources/
/// reader-highlights.js anchors and paints them), hears what the page reports (where they ended up, taps,
/// the state of a right-click) and offers the Mac right-click and iPhone edit-menu items that make them.
/// Runs in the same content world as the height script, `WKContentWorld.defaultClient`.
@MainActor
final class ReaderHighlightBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "openDispatchHighlights"

    /// reader-highlights.js from the app bundle, read once.
    static let script: String = {
        guard let url = Bundle.main.url(forResource: "reader-highlights", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return js
    }()

    private weak var webView: WKWebView?
    private var state: ReaderHighlightState?
    private var pageReady = false
    /// What the page was last given, so an unrelated update (a note edit) doesn't repaint.
    private var pushed: String?
    /// The newest right-click report from the page (Mac): the selection under it, or the highlight.
    private var context: (anchor: HighlightAnchor?, id: String?, at: Date)?

    // MARK: Setup

    func install(in config: WKWebViewConfiguration) {
        let world = WKContentWorld.defaultClient
        let controller = config.userContentController
        controller.add(ReaderWeakScriptHandler(self), contentWorld: world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
    }

    func attach(_ webView: WKWebView) { self.webView = webView }

    /// The coordinator is loading a new document: its highlights have to be given again.
    func pageWillLoad() {
        pageReady = false
        pushed = nil
        context = nil
    }

    func pageDidLoad() {
        pageReady = true
        push()
    }

    func update(_ state: ReaderHighlightState) {
        self.state = state
        push()
    }

    // MARK: Page

    private func push() {
        guard pageReady, let state, let webView else { return }
        let list = state.highlights.map { h -> [String: String] in
            ["id": h.id, "text": h.text, "prefix": h.prefix, "suffix": h.suffix, "color": h.color.rawValue]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8), json != pushed else { return }
        pushed = json
        run("window.__odHL && window.__odHL.set(\(json));", in: webView)
    }

    /// ObjC entry point: the Swift overlay variant needs libswiftWebKit.dylib, absent on iOS 18.
    private func run(_ js: String, in webView: WKWebView, _ done: @escaping (Any?) -> Void = { _ in }) {
        webView.__evaluateJavaScript(js, inFrame: nil, in: .defaultClient) { result, _ in done(result) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName, let body = message.body as? [String: Any],
              let type = body["type"] as? String, let state else { return }
        switch type {
        case "resolved":
            let order = body["order"] as? [String] ?? []
            let missing = Set(body["missing"] as? [String] ?? [])
            state.store.setResolution(.init(order: order, missing: missing), forKey: state.article.key)
        case "tap":
            if let id = body["id"] as? String { state.store.tapped(id, pane: state.article.pane, compact: state.article.compact) }
        case "context":
            context = (Self.anchor(body["anchor"]), body["id"] as? String, Date())
        default:
            break
        }
    }

    private static func anchor(_ value: Any?) -> HighlightAnchor? {
        guard let d = value as? [String: Any], let text = d["text"] as? String, !text.isEmpty else { return nil }
        return HighlightAnchor(text: text, prefix: d["prefix"] as? String ?? "", suffix: d["suffix"] as? String ?? "")
    }

    /// The selection as an anchor, asked of the page now.
    private func selectionAnchor(_ done: @escaping (HighlightAnchor?) -> Void) {
        guard let webView else { return done(nil) }
        run("JSON.stringify(window.__odHL ? window.__odHL.selectionAnchor() : null)", in: webView) { result in
            let object = (result as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
            Task { @MainActor in done(Self.anchor(object)) }
        }
    }

    /// Where a highlight starts in the page, for scrolling the reader to it; nil when it isn't in this version.
    func locate(_ id: String, _ done: @escaping (CGFloat?) -> Void) {
        guard let webView else { return done(nil) }
        run("window.__odHL ? window.__odHL.locate(\(Self.quote(id))) : null", in: webView) { result in
            let y = (result as? NSNumber).map { CGFloat($0.doubleValue) }
            Task { @MainActor in done(y) }
        }
    }

    private func clearSelection() {
        guard let webView else { return }
        run("window.__odHL && window.__odHL.clearSelection();", in: webView)
    }

    private static func quote(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]), let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    // MARK: Making and changing highlights

    /// Highlights the selection. With `note`, the panel opens on the new highlight's note.
    private func highlightSelection(color: HighlightColor, note: Bool, anchor known: HighlightAnchor?) {
        guard let state else { return }
        let make: (HighlightAnchor) -> Void = { [weak self] anchor in
            Task { @MainActor in
                guard let h = await state.store.add(anchor, in: state.article.item, color: color) else { return }
                self?.clearSelection()
                if note {
                    state.store.showPanel(pane: state.article.pane, compact: state.article.compact)
                    state.store.focusNote = h.id
                    state.store.point(at: h.id)
                }
            }
        }
        if let known { make(known) } else { selectionAnchor { if let a = $0 { make(a) } } }
    }

    func editNote(_ id: String) {
        guard let state else { return }
        state.store.showPanel(pane: state.article.pane, compact: state.article.compact)
        state.store.focusNote = id
        state.store.point(at: id)
    }

    // MARK: Mac right-click menu

    #if os(macOS)
    /// Items for the top of the right-click menu, like Apple Books': with text selected, the colors and
    /// Add Note…; over a highlight, the colors with a check on its own, Edit Note… and Remove Highlight.
    func macMenuItems() -> [NSMenuItem] {
        guard let state, let context, Date().timeIntervalSince(context.at) < 5 else { return [] }
        var items: [NSMenuItem] = []
        if let anchor = context.anchor {
            for color in HighlightColor.allCases {
                items.append(colorItem(color, checked: false) { [weak self] in
                    self?.highlightSelection(color: color, note: false, anchor: anchor)
                })
            }
            items.append(.separator())
            items.append(ReaderMenuItem("Add Note\u{2026}") { [weak self] in
                self?.highlightSelection(color: .yellow, note: true, anchor: anchor)
            })
            items.append(.separator())
        } else if let id = context.id, let h = state.store.highlight(id: id) {
            for color in HighlightColor.allCases {
                items.append(colorItem(color, checked: color == h.color) { state.store.setColor(id, color) })
            }
            items.append(.separator())
            items.append(ReaderMenuItem("Edit Note\u{2026}") { [weak self] in self?.editNote(id) })
            items.append(ReaderMenuItem("Remove Highlight") { state.store.remove(id) })
            items.append(.separator())
        }
        return items
    }

    private func colorItem(_ color: HighlightColor, checked: Bool, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ReaderMenuItem(color.title, action: action)
        item.image = color.menuImage
        item.state = checked ? .on : .off
        return item
    }
    #endif

    // MARK: iPhone edit menu

    #if os(iOS)
    /// Highlight (the colors and Underline) and Add Note, for the selection's edit menu.
    func editMenuElements() -> [UIMenuElement] {
        let colors = HighlightColor.allCases.map { color in
            UIAction(title: color.title, image: color.menuImage) { [weak self] _ in
                self?.highlightSelection(color: color, note: false, anchor: nil)
            }
        }
        let highlight = UIMenu(title: "Highlight", image: UIImage(systemName: OFIcon.highlighter.rawValue), children: colors)
        let note = UIAction(title: "Add Note", image: UIImage(systemName: "note.text.badge.plus")) { [weak self] _ in
            self?.highlightSelection(color: .yellow, note: true, anchor: nil)
        }
        return [highlight, note]
    }
    #endif
}

// MARK: Colors

extension HighlightColor {
    /// The color's solid swatch: menu circles, the panel's color bars.
    var swatchHex: UInt32 {
        switch self {
        case .yellow: 0xFFCC00
        case .green: 0x34C759
        case .blue: 0x0A84FF
        case .pink: 0xFF375F
        case .purple: 0xAF52DE
        case .underline: 0x007AFF
        }
    }

    var swatch: Color { Color(hex: swatchHex) }

    /// A small colored circle (an underlined A for Underline) for menu items.
    #if os(macOS)
    var menuImage: NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            if self == .underline {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 1.5, y: 1.5))
                path.line(to: NSPoint(x: 10.5, y: 1.5))
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                NSColor(rgb: self.swatchHex).setStroke()
                path.stroke()
                let a = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.labelColor])
                a.draw(at: NSPoint(x: 3, y: 2.5))
            } else {
                NSColor(rgb: self.swatchHex).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
    #else
    var menuImage: UIImage {
        let size = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: size).image { _ in
            if self == .underline {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 2, y: 12))
                path.addLine(to: CGPoint(x: 12, y: 12))
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                UIColor(rgb: swatchHex).setStroke()
                path.stroke()
                NSAttributedString(string: "A", attributes: [.font: UIFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: UIColor.label])
                    .draw(at: CGPoint(x: 3.5, y: 0))
            } else {
                UIColor(rgb: swatchHex).setFill()
                UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)).fill()
            }
        }.withRenderingMode(.alwaysOriginal)
    }
    #endif
}
