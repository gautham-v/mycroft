import OpenDispatchCore
import SwiftUI

/// The article's full list of highlights and notes, from the reader bar's highlighter button: a popover
/// under the button (Mac, iPad) or a sheet (iPhone). Entries are in document order, each with its color
/// bar, the quote clamped to three lines in the reader font and its note in muted text; picking one
/// closes the list and scrolls the article to it. The footer has Copy as Markdown and the Readwise
/// status line.

/// The reader bar's Highlights & Notes button. The glyph takes the accent while the list is open.
struct HighlightsToolbarButton: View {
    let item: FeedItem
    let pane: Int
    let compact: Bool
    let size: CGFloat
    let glyph: CGFloat
    @Environment(HighlightStore.self) private var store
    @State private var isOpen = false

    var body: some View {
        let open = compact ? store.isSheetPresented : isOpen
        Button {
            if compact { store.isSheetPresented.toggle() } else { isOpen.toggle() }
        } label: {
            OFIcon.highlighter.image.foregroundStyle(open ? Color.ofAccent : Color.ofInk)
        }
        .buttonStyle(ReaderIconButtonStyle(size: size, glyph: glyph))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            HighlightsList(item: item, pane: pane, showsHeader: true)
                .frame(width: 340)
                .presentationCompactAdaptation(.popover)
        }
        .help("Highlights & Notes")
        .accessibilityLabel("Highlights and notes")
    }
}

#if os(iOS)
/// iPhone: the list in a sheet.
struct HighlightsSheet: View {
    let item: FeedItem
    let pane: Int
    @Environment(HighlightStore.self) private var store

    var body: some View {
        NavigationStack {
            HighlightsList(item: item, pane: pane, showsHeader: false)
                .navigationTitle("Highlights & Notes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { store.isSheetPresented = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif

/// The list: header (in the popover), entries, empty state, and the footer.
struct HighlightsList: View {
    let item: FeedItem
    let pane: Int
    /// A title and count above the entries; the iPhone sheet has them in its navigation bar.
    let showsHeader: Bool
    @Environment(HighlightStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Task<Void, Never>?
    @State private var justCopied = false
    /// The entries' height, so the popover is as tall as its content up to a limit (a ScrollView has no
    /// height of its own).
    @State private var contentHeight: CGFloat = 0

    private static let maxListHeight: CGFloat = 380

    private var key: String { HighlightStore.key(for: item) }

    var body: some View {
        let list = store.ordered(forKey: key)
        let missing = store.resolution(forKey: key)?.missing ?? []
        VStack(spacing: 0) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Highlights & Notes")
                        .font(OFFont.ui(14, .semibold))
                        .foregroundStyle(.ofInk)
                    if !list.isEmpty {
                        Text("\(list.count)").font(OFFont.ui(13)).foregroundStyle(.ofMuted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if list.isEmpty {
                        Text(emptyText)
                            .font(OFFont.ui(13))
                            .foregroundStyle(.ofMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 36)
                    } else {
                        ForEach(list) { h in
                            HighlightRow(highlight: h, missing: missing.contains(h.id)) {
                                dismiss()
                                store.scroll(to: h.id, pane: pane)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollContentBackground(.hidden)
            .overlayScrollers()
            .frame(height: showsHeader ? min(max(contentHeight, 1), Self.maxListHeight) : nil)
            footer(empty: list.isEmpty)
        }
        .background(Color.ofSurface)
    }

    private var emptyText: String {
        #if os(macOS)
        "Select text, then Control-click to highlight or add a note."
        #else
        "Select text, then choose Highlight or Add Note."
        #endif
    }

    private func footer(empty: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                store.copyMarkdown(forKey: key)
                justCopied = true
                copied?.cancel()
                copied = Task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    if !Task.isCancelled { justCopied = false }
                }
            } label: {
                Text(justCopied ? "Copied" : "Copy as Markdown")
                    .font(OFFont.ui(13, .medium))
                    .foregroundStyle(empty ? Color.ofFaint : Color.ofAccent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(empty)
            if let line = store.readwiseLine {
                Text(line)
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ofSurface)
        .overlay(alignment: .top) { Rectangle().fill(Color.ofHairline).frame(height: 1) }
    }
}

/// One highlight in the list: a button that scrolls the article to it.
private struct HighlightRow: View {
    let highlight: Highlight
    let missing: Bool
    let pick: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(highlight.color.swatch)
                    .frame(width: 3)
                    .opacity(missing ? 0.4 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(highlight.text)
                        .font(OFFont.reader(model.settings.readerFont, 14))
                        .foregroundStyle(missing ? Color.ofMuted : Color.ofInk)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if !highlight.note.isEmpty {
                        Text(highlight.note)
                            .font(OFFont.ui(13))
                            .foregroundStyle(.ofMuted)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    if missing {
                        Text("Not found in this version of the article")
                            .font(OFFont.ui(12))
                            .foregroundStyle(.ofMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(hovering && !missing ? Color.ofHover : Color.clear)
            )
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(missing)
        .onHover { hovering = $0 }
        .help(missing ? "Not found in this version of the article" : "Show in the article")
        .accessibilityElement(children: .combine)
    }
}
