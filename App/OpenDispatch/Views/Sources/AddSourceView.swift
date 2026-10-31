import OpenDispatchCore
import SwiftUI

/// "Add sources" sheet: search by name, or paste one or more links.
///
/// A name searches X accounts, YouTube channels, Bluesky, Mastodon, Reddit communities, feeds (sites, newsletters) and podcasts as you
/// type, each landing on its own, in one list ordered by who was meant and who is followed (`SourceRanking`). Filters narrow it by what you'd
/// read, the kinds the sidebar lists, so another place needs no new filter. One word (or an @handle) is tried as an X handle, and any other name
/// finds X accounts only while the app is signed in to X. A link shows one row for it above the results, by name when it is an account;
/// several links (one per line, or separated by spaces or commas) show one row each with Add All. Adding doesn't close the sheet or wait
/// for the feed: the row shows progress and the source appears in the sidebar once it is detected (`AppModel.beginAddSource`).
/// With nothing typed, the sheet suggests starter sources (`StarterSources`) and offers OPML import. "Add to" in the footer picks the
/// folder new sources go into (No Folder by default; a folder's "Add Source to <Folder>…" preselects it through
/// `AppModel.pendingAddSourceFolderID`), and its New Folder… makes one and picks it. Picking a folder also moves
/// what this sheet already added to No Folder.
///
/// On the Mac it is two panes: a full-height column of categories that becomes the filters while a name is typed, and the field and list
/// beside it. On iPhone and iPad it is one column, with the filters and categories as rows of chips. Text is three styles (`SheetFont`).
struct AddSourceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [SourceSearchResult] = []
    @State private var channels: [SourceSearchResult] = []
    @State private var xAccounts: [SourceSearchResult] = []
    @State private var xProfile: SourceSearchResult?
    @State private var xNamed: [SourceSearchResult] = []
    @State private var bluesky: [SourceSearchResult] = []
    @State private var mastodon: [SourceSearchResult] = []
    @State private var reddit: [SourceSearchResult] = []
    /// Channels whose videos only play on YouTube, by feed URL.
    @State private var youtubeOnly: Set<String> = []
    /// What a name found, in order. Waits for the searches to answer (or `settleDelay`), so the list doesn't reorder as each lands, and
    /// after that only what's below the first rows changes.
    @State private var rows: [SourceSearchResult] = []
    @State private var settled = false
    /// The name `rows` are for.
    @State private var rankedQuery = ""
    /// How many searches for the current name haven't answered.
    @State private var unanswered = 0
    /// What each name found while the sheet is open, so going back to one (a deleted letter) is instant.
    @State private var answered: [String: [SourceSearchResult]] = [:]
    /// Past the first results.
    @State private var showsAll = false
    /// The starter pack the empty sheet shows, by name; nil is the first with anything left to add.
    @State private var suggestionPack: String?
    /// Who a pasted account link is, and the link.
    @State private var resolved: (link: String, account: SourceSearchResult)?
    @State private var filter = SourceFilter.all
    /// The sign-in sheet, from here because the app's own can't open over this one.
    @State private var signingIn: SignInTarget?
    @State private var searching = false
    @State private var searchError = false
    @State private var importing = false
    @State private var importStatus: SettingsOPMLStatus?
    /// The folder new sources go into; nil is No Folder.
    @State private var folderID: Int64?
    /// The folder each add from this sheet went into (by URL), so the footer can say where they went.
    @State private var addedTo: [String: Int64?] = [:]
    @State private var namingFolder = false
    @State private var newFolderName = ""
    @State private var folderError: String?
    #if os(macOS)
    /// Fixed when the sheet opens, so it doesn't jump as results land.
    @State private var sheetHeight = AddSourceView.fittingHeight
    #endif
    @FocusState private var fieldFocused: Bool

    /// Links in the field (empty when it holds a name).
    private var links: [String] { SourceSearch.links(in: query) }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var targetFolder: Folder? { folderID.flatMap { id in model.folders.first { $0.id == id } } }
    private var resolvedAccount: SourceSearchResult? {
        guard let resolved, links == [resolved.link] else { return nil }
        return resolved.account
    }
    private var signedInToX: Bool { model.accounts.isSignedIn(.x) }
    /// A name X can't be asked for without a sign-in: anything that couldn't be a handle.
    private var needsXSignIn: Bool { !signedInToX && links.isEmpty && trimmed.count >= 2 && SourceSearch.xHandle(in: trimmed) == nil }

    var body: some View {
        layout
        .background(Color.ofSurface)
        .onAppear {
            if let pending = model.pendingAddSourceURL {
                query = pending
                model.pendingAddSourceURL = nil
            }
            folderID = model.pendingAddSourceFolderID
            model.pendingAddSourceFolderID = nil
            fieldFocused = true
            #if canImport(WebKit)
            DiscussionWeb.shared.warmForSearch()
            #endif
        }
        .onDisappear { model.clearFinishedSourceAdds() }
        .onChange(of: folderID) { _, folder in
            if let folder { moveUnfiledAdds(to: folder) }
        }
        .onChange(of: trimmed) { showsAll = false }
        .onChange(of: filter) { showsAll = false }
        .task(id: "\(trimmed)|\(signedInToX)") { await search() }
        .task { await model.loadSourceSuggestions() }
        .sheet(item: $signingIn, onDismiss: { Task { await model.didCloseSignIn() } }) { target in
            WebSignInView(target: target, onDone: {})
        }
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

    // MARK: Layout

    #if os(macOS)
    /// The column, then the field, the list and the footer beside it.
    private var layout: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    field
                    closeButton
                }
                .padding(.leading, 20)
                .padding(.trailing, 12)
                .padding(.top, 14)
                .padding(.bottom, 12)
                ScrollView {
                    content
                        .padding(.horizontal, 20)
                        .padding(.bottom, 22)
                }
                .id(listIdentity)
                .scrollIndicators(.automatic)
                .mask(fadingOut)
                folderErrorText
                    .padding(.horizontal, 20)
                footer
            }
        }
        .frame(width: Self.sheetWidth, height: sheetHeight)
    }

    /// The title, then what narrows the list: the categories, or the filters while a name is typed.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add sources")
                .font(SheetFont.title)
                .foregroundStyle(.ofInk)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if links.isEmpty, !trimmed.isEmpty {
                        filterRows
                    } else {
                        categoryRows
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 22)
            }
            .scrollIndicators(.automatic)
            .mask(fadingOut)
            VStack(alignment: .leading, spacing: 6) {
                importButton("Import OPML\u{2026}")
                importStatusText
            }
            .padding(.horizontal, 19)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(width: Self.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.ofGround)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.ofHairline).frame(width: 1) }
    }

    /// The list starts at its top again when the category changes.
    private var listIdentity: String {
        trimmed.isEmpty ? shownPack(in: suggestionPacks)?.name ?? "" : "results"
    }

    /// A scroller's last rows fade out, which says there is more where a hard edge wouldn't.
    private var fadingOut: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 26)
        }
    }

    /// For You, the subjects, then the formats. Picking one clears any link in the field, since the list then shows the category.
    @ViewBuilder
    private var categoryRows: some View {
        let packs = suggestionPacks
        let shown = trimmed.isEmpty ? shownPack(in: packs) : nil
        ForEach(packs.filter { $0.name == Self.forYouPack }) { categoryRow($0, selected: $0 == shown) }
        sectionLabel("Subjects")
            .padding(.horizontal, 9)
            .padding(.top, 6)
        ForEach(packs.filter { $0.name != Self.forYouPack && !StarterSources.formats.contains($0.name) }) { categoryRow($0, selected: $0 == shown) }
        sectionLabel("By format")
            .padding(.horizontal, 9)
            .padding(.top, 6)
        ForEach(packs.filter { StarterSources.formats.contains($0.name) }) { pack in
            categoryRow(pack, selected: pack == shown)
        }
    }

    private func categoryRow(_ pack: StarterPack, selected: Bool) -> some View {
        AddSourceNavRow(title: pack.name, selected: selected, fills: true, action: {
            suggestionPack = pack.name
            query = ""
        }, icon: { formatIcon(pack.name) })
    }

    /// A format's mark in the column, so the places read as places. A subject has none.
    @ViewBuilder
    private func formatIcon(_ name: String) -> some View {
        if let place = [SourcePlace.x, .youtube, .bluesky, .reddit].first(where: { $0.name == name }) {
            SourceBadge(host: place.host ?? "", title: place.name, size: 16)
        } else if let symbol = ["Podcasts": "mic", "Newsletters": "envelope"][name] {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.ofMuted)
                .frame(width: 16, height: 16)
        }
    }

    /// All, Posts, Video, Articles and Podcasts, each with its count.
    private var filterRows: some View {
        ForEach(SourceFilter.allCases) { kind in
            AddSourceNavRow(title: kind.title, selected: filter == kind, count: filterCount(kind), fills: true, action: { filter = kind }, icon: { EmptyView() })
        }
    }

    /// As tall as it can be up to the usual, in a window that may be shorter than that.
    private static var fittingHeight: CGFloat {
        guard let window = NSApp.mainWindow else { return tallest }
        return max(shortest, min(tallest, window.contentLayoutRect.height - 24))
    }
    #else
    private var layout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add sources")
                    .font(SheetFont.title)
                    .foregroundStyle(.ofInk)
                Spacer()
                closeButton
            }
            field
                .padding(.top, 12)
            if links.isEmpty, !trimmed.isEmpty {
                filterChips
                    .padding(.top, 10)
            }
            ScrollView {
                content
                    .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
            .padding(.top, 4)
            folderErrorText
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// All, Posts, Video, Articles and Podcasts, each with its count.
    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(SourceFilter.allCases) { kind in
                    AddSourceNavRow(title: kind.title, selected: filter == kind, count: filterCount(kind), fills: false, action: { filter = kind }, icon: { EmptyView() })
                }
            }
        }
        .scrollIndicators(.hidden)
    }
    #endif

    // MARK: Parts

    private var closeButton: some View {
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

    @ViewBuilder
    private var folderErrorText: some View {
        if let folderError {
            Text(folderError)
                .font(SheetFont.meta)
                .foregroundStyle(.ofDanger)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
        }
    }

    private func importButton(_ title: String) -> some View {
        Button(title) { importing = true }
            .buttonStyle(.plain)
            .font(SheetFont.meta)
            .foregroundStyle(.ofMuted)
    }

    @ViewBuilder
    private var importStatusText: some View {
        if let importStatus {
            Text(importStatus.text)
                .font(SheetFont.meta)
                .foregroundStyle(importStatus.error ? Color.ofDanger : Color.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// How many of a name's results a filter shows, once there are any to count.
    private func filterCount(_ kind: SourceFilter) -> Int? {
        settled || !rows.isEmpty ? kind.results(in: rows).count : nil
    }

    private var field: some View {
        HStack(spacing: 8) {
            OFIcon.search.image
                .font(.system(size: 14))
                .foregroundStyle(.ofFaint)
            TextField("Search by name or @handle, or paste links", text: $query)
                .textFieldStyle(.plain)
                .font(SheetFont.primary)
                .foregroundStyle(.ofInk)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .focused($fieldFocused)
                .onSubmit(submit)
                .accessibilityLabel("Search by name or @handle, or paste links")
            if searching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: fieldHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofGround))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(fieldFocused ? Color.ofAccent : Color.ofBorder, lineWidth: 1)
        )
    }

    /// "Add to" and a menu of No Folder, the folders and New Folder…
    private var destination: some View {
        HStack(spacing: 6) {
            Text("Add to")
                .font(SheetFont.meta)
                .foregroundStyle(.ofMuted)
            Menu {
                Picker("Add to", selection: $folderID) {
                    Text("No Folder").tag(Int64?.none)
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
                Text(targetFolder?.title ?? "No Folder")
                    .font(SheetFont.meta)
                    .foregroundStyle(.ofInk)
                #else
                HStack(spacing: 4) {
                    Text(targetFolder?.title ?? "No Folder")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(SheetFont.meta)
                .foregroundStyle(.ofInk)
                #endif
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .fixedSize()
            #endif
            .accessibilityLabel("Add to \(targetFolder?.title ?? "No Folder")")
        }
    }

    @ViewBuilder
    private var content: some View {
        if trimmed.isEmpty {
            emptyState
        } else if links.isEmpty {
            nameResults
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if links.count > 1 {
                    HStack {
                        sectionLabel("\(links.count) links")
                        Spacer()
                        Button("Add All") { links.forEach(add) }
                            .buttonStyle(.plain)
                            .font(SheetFont.metaMedium)
                            .foregroundStyle(.ofInk)
                    }
                    .padding(.horizontal, 8)
                }
                if let resolvedAccount {
                    row(resolvedAccount)
                } else {
                    ForEach(links, id: \.self) { link in
                        AddSourceRow(title: Self.shortLink(link), subtitle: "Link", host: URLHost.host(of: link),
                                     imageUrl: nil, url: link, inLibrary: false, note: FeedDetection.noFeedPlace(link).map(Self.noFeedNote), add: add)
                    }
                }
                if links.count == 1, resolvedAccount == nil, !results.isEmpty {
                    sectionLabel("Search results").padding(.horizontal, 8).padding(.top, 8)
                    ForEach(results) { row($0) }
                }
            }
        }
    }

    /// What a name found, of the chosen kind.
    @ViewBuilder
    private var nameResults: some View {
        if rows.isEmpty, !settled {
            ExploreSkeleton(style: .rows)
                .padding(8)
        } else {
            let shown = filter.results(in: rows)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(showsAll ? shown : Array(shown.prefix(Self.firstResults))) { row($0) }
                if !showsAll, shown.count > Self.firstResults + 1 {
                    Button("Show \(shown.count - Self.firstResults) more") { showsAll = true }
                        .buttonStyle(.plain)
                        .font(SheetFont.metaMedium)
                        .foregroundStyle(.ofInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                if needsXSignIn, filter == .all || filter == .posts {
                    xSignInHint
                }
                if shown.isEmpty, !searching, !(needsXSignIn && filter == .posts) {
                    note(emptyNote)
                }
            }
            // The last name's results stay until this one's are ready, faded, rather than the list going blank between searches.
            .opacity(settled ? 1 : 0.5)
        }
    }

    private func row(_ result: SourceSearchResult) -> some View {
        AddSourceRow(title: result.title, subtitle: Self.subtitle(result, playsOnlyOnYouTube: youtubeOnly.contains(result.feedUrl)),
                     host: URLHost.host(of: result.siteUrl ?? result.feedUrl), imageUrl: result.imageUrl, url: result.feedUrl,
                     inLibrary: model.hasSource(feedUrl: result.feedUrl), roundIcon: result.handle != nil,
                     placeHost: result.imageUrl == nil ? nil : result.place.host,
                     note: result.canFollow ? nil : Self.noFeedNote(result.place.name), add: add)
    }

    private var xSignInHint: some View {
        HStack(spacing: 10) {
            Text("Sign in to X to find accounts by name, or type the @handle.")
                .font(SheetFont.meta)
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Sign In") { signingIn = .account(.x) }
                .buttonStyle(.plain)
                .font(SheetFont.metaMedium)
                .foregroundStyle(.ofInk)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var emptyNote: String {
        switch filter {
        case .all:
            searchError
                ? "Search isn't available right now. Paste the site's link instead."
                : "No matches for \u{201C}\(trimmed)\u{201D}. Paste the site's link instead."
        case .posts: "No accounts or communities for \u{201C}\(trimmed)\u{201D}."
        case .video: "No YouTube channels for \u{201C}\(trimmed)\u{201D}."
        case .articles: "No sites for \u{201C}\(trimmed)\u{201D}."
        case .podcasts: "No podcasts for \u{201C}\(trimmed)\u{201D}."
        }
    }

    /// Starter packs of free sources, leaving out what's in the library and any site this device has learned is walled, and what can be
    /// added at all. Search still finds walled sites; this is only for suggesting them. For You comes first when History points anywhere,
    /// and is what the sheet opens on. Its rows are `forYouRows`.
    private var suggestionPacks: [StarterPack] {
        let catalog = StarterSources.packs.compactMap { pack -> StarterPack? in
            let left = pack.sources.filter { source in
                guard !model.isWalled(source) else { return false }
                return !model.hasSource(feedUrl: source.feedUrl) || model.sourceAdds[source.feedUrl] != nil
            }
            return left.isEmpty ? nil : StarterPack(name: pack.name, sources: left)
        }
        return model.shownSuggestions.isEmpty ? catalog : [StarterPack(name: Self.forYouPack, sources: [])] + catalog
    }

    private func shownPack(in packs: [StarterPack]) -> StarterPack? {
        packs.first { $0.name == suggestionPack } ?? packs.first
    }

    #if os(macOS)
    /// The chosen category's sources; the column beside them does the choosing.
    @ViewBuilder
    private var emptyState: some View {
        if let shown = shownPack(in: suggestionPacks) {
            suggestionRows(shown)
        }
    }
    #else
    private var emptyState: some View {
        let packs = suggestionPacks
        let shown = shownPack(in: packs)
        return VStack(alignment: .leading, spacing: 10) {
            ReaderFlowLayout(spacingX: 10, spacingY: 4) {
                ForEach([SourcePlace.x, .youtube, .bluesky, .reddit, .mastodon], id: \.self) { place in
                    Button { suggestionPack = place.name } label: {
                        HStack(spacing: 4) {
                            SourceBadge(host: place.host ?? "", title: place.name, size: 12)
                            Text(place.name)
                        }
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(packs.contains { $0.name == place.name })
                }
                Button { suggestionPack = "Podcasts" } label: {
                    Label("Podcasts", systemImage: "mic").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                Label("Any site", systemImage: "globe").labelStyle(.titleAndIcon)
            }
            .font(SheetFont.meta)
            .foregroundStyle(.ofMuted)
            if let shown {
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(packs) { pack in
                            AddSourceNavRow(title: pack.name, selected: pack == shown, fills: false, action: { suggestionPack = pack.name }, icon: { EmptyView() })
                        }
                    }
                }
                .scrollIndicators(.hidden)
                suggestionRows(shown)
                    .padding(.horizontal, -4)
            }
            importButton("Import from another reader (OPML)\u{2026}")
                .padding(.top, 2)
            importStatusText
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
    #endif

    /// What History points to: first what was opened or linked, then neighbours in the subjects the user reads.
    private var forYouRows: some View {
        let suggested = model.shownSuggestions
        let groups: [(title: String, rows: [SourceSuggestion])] = [
            ("From what you\u{2019}ve opened", suggested.filter { $0.evidence != .subject }),
            ("More in what you read", suggested.filter { $0.evidence == .subject }),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(groups.filter { !$0.rows.isEmpty }, id: \.title) { group in
                sectionLabel(group.title).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
                ForEach(group.rows) { suggestion in
                    let result = suggestion.result
                    AddSourceRow(title: result.title, subtitle: Self.placeLine(title: result.title, subtitle: result.subtitle), host: URLHost.host(of: result.siteUrl ?? result.feedUrl),
                                 imageUrl: result.imageUrl, url: result.feedUrl, inLibrary: model.hasSource(feedUrl: result.feedUrl),
                                 roundIcon: result.handle != nil || result.place == .youtube,
                                 placeHost: result.imageUrl == nil ? nil : result.place.host, reason: suggestion.reason, add: add)
                        .contextMenu {
                            Button("Not Interested") { Task { await model.dismissSuggestion(suggestion) } }
                        }
                }
            }
        }
    }

    @ViewBuilder private func suggestionRows(_ pack: StarterPack) -> some View {
        if pack.name == Self.forYouPack {
            forYouRows
        } else {
            catalogRows(pack)
        }
    }

    private func catalogRows(_ pack: StarterPack) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(pack.sources) { source in
                AddSourceRow(title: source.title, subtitle: source.detail, host: source.host, imageUrl: source.imageUrl, url: source.feedUrl,
                             inLibrary: model.hasSource(feedUrl: source.feedUrl), roundIcon: source.place == .youtube,
                             placeHost: source.place == .youtube ? source.place.host : nil, add: add)
            }
        }
    }

    private var footer: some View {
        let adding = model.sourceAdds.values.filter { $0 == .adding }.count
        let added = model.sourceAdds.values.filter { $0 == .added }.count
        return HStack(spacing: 12) {
            destination
            Text(Self.progress(adding: adding, added: added))
                .font(SheetFont.meta)
                .foregroundStyle(.ofMuted)
                .monospacedDigit()
                .lineLimit(1)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(SheetFont.primaryMedium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: doneHeight)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofAccent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
        #if os(macOS)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        #endif
        .overlay(alignment: .top) { Rectangle().fill(Color.ofHairline).frame(height: 1) }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(SheetFont.metaMedium)
            .foregroundStyle(.ofMuted)
            .padding(.vertical, 6)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(SheetFont.meta)
            .foregroundStyle(.ofMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
    }

    private var fieldHeight: CGFloat {
        #if os(iOS)
        44
        #else
        38
        #endif
    }

    private var doneHeight: CGFloat {
        #if os(iOS)
        36
        #else
        32
        #endif
    }

    private var closeSize: CGFloat {
        #if os(iOS)
        Metrics.touchTarget
        #else
        Metrics.desktopIconButton
        #endif
    }

    // MARK: Actions

    /// Starts adding `url` to the chosen folder.
    private func add(_ url: String) {
        addedTo[url] = folderID
        model.beginAddSource(url: url, folderID: folderID)
    }

    /// No Folder is where the menu starts, not a choice, and Return adds before the menu under the field has been
    /// looked at, so the first folder picked takes what went to No Folder. What went to a folder stays there.
    private func moveUnfiledAdds(to folder: Int64) {
        for (url, target) in addedTo where target == nil {
            addedTo[url] = folder
            Task { await model.moveSourceAdd(url: url, toFolder: folder) }
        }
    }

    /// Return adds what was pasted; a name just searches (results update as you type).
    private func submit() {
        if let resolvedAccount {
            add(resolvedAccount.feedUrl)
        } else {
            links.forEach(add)
        }
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

    /// How many results show before Show More.
    private static let firstResults = 8
    /// The searches a name starts: feeds, channels, X's handle and names, Bluesky, Mastodon, Reddit.
    private static let searchCount = 7
    /// How long a name's results wait for every search before showing what has answered.
    private static let settleDelay: Duration = .milliseconds(1000)
    /// How long typing has to stop before a name is searched.
    private static let typingPause: Duration = .milliseconds(200)
    /// How many channels are asked whether their videos play here.
    private static let checkedChannels = 3

    /// How much longer a name waits before asking X's People search or Reddit: each opens a page in a hidden web view, which can't be
    /// called off once started, so it isn't asked mid-word like the others.
    private static let xSearchDelay: Duration = .milliseconds(100)

    /// Debounced search for a name (or a single link, which may also be a name like "node.js").
    private func search() async {
        let q = trimmed
        guard q.count >= 2, links.count <= 1 else {
            clearResults()
            searching = false
            return
        }
        if links.isEmpty, let known = answered[answerKey(q)] {
            clearAccounts()
            results = []
            searchError = false
            rankedQuery = q
            rows = known
            settled = true
            unanswered = 0
            searching = false
            return
        }
        try? await Task.sleep(for: Self.typingPause)
        guard !Task.isCancelled else { return }
        searching = true
        defer { if !Task.isCancelled { searching = false } }
        if let link = links.first {
            clearAccounts()
            if let account = SourceSearch.accountLink(link) {
                results = []
                searchError = false
                if resolved?.link != link { resolved = nil }
                let found = await model.account(for: account)
                guard !Task.isCancelled else { return }
                resolved = found.map { (link, $0) }
            } else {
                resolved = nil
                await searchFeeds(q)
            }
            return
        }
        resolved = nil
        clearAccounts()
        results = []
        searchError = false
        settled = false
        rankedQuery = q
        if let community = SourceSearch.redditCommunity(in: q) {
            // Typed as a community: nothing else is meant.
            reddit = [DefaultSocialAccounts.community(community)]
            settle()
            unanswered = 1
            await searchReddit(q)
            return
        }
        unanswered = Self.searchCount
        async let feeds: Void = searchFeeds(SourceSearch.name(in: q))
        async let youtube: Void = searchChannels(q)
        async let xHandle: Void = searchXHandle(q)
        async let xNames: Void = searchXNames(q)
        async let blueskyAccounts: Void = searchBluesky(q)
        async let mastodonAccounts: Void = searchMastodon(q)
        async let communities: Void = searchReddit(q)
        async let deadline: Void = settleAtDeadline()
        _ = await (feeds, youtube, xHandle, xNames, blueskyAccounts, mastodonAccounts, communities, deadline)
    }

    /// One search answered: everything answered settles the list, and once settled, what's new goes below the first rows.
    private func landed() {
        guard !Task.isCancelled else { return }
        unanswered -= 1
        if unanswered <= 0 {
            settle()
            answered[answerKey(rankedQuery)] = rows
            searching = false
        } else if settled {
            rows = SourceRanking.keepingShown(rows, next: rankedNow, shown: Self.firstResults)
        }
    }

    private func answerKey(_ q: String) -> String { "\(q)|\(signedInToX)" }

    private func settle() {
        if settled {
            rows = SourceRanking.keepingShown(rows, next: rankedNow, shown: Self.firstResults)
        } else {
            settled = true
            rows = rankedNow
        }
    }

    private func settleAtDeadline() async {
        try? await Task.sleep(for: Self.settleDelay)
        guard !Task.isCancelled, !settled else { return }
        settle()
    }

    private var rankedNow: [SourceSearchResult] {
        SourceRanking.rank(query: rankedQuery, feeds: results, accounts: channels + xAccounts + bluesky + mastodon + reddit)
    }

    private func clearResults() {
        results = []
        clearAccounts()
        rows = []
        settled = false
        unanswered = 0
        resolved = nil
        searchError = false
    }

    private func clearAccounts() {
        channels = []
        xAccounts = []
        xProfile = nil
        xNamed = []
        bluesky = []
        mastodon = []
        reddit = []
    }

    private func searchFeeds(_ q: String) async {
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
        if links.isEmpty { landed() }
    }

    private func searchChannels(_ q: String) async {
        let found = (try? await model.searchChannels(q)) ?? []
        guard !Task.isCancelled else { return }
        channels = found
        landed()
        // Ask about the ones near the top, which is all anyone reads.
        let top = rankedNow.filter { $0.place == .youtube }.prefix(Self.checkedChannels)
        for channel in top {
            guard let plays = await model.channelPlaysHere(feedUrl: channel.feedUrl), !Task.isCancelled else { continue }
            if plays { youtubeOnly.remove(channel.feedUrl) } else { youtubeOnly.insert(channel.feedUrl) }
        }
    }

    private func searchBluesky(_ q: String) async {
        let found = (try? await model.searchBluesky(q)) ?? []
        guard !Task.isCancelled else { return }
        bluesky = found
        landed()
    }

    private func searchMastodon(_ q: String) async {
        let found = (try? await model.searchMastodon(q)) ?? []
        guard !Task.isCancelled else { return }
        mastodon = found
        landed()
    }

    /// Reddit's search opens a page in a hidden web view, like X's People search, so it waits the same way. A failure keeps what's there.
    private func searchReddit(_ q: String) async {
        try? await Task.sleep(for: Self.xSearchDelay)
        guard !Task.isCancelled else { return }
        if let found = try? await model.searchReddit(q) {
            guard !Task.isCancelled else { return }
            let typed = reddit.filter { typedCommunity in !found.contains { $0.feedUrl.lowercased() == typedCommunity.feedUrl.lowercased() } }
            reddit = typed + found
        }
        landed()
    }

    /// The account whose handle this could be.
    private func searchXHandle(_ q: String) async {
        var profile: SourceSearchResult?
        if let handle = SourceSearch.xHandle(in: q) { profile = (try? await model.xProfile(handle: handle)) ?? nil }
        guard !Task.isCancelled else { return }
        xProfile = profile
        xAccounts = SourceSearch.mergedXAccounts(profile: profile, named: xNamed)
        landed()
    }

    /// Signed in, the accounts named this. An @handle asks only for that account.
    private func searchXNames(_ q: String) async {
        xNamed = []
        if signedInToX, !q.hasPrefix("@") {
            try? await Task.sleep(for: Self.xSearchDelay)
            guard !Task.isCancelled else { return }
            if let named = try? await model.searchXAccounts(q) {
                guard !Task.isCancelled else { return }
                xNamed = named
                xAccounts = SourceSearch.mergedXAccounts(profile: xProfile, named: named)
            }
        }
        landed()
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

    /// The category of suggestions from History.
    static let forYouPack = "For You"

    #if os(macOS)
    static let sheetWidth: CGFloat = 780
    static let columnWidth: CGFloat = 200
    /// The usual height, and the least it shrinks to in a short window (the smallest is 560).
    static let tallest: CGFloat = 640
    static let shortest: CGFloat = 460
    #endif

    /// A suggestion's place, leaving out a handle the title already is: "X" for @Eagles, not "X · @Eagles".
    static func placeLine(title: String, subtitle: String) -> String {
        let repeated = " · \(title)"
        return title.hasPrefix("@") && subtitle.hasSuffix(repeated) ? String(subtitle.dropLast(repeated.count)) : subtitle
    }

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

    /// A result's second line: "YouTube · @mkbhd · 21.4M subscribers", "Podcast · Publisher", "Reddit · About it", a site's host. A channel
    /// that only plays on YouTube says so in place of the place, keeping the row its height when the answer comes in.
    static func subtitle(_ result: SourceSearchResult, playsOnlyOnYouTube: Bool = false) -> String {
        switch result.place {
        case .site: return result.subtitle
        case .podcast: return "Podcast · \(result.subtitle)"
        case .reddit: return "Reddit · \(result.subtitle)"
        case .x, .youtube, .bluesky, .mastodon, .instagram:
            let lead = playsOnlyOnYouTube ? "Plays on YouTube only" : result.place.name
            return [lead, result.handle.map { "@" + $0 }, result.audience].compactMap { $0 }.joined(separator: " · ")
        }
    }

    static func noFeedNote(_ place: String) -> String {
        "\(place) has no public feed, so its posts can't be followed here."
    }

    /// A link without its scheme or a bare trailing slash, for the row's second line.
    static func shortLink(_ url: String) -> String {
        var s = url
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// The kinds a name's results can be narrowed to, the ones the sidebar lists.
enum SourceFilter: String, CaseIterable, Identifiable {
    case all, posts, video, articles, podcasts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .posts: "Posts"
        case .video: "Video"
        case .articles: "Articles"
        case .podcasts: "Podcasts"
        }
    }

    func results(in ranked: [SourceSearchResult]) -> [SourceSearchResult] {
        switch self {
        case .all: ranked
        case .posts: ranked.filter { $0.readType == .post }
        case .video: ranked.filter { $0.readType == .video }
        case .articles: ranked.filter { $0.readType == .article }
        case .podcasts: ranked.filter { $0.readType == .podcast }
        }
    }
}

/// The sheet's three text styles: the title once, rows and what you pick at the sizes of the app's sidebar, and everything else at the size
/// of its metadata. `metaMedium` is that last size for a label or a small action.
private enum SheetFont {
    static let title = OFFont.ui(17, .semibold)
    static let primary = OFFont.ui(14.5)
    static let primaryMedium = OFFont.ui(14.5, .medium)
    static let meta = OFFont.ui(13)
    static let metaMedium = OFFont.ui(13, .medium)
}

/// A category or filter: a row of the Mac's column, or a chip in a sideways row on iOS. Selected looks the same in both.
private struct AddSourceNavRow<Icon: View>: View {
    let title: String
    let selected: Bool
    var count: Int?
    /// Takes the column's width, with any count at its far edge.
    let fills: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var hovering = false

    private var height: CGFloat {
        #if os(iOS)
        32
        #else
        28
        #endif
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon()
                Text(title)
                    .font(selected ? SheetFont.primaryMedium : SheetFont.primary)
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                if fills { Spacer(minLength: 8) }
                if let count {
                    Text("\(count)")
                        .font(SheetFont.meta)
                        .foregroundStyle(.ofMuted)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: fills ? .infinity : nil, alignment: .leading)
            .frame(height: height)
            .background(selected ? Color.ofSelection : hovering ? Color.ofHover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
    /// A person's or channel's avatar rather than a site's or show's square.
    var roundIcon = false
    /// The place's favicon on the avatar's corner, for a row whose avatar doesn't say where it is.
    var placeHost: String?
    /// Why it can't be added; the row then has no add button.
    var note: String?
    /// Why it's suggested.
    var reason: String?
    /// Starts adding a URL to the sheet's chosen folder.
    let add: (String) -> Void

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var state: SourceAddState? { model.sourceAdds[url] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    // With a reason, the place moves up beside the name and the reason takes the second line, so every row is two lines.
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(title)
                            .font(SheetFont.primaryMedium)
                            .foregroundStyle(.ofInk)
                            .lineLimit(1)
                        if reason != nil {
                            Text(subtitle)
                                .font(SheetFont.meta)
                                .foregroundStyle(.ofMuted)
                                .lineLimit(1)
                        }
                    }
                    Text(reason ?? subtitle)
                        .font(SheetFont.meta)
                        .foregroundStyle(.ofMuted)
                        .lineLimit(reason == nil ? 1 : 2)
                    if let note {
                        Text(note)
                            .font(SheetFont.meta)
                            .foregroundStyle(.ofMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if note == nil { button }
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(SheetFont.meta)
                    .foregroundStyle(.ofDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 42)
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
            CachedAsyncImage(url: u, maxPixelSize: 64) { image in
                image.resizable().scaledToFill()
            } placeholder: { _ in
                Color.ofCode
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: roundIcon ? 16 : 9, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let placeHost {
                    SourceBadge(host: placeHost, title: "", size: 14)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.ofSurface, lineWidth: 1.5))
                        .offset(x: 4, y: 3)
                }
            }
        } else {
            SourceBadge(host: host, title: title, size: 32)
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
