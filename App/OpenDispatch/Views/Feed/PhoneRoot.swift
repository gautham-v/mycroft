#if os(iOS)
import OpenDispatchCore
import SwiftUI
import UIKit

/// Where the iPhone's one navigation stack can go from the home list besides the reader.
enum PhoneRoute: Hashable {
    case manageSources
}

/// The home list's horizontal slide while swiping between views (PhoneRoot drives it; the list reads it).
/// A reference type of its own so the per-frame drag only re-evaluates the small modifier that offsets the
/// list, not the list or PhoneRoot.
@MainActor @Observable final class PhoneChrome {
    /// How far the list is displaced sideways (following the finger, then the slide on a view change).
    var pageOffset: CGFloat = 0
    /// A view change is sliding out and in: swipes are ignored until it lands.
    var isPaging = false
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

    /// Where the list sits among `phonePages`; nil when it shows a folder, a source, Saved or Highlights.
    var phonePageIndex: Int? {
        guard !isInSourceFeed, !showsHighlights else { return nil }
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

    /// Something (Manage sources, a source's feed) is pushed above the iPhone's home list, so the home list
    /// must not present the search field or the reader.
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
/// rounds its corners as a peek; tapping the peek or swiping left closes it. Opening a row, Manage
/// sources and a source's feed push onto the stack; Settings and Add source are sheets (RootView).
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
    @State private var path: [PhoneRoute] = []

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
                PhoneDrawer(safeArea: safeArea, close: close, manageSources: manageSources)
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
        NavigationStack(path: $path) {
            FeedColumn(isPhoneHome: true)
                .navigationDestination(for: PhoneRoute.self) { _ in
                    SourcesView()
                }
        }
        .environment(\.isFeedStackPushed, !path.isEmpty)
        .environment(\.phoneDrawer, PhoneDrawerControl(open: { open() }))
        .environment(chrome)
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

    /// The drawer's Manage sources: close it, then push the sources list.
    private func manageSources() {
        close()
        path = [.manageSources]
    }

    // MARK: Swipes

    /// Whether a swipe may do anything: with the drawer open, or on the home list. With something pushed
    /// (the reader, Manage sources, a source's feed) the stack's own swipe back owns the left edge.
    private var swipesEnabled: Bool {
        isOpen || (path.isEmpty && model.selectedItemID == nil)
    }

    /// What a horizontal swipe that starts at `startX` moving at `velocity` (points per second) does, or
    /// nil to leave it alone. Open drawer: swiping left closes it. Closed: from the left edge, rightwards
    /// on the first view (or on a list that isn't one of the five views) it opens the drawer, otherwise
    /// it moves between the views.
    private func swipeBegin(startX: CGFloat, velocity: CGFloat) -> PhoneSwipeMode? {
        guard swipesEnabled, !chrome.isPaging else { return nil }
        if isOpen { return velocity < 0 ? .drawer : nil }
        if startX < Self.edgeWidth, velocity > 0 { return .drawer }
        if let index = model.phonePageIndex, !model.isSearchOpen {
            return index == 0 && velocity > 0 ? .drawer : .pager
        }
        return velocity > 0 ? .drawer : nil
    }

    private func swipeChanged(_ mode: PhoneSwipeMode, translation: CGFloat, drawerWidth: CGFloat, pageWidth: CGFloat) {
        switch mode {
        case .drawer:
            drag = isOpen ? min(0, max(-drawerWidth, translation)) : min(drawerWidth, max(0, translation))
        case .pager:
            guard let index = model.phonePageIndex else { return }
            let atEnd = (translation > 0 && index == 0) || (translation < 0 && index == model.phonePages.count - 1)
            chrome.pageOffset = translation * (atEnd ? 0.3 : 1)
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
            let pages = model.phonePages
            let projected = translation + velocity * 0.12
            if let index = model.phonePageIndex {
                if projected < -Self.pageThreshold, index < pages.count - 1 {
                    page(to: pages[index + 1], forward: true, pageWidth: pageWidth)
                    return
                }
                if projected > Self.pageThreshold, index > 0 {
                    page(to: pages[index - 1], forward: false, pageWidth: pageWidth)
                    return
                }
            }
            withAnimation(.smooth(duration: 0.28)) { chrome.pageOffset = 0 }
        }
    }

    /// Slides the list out the way the finger went, switches view, and slides the new one in from the other
    /// side.
    private func page(to view: FeedView, forward: Bool, pageWidth: CGFloat) {
        let direction: CGFloat = forward ? 1 : -1
        chrome.isPaging = true
        withAnimation(.easeIn(duration: 0.16)) { chrome.pageOffset = -direction * pageWidth }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(170))
            model.navigate(view: view)
            // Let the new view's first page land (it is a local query) so the rows slide in, not the old ones.
            await Task.yield()
            for _ in 0..<15 where model.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
            var jump = Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) { chrome.pageOffset = direction * pageWidth }
            withAnimation(.smooth(duration: 0.3)) { chrome.pageOffset = 0 }
            try? await Task.sleep(for: .milliseconds(300))
            chrome.isPaging = false
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
        content.offset(x: isHome ? chrome?.pageOffset ?? 0 : 0)
    }
}

/// One UIKit pan recognizer on the screen's hosting view for every sideways swipe on the iPhone home list.
/// It begins only for a horizontal-dominant drag that `begin` accepts (so vertical scrolling and row taps
/// are untouched), runs alongside the list's scroll view, and cancels the touch in the views under the
/// finger once it takes over, so the row it ends on isn't opened.
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

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
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

