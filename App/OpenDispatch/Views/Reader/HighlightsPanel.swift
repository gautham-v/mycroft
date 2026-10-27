import OpenDispatchCore
import SwiftUI

/// Highlights & Notes for the article a reader pane shows: a panel on the pane's right side (Mac, iPad), a
/// sheet on iPhone. Lists the article's highlights in document order, each with a color bar, the quote in
/// the reader font, an editable note and a remove button; clicking a quote scrolls the reader to it.
extension View {
    /// Wraps a reader pane's ScrollView: the panel (or the iPhone sheet), the highlight scrolling, and the
    /// article's identity for the web view inside. Apply it before the toolbar inset, so the toolbar spans
    /// the panel too.
    func highlightsPanel(item: FeedItem, pane: Int, compact: Bool) -> some View {
        modifier(HighlightsPanelModifier(item: item, pane: pane, compact: compact))
    }
}

private struct HighlightsPanelModifier: ViewModifier {
    let item: FeedItem
    let pane: Int
    let compact: Bool
    @Environment(HighlightStore.self) private var store
    /// iPhone: the highlight whose color the second menu is changing.
    @State private var colorTarget: String?

    func body(content: Content) -> some View {
        @Bindable var store = store
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                content
                    .environment(\.highlightArticle, ReaderHighlightArticle(item: item, pane: pane, compact: compact))
                if !compact, store.isPanelOpen(pane: pane), item.source.kind != .youtube {
                    Rectangle().fill(Color.ofHairline).frame(width: 1)
                    HighlightsPanel(item: item, pane: pane)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: store.isPanelOpen(pane: pane))
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
        #if os(iOS)
        .sheet(isPresented: Binding(get: { compact && store.isSheetPresented }, set: { store.isSheetPresented = $0 })) {
            HighlightsSheet(item: item, pane: pane)
        }
        .confirmationDialog("Highlight", isPresented: Binding(get: { compact && store.actionTarget != nil }, set: { if !$0 { store.actionTarget = nil } }),
                            titleVisibility: .hidden, presenting: store.actionTarget) { id in
            Button("Change Color\u{2026}") { colorTarget = id }
            Button("Edit Note\u{2026}") {
                store.focusNote = id
                store.isSheetPresented = true
            }
            Button("Remove Highlight", role: .destructive) { store.remove(id) }
        }
        .confirmationDialog("Color", isPresented: Binding(get: { colorTarget != nil }, set: { if !$0 { colorTarget = nil } }),
                            titleVisibility: .visible, presenting: colorTarget) { id in
            ForEach(HighlightColor.allCases) { color in
                Button(color.title) { store.setColor(id, color) }
            }
        }
        #endif
    }
}

/// The reader bar's Highlights & Notes button: opens or closes the panel (the sheet on iPhone). The glyph
/// takes the accent while it is open.
struct HighlightsToolbarButton: View {
    let pane: Int
    let compact: Bool
    let size: CGFloat
    let glyph: CGFloat
    @Environment(HighlightStore.self) private var store

    var body: some View {
        let open = compact ? store.isSheetPresented : store.isPanelOpen(pane: pane)
        Button {
            if compact { store.isSheetPresented.toggle() } else { store.togglePanel(pane: pane) }
        } label: {
            OFIcon.highlighter.image.foregroundStyle(open ? Color.ofAccent : Color.ofInk)
        }
        .buttonStyle(ReaderIconButtonStyle(size: size, glyph: glyph))
        .help("Highlights & Notes")
        .accessibilityLabel("Highlights and notes")
        .accessibilityValue(open ? "Shown" : "Hidden")
    }
}

#if os(iOS)
/// iPhone: the panel's list in a sheet.
private struct HighlightsSheet: View {
    let item: FeedItem
    let pane: Int
    @Environment(HighlightStore.self) private var store

