import OpenDispatchCore
import SwiftUI

extension View {
    /// Wraps a reader pane's ScrollView: the note sheet (and on iPhone the list sheet), the scrolling to a
    /// highlight, and the article's identity for the web view inside. Apply it before the toolbar inset,
    /// so the toolbar spans the pane.
    func readerHighlights(item: FeedItem, pane: Int, compact: Bool) -> some View {
        modifier(ReaderHighlightsModifier(item: item, pane: pane, compact: compact))
    }
}

private struct ReaderHighlightsModifier: ViewModifier {
    let item: FeedItem
    let pane: Int
    let compact: Bool
    @Environment(HighlightStore.self) private var store

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .environment(\.highlightArticle, ReaderHighlightArticle(item: item, pane: pane))
                // The web view has put its marker at the highlight: bring it a fifth of the way down.
                .onChange(of: store.scrollReady) { _, ready in
                    guard let ready, ready.pane == pane else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(40))
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(HighlightScroll.markerID(pane: pane), anchor: UnitPoint(x: 0, y: 0.2))
                        }
                    }
                }
        }
        .sheet(item: Binding(
            get: { store.noteRequest.flatMap { $0.pane == pane ? $0 : nil } },
            set: { if $0 == nil { store.noteRequest = nil } }
        )) { request in
            if let h = store.highlight(id: request.id) {
                HighlightNoteSheet(highlight: h)
            }
        }
        #if os(iOS)
        .sheet(isPresented: Binding(get: { compact && store.isSheetPresented }, set: { store.isSheetPresented = $0 })) {
            HighlightsSheet(item: item, pane: pane)
        }
        #endif
    }
}

/// Add Note…, Edit Note…, or the popover's note: a sheet over the reader like Apple Books' with the
/// highlight's time, the quote beside its color bar in the reader font, a multi-line editor, and Cancel
/// and Done. Edits are kept in the sheet and saved by Done only. On iPhone it is a bottom sheet.
struct HighlightNoteSheet: View {
    let highlight: Highlight
    @Environment(HighlightStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(highlight: Highlight) {
        self.highlight = highlight
        _text = State(initialValue: highlight.note)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var time: String { highlight.createdAt.formatted(date: .abbreviated, time: .shortened) }

    private func done() {
        if trimmed != highlight.note { store.setNote(highlight.id, trimmed) }
        dismiss()
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Note")
                    .font(OFFont.ui(17, .semibold))
                    .tracking(-0.17)
                    .foregroundStyle(.ofInk)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(time)
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofMuted)
            }
            quote
            editor
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SettingsSmallButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: done)
                    .buttonStyle(SettingsSmallButtonStyle(fill: .ofAccent))
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Color.ofSurface)
        .onAppear { focused = true }
        #else
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                quote
                editor
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Note").font(OFFont.ui(16, .semibold)).foregroundStyle(.ofInk)
                        Text(time).font(OFFont.ui(11)).foregroundStyle(.ofMuted)
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // A swipe down would drop what was typed.
        .interactiveDismissDisabled(trimmed != highlight.note)
        .onAppear { focused = true }
        #endif
    }

    /// The highlighted passage with its color bar.
    private var quote: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(highlight.color.swatch)
                .frame(width: 3)
            Text(highlight.text)
                .font(OFFont.reader(model.settings.readerFont, 14))
                .foregroundStyle(.ofBody)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(OFFont.ui(14))
            .foregroundStyle(.ofInk)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 120, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofGround))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Color.ofAccent : Color.ofBorder)
            )
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Add a note\u{2026}")
                        .font(OFFont.ui(14))
                        .foregroundStyle(.ofFaint)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Note")
    }
}
