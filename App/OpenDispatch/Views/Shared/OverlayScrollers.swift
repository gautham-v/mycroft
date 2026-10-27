import SwiftUI

extension View {
    /// macOS: show the vertical scroller of the scroll view this is attached to only while the pointer
    /// is over that scroll view, as an overlay (no reserved gutter) drawn as Claude's thin pill
    /// (ThinScroller), whatever System Settings says about showing scroll bars. Attach to the
    /// `ScrollView` / `List` itself. No-op elsewhere.
    func overlayScrollers() -> some View {
        #if os(macOS)
        background(OverlayScrollerFinder())
        #else
        self
        #endif
    }

    /// Room at the top of a scroll view for a bar its content scrolls under (`contentMargins`). On macOS
    /// the margin reaches AppKit as an automatic content inset, which AppKit recomputes to zero when
    /// the window resigns key, so the rows jumped by the bar's height on every click into another
    /// window; the inset is pinned there too (TopInsetFinder).
    func topContentInset(_ inset: CGFloat) -> some View {
        contentMargins(.top, inset, for: .scrollContent)
            .contentMargins(.top, inset, for: .scrollIndicators)
            #if os(macOS)
            .background(TopInsetFinder(inset: inset))
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
            guard let scrollView = nearestScrollView(from: self) else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            if !(scrollView.verticalScroller is ThinScroller) {
                let scroller = ThinScroller()
                scrollView.verticalScroller = scroller
                scroller.track(scrollView)
            }
        }
    }
}

/// `.background` places a probe view beside the scroll view, not inside it: look up a few levels,
/// then down for the nearest NSScrollView.
private func nearestScrollView(from probe: NSView) -> NSScrollView? {
    var container: NSView? = probe.superview
    var hops = 0
    while let c = container, hops < 4 {
        if let found = firstScrollView(in: c) { return found }
        container = c.superview
        hops += 1
    }
    return nil
}