    var body: some View {
        NavigationStack {
            HighlightsPanel(item: item, pane: pane)
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

/// The list: header, entries in document order, empty state, and a footer with Copy as Markdown and the
/// Readwise status line.
struct HighlightsPanel: View {
    let item: FeedItem
    let pane: Int
    @Environment(HighlightStore.self) private var store
    @Environment(AppModel.self) private var model
    @State private var copied: Task<Void, Never>?
    @State private var justCopied = false

    private var key: String { HighlightStore.key(for: item) }

    private var showsHeader: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        let list = store.ordered(forKey: key)
        let missing = store.resolution(forKey: key)?.missing ?? []
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if showsHeader {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Highlights & Notes")
                                .font(OFFont.ui(14, .semibold))
                                .foregroundStyle(.ofInk)
                            if !list.isEmpty {
                                Text("\(list.count)").font(OFFont.ui(13)).foregroundStyle(.ofMuted)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                    }
                    if list.isEmpty {
                        Text(emptyText)
                            .font(OFFont.ui(13))
                            .foregroundStyle(.ofMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 28)
                            .padding(.top, 48)
                    } else {
                        ForEach(list) { h in
                            HighlightEntry(highlight: h, missing: missing.contains(h.id), selected: store.selected == h.id, pane: pane)
                                .id(h.id)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollContentBackground(.hidden)
            .overlayScrollers()
            .onChange(of: store.selected) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer(empty: list.isEmpty) }
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

/// One highlight in the panel.
private struct HighlightEntry: View {
    let highlight: Highlight
    let missing: Bool
    let selected: Bool
    let pane: Int
    @Environment(HighlightStore.self) private var store
    @Environment(AppModel.self) private var model
    @State private var note: String
    @State private var saveTask: Task<Void, Never>?
    @State private var hovering = false
    @FocusState private var noteFocused: Bool

    init(highlight: Highlight, missing: Bool, selected: Bool, pane: Int) {
        self.highlight = highlight
        self.missing = missing
        self.selected = selected
        self.pane = pane
        _note = State(initialValue: highlight.note)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(highlight.color.swatch)
                .frame(width: 3)
                .opacity(missing ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    store.scroll(to: highlight.id, pane: pane)
                } label: {
                    Text(highlight.text)
                        .font(OFFont.reader(model.settings.readerFont, 14))
                        .foregroundStyle(missing ? Color.ofMuted : Color.ofInk)
                        .lineLimit(8)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(missing)
                .help(missing ? "Not found in this version of the article" : "Show in the article")

                TextField("Add a note", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofBody)
                    .lineLimit(1...8)
                    .focused($noteFocused)
                    .onSubmit(commit)
                    .accessibilityLabel("Note")

                if missing {
                    Text("Not found in this version of the article")
                        .font(OFFont.ui(12))
                        .foregroundStyle(.ofMuted)
                }
            }
            Button { store.remove(highlight.id) } label: {
                OFIcon.close.image
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.ofMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .opacity(hovering ? 1 : 0)
            #endif
            .help("Remove highlight")
            .accessibilityLabel("Remove highlight")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(selected ? Color.ofSelection : hovering ? Color.ofHover : Color.clear)
        )
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(HighlightColor.allCases) { color in
                Button { store.setColor(highlight.id, color) } label: {
                    if color == highlight.color { Label(color.title, systemImage: OFIcon.check.rawValue) } else { Text(color.title) }
                }
            }
            Divider()
            Button("Remove Highlight", role: .destructive) { store.remove(highlight.id) }
        }
        .onChange(of: note) { _, _ in scheduleSave() }
        .onChange(of: noteFocused) { _, focused in if !focused { commit() } }
        // A note changed on another device while this one isn't being edited.
        .onChange(of: highlight.note) { _, new in if !noteFocused, new != note { note = new } }
        .onChange(of: store.focusNote) { _, id in takeFocus(id) }
        .onAppear { takeFocus(store.focusNote) }
        .onDisappear { commit() }
        .accessibilityElement(children: .contain)
    }

    private func takeFocus(_ id: String?) {
        guard id == highlight.id else { return }
        store.focusNote = nil
        DispatchQueue.main.async { noteFocused = true }
    }

    /// Saves a moment after typing stops, so a note isn't lost if the panel closes mid-sentence.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { commit() }
        }
    }

    private func commit() {
        saveTask?.cancel()
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != highlight.note { store.setNote(highlight.id, trimmed) }
    }
}
