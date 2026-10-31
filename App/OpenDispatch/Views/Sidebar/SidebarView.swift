import OpenDispatchCore
import SwiftUI

/// Desktop (macOS, iPad) sidebar. Port of src/components/sidebar.tsx and the ordering in source-tree.ts
/// (AppModel.orderedFolders / sources(inFolder:)).
///
/// Top to bottom: the sidebar toggle, the search box, the six views and Highlights (any but All can be
/// hidden from the context menu into a collapsed "More" row, and unhidden from there), Topics, Pinned, a
/// "Folders" header with + (New Folder, like Topics'), each folder (header opens the folder feed, chevron
/// collapses it, persisted per device) with its sources, then the sources in no folder as a flat list with no
/// header (new sources land at its end), and a footer with "Add source" and Settings. Sources drag to reorder, between folders and in or out of the flat list; folder headers drag
/// to reorder folders. Context menus and the hover "..." button offer the same actions.
/// Pinned sources list in a "Pinned" group under the views (not in their folder); hidden ones in a
/// collapsed "Hidden" group at the end. Both are not drag targets. The filter field (⌘K) swaps the
/// tree for a flat list of matches.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    /// Inline text field in use (sidebar.tsx `editing`).
    private enum Editing: Equatable {
        case renameFolder(Int64)
        case renameSource(Int64)
        case newFolder(withSource: Int64?)
    }

    @State private var editing: Editing?
    @State private var dragging: SidebarDrag?
    @State private var over: SidebarDrop?
    @State private var pendingDelete: Source?
    @State private var errorMessage: String?

    private static let newFolderAnchor = "sidebar-new-folder"
    private static let searchAnchor = "sidebar-search"

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Scrolls with the list, like the Claude Code sidebar's search box.
                        SidebarFilterField()
                            .padding(.bottom, 6)
                            .id(Self.searchAnchor)
                        if model.isFilteringSources {
                            filterResults
                        } else {
                            viewRows
                            SidebarTopicsSection()
                            pinnedSection
                            foldersHeader
                            ForEach(Array(model.orderedFolders.enumerated()), id: \.element.id) { index, folder in
                                folderSection(folder, first: index == 0)
                            }
                            newFolderField
                            unfiledSection
                            hiddenSection
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                .overlayScrollers()
                // ⌘K with the list scrolled down: bring the search box back into view.
                .onChange(of: model.sourceFilterFocusRequests) { _, _ in
                    withAnimation { proxy.scrollTo(Self.searchAnchor, anchor: .top) }
                }
                .onChange(of: editing) { _, value in
                    if case .newFolder = value {
                        withAnimation { proxy.scrollTo(Self.newFolderAnchor, anchor: .bottom) }
                    }
                }
            }
            footer
        }
        #if os(macOS)
        .background(Color.ofSidebarGround)
        .background(SidebarMaterial())
        #else
        .background(Color.ofGround)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .confirmationDialog(
            pendingDelete.map { "Remove \($0.title)?" } ?? "Remove source?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { source in
            Button("Remove", role: .destructive) { deleteSource(source) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Removing a source also removes its items, including any you saved.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Header and footer

    /// No logo or wordmark (like the Claude desktop app): the sidebar toggle, then Back and Forward for the reader's tab. On
    /// macOS the window title bar is hidden: they follow the traffic lights on the top row.
    private var header: some View {
        HStack(spacing: 0) {
            #if os(macOS)
            SidebarIconButton(icon: .sidebar, label: "Hide sidebar", size: Metrics.desktopIconButton, iconSize: 16) {
                model.toggleSidebar()
            }
            .padding(.leading, Metrics.sidebarToggleX)
            ReaderHistoryButtons()
                .padding(.leading, 2)
            Spacer(minLength: 0)
            #else
            Spacer(minLength: 0)
            SidebarIconButton(icon: .sidebar, label: "Hide sidebar", size: Metrics.desktopIconButton, iconSize: 16) {
                model.toggleSidebar()
            }
            #endif
        }
        #if os(macOS)
        .frame(height: Metrics.topBarHeight)
        #else
        .padding(.horizontal, 10)
        .frame(height: Metrics.desktopHeaderHeight)
        .padding(.top, 10)
        #endif
    }

    private var footer: some View {
        HStack(spacing: 4) {
            SidebarFooterRow(icon: .plus, label: "Add source") {
                model.isAddSourcePresented = true
            }
            SidebarIconButton(icon: .gear, label: "Settings") {
                model.showSettings(.sources)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 5)
        // Edge to edge above the footer, like Claude's: the same 1pt hairline as the sidebar divider and top bar.
        .overlay(alignment: .top) { Rectangle().fill(Color.ofNavHairline).frame(height: 1).allowsHitTesting(false) }
    }

    // MARK: Views

    /// The views, then "More" holding the hidden ones (collapsed unless opened, or one of them is showing).
    private var viewRows: some View {
        let shown = SidebarViewItem.ordered.filter { !model.isSidebarViewHidden($0) }
        let hidden = SidebarViewItem.ordered.filter { model.isSidebarViewHidden($0) }
        let open = model.isMoreViewsExpanded || hidden.contains(where: isActive)
        return VStack(spacing: 0) {
            ForEach(shown) { item in viewRow(item) }
            if !hidden.isEmpty {
                SidebarMoreRow(open: open) {
                    model.isMoreViewsExpanded = !open
                }
                if open {
                    ForEach(hidden) { item in viewRow(item) }
                }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func viewRow(_ item: SidebarViewItem) -> some View {
        switch item {
        case .explore:
            SidebarExploreRow {
                model.openLocation()
            }
            .contextMenu { hideButton(item) }
        case .view(let view):
            SidebarViewRow(view: view, active: isActive(item)) {
                model.navigate(view: view)
            }
            .contextMenu {
                CopyDigestButtons(scope: .view(view))
                if item.isHideable {
                    Divider()
                    hideButton(item)
                }
            }
        case .highlights:
            SidebarHighlightsRow(active: isActive(item)) {
                model.showHighlights()
            }
            .contextMenu { hideButton(item) }
        case .history:
            SidebarHistoryRow(active: isActive(item)) {
                model.showHistory()
            }
            .contextMenu { hideButton(item) }
        }
    }

    private func hideButton(_ item: SidebarViewItem) -> some View {
        let hidden = model.isSidebarViewHidden(item)
        return Button(hidden ? "Unhide" : "Hide from Sidebar") {
            model.setSidebarView(item, hidden: !hidden)
        }
    }

    private func isActive(_ item: SidebarViewItem) -> Bool {
        switch item {
        case .explore:
            false
        case .view(let view):
            model.selectedView == view && model.selectedSourceID == nil && model.selectedFolderID == nil && !model.showsHighlights
                && !model.showsHistory
        case .highlights:
            model.showsHighlights
        case .history:
            model.showsHistory
        }
    }

    // MARK: Folders

    @ViewBuilder
    private func folderSection(_ folder: Folder, first: Bool) -> some View {
        let list = model.sources(inFolder: folder.id)
        let open = !model.isFolderCollapsed(folder.id)
        VStack(alignment: .leading, spacing: 0) {
            folderHeader(folder, open: open)
            if open {
                ForEach(list) { source in
                    sourceRow(source)
                }
                endZone(folderId: folder.id, empty: list.isEmpty)
            }
        }
        .padding(.top, first ? 0 : 12)
    }

    /// "Folders" and its + (New Folder), like the Topics header. Shown with no folders too, so the + is always there.
    private var foldersHeader: some View {
        HStack(spacing: 4) {
            Text("Folders")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button { editing = .newFolder(withSource: nil) } label: {
                SidebarMiniButtonLabel(icon: .plus, size: 20, iconSize: 11)
            }
            .buttonStyle(.plain)
            .help("New Folder")
            .accessibilityLabel("New Folder")
        }
        .font(SidebarStyle.groupFont)
        .tracking(SidebarStyle.sectionTracking)
        .foregroundStyle(SidebarStyle.groupColor)
        .padding(.leading, SidebarStyle.rowPadding)
        .padding(.trailing, 4)
        .frame(height: SidebarStyle.headerHeight)
        .padding(.top, 12)
    }

    /// Sources in no folder (new sources land here): a flat list under the folders, no header. The gap
    /// above it takes folder drops (after the last folder); while a source is dragged and the list is
    /// empty, a "Drop here for no folder" zone stands in for it.
    @ViewBuilder
    private var unfiledSection: some View {
        let list = model.sources(inFolder: nil)
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 12)
                .contentShape(Rectangle())
                .modifier(SidebarDropIndicator(visible: over == .afterFolders))
                .onDrop(of: [.plainText], delegate: dropDelegate(.afterFolders))
            ForEach(list) { source in
                sourceRow(source)
            }
            if !list.isEmpty || isDraggingSource {
                endZone(folderId: nil, empty: list.isEmpty)
            }
        }
    }

    private func folderHeader(_ folder: Folder, open: Bool) -> some View {
        let active = model.selectedFolderID == folder.id
        return SidebarFolderHeader(
            title: folder.title,
            open: open,
            active: active,
            isMuted: folder.isMuted,
            hasMenu: true,
            isEditing: editing == .renameFolder(folder.id),
            onTitle: {
                if active { model.goHome() } else { model.navigate(folderID: folder.id) }
            },
            onToggle: { model.toggleFolderCollapsed(folder.id) },
            onRename: { newTitle in
                editing = nil
                renameFolder(folder.id, newTitle)
            },
            onCancelRename: { editing = nil },
            menu: { folderMenu(folder) }
        )
        .modifier(SidebarDropIndicator(visible: over == .folder(folder.id)))
        .contextMenu { folderMenu(folder) }
        .onDrag {
            dragging = .folder(folder.id)
            return NSItemProvider(object: SidebarDrag.folder(folder.id).payload as NSString)
        }
        .onDrop(of: [.plainText], delegate: dropDelegate(.folder(folder.id)))
    }

    /// The strip after a folder's (or the unfiled list's) last source, or "Drop sources here" when empty:
    /// source drops land at the end; a folder dropped on a folder's strip lands after that folder.
    @ViewBuilder
    private func endZone(folderId: Int64?, empty: Bool) -> some View {
        Group {
            if empty {
                Text(folderId == nil ? "Drop here for no folder" : "Drop sources here")
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofFaint)
                    .padding(.horizontal, SidebarStyle.rowPadding)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear.frame(height: 6)
            }
        }
        .contentShape(Rectangle())
        .modifier(SidebarDropIndicator(visible: over == .end(folderId), edge: .bottom))
        .onDrop(of: [.plainText], delegate: dropDelegate(.end(folderId)))
    }

    @ViewBuilder
    private func sourceRow(_ source: Source, draggable: Bool = true) -> some View {
        let row = SidebarSourceRow(
            source: source,
            active: model.selectedSourceID == source.id,
            isMuted: model.isMuted(source),
            isEditing: editing == .renameSource(source.id),
            onOpen: { model.navigate(sourceID: source.id) },
            onRename: { newTitle in
                editing = nil
                renameSource(source.id, newTitle)
            },
            onCancelRename: { editing = nil },
            menu: { sourceMenu(source) }
        )
        if draggable {
            row
                .modifier(SidebarDropIndicator(visible: over == .row(source.id)))
                .contextMenu { sourceMenu(source) }
                .onDrag {
                    dragging = .source(source.id)
                    return NSItemProvider(object: SidebarDrag.source(source.id).payload as NSString)
                }
                .onDrop(of: [.plainText], delegate: dropDelegate(.row(source.id)))
        } else {
            // Pinned, hidden and filtered rows aren't in the folder tree: no drag, no drop.
            row.contextMenu { sourceMenu(source) }
        }
    }

    // MARK: Pinned, Hidden and filter results

    /// "Pinned" group between the view rows and the folders; its sources are not repeated in their folders.
    @ViewBuilder
    private var pinnedSection: some View {
        let list = model.pinnedSources
        if !list.isEmpty {
            let open = !model.isPinnedGroupCollapsed
            VStack(alignment: .leading, spacing: 0) {
                groupHeader("Pinned", open: open) { model.togglePinnedGroupCollapsed() }
                if open {
                    ForEach(list) { source in sourceRow(source, draggable: false) }
                }
            }
            .padding(.top, 12)
        }
    }

    /// Collapsed "Hidden" group after the unfiled sources: hidden sources stay reachable here and through the filter.
    @ViewBuilder
    private var hiddenSection: some View {
        let list = model.hiddenSources
        if !list.isEmpty {
            let open = model.isHiddenGroupExpanded
            VStack(alignment: .leading, spacing: 0) {
                groupHeader("Hidden", open: open) { model.isHiddenGroupExpanded.toggle() }
                if open {
                    ForEach(list) { source in sourceRow(source, draggable: false) }
                }
            }
            .padding(.top, 12)
        }
    }

    /// Flat matches of the filter field, by title.
    @ViewBuilder
    private var filterResults: some View {
        let list = model.filteredSources
        VStack(alignment: .leading, spacing: 0) {
            if list.isEmpty {
                Text("No sources match")
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofFaint)
                    .padding(.horizontal, SidebarStyle.rowPadding)
                    .padding(.vertical, 6)
            } else {
                ForEach(list) { source in sourceRow(source, draggable: false) }
            }
        }
        .padding(.top, 2)
    }

    private func groupHeader(_ title: String, open: Bool, toggle: @escaping () -> Void) -> some View {
        SidebarFolderHeader(
            title: title, open: open, active: false, hasMenu: false, isEditing: false,
            onTitle: toggle, onToggle: toggle, onRename: { _ in }, onCancelRename: {},
            menu: { EmptyView() }
        )
    }

    /// The name field for a new folder, after the last folder (where it will land).
    @ViewBuilder
    private var newFolderField: some View {
        if case .newFolder(let withSource) = editing {
            SidebarNameField(
                initial: "",
                placeholder: "New folder name",
                onCommit: { title in
                    editing = nil
                    createFolder(title, withSource: withSource)
                },
                onCancel: { editing = nil }
            )
            .padding(.horizontal, 4)
            .padding(.top, model.orderedFolders.isEmpty ? 0 : 12)
            .id(Self.newFolderAnchor)
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("Rename") { editing = .renameFolder(folder.id) }
        Button("New Folder") { editing = .newFolder(withSource: nil) }
        Divider()
        CopyDigestButtons(scope: .folder(folder))
        Divider()
        MuteFolderMenuItem(folder: folder)
        Divider()
        Button(model.allSources(inFolder: folder.id).isEmpty ? "Delete Folder" : "Delete Folder (Keep Sources)", role: .destructive) {
            deleteFolder(folder.id)
        }
    }

    /// Source actions first, then sidebar placement, then the folder submenu, then Remove.
    @ViewBuilder
    private func sourceMenu(_ source: Source) -> some View {
        Button("Refresh Source") { Task { await model.refreshSource(id: source.id) } }
            .disabled(model.isRefreshing)
        if let url = URL(string: source.url), url.scheme != nil {
            Button("Open Site") { openURL(url) }
        }
        if let feed = URL(string: source.feedUrl) {
            Button("Copy Feed URL") { ReaderPasteboard.copy(feed) }
        }
        Toggle("Notify on New Posts", isOn: Binding(get: { source.notifies }, set: { setNotify(source, $0) }))
        Divider()
        Button(source.isPinned ? "Unpin" : "Pin to Sidebar") { setPinned(source, !source.isPinned) }
        Button(source.isHidden ? "Unhide" : "Hide from Sidebar") { setHidden(source, !source.isHidden) }
        MuteSourceMenuItem(source: source)
        Divider()
        Button("Rename") { editing = .renameSource(source.id) }
        Menu("Move to") {
            ForEach(model.orderedFolders) { folder in
                Toggle(folder.title, isOn: moveBinding(source, to: folder.id))
            }
            Toggle("No Folder", isOn: moveBinding(source, to: nil))
            Divider()
            Button("New Folder…") { editing = .newFolder(withSource: source.id) }
        }
        Divider()
        CopyDigestButtons(scope: .source(source))
        Divider()
        Button("Remove Source…", role: .destructive) { pendingDelete = source }
    }

    /// Checked when the source is in that folder; checking it moves the source there.
    private func moveBinding(_ source: Source, to folderId: Int64?) -> Binding<Bool> {
        Binding(
            get: { source.folderId == folderId },
            set: { checked in
                if checked && source.folderId != folderId { moveSource(source.id, to: folderId) }
            })
    }

    // MARK: Drag and drop

    private var isDraggingSource: Bool {
        if case .source = dragging { true } else { false }
    }

    private func dropDelegate(_ target: SidebarDrop) -> SidebarDropDelegate {
        SidebarDropDelegate(target: target, dragging: dragging, over: $over) { drag, target in
            handleDrop(drag, at: target)
        }
    }

    private func handleDrop(_ drag: SidebarDrag, at target: SidebarDrop) {
        dragging = nil
        over = nil
        let folderOrder = model.orderedFolders.map(\.id)
        switch drag {
        case .source(let id):
            var contents: [Int64?: [Int64]] = [nil: model.sources(inFolder: nil).map(\.id)]
            for fid in folderOrder { contents[fid] = model.sources(inFolder: fid).map(\.id) }
            guard let next = SidebarTree.dropSource(id: id, at: target, folderOrder: folderOrder, contents: contents) else { return }
            let order = next.map { SourceOrderEntry(id: $0.id, folderId: $0.folderId) }
            Task { await model.reorderSources(order) }
        case .folder(let id):
            guard let ids = SidebarTree.dropFolder(id: id, at: target, order: folderOrder) else { return }
            Task { await model.reorderFolders(ids) }
        case .topic:
            return  // Topics take drops only in their own section (SidebarTopicsSection).
        }
    }

    // MARK: Actions

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch { errorMessage = HTTP.message(error) }
        }
    }

    private func moveSource(_ id: Int64, to folderId: Int64?) {
        perform { try await model.moveSource(id: id, toFolder: folderId) }
    }

    private func renameSource(_ id: Int64, _ title: String) {
        perform { try await model.renameSource(id: id, title: title) }
    }

    private func setPinned(_ source: Source, _ pinned: Bool) {
        perform { try await model.setSourcePinned(id: source.id, pinned: pinned) }
    }

    private func setHidden(_ source: Source, _ hidden: Bool) {
        perform { try await model.setSourceHidden(id: source.id, hidden: hidden) }
    }

    private func setNotify(_ source: Source, _ on: Bool) {
        perform { try await model.setSourceNotify(id: source.id, on: on) }
    }

    private func deleteSource(_ source: Source) {
        perform { try await model.deleteSource(id: source.id) }
    }

    private func createFolder(_ title: String, withSource sourceId: Int64?) {
        perform { try await model.createFolder(title: title, withSource: sourceId) }
    }

    private func renameFolder(_ id: Int64, _ title: String) {
        perform { try await model.renameFolder(id: id, title: title) }
    }

    private func deleteFolder(_ id: Int64) {
        perform { try await model.deleteFolder(id: id) }
    }
}

