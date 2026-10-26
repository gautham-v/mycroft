import SwiftUI

extension View {
    /// macOS: show the scrollers of the scroll view this is attached to as overlays that fade out
    /// after scrolling, even when System Settings asks for scroll bars to be shown always, drawn as
    /// Claude's thin pill (ThinScroller). Attach to the `ScrollView` / `List` itself. No-op elsewhere.
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
            if !(scrollView.verticalScroller is ThinScroller) {
                scrollView.verticalScroller = ThinScroller()
            }
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

/// Claude desktop's scroller: a 6pt grey pill 2pt in from the edge, no track, and no widening on hover.
final class ThinScroller: NSScroller {
    private static let knobWidth: CGFloat = 6
    private static let edgeInset: CGFloat = 2

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        let w = Self.knobWidth
        let pill = NSRect(x: bounds.maxX - Self.edgeInset - w, y: knob.minY + Self.edgeInset,
                          width: w, height: knob.height - Self.edgeInset * 2)
        NSColor(.ofScroller).setFill()
        NSBezierPath(roundedRect: pill, xRadius: w / 2, yRadius: w / 2).fill()
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
        if let content = window.contentView { HairlineSplitView.adopt(in: content) }
    }
}

/// The column dividers of NavigationSplitView's NSSplitView, which AppKit draws near-black. SwiftUI
/// owns the split view, so its class is swapped in place (this subclass adds no storage). The
/// list | reader divider takes the hairline color the rows and reader bar use. The sidebar divider
/// is a CoreUI image that ignores colors, so it is hidden and the list column draws that hairline
/// itself (RootView).
final class HairlineSplitView: NSSplitView {
    override var dividerColor: NSColor { NSColor(.ofHairline) }

    static func adopt(in root: NSView) {
        if type(of: root) == NSSplitView.self {
            object_setClass(root, HairlineSplitView.self)
        }
        if let split = root as? HairlineSplitView {
            split.subviews.forEach(split.restyle)
            return
        }
        root.subviews.forEach(adopt(in:))
    }

    // Dividers are rebuilt when columns show or hide.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        restyle(subview)
    }

    private func restyle(_ divider: NSView) {
        switch NSStringFromClass(type(of: divider)) {
        case "NSSplitDividerView":
            let setter = Selector(("setBackgroundColor:"))
            if divider.responds(to: setter) { divider.perform(setter, with: dividerColor) }
        case "NSVibrantSplitDividerView":
            for v in divider.subviews where NSStringFromClass(type(of: v)) == "NSSplitDividerView" { v.isHidden = true }
        default:
            break
        }
    }
}
#endif
