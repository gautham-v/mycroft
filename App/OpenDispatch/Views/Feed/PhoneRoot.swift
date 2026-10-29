#if os(iOS)
import OpenDispatchCore
import SwiftUI
import UIKit

/// The home list's horizontal slide while swiping between views (PhoneRoot drives it; the list reads it).
/// A reference type of its own so the per-frame drag only re-evaluates the small modifier that offsets the
/// list, not the list or PhoneRoot.
@MainActor @Observable final class PhoneChrome {
    /// How far the list is displaced sideways (following the finger, then the slide on a view change).
    var pageOffset: CGFloat = 0
    /// The list is switching to the view it slid to (a couple of frames): swipes wait for it.
    var isSwapping = false
    /// A finger is scrubbing the page dots (`PhonePageDots`): sideways swipes leave the list alone.
    @ObservationIgnored var isScrubbing = false
    /// The views on either side of the list, kept while a view change slides so the page sliding in
    /// beside the list doesn't change under the finger when the view switches.
    var previousPage: FeedView?
    var nextPage: FeedView?
    /// The first rows of the views beside the list, so the page sliding in shows them instead of an empty
    /// screen.
    var peekItems: [FeedView: [FeedItem]] = [:]

    /// Where the slide was when the current swipe caught it (0 from rest).
    @ObservationIgnored var swipeBase: CGFloat = 0

    // A spring driven frame by frame rather than a SwiftUI animation, so `pageOffset` is always where the
    // list is on screen and a swipe can catch the slide mid-flight.
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var target: CGFloat = 0
    @ObservationIgnored private var velocity: CGFloat = 0
    @ObservationIgnored private var lastTime: CFTimeInterval = 0
    @ObservationIgnored private var onLand: (() -> Void)?

    /// The list is sliding on its own (not under the finger).
    var isSliding: Bool { link != nil }

    /// Slides the list to `target`, starting at `velocity` (points per second), and calls `onLand` there.
    func slide(to target: CGFloat, velocity: CGFloat, onLand: (() -> Void)? = nil) {
        stopSliding()
        self.target = target
        self.velocity = velocity
        self.onLand = onLand
        lastTime = CACurrentMediaTime()
        let link = CADisplayLink(target: PhoneSlideTicker(self), selector: #selector(PhoneSlideTicker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Stops the slide where it is (a swipe caught it).
    func stopSliding() {
        link?.invalidate()
        link = nil
        onLand = nil
    }

    /// One frame of a critically damped spring (no overshoot) that settles in about a quarter second.
    fileprivate func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(1.0 / 30, max(0, now - lastTime))
        lastTime = now
        let omega: CGFloat = 2 * .pi / 0.3
        let x = pageOffset - target
        let decay = exp(-omega * dt)
        let nextX = (x + (velocity + omega * x) * dt) * decay
        velocity = (velocity - omega * (velocity + omega * x) * dt) * decay
        if abs(nextX) < 1, abs(velocity) < 60 {
            pageOffset = target
            let landed = onLand
            stopSliding()
            landed?()
        } else {
            pageOffset = target + nextX
        }
    }
}

/// The display link's target: CADisplayLink retains it, and it holds the chrome weakly.
private final class PhoneSlideTicker: NSObject {
    weak var chrome: PhoneChrome?

    init(_ chrome: PhoneChrome) { self.chrome = chrome }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let chrome else { return link.invalidate() }
        chrome.step(link)
    }
}

extension AppModel {
    /// The views the iPhone's page dots and horizontal swipe cycle through: the sidebar's content views in
    /// order (All, Articles, Posts, Video, Podcasts), less the ones hidden in Settings.
    var phonePages: [FeedView] {
        SidebarViewItem.ordered.compactMap { item in
            guard case .view(let view) = item, view != .saved, !isSidebarViewHidden(item) else { return nil }
            return view
        }
    }

    /// Where the list sits among `phonePages`; nil when it shows a folder, a source, Saved, Highlights, History or Explore.
    var phonePageIndex: Int? {
        guard !isInSourceFeed, !showsHighlights, !showsHistory, !showsExplore else { return nil }
        return phonePages.firstIndex(of: selectedView)
    }
}

/// Opens the iPhone drawer; the list's hamburger button calls it.
struct PhoneDrawerControl: Sendable {
    var open: @MainActor @Sendable () -> Void = {}
}

private struct PhoneDrawerKey: EnvironmentKey {
    static let defaultValue = PhoneDrawerControl()
}

private struct FeedStackPushedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var phoneDrawer: PhoneDrawerControl {
        get { self[PhoneDrawerKey.self] }
        set { self[PhoneDrawerKey.self] = newValue }
    }

    /// Something is pushed above the iPhone's home list, so the home list must not present the search field or
    /// the reader. Nothing pushes onto the home stack now (the drawer manages folders and sources itself), so
    /// this stays false.
    var isFeedStackPushed: Bool {
        get { self[FeedStackPushedKey.self] }
        set { self[FeedStackPushedKey.self] = newValue }
    }
}

/// The iPhone layout (compact width): a single NavigationStack around the home list (the Feed, Saved or
/// Highlights, by what the drawer picked), with a Duet-style side drawer behind it. The drawer opens from
/// the list's hamburger bubble or a swipe: in from the left edge, or right on the first view or on a list
/// that is not one of the five content views. Sideways swipes otherwise move between those views (page
/// dots). The drawer covers 82% of the width, and the list slides right, dims, shrinks a little and
/// rounds its corners as a peek; tapping the peek or swiping left closes it. Opening a row pushes the
/// reader onto the stack; Settings and Add source are sheets (RootView).
///
/// The swipes are one UIKit pan recognizer on the hosting view (`PhoneSwipeBridge`), not a SwiftUI
/// gesture: the list's scroll view takes the touch first and a SwiftUI drag on a parent never fired.
struct PhoneRoot: View {
    @Environment(AppModel.self) private var model
    /// The drawer is open (or opening: a drag in progress is tracked by `drag`).
    @State private var isOpen = false
    /// Finger travel while dragging the drawer open or closed.
    @State private var drag: CGFloat = 0
    @State private var chrome = PhoneChrome()

