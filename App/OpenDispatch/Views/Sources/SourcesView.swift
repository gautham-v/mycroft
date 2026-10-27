#if os(iOS)
import OpenDispatchCore
import SwiftUI

/// iPhone "Sources" screen, pushed on a surrounding NavigationStack (from the Feed's drawer, or from
/// Settings → Manage sources). Port of src/components/sources-page.tsx (ordering from source-tree.ts via
/// AppModel.orderedFolders / sources(inFolder:)), laid out as grouped cards on the warm ground.
///
/// The screen leads with a card for adding: a field that takes a link or a name (Return opens the add
/// sheet with it), Import OPML and New folder. Then each folder is a muted label over a card of its
/// sources (badge, title, host); the label opens everything in that folder, a source row opens that
/// source's feed (pushed, with back to Sources; from the Settings sheet, the sheet closes and the Feed
/// shows it). Unfiled comes last and shows only when it has sources. Beyond the web page, rows swipe to
/// delete and long-press for Move to / Rename / Open site / Delete, and folder labels long-press for
/// Rename / Delete.
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
    /// The add field's text, and the sheet it opens. The sheet is this screen's own: Settings is itself
    /// a sheet, where the root's add sheet could not present.
    @State private var addText = ""
    @State private var isAddPresented = false
    @State private var isImportingOPML = false

    var body: some View {
        dialogs(navigation(content))
    }

    /// The list under the system navigation bar and its back button, titled "Sources".
    private var content: some View {
        list
            .background(Color.ofSurface)
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $isAddPresented) {
                AddSourceView().environment(model)
            }
            .opmlImporter(isPresented: $isImportingOPML)
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

    // MARK: List

    /// A List rather than a ScrollView of cards so rows keep swipe actions, context menus and pull to
    /// refresh. Each section's rows draw their own slice of the card (see `cardRow`).
    private var list: some View {
        List {
            Section {
                addField
                    .cardRow(.first)
                Button {
                    isImportingOPML = true
                } label: {
                    GroupedRow(title: "Import OPML") { GroupedIcon(systemName: "square.and.arrow.down") }
                }
                .buttonStyle(GroupedRowButtonStyle())
                .cardRow(.middle)
                Button {
                    open(.newFolder(withSource: nil))
                } label: {
                    GroupedRow(title: "New folder") { GroupedIcon(systemName: OFIcon.folder.rawValue) }
                }
                .buttonStyle(GroupedRowButtonStyle())
                .cardRow(.last)
            }
            ForEach(model.orderedFolders) { folder in
                let sources = model.allSources(inFolder: folder.id)
                Section {
                    if sources.isEmpty {
                        Text("No sources")
                            .font(OFFont.ui(15))
                            .foregroundStyle(.ofFaint)
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .cardRow(.only)
                    } else {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                            sourceRow(source).cardRow(.at(index, of: sources.count))
                        }
                    }
                } header: {
                    folderHeader(folder, count: sources.count)
                }
            }
            let unfiled = model.allSources(inFolder: nil)
            if !unfiled.isEmpty {
                Section {
                    ForEach(Array(unfiled.enumerated()), id: \.element.id) { index, source in
                        sourceRow(source).cardRow(.at(index, of: unfiled.count))
                    }
                } header: {
                    sectionLabel("Unfiled")
                        .listRowInsets(EdgeInsets())
                        .background(Color.ofSurface)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listSectionSeparator(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .refreshable { await model.refresh(force: true) }
    }

    /// The top card's first row: paste a link, or search by name. Return opens the add sheet with the
    /// text in its field (AddSourceView runs the detection and the search).
    private var addField: some View {
        HStack(spacing: 10) {
            OFIcon.search.image
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.ofMuted)
            TextField("Paste a link, or search by name", text: $addText)
                .font(OFFont.ui(16))
                .foregroundStyle(.ofInk)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.search)
                .onSubmit(submitAddText)
                .accessibilityLabel("Paste a link, or search by name")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.ofCardInset, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, -4)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(OFFont.ui(15, .medium))
            .foregroundStyle(.ofMuted)
            .lineLimit(1)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The folder's name as the muted label above its card; it opens everything in the folder.
    private func folderHeader(_ folder: Folder, count: Int) -> some View {
        Button {
            openFeed(.folder(folder.id))
        } label: {
            sectionLabel(folder.title)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show everything in \(folder.title)")
        .listRowInsets(EdgeInsets())
        .background(Color.ofSurface)
        .contextMenu {
            Button {
                open(.renameFolder(folder))
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            CopyDigestButtons(scope: .folder(folder), icons: true)
            Divider()
            Button(role: .destructive) {
                pendingFolderDelete = folder
            } label: {
                Label(count == 0 ? "Delete folder" : "Delete folder (keep sources)", systemImage: "trash")
            }
        }
    }

    private func sourceRow(_ source: Source) -> some View {
        Button {
            openFeed(.source(source.id))
        } label: {
            GroupedRow(title: source.title, subtitle: source.host) {
                SourceBadge(source: source, size: 30)
            }
        }
        .buttonStyle(GroupedRowButtonStyle())
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
        CopyDigestButtons(scope: .source(source), icons: true)
        Divider()
        Button(role: .destructive) {
            pendingDelete = source
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Actions

    private func openFeed(_ r: Route) {
        switch r {
        case .source(let id): model.navigate(sourceID: id)
        case .folder(let id): model.navigate(folderID: id)
        }
        // In the Settings sheet there is no stack to show the feed in: close the sheet and let the Feed
        // behind it show what was just selected.
        if model.isSettingsPresented {
            model.isSettingsPresented = false
        } else {
            route = r
        }
    }

    /// Return in the add field: open the add sheet with its text.
    private func submitAddText() {
        let text = addText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.pendingAddSourceURL = text
        addText = ""
        isAddPresented = true
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

/// Where a row sits in its card, which decides its corners and whether a hairline follows it.
private struct CardPosition {
    let isFirst: Bool
    let isLast: Bool

    static let first = CardPosition(isFirst: true, isLast: false)
    static let middle = CardPosition(isFirst: false, isLast: false)
    static let last = CardPosition(isFirst: false, isLast: true)
    static let only = CardPosition(isFirst: true, isLast: true)

    static func at(_ index: Int, of count: Int) -> CardPosition {
        CardPosition(isFirst: index == 0, isLast: index == count - 1)
    }
}

private extension View {
    /// A list row drawn as a slice of a white card: 16pt in from the screen, 20pt of content padding,
    /// 26pt corners on the card's ends, and a hairline inset 20pt between rows.
    func cardRow(_ position: CardPosition) -> some View {
        let radius = Metrics.cardRadius
        return self
            .padding(.horizontal, 20)
            .overlay(alignment: .bottom) {
                if !position.isLast {
                    Rectangle().fill(Color.ofHairline).frame(height: 1).padding(.horizontal, 20)
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(
                UnevenRoundedRectangle(
                    topLeadingRadius: position.isFirst ? radius : 0, bottomLeadingRadius: position.isLast ? radius : 0,
                    bottomTrailingRadius: position.isLast ? radius : 0, topTrailingRadius: position.isFirst ? radius : 0,
                    style: .continuous)
                    .fill(Color.ofCard)
                    .padding(.horizontal, 16)
            )
    }
}

#Preview {
    NavigationStack { SourcesView() }
        .environment(AppModel.preview())
}
#endif

