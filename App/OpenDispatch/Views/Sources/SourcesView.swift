import OpenDispatchCore
import SwiftUI

/// Phone Sources tab. Port of src/components/sources-page.tsx (ordering from source-tree.ts via
/// AppModel.orderedFolders / sources(inFolder:)).
///
/// Folders are sections; the folder header opens everything in that folder, a source row opens that
/// source's feed (pushed, with back to Sources). Unfiled shows only when it has sources. Beyond the web
/// page, rows swipe to delete and long-press for Move to / Rename / Open site / Delete, folder headers
/// long-press for Rename / Delete, and the toolbar "+" menu adds a source or a folder.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    /// The feed pushed from this page.
    private enum Route: Hashable {
        case source(Int64)
        case folder(Int64)
    }

    /// Name prompt in use (rename or create).
    private enum NamePrompt: Identifiable {
        case newFolder(withSource: Int64?)
        case renameFolder(Folder)
        case renameSource(Source)

        var id: String {
            switch self {
            case .newFolder(let s): "new-\(s.map(String.init) ?? "")"
            case .renameFolder(let f): "folder-\(f.id)"
            case .renameSource(let s): "source-\(s.id)"
            }
        }

        var title: String {
            switch self {
            case .newFolder(let s): s == nil ? "New folder" : "New folder with this"
            case .renameFolder: "Rename folder"
            case .renameSource: "Rename source"
            }
        }

        var initial: String {
            switch self {
            case .newFolder: ""
            case .renameFolder(let f): f.title
            case .renameSource(let s): s.title
            }
        }
    }

    @State private var route: Route?
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var pendingDelete: Source?
    @State private var pendingFolderDelete: Folder?
    @State private var errorMessage: String?

    var body: some View {
        dialogs(navigation(content))
    }

    /// The list alone under the system navigation bar (no title text); "+" sits in the toolbar.
    private var content: some View {
        list
            .background(Color.ofSurface)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) { addMenu }
            }
    }

    private func navigation(_ view: some View) -> some View {
        view
            .navigationDestination(item: $route) { _ in
                ItemListView()
            }
            // System back pops the route: leave the source/folder feed like the web's "Back to sources".
            .onChange(of: route) { _, value in
                if value == nil, model.isInSourceFeed { model.goHome() }
            }
            // If the feed screen navigates away from the source/folder itself, pop back here.
            .onChange(of: model.isInSourceFeed) { _, inFeed in
                if !inFeed, route != nil { route = nil }
            }
    }

    private func dialogs(_ view: some View) -> some View {
        deleteDialogs(view)
            .alert(prompt?.title ?? "", isPresented: isPrompting, presenting: prompt) { p in
                TextField("Name", text: $promptText)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                Button("Cancel", role: .cancel) {}
                Button(p.initial.isEmpty ? "Create" : "Save") { commit(p) }
            }
            .alert("Something went wrong", isPresented: hasError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func deleteDialogs(_ view: some View) -> some View {
        view
            .confirmationDialog(
                pendingDelete.map { "Delete \($0.title)?" } ?? "Delete source?",
                isPresented: isConfirmingSourceDelete,
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { source in
                Button("Delete", role: .destructive) {
                    perform { try await model.deleteSource(id: source.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Removing a source also removes its items.")
            }
            .confirmationDialog(
                pendingFolderDelete.map { "Delete \($0.title)?" } ?? "Delete folder?",
                isPresented: isConfirmingFolderDelete,
                titleVisibility: .visible,
                presenting: pendingFolderDelete
            ) { folder in
                Button("Delete folder", role: .destructive) {
                    perform { try await model.deleteFolder(id: folder.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its sources move to Unfiled.")
            }
    }

    private var isPrompting: Binding<Bool> {
        Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    }

    private var hasError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var isConfirmingSourceDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var isConfirmingFolderDelete: Binding<Bool> {
        Binding(get: { pendingFolderDelete != nil }, set: { if !$0 { pendingFolderDelete = nil } })
    }

    // MARK: Toolbar

    private var addMenu: some View {
        Menu {
            Button {
                model.isAddSourcePresented = true
            } label: {
                Label("Add source", systemImage: OFIcon.plus.rawValue)
            }
            Button {
                open(.newFolder(withSource: nil))
            } label: {
                Label("New folder", systemImage: OFIcon.folder.rawValue)
            }
        } label: {
            Label("Add", systemImage: OFIcon.plus.rawValue)
        }
        .tint(Color.primary)
        .accessibilityLabel("Add")
    }

    // MARK: List

    private var list: some View {
        List {
            ForEach(model.orderedFolders) { folder in
                let sources = model.allSources(inFolder: folder.id)
                Section {
                    if sources.isEmpty {
                        Text("No sources")
                            .font(OFFont.ui(13))
                            .foregroundStyle(.ofFaint)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                            .sourcesRowChrome()
                    } else {
                        ForEach(sources) { sourceRow($0) }
                    }
                } header: {
                    folderHeader(folder, count: sources.count)
                }
            }
            let unfiled = model.allSources(inFolder: nil)
            if !unfiled.isEmpty {
                Section {
                    ForEach(unfiled) { sourceRow($0) }
                } header: {
                    Text("Unfiled")
                        .font(OFFont.ui(13, .semibold))
                        .tracking(0.13)
                        .foregroundStyle(.ofMuted)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: Metrics.touchTarget, alignment: .leading)
                        .sourcesHeaderChrome()
                }
            }
            Section {
                addSourceRow
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .refreshable { await model.refresh(force: true) }
    }

    private func folderHeader(_ folder: Folder, count: Int) -> some View {
        Button {
            openFeed(.folder(folder.id))
        } label: {
            HStack(spacing: 12) {
                Text(folder.title)
                    .font(OFFont.ui(13, .semibold))
                    .tracking(0.13)
                    .foregroundStyle(.ofMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(OFFont.ui(13, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.ofFaint)
                OFIcon.chevron.image
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.ofFaint)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Metrics.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(SourcesRowButtonStyle())
        .accessibilityLabel("Show everything in \(folder.title)")
        .contextMenu {
            Button {
                open(.renameFolder(folder))
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingFolderDelete = folder
            } label: {
                Label(count == 0 ? "Delete folder" : "Delete folder (keep sources)", systemImage: "trash")
            }
        }
        .sourcesHeaderChrome()
    }

    private func sourceRow(_ source: Source) -> some View {
        Button {
            openFeed(.source(source.id))
        } label: {
            HStack(spacing: 12) {
                SourceBadge(source: source, size: 24)
                Text(source.title)
                    .font(OFFont.ui(15))
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Metrics.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(SourcesRowButtonStyle())
        .sourcesRowChrome()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = source
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu { sourceMenu(source) }
    }

    @ViewBuilder
    private func sourceMenu(_ source: Source) -> some View {
        Menu {
            ForEach(model.orderedFolders) { folder in
                Toggle(folder.title, isOn: moveBinding(source, to: folder.id))
            }
            Toggle("Unfiled", isOn: moveBinding(source, to: nil))
            Divider()
            Button("New folder with this") { open(.newFolder(withSource: source.id)) }
        } label: {
            Label("Move to", systemImage: OFIcon.folder.rawValue)
        }
        Button {
            open(.renameSource(source))
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        if let url = URL(string: source.url), url.scheme != nil {
            Button {
                openURL(url)
            } label: {
                Label("Open site", systemImage: OFIcon.external.rawValue)
            }
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = source
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var addSourceRow: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.ofHairline).frame(height: 1).padding(.top, 12).padding(.bottom, 12)
            Button {
                model.isAddSourcePresented = true
            } label: {
                HStack(spacing: 12) {
                    OFIcon.plus.image
                        .font(.system(size: 18, weight: .regular))
                        .frame(width: 24, height: 24)
                    Text("Add source").font(OFFont.ui(15, .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.ofAccent)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: Metrics.touchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(SourcesRowButtonStyle())
        }
        .padding(.bottom, 16)
        .sourcesRowChrome()
    }

    // MARK: Actions

    private func openFeed(_ r: Route) {
        switch r {
        case .source(let id): model.navigate(sourceID: id)
        case .folder(let id): model.navigate(folderID: id)
        }
        route = r
    }

    private func moveBinding(_ source: Source, to folderId: Int64?) -> Binding<Bool> {
        Binding(
            get: { source.folderId == folderId },
            set: { checked in
                guard checked, source.folderId != folderId else { return }
                perform { try await model.moveSource(id: source.id, toFolder: folderId) }
            })
    }

    private func open(_ p: NamePrompt) {
        promptText = p.initial
        prompt = p
    }

    private func commit(_ p: NamePrompt) {
        let title = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != p.initial else { return }
        switch p {
        case .newFolder(let withSource):
            perform { try await model.createFolder(title: title, withSource: withSource) }
        case .renameFolder(let folder):
            perform { try await model.renameFolder(id: folder.id, title: title) }
        case .renameSource(let source):
            perform { try await model.renameSource(id: source.id, title: title) }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch { errorMessage = HTTP.message(error) }
        }
    }
}

/// Row press feedback: rounded hover background (rounded-lg, --hover) while pressed.
private struct SourcesRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Color.ofHover : Color.clear)
            )
    }
}

private extension View {
    /// Plain list row: no separator, surface background, 8pt side inset (px-2), no vertical inset.
    func sourcesRowChrome() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.ofSurface)
    }

    /// Section header with the same insets as rows, on the surface (headers stick while scrolling).
    func sourcesHeaderChrome() -> some View {
        self
            .padding(.top, 12)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .background(Color.ofSurface)
    }
}

#Preview {
    NavigationStack { SourcesView() }
        .environment(AppModel.preview())
}