/// The drawer: the app's logo and name over a hairline; the sidebar's views in its order (All, Articles,
/// Posts, Video, Podcasts, Saved, Highlights, less the ones hidden in Settings); Folders with their source counts; Sources (Add
/// source, Manage sources); Copy Last 24 Hours / 7 Days of the list shown; and Settings pinned at the
/// bottom. The row for what the list shows gets the soft pill; picking anything closes the drawer.
private struct PhoneDrawer: View {
    let safeArea: EdgeInsets
    let close: () -> Void
    let manageSources: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    viewRows
                    foldersSection
                    sourcesSection
                    copySection
                }
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .padding(.top, safeArea.top + 8)
        .padding(.bottom, max(safeArea.bottom, 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.ofDrawer)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("OpenDispatch")
                .font(OFFont.ui(22, .semibold))
                .tracking(-0.3)
                .foregroundStyle(.ofInk)
                .lineLimit(1)
        }
        .padding(.leading, 20)
        .padding(.bottom, 16)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.ofHairline).frame(height: 1).padding(.trailing, 20).padding(.leading, 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OpenDispatch")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Views

    /// The sidebar's rows in its order (`SidebarViewItem.ordered`), less the ones hidden in Settings. Saved and
    /// Highlights stay: the drawer is the only way to them on iPhone.
    @ViewBuilder private var viewRows: some View {
        ForEach(SidebarViewItem.ordered.filter { item in
            switch item {
            case .view(.saved), .highlights: true
            default: !model.isSidebarViewHidden(item)
            }
        }) { item in
            switch item {
            case .view(let view):
                DrawerRow(
                    icon: Self.icon(view),
                    title: view.title,
                    subtitle: view == .all ? "Everything from your \(sourceCount) \(sourceCount == 1 ? "source" : "sources")" : nil,
                    isCurrent: model.selectedView == view && !model.isInSourceFeed && !model.showsHighlights
                ) { pick { model.navigate(view: view) } }
            case .highlights:
                DrawerRow(icon: "ph.highlights", title: "Highlights", isCurrent: model.showsHighlights) {
                    pick { model.showHighlights() }
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

    // MARK: Folders and sources

    @ViewBuilder private var foldersSection: some View {
        if !model.orderedFolders.isEmpty {
            DrawerSectionLabel("Folders")
            ForEach(model.orderedFolders) { folder in
                DrawerRow(
                    icon: "ph.folder",
                    title: folder.title,
                    count: model.sources(inFolder: folder.id).count,
                    isCurrent: model.selectedFolderID == folder.id && model.selectedSourceID == nil
                ) { pick { model.navigate(folderID: folder.id) } }
            }
        }
    }

    @ViewBuilder private var sourcesSection: some View {
        DrawerSectionLabel("Sources")
        DrawerRow(icon: "ph.plus", title: "Add source") { pick { model.isAddSourcePresented = true } }
        DrawerRow(icon: "ph.list", title: "Manage sources", action: manageSources)
    }

    /// Copy Last 24 Hours / 7 Days of what the list shows, small rows at the end.
    @ViewBuilder private var copySection: some View {
        DrawerSectionLabel("Copy this list as Markdown")
        DrawerRow(systemIcon: "doc.on.doc", title: "Last 24 Hours", compact: true) {
            pick { model.copyDigest(model.currentDigestScope, days: 1) }
        }
        DrawerRow(systemIcon: "doc.on.doc", title: "Last 7 Days", compact: true) {
            pick { model.copyDigest(model.currentDigestScope, days: 7) }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.ofHairline).frame(height: 1).padding(.horizontal, 20).padding(.bottom, 8)
            DrawerRow(icon: "ph.settings", title: "Settings") { pick { model.isSettingsPresented = true } }
        }
    }

    /// Runs `action`, then closes the drawer.
    private func pick(_ action: () -> Void) {
        action()
        close()
    }
}

/// "Folders", "Sources": a muted section label in the drawer.
private struct DrawerSectionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(OFFont.ui(13, .semibold))
            .foregroundStyle(.ofMuted)
            .lineLimit(1)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A drawer row: icon, title with an optional subtitle, an optional count; the soft pill when current.
private struct DrawerRow: View {
    private enum Icon {
        case asset(String)
        case symbol(String)
    }

    private let icon: Icon
    let title: String
    var subtitle: String?
    var count: Int?
    var compact = false
    var isCurrent = false
    let action: () -> Void

    init(icon: String, title: String, subtitle: String? = nil, count: Int? = nil, isCurrent: Bool = false, action: @escaping () -> Void) {
        self.icon = .asset(icon)
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.isCurrent = isCurrent
        self.action = action
    }

    /// A small row with an SF Symbol (the copy actions).
    init(systemIcon: String, title: String, compact: Bool, action: @escaping () -> Void) {
        self.icon = .symbol(systemIcon)
        self.title = title
        self.compact = compact
        self.action = action
    }

    var body: some View {
        // A swipe that ends over the row (closing the drawer) is not a tap on it.
        Button(action: { if !PhoneDrawerTouch.blocksRowTap { action() } }) {
            HStack(spacing: 13) {
                iconView
                    .frame(width: 24, height: 24)
                    .foregroundStyle(compact ? Color.ofMuted : Color.ofInk)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(OFFont.ui(compact ? 15 : 17, compact ? .regular : .medium))
                        .foregroundStyle(compact ? Color.ofMuted : Color.ofInk)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(OFFont.ui(13))
                            .foregroundStyle(.ofMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let count {
                    Text("\(count)")
                        .font(OFFont.ui(14))
                        .monospacedDigit()
                        .foregroundStyle(.ofMuted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, compact ? 7 : 8)
            .background(isCurrent ? Color.ofNavSelection : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case .asset(let name):
            Image(name).renderingMode(.template).resizable().scaledToFit()
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 15))
        }
    }
}
#endif
