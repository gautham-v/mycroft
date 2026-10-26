import OpenfeedCore
import SwiftUI

/// Desktop (macOS, iPad) sidebar. Port of src/components/sidebar.tsx and the ordering in source-tree.ts
/// (AppModel.orderedFolders / sources(inFolder:)).
///
/// Top to bottom: logo + "Openfeed", the six views, each folder (header opens the folder feed, chevron
/// collapses it, persisted per device) with its sources, Unfiled (when it has sources, or while a source is
/// dragged), "New folder",
/// and a footer with "Add source" and Settings. Sources drag to reorder and between folders; folder
/// headers drag to reorder folders. Context menus and the hover "..." button offer the same actions.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

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

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        viewRows
                        ForEach(model.orderedFolders) { folder in
                            folderSection(folder)
                        }
                        folderSection(nil)
                        newFolderArea.id(Self.newFolderAnchor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.automatic)
                .onChange(of: editing) { _, value in
                    if case .newFolder = value {
                        withAnimation { proxy.scrollTo(Self.newFolderAnchor, anchor: .bottom) }
                    }
                }
            }
            footer
        }
        .background(Color.ofGround)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .confirmationDialog(
            pendingDelete.map { "Delete \($0.title)?" } ?? "Delete source?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { source in
            Button("Delete", role: .destructive) { deleteSource(source) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Removing a source also removes its items.")
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

    private var header: some View {
        HStack(spacing: 8) {
            FeedMarkIcon(size: 20)
            Text("Openfeed")
                .font(OFFont.serif(17, .semibold))
                .tracking(-0.17)
                .foregroundStyle(.ofInk)
                .lineLimit(1)
            Spacer(minLength: 0)
            #if os(iOS)
            SidebarIconButton(icon: .sidebar, label: "Hide sidebar", size: Metrics.desktopIconButton, iconSize: 16) {
                model.toggleSidebar()
            }
            #endif
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        #if os(iOS)
        .frame(height: Metrics.desktopHeaderHeight)
        .padding(.top, 10)
        #else
        .frame(height: 40)
        #endif
    }

    private var footer: some View {
        HStack(spacing: 4) {
            SidebarFooterRow(icon: .plus, label: "Add source") {
                model.isAddSourcePresented = true
            }
            SidebarIconButton(icon: .gear, label: "Settings") {
                #if os(macOS)
                model.settingsTab = .sources
                openSettings()
                #else
                model.showSettings(.sources)
                #endif
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: Views

    private var viewRows: some View {
        VStack(spacing: 0) {
            ForEach(FeedView.allCases) { view in
                SidebarViewRow(view: view, active: isActive(view)) {
                    model.navigate(view: view)
                }
            }
        }
        .padding(.top, 4)
    }

    private func isActive(_ view: FeedView) -> Bool {
        model.selectedView == view && model.selectedSourceID == nil && model.selectedFolderID == nil
    }

    // MARK: Folders

    @ViewBuilder
    private func folderSection(_ folder: Folder?) -> some View {
        let id = folder?.id
        let list = model.sources(inFolder: id)
        // An empty Unfiled appears while a source is dragged so it can be dropped there.
        if folder != nil || !list.isEmpty || isDraggingSource {
            let open = !model.isFolderCollapsed(id)
            VStack(alignment: .leading, spacing: 0) {
                folderHeader(folder, count: list.count, open: open)
                if open {
                    ForEach(list) { source in
                        sourceRow(source)
                    }
                    endZone(folderId: id, empty: list.isEmpty)
                }
            }
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private func folderHeader(_ folder: Folder?, count: Int, open: Bool) -> some View {
        let title = folder?.title ?? "Unfiled"
        let active = folder != nil && model.selectedFolderID == folder?.id
        let isEditing = folder.map { editing == .renameFolder($0.id) } ?? false
        let base = SidebarFolderHeader(
            title: title,
            count: count,
            open: open,
            active: active,
            hasMenu: folder != nil,
            isEditing: isEditing,
            onTitle: {
                if let folder {
                    if active { model.goHome() } else { model.navigate(folderID: folder.id) }
                } else {
                    model.toggleFolderCollapsed(nil)
                }
            },
            onToggle: { model.toggleFolderCollapsed(folder?.id) },
            onRename: { newTitle in
                editing = nil
                if let folder { renameFolder(folder.id, newTitle) }
            },
            onCancelRename: { editing = nil },
            menu: { if let folder { folderMenu(folder) } }
        )
        if let folder {
            base
                .modifier(SidebarDropIndicator(visible: over == .folder(folder.id)))
                .contextMenu { folderMenu(folder) }
                .onDrag {
                    dragging = .folder(folder.id)
                    return NSItemProvider(object: SidebarDrag.folder(folder.id).payload as NSString)
                }
                .onDrop(of: [.plainText], delegate: dropDelegate(.folder(folder.id)))
        } else {
            // Unfiled has no menu and isn't draggable; a drop on it lands at its end.
            base
                .onDrop(of: [.plainText], delegate: dropDelegate(.end(nil)))
        }
    }

    /// The strip after a folder's last source (or "Drop sources here" when empty): drops land at the end.
    @ViewBuilder
    private func endZone(folderId: Int64?, empty: Bool) -> some View {
        Group {
            if empty {
                Text("Drop sources here")
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

    private func sourceRow(_ source: Source) -> some View {
        SidebarSourceRow(
            source: source,
            active: model.selectedSourceID == source.id,
            isEditing: editing == .renameSource(source.id),
            onOpen: { model.navigate(sourceID: source.id) },
            onRename: { newTitle in
                editing = nil
                renameSource(source.id, newTitle)
            },
            onCancelRename: { editing = nil },
            menu: { sourceMenu(source) }
        )
        .modifier(SidebarDropIndicator(visible: over == .row(source.id)))
        .contextMenu { sourceMenu(source) }
        .onDrag {
            dragging = .source(source.id)
            return NSItemProvider(object: SidebarDrag.source(source.id).payload as NSString)
        }
        .onDrop(of: [.plainText], delegate: dropDelegate(.row(source.id)))
    }

    @ViewBuilder
    private var newFolderArea: some View {
        Group {
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
            } else {
                SidebarNewFolderButton { editing = .newFolder(withSource: nil) }
            }
        }
        .padding(.top, 12)
    }

    // MARK: Menus

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("Rename") { editing = .renameFolder(folder.id) }
        Button("New folder") { editing = .newFolder(withSource: nil) }
        Divider()
        Button(model.sources(inFolder: folder.id).isEmpty ? "Delete folder" : "Delete folder (keep sources)", role: .destructive) {
            deleteFolder(folder.id)
        }
    }

    @ViewBuilder
    private func sourceMenu(_ source: Source) -> some View {
        Section("Move to") {
            ForEach(model.orderedFolders) { folder in
                Toggle(folder.title, isOn: moveBinding(source, to: folder.id))
            }
            Toggle("Unfiled", isOn: moveBinding(source, to: nil))
        }
        Divider()
        Button("New folder with this") { editing = .newFolder(withSource: source.id) }
        Button("Rename") { editing = .renameSource(source.id) }
        if let url = URL(string: source.url), url.scheme != nil {
            Button("Open site") { openURL(url) }
        }
        Divider()
        Button("Delete source...", role: .destructive) { pendingDelete = source }
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
                Button(action: onOpen) {
                    Text(source.title)
                        .font(OFFont.sidebarRow)
                        .foregroundStyle(.ofInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(source.lastError.map { "Last refresh failed: \($0)" } ?? source.title)
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
        .padding(.horizontal, SidebarStyle.rowPadding)
        .frame(height: Metrics.sidebarRowHeight)
        .contentShape(Rectangle())
        .modifier(SidebarRowBackground(active: active, hovered: hovered && !isEditing))
        .onHover { hovered = $0 }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A folder (or Unfiled) header: 26pt, 11pt semibold faint text; title opens the folder feed,
/// count shows while collapsed, "..." on hover, chevron toggles.
private struct SidebarFolderHeader<MenuContent: View>: View {
    let title: String
    let count: Int
    let open: Bool
    let active: Bool
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
                Button(action: onTitle) {
                    Text(title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(hasMenu ? "Show everything in \(title)" : "")
                if !open {
                    Text("\(count)").monospacedDigit()
                }
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
        .foregroundStyle(active ? Color.ofInk : hovered ? Color.ofMuted : Color.ofFaint)
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

/// "+ New folder" at the bottom of the folder list.
private struct SidebarNewFolderButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                OFIcon.plus.image.font(.system(size: 10, weight: .semibold))
                Text("New folder")
                Spacer(minLength: 0)
            }
            .font(SidebarStyle.sectionFont)
            .tracking(SidebarStyle.sectionTracking)
            .foregroundStyle(hovered ? Color.ofMuted : Color.ofFaint)
            .padding(.horizontal, SidebarStyle.rowPadding)
            .frame(height: SidebarStyle.headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

#Preview {
    SidebarView()
        .environment(AppModel.preview())
        .frame(width: Metrics.sidebarWidth, height: 700)
}
