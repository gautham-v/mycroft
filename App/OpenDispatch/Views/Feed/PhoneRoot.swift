#if os(iOS)
import OpenDispatchCore
import SwiftUI
import UIKit

/// Where the iPhone's one navigation stack can go from the home list besides the reader.
enum PhoneRoute: Hashable {
    case manageSources
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
/// the list's hamburger button or an edge swipe from the left: it covers 82% of the width, and the list
/// slides right, dims, shrinks a little and rounds its corners as a peek; tapping the peek or swiping
/// closes it. Opening a row, Manage sources and a source's feed push onto the stack; Settings and Add
/// source are sheets (RootView).
struct PhoneRoot: View {
    @Environment(AppModel.self) private var model
    /// The drawer is open (or opening: a drag in progress is tracked by `drag`).
    @State private var isOpen = false
    /// Finger travel while dragging the drawer open or closed.
    @State private var drag: CGFloat = 0
    /// Whether the current drag moves the drawer: decided once, on its first movement.
    @State private var dragMoves: Bool?
    @State private var path: [PhoneRoute] = []

    private static let drawerFraction: CGFloat = 0.82
    /// An edge swipe starts within this distance of the screen's left edge.
    private static let edgeWidth: CGFloat = 24

    var body: some View {
        // The outer reader only learns the safe area (the drawer's content keeps clear of the status bar
        // and home indicator); the inner one fills the screen.
        // Read here, not in the geometry closures, which don't re-run when the model changes.
        let edgeSwipe = canOpenFromEdge
        return GeometryReader { outer in
            screen(safeArea: outer.safeAreaInsets, edgeSwipe: edgeSwipe)
        }
        .background(Color.ofDrawer.ignoresSafeArea())
    }

    private func screen(safeArea: EdgeInsets, edgeSwipe: Bool) -> some View {
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
            .simultaneousGesture(drawerDrag(width: width, edgeSwipe: edgeSwipe))
        }
        .ignoresSafeArea()
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

    /// The edge swipe may only open the drawer from the home list: with something pushed, the stack's own
    /// swipe back owns the left edge.
    private var canOpenFromEdge: Bool {
        path.isEmpty && model.selectedItemID == nil
    }

    /// The drawer follows the finger: `translation` is how far it moved horizontally.
    private func panChanged(_ translation: CGFloat, width: CGFloat) {
        drag = isOpen ? min(0, max(-width, translation)) : min(width, max(0, translation))
    }

    /// Settles open or closed by where the drawer would stop.
    private func panEnded(_ translation: CGFloat, velocity: CGFloat, width: CGFloat) {
        let predicted = (isOpen ? width : 0) + translation + velocity * 0.15
        settle(open: predicted > width / 2)
    }

    /// Dragging the drawer: a swipe from the left edge opens it (home list only); a horizontal swipe while it
    /// is open closes it.
    private func drawerDrag(width: CGFloat, edgeSwipe: Bool) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if dragMoves == nil {
                    let horizontal = abs(value.translation.width) > abs(value.translation.height)
                    dragMoves = horizontal && (isOpen || (edgeSwipe && value.startLocation.x < Self.edgeWidth))
                    PhoneDrawerTouch.isDragging = dragMoves == true
                }
                if dragMoves == true { panChanged(value.translation.width, width: width) }
            }
            .onEnded { value in
                defer {
                    dragMoves = nil
                    PhoneDrawerTouch.isDragging = false
                }
                if dragMoves == true {
                    PhoneDrawerTouch.endedAt = Date()
                    panEnded(value.translation.width, velocity: (value.predictedEndTranslation.width - value.translation.width) / 0.15, width: width)
                }
            }
    }
}

/// Whether a drawer drag is under way or just ended. The list under the finger is a UIKit view that still
/// sees the touch and would open the row it ends on, so rows ignore taps for a moment after a drag.
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
