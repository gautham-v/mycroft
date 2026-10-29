import OpenDispatchCore
import SwiftUI

// The Settings sidebar (Mac and iPad) and the iPhone root's pane rows: each pane has an outline SF Symbol drawn
// like the app sidebar's view rows, the panes come in groups, and the Mac's column has a search field and the
// iCloud status at the top.

extension SettingsTab {
    /// The panes as the sidebar groups them.
    static let groups: [[SettingsTab]] = [
        [.appearance, .themes, .reader],
        [.sources, .playback, .notifications],
        [.integrations, .data],
        [.about],
    ]

    /// The pane's SF Symbol, outline like the app sidebar's.
    var symbol: String {
        switch self {
        case .sources: "dot.radiowaves.up.forward"
        case .appearance: "circle.lefthalf.filled"
        case .themes: "paintpalette"
        case .reader: "textformat"
        case .playback: OFIcon.video.rawValue
        case .notifications: OFIcon.bell.rawValue
        case .integrations: "puzzlepiece.extension"
        case .data: "internaldrive"
        case .about: "info.circle"
        }
    }

    /// Words the sidebar's search matches besides the label.
    var keywords: String {
        switch self {
        case .sources: "feeds folders add opml import export remove"
        case .appearance: "theme color scheme light dark auto system accent lists density compact thumbnails unread read icons shortcuts keyboard"
        case .themes: "theme colors palette custom light dark mode background accent"
        case .reader: "font serif sans size text line spacing width fill window highlight links underline comments"
        case .playback: "video youtube autoplay theater transcript sponsorblock read aloud voice speed"
        case .notifications: "alerts new posts notify"
        case .integrations: "readwise webhook send markdown copy prompt sign in x reddit paywall subscribe"
        case .data: "icloud sync refresh cache database storage"
        case .about: "version updates credits"
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || label.lowercased().contains(q) || keywords.contains(q)
    }
}

extension CloudSyncStatus {
    /// One line for the status: "Up to date", "Synced 5m ago", "Off on this device".
    func line(now: Date) -> String {
        switch self {
        case .off: return "Off on this device"
        case .unavailable(let why): return why
        case .syncing: return "Syncing…"
        case .synced(let at):
            let rel = RelativeTime.format(at, now: now)
            return rel == "now" ? "Up to date" : "Synced \(rel) ago"
        case .failed(let why): return "Couldn't sync: \(why)"
        }
    }

    /// Green when synced, grey when off or busy, red when it failed.
    var dot: Color {
        switch self {
        case .synced: .ofOK
        case .failed, .unavailable: .ofDanger
        case .off, .syncing: .ofFaint
        }
    }
}

/// The Mac and iPad Settings sidebar: search, the iCloud status (opens Data), then the panes in groups.
struct SettingsSidebar: View {
    let selection: SettingsTab
    let select: (SettingsTab) -> Void
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var groups: [[SettingsTab]] {
        SettingsTab.groups.map { $0.filter { $0.matches(query) } }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            search
                .padding(.bottom, 10)
            syncRow
                .padding(.bottom, 12)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(group) { p in
                        SettingsNavRow(pane: p, selected: selection == p) { select(p) }
                    }
                }
                .padding(.bottom, 12)
            }
            if groups.isEmpty {
                Text("No settings match")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
                    .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.ofMuted)
            TextField("Search Settings", text: $query)
                .textFieldStyle(.plain)
                .font(OFFont.ui(13))
                .foregroundStyle(.ofInk)
                .focused($searchFocused)
                .onSubmit { if let first = groups.first?.first { select(first) } }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.ofFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofNavSelection))
    }

    private var syncRow: some View {
        Button { select(.data) } label: {
            HStack(spacing: 10) {
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("OpenDispatch")
                        .font(OFFont.ui(13, .semibold))
                        .foregroundStyle(.ofInk)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        HStack(spacing: 5) {
                            Circle().fill(model.syncStatus.dot).frame(width: 6, height: 6)
                            Text(model.syncStatus.line(now: context.date))
                                .font(OFFont.ui(11))
                                .foregroundStyle(.ofMuted)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selection == .data ? Color.ofNavSelection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("iCloud sync, \(model.syncStatus.line(now: Date()))")
    }
}

/// A sidebar row drawn like the app sidebar's view rows (`SidebarViewRow`): the outline symbol in a 20pt column,
/// the name, the same height and backgrounds.
struct SettingsNavRow: View {
    let pane: SettingsTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.ofInk)
                    .frame(width: SidebarStyle.iconColumn)
                    .accessibilityHidden(true)
                Text(pane.label)
                    .font(OFFont.sidebarRow)
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SidebarStyle.rowPadding)
            .frame(height: Metrics.sidebarRowHeight)
            .contentShape(Rectangle())
            .modifier(SidebarRowBackground(active: selected, hovered: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
