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

/// Lets content run under the (hidden) title bar so the three columns reach the top edge. The
/// window keeps its toolbar (drawn transparent, with no items) so AppKit itself lays out the traffic
/// lights on the unified-compact row; nothing is moved by hand.
struct FlushWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { Self.apply(to: v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
    }

    static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unifiedCompact
        window.toolbar?.isVisible = true
        window.toolbar?.showsBaselineSeparator = false
    }
}
#endif
