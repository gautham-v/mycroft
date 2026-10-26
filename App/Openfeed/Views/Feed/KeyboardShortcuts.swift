import OpenfeedCore
import SwiftUI
#if os(macOS)
import AppKit
import WebKit
#endif

/// Single-key shortcuts from src/hooks/use-keyboard.ts:
///   j / ↓ next item, k / ↑ previous, o / Enter open original, s save or unsave, r refresh,
///   / search, ? shortcuts, g then a / s / v / p (within 1 s) for All / Saved / Video / Podcasts,
///   Esc clears an open search, else leaves the full-screen reader.
/// ⌘\, ⇧⌘F, ⌘F, ⌘R and ⌘/ are menu commands (OpenfeedApp.swift).
///
/// macOS: a local key monitor scoped to the window hosting the list. Keys pass through while a text
/// field has focus (except Esc in the search field), while a sheet is attached, or with ⌘/⌃/⌥ held.
/// Arrows keep scrolling the article after the last click landed right of the list (the reader),
/// like the web's `readerClicked`.
/// iPad with a hardware keyboard (regular width): hidden buttons with `.keyboardShortcut`.
/// iPhone: off, as on the web (single keys need the list and reader side by side).
extension View {
    func feedKeyboardShortcuts(searchFocus: FocusState<Bool>.Binding) -> some View {
        modifier(FeedKeyboardShortcutsModifier(searchFocus: searchFocus))
    }
}

/// The keys the handler understands.
enum FeedKey: Equatable {
    case down, up, enter, escape
    case char(Character)
}

/// Shared shortcut logic (both platforms). Holds the pending "g" chord.
@MainActor
final class FeedKeyHandler {
    private static let chordInterval: TimeInterval = 1
    private static let chords: [Character: FeedView] = ["a": .all, "s": .saved, "v": .video, "p": .podcasts]
    private var gAt: Date?

    /// Returns true when the key was handled (and should be swallowed).
    func handle(_ key: FeedKey, model: AppModel, openURL: (URL) -> Void, focusSearch: () -> Void) -> Bool {
        if key == .escape {
            guard model.isSourceFilterOpen || model.isSearchOpen || model.focusMode else { return false }
            model.escape()
            return true
        }
        if let at = gAt, Date().timeIntervalSince(at) < Self.chordInterval {
            gAt = nil
            if case .char(let c) = key, let view = Self.chords[c] {
                model.navigate(view: view)
                return true
            }
            return false
        }
        gAt = nil

        switch key {
        case .down, .char("j"):
            model.moveSelection(by: 1)
        case .up, .char("k"):
            model.moveSelection(by: -1)
        case .enter, .char("o"):
            guard let item = model.selectedItem, let url = URL(string: item.item.url) else { return true }
            openURL(url)
        case .char("s"):
            Task { await model.toggleSavedOnSelection() }
        case .char("r"):
            if !model.isRefreshing { Task { await model.refresh(force: true) } }
        case .char("/"):
            focusSearch()
        case .char("?"):
            model.isShortcutsPresented.toggle()
        case .char("g"):
            gAt = Date()
        default:
            return false
        }
        return true
    }
}

private struct FeedKeyboardShortcutsModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    var searchFocus: FocusState<Bool>.Binding
    @State private var handler = FeedKeyHandler()
    #if os(macOS)
    @State private var monitor = FeedKeyMonitor()
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .background(FeedHostWindowReader {
                monitor.window = $0
                ReaderWindow.current = $0
            })
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).maxX
            } action: { maxX in
                monitor.listMaxX = maxX
            }
            .onAppear {
                monitor.onKey = { key, typingInSearch in
                    if typingInSearch {
                        // Only Esc reaches here while the search field has focus.
                        searchFocus.wrappedValue = false
                        model.closeSearch()
                        return true
                    }
                    return handler.handle(key, model: model, openURL: { openURL($0) }, focusSearch: focusSearch)
                }
                monitor.isSearchFocused = { searchFocus.wrappedValue }
                monitor.install()
            }
            .onDisappear { monitor.uninstall() }
        #else
        content
            .background {
                if horizontalSizeClass == .regular { iPadShortcutButtons }
            }
        #endif
    }

    private func focusSearch() {
        model.openSearch()
        Task { @MainActor in
            await Task.yield()
            searchFocus.wrappedValue = true
        }
    }

    #if os(iOS)
    private static let characterKeys: [Character] = ["j", "k", "o", "s", "r", "/", "?", "g", "a", "v", "p"]

    /// Invisible buttons that register UIKeyCommands; text fields keep priority for plain keys.
    private var iPadShortcutButtons: some View {
        ZStack {
            ForEach(Self.characterKeys, id: \.self) { c in
                shortcutButton(KeyEquivalent(c), modifiers: c == "?" ? .shift : []) { .char(c) }
            }
            shortcutButton(.downArrow) { .down }
            shortcutButton(.upArrow) { .up }
            shortcutButton(.return) { .enter }
            shortcutButton(.escape) { .escape }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func shortcutButton(_ key: KeyEquivalent, modifiers: EventModifiers = [], _ make: @escaping () -> FeedKey) -> some View {
        Button("") {
            _ = handler.handle(make(), model: model, openURL: { openURL($0) }, focusSearch: focusSearch)
        }
        .keyboardShortcut(key, modifiers: modifiers)
    }
    #endif
}

#if os(macOS)
/// The window hosting the item list (the reader window), so the Close Tab command (⌘W) can tell it
/// from Settings.
@MainActor
enum ReaderWindow {
    static weak var current: NSWindow?
}

/// Local NSEvent monitors for key-down (shortcuts) and mouse-down (which pane was clicked last).
@MainActor
private final class FeedKeyMonitor {
    weak var window: NSWindow?
    /// Right edge of the list column in window coordinates; clicks right of it are in the reader.
    var listMaxX: CGFloat = 0
    var onKey: ((FeedKey, _ typingInSearch: Bool) -> Bool)?
    var isSearchFocused: (() -> Bool)?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var readerClicked = false
    /// The reader's vertical ScrollView under the last reader click; nil when the click landed in an
    /// embedded web player (YouTube), which keeps its own arrow keys.
    private weak var readerScrollView: NSScrollView?

    private static func readerScrollTarget(in window: NSWindow, at point: NSPoint) -> NSScrollView? {
        guard let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else { return nil }
        var v: NSView? = hit
        while let view = v {
            if view is WKWebView, !(view is ReaderFittedWebView) { return nil }
            v = view.superview
        }
        return ReaderScrollKeys.verticalScrollView(enclosing: hit)
    }

    func install() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let window = self.window, event.window === window {
                    self.readerClicked = event.locationInWindow.x > self.listMaxX
                    self.readerScrollView = self.readerClicked ? Self.readerScrollTarget(in: window, at: event.locationInWindow) : nil
                }
            }
            return event
        }
    }

    func uninstall() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil, window.isKeyWindow else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.intersection([.command, .control, .option]).isEmpty { return false }

        let typing = window.firstResponder is NSText
        let isEscape = event.keyCode == 53
        if typing {
            // Esc in the search field closes it (search-field.tsx); every other key types.
            if isEscape, isSearchFocused?() == true { return onKey?(.escape, true) ?? false }
            return false
        }

        // After a click in the reader, scroll keys scroll the article (the web's readerClicked).
        if readerClicked, let scrollView = readerScrollView, scrollView.window === window,
           ReaderScrollKeys.scroll(scrollView, for: event) {
            return true
        }

        let key: FeedKey
        switch event.keyCode {
        case 53: key = .escape
        case 125, 126:
            // Arrows keep scrolling the article after a click in the reader.
            if readerClicked { return false }
            key = event.keyCode == 125 ? .down : .up
        case 36, 76: key = .enter
        default:
            guard let chars = event.characters, chars.count == 1, let c = chars.first else { return false }
            key = .char(c)
        }
        return onKey?(key, false) ?? false
    }
}

/// Reports the NSWindow hosting this view (so the key monitor ignores other windows, like Settings).
private struct FeedHostWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowProbeView {
        let v = WindowProbeView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class WindowProbeView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
#endif
