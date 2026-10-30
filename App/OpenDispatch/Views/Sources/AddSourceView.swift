import OpenDispatchCore
import SwiftUI

/// "Add sources" sheet: search by name, or paste one or more links.
///
/// A name searches feeds (sites, newsletters, YouTube channels) and podcasts as you type; a link shows
/// one row for it above the results; several links (one per line, or separated by spaces or commas)
/// show one row each with Add All. Adding doesn't close the sheet or wait for the feed: the row shows
/// progress and the source appears in the sidebar once it is detected (`AppModel.beginAddSource`).
/// With nothing typed, the sheet explains what works and offers OPML import. "Add to" under the field picks the
/// folder new sources go into (Unfiled by default; a folder's "Add Source to <Folder>…" preselects it through
/// `AppModel.pendingAddSourceFolderID`), and its New Folder… makes one and picks it. Picking a folder also moves
/// what this sheet already added to Unfiled.
struct AddSourceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [SourceSearchResult] = []
    @State private var searching = false
    @State private var searchError = false
    @State private var importing = false
    @State private var importStatus: SettingsOPMLStatus?
    /// The folder new sources go into; nil is Unfiled.
    @State private var folderID: Int64?
    /// The folder each add from this sheet went into (by URL), so the footer can say where they went.
    @State private var addedTo: [String: Int64?] = [:]
    @State private var namingFolder = false
    @State private var newFolderName = ""
    @State private var folderError: String?
    /// Height of the list or intro, which sizes the sheet on macOS.
    @State private var contentHeight: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    /// Links in the field (empty when it holds a name).
    private var links: [String] { SourceSearch.links(in: query) }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var targetFolder: Folder? { folderID.flatMap { id in model.folders.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            field
                .padding(.top, 12)
            destination
                .padding(.top, 10)
            ScrollView {
                content
                    .padding(.vertical, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.automatic)
            #if os(macOS)
            // The sheet fits what it shows (the short intro, or the results up to a cap).
            .frame(height: min(contentHeight, Self.maxContentHeight))
            #endif
            .padding(.top, 4)
            footer
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 460)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .background(Color.ofSurface)
        .onAppear {
            if let pending = model.pendingAddSourceURL {
                query = pending
                model.pendingAddSourceURL = nil
            }
            folderID = model.pendingAddSourceFolderID
            model.pendingAddSourceFolderID = nil
            fieldFocused = true
        }
        .onDisappear { model.clearFinishedSourceAdds() }
        .onChange(of: folderID) { _, folder in
            if let folder { moveUnfiledAdds(to: folder) }
        }
        .task(id: trimmed) { await search() }
        .alert("New Folder", isPresented: $namingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create", action: createFolder)
        } message: {
            Text("Enter a name for the folder.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.openDispatchOPML, .xml]) { result in
            switch result {
            case .success(let url): Task { await importFile(url) }
            case .failure(let error): importStatus = .init(text: "Import failed: \(HTTP.message(error))", error: true)
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack {
            Text("Add sources")
                .font(OFFont.ui(17, .semibold))
                .tracking(-0.17)
                .foregroundStyle(.ofInk)
            Spacer()
            Button {
                dismiss()
            } label: {
                OFIcon.close.image
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.ofMuted)
                    .frame(width: closeSize, height: closeSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            OFIcon.search.image
                .font(.system(size: 14))
                .foregroundStyle(.ofFaint)
            TextField("Search by name, or paste links", text: $query)
                .textFieldStyle(.plain)
                .font(OFFont.ui(15))
                .foregroundStyle(.ofBody)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .focused($fieldFocused)
                .onSubmit(submit)
                .accessibilityLabel("Search by name, or paste links")
            if searching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofGround))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(fieldFocused ? Color.ofAccent : Color.ofBorder, lineWidth: 1)
        )
    }

    /// "Add to" and a menu of Unfiled, the folders and New Folder…
    private var destination: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Add to")
                    .font(OFFont.ui(destinationSize))
                    .foregroundStyle(.ofMuted)
                Menu {
                    Picker("Add to", selection: $folderID) {
                        Text("Unfiled").tag(Int64?.none)
                        ForEach(model.orderedFolders) { folder in
                            Text(folder.title).tag(Int64?.some(folder.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Button("New Folder\u{2026}") {
                        newFolderName = ""
                        namingFolder = true
                    }
                } label: {
                    #if os(macOS)
                    Text(targetFolder?.title ?? "Unfiled")
                    #else
                    HStack(spacing: 4) {
                        Text(targetFolder?.title ?? "Unfiled")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(OFFont.ui(destinationSize, .medium))
                    .foregroundStyle(.ofAccent)
                    #endif
                }
                #if os(macOS)
                .fixedSize()
                #endif
                .accessibilityLabel("Add to \(targetFolder?.title ?? "Unfiled")")
            }
            if let folderError {
                Text(folderError)
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    private var destinationSize: CGFloat {
        #if os(iOS)
        15
        #else
        13
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if trimmed.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if links.count > 1 {
                    HStack {
                        sectionLabel("\(links.count) links")
                        Spacer()
                        Button("Add All") { links.forEach(add) }
                            .buttonStyle(.plain)
                            .font(OFFont.ui(13, .medium))
                            .foregroundStyle(.ofAccent)
                    }
                    .padding(.horizontal, 8)
                }
                ForEach(links, id: \.self) { link in
                    AddSourceRow(title: Self.shortLink(link), subtitle: "Link", host: URLHost.host(of: link),
                                 imageUrl: nil, url: link, inLibrary: false, add: add)
                }
                if links.count <= 1 {
                    if !links.isEmpty, !results.isEmpty {
                        sectionLabel("Search results").padding(.horizontal, 8).padding(.top, 8)
                    }
                    ForEach(results) { r in
                        AddSourceRow(title: r.title, subtitle: r.kind == .podcast ? "Podcast · \(r.subtitle)" : r.subtitle,
                                     host: URLHost.host(of: r.siteUrl ?? r.feedUrl), imageUrl: r.imageUrl, url: r.feedUrl,
                                     inLibrary: model.hasSource(feedUrl: r.feedUrl), add: add)
                    }
                    if results.isEmpty, links.isEmpty, !searching {
                        note(searchError
                             ? "Search isn't available right now. Paste the site's link instead."
                             : "No matches for \u{201C}\(trimmed)\u{201D}. Paste the site's link instead.")
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find sites, newsletters, YouTube channels and podcasts by name, or paste a link. Paste several at once to add them together.")
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text("No feed? A news or blog listing page is checked for new posts.")
                .font(OFFont.ui(12))
                .foregroundStyle(.ofFaint)
                .fixedSize(horizontal: false, vertical: true)
            Button("Import from another reader (OPML)…") { importing = true }
                .buttonStyle(.plain)
                .font(OFFont.ui(13, .medium))
                .foregroundStyle(.ofAccent)
                .padding(.top, 4)
            if let importStatus {
                Text(importStatus.text)
                    .font(OFFont.ui(12))
                    .foregroundStyle(importStatus.error ? Color.ofDanger : Color.ofMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var footer: some View {
        let adding = model.sourceAdds.values.filter { $0 == .adding }.count
        let added = model.sourceAdds.values.filter { $0 == .added }.count
        return HStack(spacing: 8) {
            Text(Self.progress(adding: adding, added: added, folder: addsFolder))
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
                .monospacedDigit()
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(OFFont.ui(14, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofAccent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Color.ofHairline).frame(height: 1) }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(OFFont.ui(11, .semibold))
            .tracking(0.6)
            .foregroundStyle(.ofMuted)
            .padding(.vertical, 6)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(OFFont.ui(13))
            .foregroundStyle(.ofMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
    }

    private var closeSize: CGFloat {
        #if os(iOS)
        Metrics.touchTarget
        #else
        Metrics.desktopIconButton
        #endif
    }

    // MARK: Actions

    /// The folder every add in progress or done went into, when they all went into the same one (nil when
    /// they went to Unfiled, to different folders, or some started outside this sheet).
    private var addsFolder: String? {
        let urls = model.sourceAdds.filter { $0.value == .adding || $0.value == .added }.map(\.key)
        guard !urls.isEmpty, urls.allSatisfy({ addedTo[$0] != nil }) else { return nil }
        let ids = Set(urls.map { addedTo[$0]! })
        guard ids.count == 1, let id = ids.first!, let folder = model.folders.first(where: { $0.id == id }) else { return nil }
        return folder.title
    }

    /// Starts adding `url` to the chosen folder.
    private func add(_ url: String) {
        addedTo[url] = folderID
        model.beginAddSource(url: url, folderID: folderID)
    }

    /// Unfiled is where the menu starts, not a choice, and Return adds before the menu under the field has been
    /// looked at, so the first folder picked takes what went to Unfiled. What went to a folder stays there.
    private func moveUnfiledAdds(to folder: Int64) {
        for (url, target) in addedTo where target == nil {
            addedTo[url] = folder
            Task { await model.moveSourceAdd(url: url, toFolder: folder) }
        }
    }

    /// Return adds what was pasted; a name just searches (results update as you type).
    private func submit() {
        links.forEach(add)
    }

    /// Makes the folder named in the New Folder prompt and picks it.
    private func createFolder() {
        let title = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task {
            do {
                folderID = try await model.createFolder(title: title).id
                folderError = nil
            } catch {
                folderError = "Couldn't create the folder: \(HTTP.message(error))"
            }
        }
    }

    /// Debounced search for a name (or a single link, which may also be a name like "node.js").
    private func search() async {
        let q = trimmed
        guard q.count >= 2, links.count <= 1 else {
            results = []
            searching = false
            searchError = false
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        searching = true
        defer { if !Task.isCancelled { searching = false } }
        do {
            let found = try await model.searchSources(q)
            guard !Task.isCancelled else { return }
            results = found
            searchError = false
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchError = true
        }
    }

    private func importFile(_ url: URL) async {
        importStatus = .init(text: "Importing…", error: false)
        do {
            let r = try await model.importOPML(from: url)
            importStatus = .init(text: SettingsOPMLButtons.summary(r), error: r.added == 0 && !r.errors.isEmpty)
            if r.added > 0 { Task { await model.refresh(force: true) } }
        } catch {
            importStatus = .init(text: "Import failed: \(HTTP.message(error))", error: true)
        }
    }

    // MARK: Formatting

    /// Tallest the results get on macOS before they scroll.
    static let maxContentHeight: CGFloat = 400

    /// "Added 2", "Adding 1…", "Added 1, adding 1…", with " to <Folder>" before any ellipsis when `folder` is given.
    static func progress(adding: Int, added: Int, folder: String? = nil) -> String {
        let to = folder.map { " to \($0)" } ?? ""
        return switch (adding, added) {
        case (0, 0): ""
        case (0, _): "Added \(added)\(to)"
        case (_, 0): "Adding \(adding)\(to)…"
        default: "Added \(added), adding \(adding)\(to)…"
        }
    }

    /// A link without its scheme or a bare trailing slash, for the row's second line.
    static func shortLink(_ url: String) -> String {
        var s = url
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// One result or pasted link: icon, title, subtitle, and an add button that shows the add's progress.
private struct AddSourceRow: View {
    let title: String
    let subtitle: String
    let host: String
    let imageUrl: String?
    /// What gets added: a feed URL from search, or the pasted link.
    let url: String
    let inLibrary: Bool
    /// Starts adding a URL to the sheet's chosen folder.
    let add: (String) -> Void

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var state: SourceAddState? { model.sourceAdds[url] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(OFFont.ui(14, .medium))
                        .foregroundStyle(.ofInk)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(OFFont.ui(12))
                        .foregroundStyle(.ofMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                button
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(hovering ? Color.ofHover : .clear))
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        if let imageUrl, let u = URL(string: imageUrl) {
            CachedAsyncImage(url: u, maxPixelSize: 56) { image in
                image.resizable().scaledToFill()
            } placeholder: { _ in
                Color.ofCode
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            SourceBadge(host: host, title: title, size: 28)
        }
    }

    @ViewBuilder
    private var button: some View {
        let done = inLibrary || state == .added
        Button {
            add(url)
        } label: {
            ZStack {
                if state == .adding {
                    ProgressView().controlSize(.small)
                } else {
                    (done ? OFIcon.check : OFIcon.plus).image
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(done ? Color.white : Color.ofInk)
                }
            }
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(done ? Color.ofAccent : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(done ? Color.ofAccent : Color.ofBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done || state == .adding)
        .accessibilityLabel(done ? "\(title), added" : state == .adding ? "Adding \(title)" : "Add \(title)")
    }
}

#Preview {
    AddSourceView().environment(AppModel.preview())
}