    private static let drawerFraction: CGFloat = 0.82
    /// An edge swipe starts within this distance of the screen's left edge.
    private static let edgeWidth: CGFloat = 30
    /// A sideways swipe this far (with its momentum) changes view.
    private static let pageThreshold: CGFloat = 60

    var body: some View {
        // The outer reader only learns the safe area (the drawer's content keeps clear of the status bar
        // and home indicator); the inner one fills the screen.
        GeometryReader { outer in
            screen(safeArea: outer.safeAreaInsets)
        }
        .background(Color.ofDrawer.ignoresSafeArea())
    }

    private func screen(safeArea: EdgeInsets) -> some View {
        GeometryReader { geo in
            let width = geo.size.width * Self.drawerFraction
            let progress = progress(width: width)
            ZStack(alignment: .leading) {
                PhoneDrawer(safeArea: safeArea, isOpen: isOpen, close: close)
                    .frame(width: width)
                    .accessibilityHidden(!isOpen)
                stack
                    .overlay {
                        if progress > 0 {
                            // A UIKit shield, not a SwiftUI color: the list underneath is a UIKit view that
                            // would still take the touch (and open the row under the finger).
                            TouchShield(onTap: close)
                                .overlay { Color.black.opacity(0.3 * progress).allowsHitTesting(false) }
                                .accessibilityHidden(true)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 40 * progress, style: .continuous))
                    .shadow(color: .black.opacity(0.18 * progress), radius: 16)
                    .scaleEffect(1 - 0.08 * progress, anchor: .leading)
                    .offset(x: width * progress)
                    .accessibilityHidden(isOpen)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .background(Color.ofDrawer)
            .background {
                PhoneSwipeBridge(
                    begin: { swipeBegin(startX: $0, velocity: $1) },
                    changed: { swipeChanged($0, translation: $1, drawerWidth: width, pageWidth: geo.size.width) },
                    ended: { swipeEnded($0, translation: $1, velocity: $2, drawerWidth: width, pageWidth: geo.size.width) })
            }
        }
        .ignoresSafeArea(.container)
    }

    private var stack: some View {
        NavigationStack {
            FeedColumn(isPhoneHome: true)
        }
        .environment(\.phoneDrawer, PhoneDrawerControl(open: { open() }))
        .environment(chrome)
        .task(id: PeekKey(index: model.phonePageIndex, pages: model.phonePages, firstID: model.items.first?.id)) {
            await loadPeeks()
        }
    }

    /// What the rows beside the list are loaded for: they reload on a view change and after a refresh
    /// (which brings new rows to the top of the list too).
    private struct PeekKey: Equatable {
        let index: Int?
        let pages: [FeedView]
        let firstID: Int64?
    }

    /// Loads the first rows of the views on either side of the list (local queries).
    private func loadPeeks() async {
        if chrome.pageOffset == 0, !chrome.isSwapping { syncNeighbors() }
        guard let index = model.phonePageIndex else { return }
        let pages = model.phonePages
        for neighbor in [index - 1, index + 1] where pages.indices.contains(neighbor) {
            let view = pages[neighbor]
            guard let page = try? await model.database.items(ItemQuery(view: view, limit: PhonePagePeek.rows)) else { continue }
            chrome.peekItems[view] = page.items
        }
    }

    /// Points the pages beside the list at the views on either side of it, or none off the content views.
    private func syncNeighbors() {
        let pages = model.phonePages
        guard let index = model.phonePageIndex else {
            chrome.previousPage = nil
            chrome.nextPage = nil
            return
        }
        chrome.previousPage = index > 0 ? pages[index - 1] : nil
        chrome.nextPage = index < pages.count - 1 ? pages[index + 1] : nil
    }

    // MARK: Opening and closing

    /// 0 closed, 1 open, following the finger while dragging.
    private func progress(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(1, max(0, ((isOpen ? width : 0) + drag) / width))
    }

    private func open() { settle(open: true) }
    private func close() { settle(open: false) }

    private func settle(open: Bool) {
        withAnimation(.smooth(duration: 0.32)) {
            isOpen = open
            drag = 0
        }
    }

    // MARK: Swipes

    /// Whether a swipe may do anything: with the drawer open, or on the home list. With the reader pushed the
    /// stack's own swipe back owns the left edge.
    private var swipesEnabled: Bool {
        isOpen || model.selectedItemID == nil
    }

    /// What a horizontal swipe that starts at `startX` moving at `velocity` (points per second) does, or
    /// nil to leave it alone. Open drawer: swiping left closes it. A swipe that catches the list sliding
    /// between views takes it from there. Otherwise, from the left edge, rightwards on the first view (or
    /// on a list that isn't one of the five views) it opens the drawer, else it moves between the views.
    private func swipeBegin(startX: CGFloat, velocity: CGFloat) -> PhoneSwipeMode? {
        guard swipesEnabled, !chrome.isSwapping, !chrome.isScrubbing else { return nil }
        if isOpen { return velocity < 0 ? .drawer : nil }
        if chrome.isSliding || chrome.pageOffset != 0 {
            chrome.stopSliding()
            chrome.swipeBase = chrome.pageOffset
            return .pager
        }
        if startX < Self.edgeWidth, velocity > 0 { return .drawer }
        if let index = model.phonePageIndex, !model.isSearchOpen {
            if index == 0 && velocity > 0 { return .drawer }
            syncNeighbors()
            chrome.swipeBase = 0
            return .pager
        }
        return velocity > 0 ? .drawer : nil
    }

    private func swipeChanged(_ mode: PhoneSwipeMode, translation: CGFloat, drawerWidth: CGFloat, pageWidth: CGFloat) {
        switch mode {
        case .drawer:
            drag = isOpen ? min(0, max(-drawerWidth, translation)) : min(drawerWidth, max(0, translation))
        case .pager:
            // Follows the finger between the pages there are, and drags with resistance past them.
            let raw = chrome.swipeBase + translation
            let low: CGFloat = chrome.nextPage == nil ? 0 : -pageWidth
            let high: CGFloat = chrome.previousPage == nil ? 0 : pageWidth
            chrome.pageOffset = raw < low ? low + (raw - low) * 0.3 : raw > high ? high + (raw - high) * 0.3 : raw
        }
    }

    private func swipeEnded(_ mode: PhoneSwipeMode, translation: CGFloat, velocity: CGFloat, drawerWidth: CGFloat, pageWidth: CGFloat) {
        switch mode {
        case .drawer:
            PhoneDrawerTouch.endedAt = Date()
            let predicted = (isOpen ? drawerWidth : 0) + translation + velocity * 0.15
            settle(open: predicted > drawerWidth / 2)
        case .pager:
            PhoneDrawerTouch.endedAt = Date()
            let target = pageTarget(velocity: velocity, pageWidth: pageWidth)
            let view = target < 0 ? chrome.nextPage : target > 0 ? chrome.previousPage : nil
            chrome.slide(to: target, velocity: velocity) {
                if let view { swap(to: view) }
            }
        }
    }

    /// Where a released swipe lands: this view (0), or the next (−width) or previous (+width) one. A flick
    /// goes on to the next stop its way; a slow release from rest changes view past `pageThreshold`, and one
    /// that caught the list mid-slide goes to the nearest.
    private func pageTarget(velocity: CGFloat, pageWidth: CGFloat) -> CGFloat {
        let offset = chrome.pageOffset
        var stops: [CGFloat] = [0]
        if chrome.nextPage != nil { stops.append(-pageWidth) }
        if chrome.previousPage != nil { stops.append(pageWidth) }
        if abs(velocity) > 250 {
            return velocity < 0
                ? stops.filter { $0 < offset - 0.5 }.max() ?? stops.min() ?? 0
                : stops.filter { $0 > offset + 0.5 }.min() ?? stops.max() ?? 0
        }
        let projected = offset + velocity * 0.12
        if chrome.swipeBase == 0 {
            guard abs(projected) > Self.pageThreshold else { return 0 }
            let side = projected < 0 ? -pageWidth : pageWidth
            return stops.contains(side) ? side : 0
        }
        return stops.min { abs($0 - projected) < abs($1 - projected) } ?? 0
    }

    /// The list has slid all the way to `view`'s page (`PhonePagePeek`): switch it to that view, starting
    /// from the page's rows so it can take the page's place a couple of frames later, and move it back
    /// under the page.
    private func swap(to view: FeedView) {
        chrome.isSwapping = true
        model.navigate(view: view, startingWith: chrome.peekItems[view] ?? [])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(34))
            chrome.pageOffset = 0
            chrome.isSwapping = false
            syncNeighbors()
        }
    }
}

