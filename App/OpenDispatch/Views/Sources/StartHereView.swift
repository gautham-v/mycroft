import OpenDispatchCore
import SwiftUI

/// The "Start here" board for an empty library: one page to search, add a starter pack or import, with the stories landing in
/// the list beside it (Mac and iPad: `StartHerePane`, in the reader's default tab) or under it (iPhone: `StartHereListRow`).
/// `AppModel.isStartHereUp` says when it shows. Done appears once the library has something, since an empty one has
/// nothing to show instead.
struct StartHereView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
                .padding(.top, 10)
                .padding(.bottom, 18)
            ForEach(StarterSources.packs) { pack in
                Rectangle().fill(Color.ofHairline).frame(height: 1)
                StarterPackRow(pack: pack)
            }
            Rectangle().fill(Color.ofHairline).frame(height: 1)
            links
                .padding(.top, 12)
        }
    }

    private var header: some View {
        HStack {
            Text("Start here")
                .font(OFFont.ui(22, .semibold))
                .foregroundStyle(.ofInk)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if !model.isLibraryEmpty {
                Button { model.dismissStartHere() } label: {
                    Text("Done")
                        .font(OFFont.ui(13))
                        .foregroundStyle(.ofMuted)
                        .frame(minHeight: StartHereMetrics.target)
                        .padding(.leading, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: StartHereMetrics.target)
    }

    /// Looks like a field and opens the Add sources sheet, where the typing happens.
    private var searchField: some View {
        Button {
            model.isAddSourcePresented = true
        } label: {
            HStack(spacing: 8) {
                OFIcon.search.image
                    .font(.system(size: 13))
                Text("Name, @handle or link")
                    .font(OFFont.ui(14))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.ofFaint)
            .padding(.horizontal, 12)
            .frame(minHeight: max(40, StartHereMetrics.target))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofGround))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.ofBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add sources")
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 0) {
            link("Import from another reader\u{2026}") { importing = true }
                .opmlImporter(isPresented: $importing)
            link("Follow a topic\u{2026}") { model.beginNewTopic() }
        }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(OFFont.ui(13))
                .foregroundStyle(.ofAccent)
                .frame(minHeight: StartHereMetrics.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The board's touch targets: the iOS minimum, or a compact row on the Mac.
private enum StartHereMetrics {
    static var target: CGFloat {
        #if os(iOS)
        Metrics.touchTarget
        #else
        28
        #endif
    }
}

/// One starter pack: up to three overlapping favicons, its name and sources, and Add.
private struct StarterPackRow: View {
    let pack: StarterPack
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private static let badgeSize: CGFloat = 24
    /// The ring around each badge, which keeps the overlap readable.
    private static let badgeRing: CGFloat = 1.5
    private static let badgeOverlap: CGFloat = 9
    private static var badgesWidth: CGFloat {
        let badge = badgeSize + badgeRing * 2
        return badge * 3 - badgeOverlap * 2
    }

    var body: some View {
        let progress = model.starterProgress(pack)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                badges
                VStack(alignment: .leading, spacing: 1) {
                    Text(pack.name)
                        .font(OFFont.ui(14, .medium))
                        .foregroundStyle(.ofInk)
                        .lineLimit(1)
                    Text(pack.sources.map(\.title).joined(separator: ", "))
                        .font(OFFont.ui(12))
                        .foregroundStyle(.ofMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                button(progress)
            }
            if let note = progress.failureNote {
                Text(note)
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.badgesWidth + 12)
            }
        }
        .padding(.vertical, 8)
    }

    private var badges: some View {
        HStack(spacing: -Self.badgeOverlap) {
            ForEach(pack.sources.prefix(3)) { source in
                SourceBadge(host: source.host, title: source.title, size: Self.badgeSize)
                    .padding(Self.badgeRing)
                    .background(Color.ofSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(width: Self.badgesWidth, alignment: .leading)
    }

    @ViewBuilder private func button(_ progress: StarterPackProgress) -> some View {
        let enabled = !progress.isAdding && !progress.isAdded
        Button { model.addStarterPack(pack) } label: {
            ZStack {
                if progress.isAdding {
                    ProgressView().controlSize(.small)
                } else if progress.isAdded {
                    Text("Added")
                        .font(OFFont.ui(13))
                        .foregroundStyle(.ofMuted)
                } else {
                    Text("Add")
                        .font(OFFont.ui(13, .medium))
                        .foregroundStyle(.ofInk)
                }
            }
            .frame(width: 64, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(enabled && hovering ? Color.ofHover : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(enabled ? Color.ofBorder : .clear, lineWidth: 1)
            )
            .frame(minHeight: StartHereMetrics.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .accessibilityLabel(progress.isAdded ? "\(pack.name), added" : progress.isAdding ? "Adding \(pack.name)" : "Add \(pack.name)")
    }
}

/// Mac and iPad: the board fills the reader pane, under the pane's tabs (+ still opens Explore).
struct StartHerePane: View {
    let pane: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            StartHereView()
                .frame(maxWidth: 460)
                .padding(.horizontal, 24)
                .padding(.top, 72)
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .overlayScrollers()
        .safeAreaInset(edge: .top, spacing: 0) {
            ReaderBar(pane: pane) {
                if model.isSplit {
                    Button { model.closePane(pane) } label: { OFIcon.close.image }
                        .buttonStyle(ReaderIconButtonStyle(size: Metrics.readerActionButton, glyph: Metrics.readerActionGlyph))
                        .help("Close this pane")
                        .accessibilityLabel("Close pane")
                }
            }
        }
        .background(Color.ofSurface)
    }
}

#if os(iOS)
/// iPhone: the board in the home list's place for its title, so the stories arrive under it in the same scroll. It takes the
/// title's id, since scrolling the list back to the top goes there.
struct StartHereListRow: View {
    var body: some View {
        StartHereView()
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .id(PhoneTitleRow.id)
    }
}
#endif