// MARK: - Rows

/// A source row: title (ink, 14pt), "..." options button on hover, inline rename field when editing.
private struct SidebarSourceRow<MenuContent: View>: View {
    let source: Source
    let active: Bool
    /// Out of the feeds: the title goes quiet.
    let isMuted: Bool
    let isEditing: Bool
    let onOpen: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            if isEditing {
                SidebarNameField(initial: source.title, placeholder: "Source name", onCommit: onRename, onCancel: onCancelRename)
            } else {
                // A tap gesture, not a Button: on macOS a Button keeps the mouse-down, so the row's .onDrag never starts.
                Text(source.title)
                    .font(OFFont.sidebarRow)
                    .foregroundStyle(isMuted ? Color.ofRead : Color.ofInk)
                    .modifier(SidebarTitleFade(clearsButton: hovered))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpen)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onOpen() }
                    .help(source.lastError.map { "Last refresh failed: \($0)" } ?? source.title)
                    .overlay(alignment: .trailing) {
                        Menu {
                            menu()
                        } label: {
                            SidebarMiniButtonLabel(icon: .more, size: 22, iconSize: 12)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .opacity(hovered ? 1 : 0)
                        .accessibilityLabel("Options for \(source.title)")
                    }
            }
        }
        .padding(.horizontal, SidebarStyle.rowPadding)
        .frame(height: Metrics.sidebarRowHeight)
        .contentShape(Rectangle())
        .modifier(SidebarRowBackground(active: active, hovered: hovered && !isEditing))
        .onHover { hovered = $0 }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A folder (or Pinned / Hidden group) header: 26pt, 13pt muted text (Claude's "Recents"); title opens the folder feed,
/// "..." on hover, chevron toggles.
private struct SidebarFolderHeader<MenuContent: View>: View {
    let title: String
    let open: Bool
    let active: Bool
    /// A muted folder: the title goes quiet.
    var isMuted = false
    let hasMenu: Bool
    let isEditing: Bool
    let onTitle: () -> Void
    let onToggle: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            if isEditing {
                SidebarNameField(initial: title, placeholder: "Folder name", onCommit: onRename, onCancel: onCancelRename)
            } else {
                // A tap gesture, not a Button, so the header's .onDrag can start (see SidebarSourceRow).
                Text(title)
                    .modifier(SidebarTitleFade(clearsButton: hovered && hasMenu, buttonWidth: 20))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTitle)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onTitle() }
                    .help(hasMenu ? "Show everything in \(title)" : "")
                    .overlay(alignment: .trailing) {
                        if hasMenu {
                            Menu {
                                menu()
                            } label: {
                                SidebarMiniButtonLabel(icon: .more, size: 20, iconSize: 11)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .opacity(hovered ? 1 : 0)
                            .accessibilityLabel("Options for \(title)")
                        }
                    }
                Button(action: onToggle) {
                    SidebarMiniButtonLabel(icon: .chevron, size: 20, iconSize: 10, rotation: .degrees(open ? 90 : 0))
                        .animation(.easeOut(duration: 0.15), value: open)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Collapse \(title)" : "Expand \(title)")
            }
        }
        .font(SidebarStyle.sectionFont)
        .tracking(SidebarStyle.sectionTracking)
        .foregroundStyle(active || hovered ? Color.ofInk : isMuted ? Color.ofRead : Color.ofMuted)
        .padding(.leading, SidebarStyle.rowPadding)
        .padding(.trailing, 4)
        .frame(height: SidebarStyle.headerHeight)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(active ? Color.ofNavSelection : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

#Preview {
    let model = AppModel.preview()
    return SidebarView()
        .environment(model)
        .environment(HighlightStore(model: model))
        .frame(width: Metrics.sidebarWidth, height: 700)
}

#if os(macOS)
/// Window-behind blur under the sidebar (the Claude desktop app's translucent sidebar).
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#endif