/// What a horizontal swipe on the home list is doing.
enum PhoneSwipeMode {
    /// Opening or closing the drawer, following the finger.
    case drawer
    /// Moving between the content views.
    case pager
}

/// Slides the home list sideways while swiping between views. Only the list moves: the bubbles stay.
struct PhonePageOffset: ViewModifier {
    /// Only the stack's home list slides; a source's feed pushed above it stays put.
    let isHome: Bool
    @Environment(PhoneChrome.self) private var chrome: PhoneChrome?

    func body(content: Content) -> some View {
        let offset = isHome ? chrome?.pageOffset ?? 0 : 0
        content
            .offset(x: offset)
            .overlay {
                // Both pages stay built (and their images loaded) beside the list, hidden until it moves, so a
                // swipe doesn't build a list as it starts.
                if isHome, let chrome {
                    GeometryReader { geo in
                        ZStack {
                            if let view = chrome.previousPage {
                                PhonePagePeek(title: view.title, items: chrome.peekItems[view] ?? [])
                                    .equatable()
                                    .offset(x: offset - geo.size.width)
                            }
                            if let view = chrome.nextPage {
                                PhonePagePeek(title: view.title, items: chrome.peekItems[view] ?? [])
                                    .equatable()
                                    .offset(x: offset + geo.size.width)
                            }
                        }
                        .opacity(offset == 0 ? 0 : 1)
                    }
                }
            }
    }
}

/// The view beside the list while swiping between views: its title and first rows, laid out as the list
/// lays them out so the list can take its place without a jump. Not interactive.
struct PhonePagePeek: View, Equatable {
    let title: String
    let items: [FeedItem]

    /// More rows than fit on the screen.
    static let rows = 12

