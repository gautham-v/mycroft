import SwiftUI

extension View {
    /// macOS: show the scrollers of the scroll view this is attached to as overlays that fade out
    /// after scrolling, even when System Settings asks for scroll bars to be shown always. Attach to
    /// the `ScrollView` / `List` itself. No-op elsewhere.
    func overlayScrollers() -> some View {
        #if os(macOS)
        background(OverlayScrollerFinder())
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct OverlayScrollerFinder: NSViewRepresentable {
    func makeNSView(context: Context) -> FinderView { FinderView() }
    func updateNSView(_ nsView: FinderView, context: Context) { nsView.apply() }

    final class FinderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply() {
            // `.background` places this view beside the scroll view, not inside it: look up a few
            // levels, then down for the nearest NSScrollView.
            var container: NSView? = superview
            var found: NSScrollView?
            var hops = 0
            while let c = container, found == nil, hops < 4 {
                found = Self.firstScrollView(in: c)
                container = c.superview
                hops += 1
            }
            guard let scrollView = found else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }

        private static func firstScrollView(in root: NSView) -> NSScrollView? {
            var queue: [NSView] = [root]
            var depth = 0
            while !queue.isEmpty, depth < 8 {
                var next: [NSView] = []
                for v in queue {
                    if let sv = v as? NSScrollView { return sv }
                    next.append(contentsOf: v.subviews)
                }
                queue = next
                depth += 1
            }
            return nil
        }
    }
}

/// Hides the window toolbar that NavigationSplitView installs and lets content run under the
/// (hidden) title bar, so the three columns reach the top edge like the Claude desktop app.
struct FlushWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView {
        let v = ChromeView()
        DispatchQueue.main.async { Self.apply(to: v.window) }
        return v
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
    }

    /// Re-applies after resizes and full-screen transitions, which re-layout the title bar.
    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didEndLiveResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    FlushWindowChrome.apply(to: window)
                })
            }
            FlushWindowChrome.apply(to: window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    static func apply(to window: NSWindow?) {
        guard let window else { return }
        defer { centerTrafficLights(window) }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unifiedCompact
        if let toolbar = window.toolbar, toolbar.isVisible {
            toolbar.isVisible = false
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let b = window.standardWindowButton(kind) {
                b.isHidden = false
                b.superview?.isHidden = false
            }
        }
    }

    /// Moves the close / minimize / zoom buttons so their centre sits `Metrics.titleStripHeight / 2`
    /// below the top edge (AppKit puts them 14pt down), keeping their standard x positions.
    static func centerTrafficLights(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = window.standardWindowButton(kind), let sup = b.superview else { continue }
            let frameInWindow = sup.convert(b.frame, to: nil)
            let targetCenterY = window.frame.height - Metrics.titleStripHeight / 2
            let dy = targetCenterY - frameInWindow.midY
            // Default x of the close button is 7pt; the others keep their 20pt pitch.
            let defaultX: CGFloat = kind == .closeButton ? 7 : kind == .miniaturizeButton ? 27 : 47
            let dx = (defaultX + Metrics.trafficLightShift) - frameInWindow.minX
            guard abs(dy) > 0.5 || abs(dx) > 0.5 else { continue }
            var f = b.frame
            f.origin.y += sup.isFlipped ? -dy : dy
            f.origin.x += dx
            b.frame = f
        }
    }
}
#endif
