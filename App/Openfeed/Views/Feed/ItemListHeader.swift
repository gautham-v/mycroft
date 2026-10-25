import OpenfeedCore
import SwiftUI

/// Desktop list header (openfeed-app.tsx, lg and up): 54pt, title 15/600 + "updated X ago" 13 muted on
/// one baseline, search button (or the search field in place of the title), refresh button.
/// A show-sidebar button leads when the sidebar is collapsed.
struct DesktopListHeader: View {
    @Environment(AppModel.self) private var model
    var searchFocus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            if model.sidebarCollapsed {
                Button(action: { model.toggleSidebar() }) {
                    OFIcon.sidebar.image
                        .font(.system(size: 15))
                        .frame(width: Metrics.desktopIconButton, height: Metrics.desktopIconButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FeedHoverIconButtonStyle())
                .help("Show sidebar (⌘\\)")
                .accessibilityLabel("Show sidebar")
            }
            if model.isSearchOpen {
                FeedSearchField(variant: .desktop, focus: searchFocus)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.listTitle)
                        .font(OFFont.listHeaderTitle)
                        .tracking(-0.15)
                        .foregroundStyle(.ofInk)
                        .lineLimit(1)
                        .layoutPriority(1)
                    FeedUpdatedLabel(font: OFFont.listHeaderSubline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                FeedSearchButton(phone: false, searchFocus: searchFocus)
            }
            FeedRefreshButton(phone: false)
        }
        .padding(.leading, model.sidebarCollapsed ? 12 : 18)
        .padding(.trailing, 12)
        .frame(height: Metrics.desktopHeaderHeight)
    }
}

/// Phone/tablet header: large title 28/700 with the subline under it, back chevron in a source or
/// folder feed, search and refresh buttons (44pt), the full-width search row when open, then the view
/// chips on the Feed tab.
struct PhoneListHeader: View {
    @Environment(AppModel.self) private var model
    var searchFocus: FocusState<Bool>.Binding
    /// Show the All/Articles/Posts/Video/Podcasts chips (the Feed tab).
    var showsChips: Bool
    var onBack: (() -> Void)?

    /// Blank while a source/folder feed waits for the sources list, rather than flashing the view name.
    private var title: String {
        if model.isInSourceFeed, model.activeSource == nil, model.activeFolder == nil { return "" }
        return model.listTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let onBack {
                    Button(action: onBack) {
                        OFIcon.back.image
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FeedHoverIconButtonStyle(inkOnHover: false, baseColor: .ofInk))
                    .accessibilityLabel("Back to sources")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(OFFont.phoneTitle)
                        .tracking(-0.56)
                        .foregroundStyle(.ofInk)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    FeedUpdatedLabel(font: OFFont.phoneSubline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !model.isSearchOpen {
                    FeedSearchButton(phone: true, searchFocus: searchFocus)
                }
                FeedRefreshButton(phone: true)
            }
            .padding(.leading, onBack == nil ? 16 : 4)
            .padding(.trailing, 8)
            .padding(.top, 12)

            if model.isSearchOpen {
                FeedSearchField(variant: .phone, focus: searchFocus)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            if showsChips {
                FeedViewChips()
                    .padding(.top, 6)
            } else {
                Color.clear.frame(height: 12)
            }
        }
    }
}

/// "updated 5m ago", re-rendered every 30 s.
struct FeedUpdatedLabel: View {
    @Environment(AppModel.self) private var model
    let font: Font

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(model.updatedLabel(now: context.date))
                .font(font)
                .foregroundStyle(.ofMuted)
                .lineLimit(1)
        }
    }
}

/// Refresh feeds (forced). Spins while refreshing; disabled meanwhile.
struct FeedRefreshButton: View {
    @Environment(AppModel.self) private var model
    let phone: Bool

    var body: some View {
        Button(action: { Task { await model.refresh(force: true) } }) {
            OFIcon.refresh.image
                .font(.system(size: phone ? 18 : 15, weight: .regular))
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: model.isRefreshing)
                .frame(width: phone ? Metrics.touchTarget : Metrics.desktopIconButton,
                       height: phone ? Metrics.touchTarget : Metrics.desktopIconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(FeedHoverIconButtonStyle(inkOnHover: !phone, baseColor: phone ? .ofInk : .ofMuted))
        .disabled(model.isRefreshing)
        .opacity(model.isRefreshing ? 0.7 : 1)
        .help("Refresh (r)")
        .accessibilityLabel(model.isRefreshing ? "Refreshing" : "Refresh feeds")
    }
}

/// Opens and focuses the search field.
struct FeedSearchButton: View {
    @Environment(AppModel.self) private var model
    let phone: Bool
    var searchFocus: FocusState<Bool>.Binding

    var body: some View {
        Button(action: {
            model.openSearch()
            Task { @MainActor in
                await Task.yield()
                searchFocus.wrappedValue = true
            }
        }) {
            OFIcon.search.image
                .font(.system(size: phone ? 18 : 15))
                .frame(width: phone ? Metrics.touchTarget : Metrics.desktopIconButton,
                       height: phone ? Metrics.touchTarget : Metrics.desktopIconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(FeedHoverIconButtonStyle(inkOnHover: !phone, baseColor: phone ? .ofInk : .ofMuted))
        .help("Search (/)")
        .accessibilityLabel("Search")
    }
}

/// Phone view chips: All, Articles, Posts, Video, Podcasts (CHIPS in openfeed-app.tsx). Horizontally
/// scrolling; each is a 44pt touch target with a 32pt pill inside. Active = ink pill with surface text.
struct FeedViewChips: View {
    @Environment(AppModel.self) private var model
    private static let chips: [(FeedView, String)] = [
        (.all, "All"), (.articles, "Articles"), (.posts, "Posts"), (.video, "Video"), (.podcasts, "Podcasts"),
    ]

    private var activeChip: FeedView? {
        model.isInSourceFeed || model.selectedView == .saved ? nil : model.selectedView
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.chips, id: \.0) { view, label in
                    let active = activeChip == view
                    Button(action: { model.navigate(view: view) }) {
                        Text(label)
                            .font(OFFont.chip)
                            .foregroundStyle(active ? Color.ofSurface : Color.ofInk)
                            .padding(.horizontal, 14)
                            .frame(height: Metrics.chipHeight)
                            .background(active ? Color.ofInk : Color.ofCode, in: Capsule())
                            .frame(height: Metrics.touchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .accessibilityLabel("Views")
    }
}