    var body: some View {
        List {
            PhoneTitleRow(title: title)
            ForEach(Array(items.prefix(Self.rows).enumerated()), id: \.element.id) { index, item in
                ItemRowView(item: item, isPhone: true)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle()
                                .fill(Color.ofHairline)
                                .frame(height: 1)
                                .padding(.horizontal, Metrics.phoneRowPaddingH)
                        }
                    }
                    .padding(.horizontal, 8)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .environment(\.defaultMinListRowHeight, 1)
        .background(Color.ofSurface)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One UIKit pan recognizer on the screen's hosting view for every sideways swipe on the iPhone home list.
/// It begins only for a horizontal-dominant drag that `begin` accepts (so vertical scrolling and row taps
/// are untouched), holds the list's scroll view off while it runs, and cancels the touch in the views under
/// the finger once it takes over, so the row it ends on isn't opened.
private struct PhoneSwipeBridge: UIViewRepresentable {
    /// Starting x in the hosting view and horizontal velocity; the mode, or nil to not begin.
    let begin: (CGFloat, CGFloat) -> PhoneSwipeMode?
    let changed: (PhoneSwipeMode, CGFloat) -> Void
    let ended: (PhoneSwipeMode, CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        let c = context.coordinator
        c.begin = begin
        c.changed = changed
        c.ended = ended
    }

    /// Finds the hosting view once it is in a window and adds the recognizer there.
    final class InstallerView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { coordinator?.install(from: self) }
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var begin: (CGFloat, CGFloat) -> PhoneSwipeMode? = { _, _ in nil }
        var changed: (PhoneSwipeMode, CGFloat) -> Void = { _, _ in }
        var ended: (PhoneSwipeMode, CGFloat, CGFloat) -> Void = { _, _, _ in }
        private let pan = UIPanGestureRecognizer()
        private weak var host: UIView?
        private var startX: CGFloat = 0
        private var mode: PhoneSwipeMode?

        override init() {
            super.init()
            pan.addTarget(self, action: #selector(handle))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
        }

        /// The topmost view below the window: the screen's hosting view. Sheets are presented outside it,
        /// so swipes in a sheet never reach this recognizer.
        func install(from view: UIView) {
            var top = view
            while let parent = top.superview, !(parent is UIWindow) { top = parent }
            guard host !== top else { return }
            host?.removeGestureRecognizer(pan)
            top.addGestureRecognizer(pan)
            host = top
        }

        @objc private func handle(_ g: UIPanGestureRecognizer) {
            guard let host else { return }
            let t = g.translation(in: host).x
            switch g.state {
            case .began:
                PhoneDrawerTouch.isDragging = true
                if let mode { changed(mode, t) }
            case .changed:
                if let mode { changed(mode, t) }
            case .ended, .cancelled, .failed:
                PhoneDrawerTouch.isDragging = false
                if let mode { ended(mode, t, g.state == .ended ? g.velocity(in: host).x : 0) }
                mode = nil
            default:
                break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if let host { startX = touch.location(in: host).x }
            return true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let host else { return false }
            let v = pan.velocity(in: host)
            guard abs(v.x) > abs(v.y) * 1.25 else { return false }
            mode = begin(startX, v.x)
            return mode != nil
        }

        /// Scroll views' pans wait for this one to fail, so a drag is either a swipe or a scroll, never both:
        /// otherwise a diagonal swipe also scrolled (and pulled to refresh) the list while it slid sideways,
        /// and the page floated around under the finger. A vertical drag fails this recognizer at once
        /// (`gestureRecognizerShouldBegin`), so scrolling starts as soon as it would have anyway.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            isScrollPan(other)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !isScrollPan(other)
        }

        private func isScrollPan(_ other: UIGestureRecognizer) -> Bool {
            guard let scrollView = other.view as? UIScrollView else { return false }
            return other === scrollView.panGestureRecognizer
        }
    }
}

/// Whether a sideways swipe is under way or just ended. The list under the finger is a UIKit view that may
/// still see the touch and open the row it ends on, so rows ignore taps for a moment after a swipe.
@MainActor enum PhoneDrawerTouch {
    static var isDragging = false
    static var endedAt = Date.distantPast

    static var blocksRowTap: Bool { isDragging || Date().timeIntervalSince(endedAt) < 0.4 }
}

/// A clear UIKit view that takes the touches in its frame, so nothing under it (the list's rows) gets them;
/// a tap calls `onTap`.
private struct TouchShield: UIViewRepresentable {
    var onTap: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap)))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
    }

    @MainActor final class Coordinator: NSObject {
        var onTap: (() -> Void)?

        @objc func tap() { onTap?() }
    }
}


// MARK: - Drawer

/// What the drawer's name alert is asking for.
private enum DrawerPrompt: Identifiable {
    case newFolder
    case renameFolder(Folder)
    case renameSource(Source)

    var id: String {
        switch self {
        case .newFolder: "new"
        case .renameFolder(let f): "folder-\(f.id)"
        case .renameSource(let s): "source-\(s.id)"
        }
    }

    var title: String {
        switch self {
        case .newFolder: "New Folder"
        case .renameFolder: "Rename Folder"
        case .renameSource: "Rename Source"
        }
    }

    var message: String {
        switch self {
        case .newFolder: "Enter a name for the folder."
        case .renameFolder(let f): "Enter a new name for \u{201C}\(f.title)\u{201D}."
        case .renameSource(let s): "Enter a new name for \u{201C}\(s.title)\u{201D}."
        }
    }

    var initial: String {
        switch self {
        case .newFolder: ""
        case .renameFolder(let f): f.title
        case .renameSource(let s): s.title
        }
    }

    var confirm: String {
        if case .newFolder = self { "Create" } else { "Rename" }
    }
}