private func firstScrollView(in root: NSView) -> NSScrollView? {
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

private struct TopInsetFinder: NSViewRepresentable {
    let inset: CGFloat

    func makeNSView(context: Context) -> FinderView { FinderView() }
    func updateNSView(_ nsView: FinderView, context: Context) {
        nsView.inset = inset
        nsView.apply()
    }

    final class FinderView: NSView {
        var inset: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Fixed insets: AppKit stops deriving them from the window, so key changes leave them alone.
        func apply() {
            guard let scrollView = nearestScrollView(from: self) else { return }
            let insets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
            if scrollView.automaticallyAdjustsContentInsets { scrollView.automaticallyAdjustsContentInsets = false }
            if scrollView.contentInsets.top != inset {
                // At the top, stay at the top; otherwise keep the rows where they are on screen.
                let old = scrollView.contentInsets.top
                let current = scrollView.contentView.bounds.origin.y
                let y = current <= -old + 1 ? -inset : current
                scrollView.contentInsets = insets
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }
}

/// Claude desktop's scroller: a 6pt grey pill 2pt in from the edge, no track, and no widening on hover.
/// Shown only while the pointer is over its scroll view: AppKit's overlay fade-in and fade-out go
/// through `alphaValue`, which this pins to the hover state.
final class ThinScroller: NSScroller {
    private static let knobWidth: CGFloat = 6
    private static let edgeInset: CGFloat = 2

    private var pointerInside = false {
        didSet { super.alphaValue = pointerInside ? 1 : 0 }
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override var alphaValue: CGFloat {
        get { super.alphaValue }
        set { super.alphaValue = pointerInside ? 1 : 0 }
    }

    /// Follows the pointer in and out of `scrollView`.
    func track(_ scrollView: NSScrollView) {
        scrollView.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        if let window = scrollView.window {
            let p = scrollView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            pointerInside = scrollView.bounds.contains(p)
        } else {
            pointerInside = false
        }
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false }

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
        TrafficLightsView.install(in: window)
        TitlebarRightClicks.install(in: window)
        if let content = window.contentView { HairlineSplitView.adopt(in: content) }
    }
}

/// The close / minimize / zoom buttons where the Claude desktop app has them: centred
/// `Metrics.trafficLightCenter` from the window's top and left edges, 20pt apart. AppKit pins its own
/// buttons to the compact toolbar row (3pt higher and to the left) and re-applies that through Auto
/// Layout whenever the title bar re-lays out (e.g. a column is toggled), so moving them flickers or
/// snaps back. Instead this view holds a second set of standard buttons at the Claude spot, above the
/// title bar, and AppKit's own are made transparent (they keep working underneath, at nearly the
/// same spot). In full screen AppKit's buttons come back and these hide.
final class TrafficLightsView: NSView {
    private static let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private var buttons: [NSButton] = []
    private var hovering = false
    private var observers: [NSObjectProtocol] = []

    static func install(in window: NSWindow) {
        guard let frameView = window.contentView?.superview else { return }
        let lights = frameView.subviews.compactMap { $0 as? TrafficLightsView }.first ?? {
            let v = TrafficLightsView(window: window)
            frameView.addSubview(v, positioned: .above, relativeTo: nil)
            return v
        }()
        lights.sync()
    }

    private init(window: NSWindow) {
        let side = Metrics.trafficLightCenter * 2
        super.init(frame: NSRect(x: 0, y: window.frame.height - side, width: side + 40, height: side))
        autoresizingMask = [.maxXMargin, .minYMargin]
        for (i, kind) in Self.kinds.enumerated() {
            guard let b = NSWindow.standardWindowButton(kind, for: window.styleMask) else { continue }
            b.setFrameOrigin(NSPoint(x: Metrics.trafficLightCenter + CGFloat(i) * 20 - b.frame.width / 2,
                                     y: Metrics.trafficLightCenter - b.frame.height / 2))
            addSubview(b)
            buttons.append(b)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                          NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                                          NSWindow.willEnterFullScreenNotification]
        observers = names.map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows this set or AppKit's (full screen), and redraws for the window's key state.
    func sync() {
        guard let window else { return }
        let fullScreen = window.styleMask.contains(.fullScreen) || !window.styleMask.contains(.titled)
        isHidden = fullScreen
        for kind in Self.kinds { window.standardWindowButton(kind)?.alphaValue = fullScreen ? 1 : 0 }
        buttons.forEach { $0.needsDisplay = true }
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ value: Bool) {
        hovering = value
        buttons.forEach { $0.needsDisplay = true }
    }

    /// Asked by the standard buttons: show their x / – / + glyphs while the pointer is over the group.
    @objc func _mouseInGroup(_ button: NSButton) -> Bool { hovering }

    /// Only the buttons take clicks; the rest of the strip passes through to the content below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Right-clicks on the title-bar row (the reader's tabs, the list header) reach the content below.
/// The window's toolbar view sits over that row and takes right-clicks without showing a menu, so
/// SwiftUI context menus there (Pin Tab, Close Tab) never opened; left clicks AppKit already passes on.
@MainActor
final class TitlebarRightClicks {
    private static var windows = Set<ObjectIdentifier>()

    static func install(in window: NSWindow) {
        guard windows.insert(ObjectIdentifier(window)).inserted else { return }
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak window] event in
            let point = event.locationInWindow
            let forwarded = MainActor.assumeIsolated { () -> Bool in
                guard let window, event.window === window, let content = window.contentView,
                      let frame = content.superview,
                      let hit = frame.hitTest(frame.convert(point, from: nil)),
                      !hit.isDescendant(of: content), !(hit is NSControl),
                      let target = content.hitTest(content.convert(point, from: nil))
                else { return false }
                target.rightMouseDown(with: event)
                return true
            }
            return forwarded ? nil : event
        }
    }
}

/// The column dividers of NavigationSplitView's NSSplitView, which AppKit draws near-black. SwiftUI
/// owns the split view, so its class is swapped in place (this subclass adds no storage). The
/// list | reader divider takes the hairline color the rows and reader bar use. The sidebar divider
/// is a CoreUI image plus a 1pt strip of sidebar material, neither of which takes a color, so both
/// are hidden and a HairlineStrip draws a 1pt hairline tint in their place.
final class HairlineSplitView: NSSplitView {
    override var dividerColor: NSColor { NSColor(.ofHairline) }

    static func adopt(in root: NSView) {
        if type(of: root) == NSSplitView.self {
            object_setClass(root, HairlineSplitView.self)
        }
        if let split = root as? HairlineSplitView {
            split.subviews.forEach(split.restyle)
            split.restoreSidebarWidth()
            return
        }
        root.subviews.forEach(adopt(in:))
    }

    /// SwiftUI leaves the sidebar's split-view item at a 140pt minimum and no maximum whatever
    /// `navigationSplitViewColumnWidth` says, and AppKit restores whatever width was saved: bring a
    /// saved width outside the sidebar's limits back inside them.
    func restoreSidebarWidth() {
        guard isVertical, let sidebar = arrangedSubviews.first, !isSubviewCollapsed(sidebar), !sidebar.isHidden else { return }
        let width = min(max(sidebar.frame.width, Metrics.sidebarMinWidth), Metrics.sidebarMaxWidth)
        if abs(width - sidebar.frame.width) > 0.5 { setPosition(width, ofDividerAt: 0) }
    }

    /// Divider drags, handled here so the columns resize independently. AppKit's own tracking moves
    /// only the two columns beside a divider and, once the list reaches its minimum, keeps going by
    /// shrinking the sidebar. Here each column keeps to its limits and the reader takes up the
    /// difference: the sidebar's divider resizes the sidebar and carries the list along unchanged,
    /// the list's divider resizes the list.
    override func mouseDown(with event: NSEvent) {
        let views = arrangedSubviews
        let point = convert(event.locationInWindow, from: nil)
        guard isVertical, views.count == 3, let window,
              let index = (0..<2).first(where: { i in
                  !isSubviewCollapsed(views[i]) && !isSubviewCollapsed(views[i + 1])
                      && abs(point.x - (views[i].frame.maxX + dividerThickness / 2)) <= 4
              })
        else { return super.mouseDown(with: event) }

        let column = views[index]
        let grab = point.x - column.frame.maxX
        let listWidth = views[1].frame.width
        // Leave the reader at least this much.
        let readerMin: CGFloat = 360
        let range: ClosedRange<CGFloat>
        if index == 0 {
            let most = max(Metrics.sidebarMinWidth, min(Metrics.sidebarMaxWidth, bounds.width - 2 * dividerThickness - listWidth - readerMin))
            range = Metrics.sidebarMinWidth...most
        } else {
            range = (column.frame.minX + Metrics.listMinWidth)...(column.frame.minX + Metrics.listMaxWidth)
        }
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { ev, stop in
            guard let ev else { return }
            let x = min(max(self.convert(ev.locationInWindow, from: nil).x - grab, range.lowerBound), range.upperBound)
            if index == 0 {
                // Move the far divider first when growing so the list never gets squeezed in between.
                let listEdge = x + self.dividerThickness + listWidth
                if x > column.frame.maxX {
                    self.setPosition(listEdge, ofDividerAt: 1)
                    self.setPosition(x, ofDividerAt: 0)
                } else {
                    self.setPosition(x, ofDividerAt: 0)
                    self.setPosition(listEdge, ofDividerAt: 1)
                }
            } else {
                self.setPosition(x, ofDividerAt: 1)
            }
            if ev.type == .leftMouseUp { stop.pointee = true }
        }
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
            for v in divider.subviews where !(v is HairlineStrip) { v.isHidden = true }
            if !divider.subviews.contains(where: { $0 is HairlineStrip }) {
                // The divider overlaps the sidebar's last 3pt; only its trailing point shows.
                let strip = HairlineStrip(frame: NSRect(x: divider.bounds.width - 1, y: 0, width: 1, height: divider.bounds.height))
                strip.autoresizingMask = [.minXMargin, .height]
                divider.addSubview(strip)
            }
        default:
            break
        }
    }
}
/// A 1pt line in the sidebar's hairline tint (the sidebar divider, see HairlineSplitView).
final class HairlineStrip: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(.ofNavHairline).setFill()
        bounds.fill(using: .sourceOver)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