/// The drawer: the OpenDispatch wordmark with a glass search bubble; the sidebar's views in its order (All,
/// Articles, Posts, Video, Podcasts, Saved, Highlights, less the ones hidden in Settings); Topics, one row per
/// followed keyword with its unread count and a + for a new one; Folders, each
/// with its source count and a chevron that opens its sources inline, then Unfiled if any source is
/// without a folder; Settings as a glass bubble and Add source as a dark pill floating over the list. The
/// row for what the list shows gets the soft pill; picking a view, folder or source closes the drawer.
///
/// Search turns the top into a glass field and filters the list to the topics, folders and sources whose name
/// matches. Holding a folder, source or topic gives its actions (rename, move, copy, delete) as a context menu.
/// Edit switches the list to the folders alone, with a delete control and a drag handle on each, and the
/// bottom to New folder and Done.
private struct PhoneDrawer: View {
    let safeArea: EdgeInsets
    let isOpen: Bool
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    /// Folders whose sources are showing (`AppModel.folderKey`); collapsed by default, kept for the session.
    @State private var expanded: Set<String> = []
    @State private var isSearching = false
    @State private var query = ""
    @State private var isEditing = false
    @State private var prompt: DrawerPrompt?
    @State private var promptText = ""
    @State private var pendingFolderDelete: Folder?
    @State private var pendingSourceDelete: Source?
    @State private var pendingTopicDelete: Source?
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isFiltering: Bool { isSearching && !trimmedQuery.isEmpty }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isEditing { editList } else { browseList }
            }
            .padding(.top, safeArea.top + 8)
            // Stays put when the keyboard comes up for an alert's text field.
            if !isSearching { bottomBar.ignoresSafeArea(.keyboard) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.ofDrawer)
        // Once the drawer has closed, the next opening starts from the plain list.
        .task(id: isOpen) {
            guard !isOpen else { return }
            searchFocused = false
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            isSearching = false
            query = ""
            isEditing = false
        }
        .modifier(DrawerDialogs(
            prompt: $prompt, promptText: $promptText, pendingFolderDelete: $pendingFolderDelete,
            pendingSourceDelete: $pendingSourceDelete, pendingTopicDelete: $pendingTopicDelete, errorMessage: $errorMessage,
            commit: commit, deleteFolder: { folder in run { try await model.deleteFolder(id: folder.id) } },
            deleteSource: { source in run { try await model.deleteSource(id: source.id) } },
            deleteTopic: { topic in run { try await model.deleteTopic(id: topic.id) } }))
    }

    // MARK: Top

    private var header: some View {
        HStack(spacing: 10) {
            if isSearching {
                searchField
            } else {
                Text("OpenDispatch")
                    .font(OFFont.ui(27, .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if !isEditing { searchBubble }
            }
        }
        .padding(.leading, isSearching ? 12 : 22)
        .padding(.trailing, 12)
        .frame(height: 56)
    }

    private var searchBubble: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { isSearching = true }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.ofInk)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Search sources and folders")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.ofMuted)
            TextField("", text: $query, prompt: Text("Search sources and folders").foregroundStyle(.ofFaint))
                .font(OFFont.ui(17))
                .foregroundStyle(.ofInk)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            Button {
                searchFocused = false
                query = ""
                withAnimation(.smooth(duration: 0.2)) { isSearching = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.ofInk)
                    .frame(width: 36, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .frame(height: 46)
        .glassEffect(.regular, in: .capsule)
        .onAppear { searchFocused = true }
    }

    // MARK: Browsing

    private var browseList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isFiltering {
                    searchResults
                } else {
                    viewRows
                    topicsSection
                    foldersSection
                }
            }
            .padding(.top, 10)
            .padding(.bottom, Self.listBottomInset)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Room under the last row for the bubble and pill floating at the bottom.
    private static let listBottomInset: CGFloat = 130

    /// The sidebar's rows in its order (`SidebarViewItem.ordered`), less the ones hidden in Settings. Explore,
    /// Saved, Highlights and History stay: the drawer is the only way to them on iPhone. Explore sits first,
    /// apart from the views by a hairline.
    @ViewBuilder private var viewRows: some View {
        ForEach(SidebarViewItem.ordered.filter { item in
            switch item {
            case .explore, .view(.saved), .highlights, .history: true
            default: !model.isSidebarViewHidden(item)
            }
        }) { item in
            switch item {
            case .explore:
                DrawerRow(icon: "ph.explore", title: "Explore", isCurrent: model.showsExplore) {
                    pick { model.showExplore() }
                }
                Rectangle().fill(Color.ofHairline).frame(height: 1).padding(.horizontal, 24).padding(.vertical, 6)
            case .view(let view):
                DrawerRow(
                    icon: Self.icon(view),
                    title: view.title,
                    subtitle: view == .all ? "Everything from your \(sourceCount) \(sourceCount == 1 ? "source" : "sources")" : nil,
                    isCurrent: model.selectedView == view && !model.isInSourceFeed && !model.showsHighlights && !model.showsHistory
                        && !model.showsExplore
                ) { pick { model.navigate(view: view) } }
            case .highlights:
                DrawerRow(icon: "ph.highlights", title: "Highlights", isCurrent: model.showsHighlights) {
                    pick { model.showHighlights() }
                }
            case .history:
                DrawerRow(icon: "ph.history", title: "History", isCurrent: model.showsHistory) {
                    pick { model.showHistory() }
                }
            }
        }
    }

    private var sourceCount: Int { model.sources.filter { !$0.isOpenedLinks }.count }

    private static func icon(_ view: FeedView) -> String {
        switch view {
        case .all: "ph.all"
        case .saved: "ph.saved"
        case .articles: "ph.articles"
        case .posts: "ph.posts"
        case .video: "ph.video"
        case .podcasts: "ph.podcasts"
        }
    }

    // MARK: Topics

    /// The Topics group between the views and the folders. It shows with no topic too: the + here and
    /// Explore's Follow are how the first one is made on the iPhone.
    @ViewBuilder private var topicsSection: some View {
        DrawerSectionLabel("Topics") {
            Button {
                pick { model.beginNewTopic() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.ofInk)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Topic")
        }
        if model.topics.isEmpty {
            Text("Follow a keyword to collect new matches from news, forums, videos and podcasts.")
                .font(OFFont.ui(14))
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
        }
        ForEach(model.topics) { topicRow($0) }
    }

    private func topicRow(_ topic: Source) -> some View {
        DrawerTopicRow(
            topic: topic, unread: model.topicStore.unreadCount(topic),
            isRefreshing: model.topicStore.refreshing.contains(topic.id), isCurrent: model.selectedSourceID == topic.id
        ) { pick { model.navigate(sourceID: topic.id) } }
        .contextMenu {
            topicMenu(topic)
        } preview: {
            DrawerLift {
                OFIcon.topic.image.font(.system(size: 18)).frame(width: 24, height: 24)
                Text(topic.title).font(OFFont.ui(17, .medium)).lineLimit(1)
                Spacer(minLength: 12)
                Text("Topic").font(OFFont.ui(14)).foregroundStyle(.ofMuted)
            }
        }
        .tint(.ofInk)
    }

    @ViewBuilder private func topicMenu(_ topic: Source) -> some View {
        Button {
            pick { model.beginEditTopic(topic) }
        } label: {
            Label("Edit Topic\u{2026}", systemImage: "pencil")
        }
        Toggle("Notify on New Matches", isOn: Binding(
            get: { topic.notifies },
            set: { on in run { try await model.setSourceNotify(id: topic.id, on: on) } }))
        Button {
            model.markAllRead(topic: topic)
        } label: {
            Label("Mark All as Read", systemImage: "checkmark.circle")
        }
        Divider()
        Button(role: .destructive) {
            pendingTopicDelete = topic
        } label: {
            Label("Remove Topic\u{2026}", systemImage: "trash")
        }
    }

    // MARK: Folders and sources

    /// The sources of a folder (nil = Unfiled) in sidebar order. The iPhone has no Pinned or Hidden groups, so
    /// those are listed in their folder too; the opened-links holders are not subscriptions.
    private func sources(in folderID: Int64?) -> [Source] {
        model.allSources(inFolder: folderID).filter { !$0.isOpenedLinks }
    }

    @ViewBuilder private var foldersSection: some View {
        DrawerSectionLabel("Folders") {
            Button("Edit") {
                withAnimation(.smooth(duration: 0.2)) { isEditing = true }
            }
            .font(OFFont.ui(14, .semibold))
            .foregroundStyle(.ofInk)
            .buttonStyle(.plain)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        ForEach(model.orderedFolders) { folder in
            folderRow(folder, expandable: true)
            if expanded.contains(AppModel.folderKey(folder.id)) {
                sourceRows(sources(in: folder.id))
            }
        }
        let unfiled = sources(in: nil)
        if !unfiled.isEmpty {
            let key = AppModel.folderKey(nil)
            let toggle = { toggleExpanded(key) }
            DrawerFolderRow(title: "Unfiled", count: unfiled.count, isExpanded: expanded.contains(key), open: toggle, toggle: toggle)
            if expanded.contains(key) { sourceRows(unfiled) }
        }
    }

    private func folderRow(_ folder: Folder, expandable: Bool) -> some View {
        let key = AppModel.folderKey(folder.id)
        let count = sources(in: folder.id).count
        return DrawerFolderRow(
            title: folder.title,
            count: count,
            isCurrent: model.selectedFolderID == folder.id && model.selectedSourceID == nil,
            isExpanded: expandable ? expanded.contains(key) : nil,
            open: { pick { model.navigate(folderID: folder.id) } },
            toggle: expandable ? { toggleExpanded(key) } : nil
        )
        .contextMenu {
            folderMenu(folder)
        } preview: {
            DrawerLift {
                Image("ph.folder").renderingMode(.template).resizable().scaledToFit().frame(width: 24, height: 24)
                Text(folder.title).font(OFFont.ui(17, .medium)).lineLimit(1)
                Spacer(minLength: 12)
                Text("\(count) \(count == 1 ? "source" : "sources")").font(OFFont.ui(14)).foregroundStyle(.ofMuted)
            }
        }
        // The menu in ink, like the feed rows' menu, rather than the accent blue.
        .tint(.ofInk)
    }

    private func sourceRows(_ list: [Source]) -> some View {
        ForEach(list) { source in
            sourceRow(source, detail: nil, indented: true)
        }
        .transition(.opacity)
    }

    private func sourceRow(_ source: Source, detail: String?, indented: Bool) -> some View {
        DrawerSourceRow(source: source, detail: detail, isIndented: indented, isCurrent: model.selectedSourceID == source.id) {
            pick { model.navigate(sourceID: source.id) }
        }
        .contextMenu {
            sourceMenu(source)
        } preview: {
            DrawerLift {
                SourceBadge(source: source, size: 24)
                Text(source.title).font(OFFont.ui(17, .medium)).lineLimit(1)
                Spacer(minLength: 12)
                Text(source.host).font(OFFont.ui(14)).foregroundStyle(.ofMuted).lineLimit(1)
            }
        }
        // The menu in ink, like the feed rows' menu, rather than the accent blue.
        .tint(.ofInk)
    }

    private func toggleExpanded(_ key: String) {
        withAnimation(.smooth(duration: 0.22)) {
            if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        }
    }

    // MARK: Search

    /// Topics, folders, then sources, whose name contains the query; a source shows the folder it is in.
    @ViewBuilder private var searchResults: some View {
        let q = trimmedQuery
        let folders = model.orderedFolders.filter { $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        let found = SourceList.matching(model.sources.filter { !$0.isOpenedLinks }, query: q)
        let topics = model.topics.filter { $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        if folders.isEmpty, found.isEmpty, topics.isEmpty {
            Text("No folders, topics or sources match \u{201C}\(q)\u{201D}")
                .font(OFFont.ui(15))
                .foregroundStyle(.ofMuted)
                .padding(.horizontal, 24)
                .padding(.top, 12)
        }
        if !topics.isEmpty {
            DrawerSectionLabel("Topics")
            ForEach(topics) { topicRow($0) }
        }
        if !folders.isEmpty {
            DrawerSectionLabel("Folders")
            ForEach(folders) { folderRow($0, expandable: false) }
        }
        if !found.isEmpty {
            DrawerSectionLabel("Sources")
            ForEach(found) { source in
                sourceRow(source, detail: model.folders.first { $0.id == source.folderId }?.title ?? "Unfiled", indented: false)
            }
        }
    }

    // MARK: Menus

    @ViewBuilder private func folderMenu(_ folder: Folder) -> some View {
        Button {
            open(.renameFolder(folder))
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            model.pendingAddSourceFolderID = folder.id
            model.isAddSourcePresented = true
        } label: {
            Label("Add Source to \(folder.title)\u{2026}", systemImage: "plus")
        }
        CopyDigestButtons(scope: .folder(folder), icons: true)
        Divider()
        Button(role: .destructive) {
            pendingFolderDelete = folder
        } label: {
            Label("Delete Folder\u{2026}", systemImage: "trash")
        }
    }

    @ViewBuilder private func sourceMenu(_ source: Source) -> some View {
        Button {
            pick { model.navigate(sourceID: source.id) }
        } label: {
            Label("Open Feed", systemImage: "dot.radiowaves.up.forward")
        }
        if let url = URL(string: source.url), url.scheme != nil {
            Button {
                openURL(url)
            } label: {
                Label("Open Site", systemImage: OFIcon.external.rawValue)
            }
        }
        Menu {
            ForEach(model.orderedFolders) { folder in
                Toggle(folder.title, isOn: moveBinding(source, to: folder.id))
            }
            Toggle("Unfiled", isOn: moveBinding(source, to: nil))
        } label: {
            Label("Move to Folder", systemImage: OFIcon.folder.rawValue)
        }
        Button {
            open(.renameSource(source))
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            run { try await model.setSourceNotify(id: source.id, on: !source.notifies) }
        } label: {
            Label(source.notifies ? "Stop Notifications" : "Notify on New Posts",
                  systemImage: (source.notifies ? OFIcon.bellOff : OFIcon.bell).rawValue)
        }
        Divider()
        Button(role: .destructive) {
            pendingSourceDelete = source
        } label: {
            Label("Remove Source\u{2026}", systemImage: "trash")
        }
    }

    /// Checked when the source is in that folder; checking it moves the source there.
    private func moveBinding(_ source: Source, to folderID: Int64?) -> Binding<Bool> {
        Binding(
            get: { source.folderId == folderID },
            set: { checked in
                guard checked, source.folderId != folderID else { return }
                run { try await model.moveSource(id: source.id, toFolder: folderID) }
            })
    }

    // MARK: Editing

    /// Edit mode: just the folders, each with a delete control and a drag handle.
    private var editList: some View {
        List {
            DrawerSectionLabel("Folders")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .moveDisabled(true)
            if model.orderedFolders.isEmpty {
                Text("No folders yet")
                    .font(OFFont.ui(15))
                    .foregroundStyle(.ofMuted)
                    .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .moveDisabled(true)
            }
            ForEach(model.orderedFolders) { folder in
                editRow(folder)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.ofHairline)
                    .deleteDisabled(true)
            }
            .onMove(perform: moveFolders)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .environment(\.editMode, .constant(.active))
        .contentMargins(.bottom, Self.listBottomInset, for: .scrollContent)
    }

    private func editRow(_ folder: Folder) -> some View {
        HStack(spacing: 12) {
            Button {
                pendingFolderDelete = folder
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.ofDanger, in: Circle())
                    .frame(width: 34, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(folder.title)")
            Image("ph.folder").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(.ofInk)
            Text(folder.title)
                .font(OFFont.ui(17, .medium))
                .foregroundStyle(.ofInk)
                .lineLimit(1)
            Text("\(sources(in: folder.id).count)")
                .font(OFFont.ui(14))
                .monospacedDigit()
                .foregroundStyle(.ofMuted)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func moveFolders(from: IndexSet, to: Int) {
        var ids = model.orderedFolders.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        Task { await model.reorderFolders(ids) }
    }

    // MARK: Bottom

    /// Settings and Add source (or New folder and Done while editing), over a fade of the drawer's ground.
    private var bottomBar: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 10) {
                if isEditing {
                    DrawerPill(title: "New folder") { open(.newFolder) }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { isEditing = false }
                    } label: {
                        Text("Done")
                            .font(OFFont.ui(16, .semibold))
                            .foregroundStyle(.ofInk)
                            .padding(.horizontal, 22)
                            .frame(height: 46)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                } else {
                    settingsButton
                    Spacer(minLength: 0)
                    DrawerPill(title: "Add source") {
                        model.pendingAddSourceFolderID = nil
                        model.isAddSourcePresented = true
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 36)
        .padding(.bottom, 22)
        .background {
            LinearGradient(colors: [Color.ofDrawer.opacity(0), Color.ofDrawer], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }

    private var settingsButton: some View {
        Button {
            pick { model.isSettingsPresented = true }
        } label: {
            Image("ph.settings")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(.ofInk)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Settings")
    }

    // MARK: Actions

    /// Runs `action`, then closes the drawer.
    private func pick(_ action: () -> Void) {
        action()
        close()
    }

    private func open(_ p: DrawerPrompt) {
        promptText = p.initial
        prompt = p
    }

    private func commit(_ p: DrawerPrompt) {
        let title = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != p.initial else { return }
        switch p {
        case .newFolder:
            run { try await model.createFolder(title: title) }
        case .renameFolder(let folder):
            run { try await model.renameFolder(id: folder.id, title: title) }
        case .renameSource(let source):
            run { try await model.renameSource(id: source.id, title: title) }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch { errorMessage = HTTP.message(error) }
        }
    }
}

/// The drawer's alerts: the name field (new folder, rename), the delete confirmations and errors.
private struct DrawerDialogs: ViewModifier {
    @Binding var prompt: DrawerPrompt?
    @Binding var promptText: String
    @Binding var pendingFolderDelete: Folder?
    @Binding var pendingSourceDelete: Source?
    @Binding var pendingTopicDelete: Source?
    @Binding var errorMessage: String?
    let commit: (DrawerPrompt) -> Void
    let deleteFolder: (Folder) -> Void
    let deleteSource: (Source) -> Void
    let deleteTopic: (Source) -> Void

    func body(content: Content) -> some View {
        content
            .alert(prompt?.title ?? "", isPresented: isSet($prompt), presenting: prompt) { p in
                TextField("Name", text: $promptText)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button(p.confirm) { commit(p) }
            } message: { p in
                Text(p.message)
            }
            .alert(
                pendingFolderDelete.map { "Delete \($0.title)?" } ?? "Delete folder?",
                isPresented: isSet($pendingFolderDelete), presenting: pendingFolderDelete
            ) { folder in
                Button("Delete Folder", role: .destructive) { deleteFolder(folder) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its sources move to Unfiled.")
            }
            .alert(
                pendingSourceDelete.map { "Remove \($0.title)?" } ?? "Remove source?",
                isPresented: isSet($pendingSourceDelete), presenting: pendingSourceDelete
            ) { source in
                Button("Remove Source", role: .destructive) { deleteSource(source) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Removing a source also removes its items.")
            }
            .alert(
                pendingTopicDelete.map { "Remove \($0.title)?" } ?? "Remove topic?",
                isPresented: isSet($pendingTopicDelete), presenting: pendingTopicDelete
            ) { topic in
                Button("Remove Topic", role: .destructive) { deleteTopic(topic) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Removing a topic also removes its items.")
            }
            .alert("Something went wrong", isPresented: isSet($errorMessage)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func isSet<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

/// A muted section label in the drawer ("Folders", "Sources"), with an optional control at its trailing side.
private struct DrawerSectionLabel<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(OFFont.ui(13, .semibold))
                .foregroundStyle(.ofMuted)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

extension DrawerSectionLabel where Trailing == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

/// The card a held row lifts into above its context menu.
private struct DrawerLift<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .foregroundStyle(.ofInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minWidth: 280)
            .background(Color.ofCard)
    }
}

/// A big pill at the drawer's bottom: ink with light text, and the reverse in dark mode.
private struct DrawerPill: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image("ph.plus").renderingMode(.template).resizable().scaledToFit().frame(width: 20, height: 20)
                Text(title).font(OFFont.ui(17, .semibold)).lineLimit(1)
            }
            .foregroundStyle(Color(light: 0xFFFFFF, dark: 0x1B1B1A))
            .padding(.leading, 18)
            .padding(.trailing, 22)
            .frame(height: 52)
            .background(Capsule().fill(Color.ofInk))
            .shadow(color: .black.opacity(0.18), radius: 11, y: 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A view row in the drawer: icon, title with an optional subtitle; the soft pill when current.
private struct DrawerRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var isCurrent = false
    let action: () -> Void

    var body: some View {
        // A swipe that ends over the row (closing the drawer) is not a tap on it.
        Button(action: { if !PhoneDrawerTouch.blocksRowTap { action() } }) {
            HStack(spacing: 13) {
                Image(icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.ofInk)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(OFFont.ui(17, .medium))
                        .foregroundStyle(.ofInk)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(OFFont.ui(13))
                            .foregroundStyle(.ofMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isCurrent ? Color.ofNavSelection : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// A folder row: icon, name, source count, and a chevron that shows or hides its sources. Tapping the name
/// calls `open`; the chevron only calls `toggle`. Without `toggle` (search results) there is no chevron.
private struct DrawerFolderRow: View {
    let title: String
    let count: Int
    var isCurrent = false
    /// Whether its sources are showing; nil when the row has no chevron.
    var isExpanded: Bool?
    let open: () -> Void
    var toggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { if !PhoneDrawerTouch.blocksRowTap { open() } }) {
                HStack(spacing: 13) {
                    Image("ph.folder")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.ofInk)
                    Text(title)
                        .font(OFFont.ui(17, .medium))
                        .foregroundStyle(.ofInk)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(count)")
                        .font(OFFont.ui(14))
                        .monospacedDigit()
                        .foregroundStyle(.ofMuted)
                }
                .padding(.leading, 14)
                .padding(.trailing, toggle == nil ? 14 : 6)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(count) \(count == 1 ? "source" : "sources")")
            if let toggle {
                Button(action: { if !PhoneDrawerTouch.blocksRowTap { toggle() } }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.ofFaint)
                        .rotationEffect(.degrees(isExpanded == true ? 90 : 0))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded == true ? "Hide sources in \(title)" : "Show sources in \(title)")
            }
        }
        .background(isCurrent ? Color.ofNavSelection : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// A topic row: the "number" symbol, the keyword, and the unread count (a spinner while it searches).
private struct DrawerTopicRow: View {
    let topic: Source
    let unread: Int
    let isRefreshing: Bool
    var isCurrent = false
    let action: () -> Void

    var body: some View {
        Button(action: { if !PhoneDrawerTouch.blocksRowTap { action() } }) {
            HStack(spacing: 13) {
                OFIcon.topic.image
                    .font(.system(size: 18))
                    .foregroundStyle(.ofInk)
                    .frame(width: 24, height: 24)
                Text(topic.title)
                    .font(OFFont.ui(17, .medium))
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else if unread > 0 {
                    Text(unread.formatted())
                        .font(OFFont.ui(14))
                        .monospacedDigit()
                        .foregroundStyle(.ofMuted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isCurrent ? Color.ofNavSelection : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unread > 0 ? "\(topic.title), \(unread) unread" : topic.title)
        .accessibilityHint("Topic")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// A source row: its badge and title, indented under its folder; `detail` (the folder's name in search
/// results) sits at the trailing side.
private struct DrawerSourceRow: View {
    let source: Source
    var detail: String?
    var isIndented = true
    var isCurrent = false
    let action: () -> Void

    var body: some View {
        Button(action: { if !PhoneDrawerTouch.blocksRowTap { action() } }) {
            HStack(spacing: 12) {
                SourceBadge(source: source, size: 20)
                Text(source.title)
                    .font(OFFont.ui(15.5))
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(OFFont.ui(14))
                        .foregroundStyle(.ofMuted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isCurrent ? Color.ofNavSelection : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.leading, isIndented ? 36 : 10)
            .padding(.trailing, 10)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
#endif
