import OpenDispatchCore
import SwiftUI

/// "Add sources" sheet: search by name, or paste one or more links.
///
/// A name searches X accounts, YouTube channels, Bluesky, Mastodon, Reddit communities, feeds (sites, newsletters) and podcasts as you
/// type, each landing on its own, in one list ordered by who was meant and who is followed (`SourceRanking`). Chips narrow it by what you'd
/// read, the kinds the sidebar lists, so another place needs no new chip. One word (or an @handle) is tried as an X handle, and any other name
/// finds X accounts only while the app is signed in to X. A link shows one row for it above the results, by name when it is an account;
/// several links (one per line, or separated by spaces or commas) show one row each with Add All. Adding doesn't close the sheet or wait
/// for the feed: the row shows progress and the source appears in the sidebar once it is detected (`AppModel.beginAddSource`).
/// With nothing typed, the sheet suggests starter sources (`StarterSources`) and offers OPML import. "Add to" in the footer picks the
/// folder new sources go into (No Folder by default; a folder's "Add Source to <Folder>…" preselects it through
/// `AppModel.pendingAddSourceFolderID`), and its New Folder… makes one and picks it. Picking a folder also moves
/// what this sheet already added to No Folder.
struct AddSourceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [SourceSearchResult] = []
    @State private var channels: [SourceSearchResult] = []
    @State private var xAccounts: [SourceSearchResult] = []
    @State private var bluesky: [SourceSearchResult] = []
    @State private var mastodon: [SourceSearchResult] = []
    @State private var reddit: [SourceSearchResult] = []
    /// Channels whose videos only play on YouTube, by feed URL.
    @State private var youtubeOnly: Set<String> = []
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
    /// Height of the list or intro, which sizes the sheet on macOS.
    @State private var contentHeight: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    /// Links in the field (empty when it holds a name).
    private var links: [String] { SourceSearch.links(in: query) }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var targetFolder: Folder? { folderID.flatMap { id in model.folders.first { $0.id == id } } }
    private var ranked: [SourceSearchResult] {
        SourceRanking.rank(query: trimmed, feeds: results, accounts: channels + xAccounts + bluesky + mastodon + reddit)
    }
    private var resolvedAccount: SourceSearchResult? {
        guard let resolved, links == [resolved.link] else { return nil }
        return resolved.account
    }
    private var signedInToX: Bool { model.accounts.isSignedIn(.x) }
    /// A name X can't be asked for without a sign-in: anything that couldn't be a handle.
    private var needsXSignIn: Bool { !signedInToX && links.isEmpty && trimmed.count >= 2 && SourceSearch.xHandle(in: trimmed) == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            field
                .padding(.top, 12)
            if links.isEmpty, !trimmed.isEmpty {
                filterChips
                    .padding(.top, 10)
            }
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
            if let folderError {
                Text(folderError)
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
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
        .onChange(of: trimmed) { showsAll = false }
        .onChange(of: filter) { showsAll = false }
        .task(id: "\(trimmed)|\(signedInToX)") { await search() }
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
            TextField("Search by name or @handle, or paste links", text: $query)
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
                .accessibilityLabel("Search by name or @handle, or paste links")
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

    /// "Add to" and a menu of No Folder, the folders and New Folder…
    private var destination: some View {
        HStack(spacing: 8) {
            Text("Add to")
                .font(OFFont.ui(destinationSize))
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
                #else
                HStack(spacing: 4) {
                    Text(targetFolder?.title ?? "No Folder")
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
            .accessibilityLabel("Add to \(targetFolder?.title ?? "No Folder")")
        }
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
                            .font(OFFont.ui(13, .medium))
                            .foregroundStyle(.ofAccent)
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
        let shown = filter.results(in: ranked)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(showsAll ? shown : Array(shown.prefix(Self.firstResults))) { row($0) }
            if !showsAll, shown.count > Self.firstResults + 1 {
                Button("Show \(shown.count - Self.firstResults) more") { showsAll = true }
                    .buttonStyle(.plain)
                    .font(OFFont.ui(13, .medium))
                    .foregroundStyle(.ofAccent)
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
    }

    private func row(_ result: SourceSearchResult) -> some View {
        AddSourceRow(title: result.title, subtitle: Self.subtitle(result), host: URLHost.host(of: result.siteUrl ?? result.feedUrl),
                     imageUrl: result.imageUrl, url: result.feedUrl, inLibrary: model.hasSource(feedUrl: result.feedUrl),
                     roundIcon: result.handle != nil, placeHost: result.imageUrl == nil ? nil : result.place.host,
                     warning: youtubeOnly.contains(result.feedUrl) ? "Plays on YouTube only" : nil,
                     note: result.canFollow ? nil : Self.noFeedNote(result.place.name), add: add)
    }

    /// All, Posts, Video, Articles and Podcasts, each with its count.
    private var filterChips: some View {
        let ranked = ranked
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(SourceFilter.allCases) { kind in
                    let selected = filter == kind
                    Button { filter = kind } label: {
                        HStack(spacing: 5) {
                            Text(kind.title)
                            Text("\(kind.results(in: ranked).count)").monospacedDigit().opacity(0.6)
                        }
                        .font(OFFont.ui(chipFontSize, .medium))
                        .foregroundStyle(selected ? Color.ofSurface : Color.ofBody)
                        .padding(.horizontal, chipPadding)
                        .frame(height: chipHeight)
                        .background(selected ? Color.ofInk : Color.ofCode, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var xSignInHint: some View {
        HStack(spacing: 10) {
            Text("Sign in to X to find accounts by name, or type the @handle.")
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Sign In") { signingIn = .account(.x) }
                .buttonStyle(.plain)
                .font(OFFont.ui(13, .medium))
                .foregroundStyle(.ofAccent)
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

    /// Starter packs that still have something to add, and what can be added at all.
    private var emptyState: some View {
        let packs = StarterSources.packs.compactMap { pack -> StarterPack? in
            let left = pack.sources.filter { !model.hasSource(feedUrl: $0.feedUrl) || model.sourceAdds[$0.feedUrl] != nil }
            return left.isEmpty ? nil : StarterPack(name: pack.name, sources: left)
        }
        let shown = packs.first { $0.name == suggestionPack } ?? packs.first
        return VStack(alignment: .leading, spacing: 10) {
            ReaderFlowLayout(spacingX: 10, spacingY: 4) {
                ForEach([SourcePlace.x, .youtube, .bluesky, .reddit, .mastodon], id: \.self) { place in
                    HStack(spacing: 4) {
                        SourceBadge(host: place.host ?? "", title: place.name, size: 12)
                        Text(place.name)
                    }
                }
                Label("Podcasts", systemImage: "mic").labelStyle(.titleAndIcon)
                Label("Any site", systemImage: "globe").labelStyle(.titleAndIcon)
            }
            .font(OFFont.ui(12))
            .foregroundStyle(.ofMuted)
            if let shown {
                HStack(spacing: 2) {
                    ForEach(packs) { pack in
                        Button(pack.name) { suggestionPack = pack.name }
                            .buttonStyle(.plain)
                            .font(OFFont.ui(destinationSize, pack == shown ? .medium : .regular))
                            .foregroundStyle(pack == shown ? Color.ofInk : Color.ofMuted)
                            .padding(.horizontal, 9)
                            .frame(height: chipHeight)
                            .background(pack == shown ? Color.ofSelection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown.sources) { source in
                        AddSourceRow(title: source.title, subtitle: source.host, host: source.host, imageUrl: nil, url: source.feedUrl,
                                     inLibrary: model.hasSource(feedUrl: source.feedUrl), add: add)
                    }
                }
                .padding(.horizontal, -4)
            }
            Button("Import from another reader (OPML)…") { importing = true }
                .buttonStyle(.plain)
                .font(OFFont.ui(13, .medium))
                .foregroundStyle(.ofAccent)
                .padding(.top, 2)
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
        return HStack(spacing: 12) {
            destination
            Text(Self.progress(adding: adding, added: added))
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
                .monospacedDigit()
                .lineLimit(1)
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

    private var chipFontSize: CGFloat {
        #if os(iOS)
        14
        #else
        12.5
        #endif
    }

    private var chipPadding: CGFloat {
        #if os(iOS)
        13
        #else
        10
        #endif
    }

    private var chipHeight: CGFloat {
        #if os(iOS)
        32
        #else
        26
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
    /// How many channels are asked whether their videos play here.
    private static let checkedChannels = 3

    /// How much longer a name waits before asking X's People search or Reddit: each opens a page in a hidden web view, which can't be
    /// called off once started, so it isn't asked mid-word like the others.
    private static let xSearchDelay: Duration = .milliseconds(600)

    /// Debounced search for a name (or a single link, which may also be a name like "node.js").
    private func search() async {
        let q = trimmed
        guard q.count >= 2, links.count <= 1 else {
            clearResults()
            searching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
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
        if let community = SourceSearch.redditCommunity(in: q) {
            // Typed as a community: nothing else is meant.
            clearAccounts()
            results = []
            searchError = false
            reddit = [DefaultSocialAccounts.community(community)]
            await searchReddit(q)
            return
        }
        async let feeds: Void = searchFeeds(SourceSearch.name(in: q))
        async let youtube: Void = searchChannels(q)
        async let x: Void = searchX(q)
        async let blueskyAccounts: Void = searchBluesky(q)
        async let mastodonAccounts: Void = searchMastodon(q)
        async let communities: Void = searchReddit(q)
        _ = await (feeds, youtube, x, blueskyAccounts, mastodonAccounts, communities)
    }

    private func clearResults() {
        results = []
        clearAccounts()
        resolved = nil
        searchError = false
    }

    private func clearAccounts() {
        channels = []
        xAccounts = []
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
    }

    private func searchChannels(_ q: String) async {
        let found = (try? await model.searchChannels(q)) ?? []
        guard !Task.isCancelled else { return }
        channels = found
        // Ask about the ones near the top, which is all anyone reads.
        let top = ranked.filter { $0.place == .youtube }.prefix(Self.checkedChannels)
        for channel in top {
            guard let plays = await model.channelPlaysHere(feedUrl: channel.feedUrl), !Task.isCancelled else { continue }
            if plays { youtubeOnly.remove(channel.feedUrl) } else { youtubeOnly.insert(channel.feedUrl) }
        }
    }

    private func searchBluesky(_ q: String) async {
        let found = (try? await model.searchBluesky(q)) ?? []
        guard !Task.isCancelled else { return }
        bluesky = found
    }

    private func searchMastodon(_ q: String) async {
        let found = (try? await model.searchMastodon(q)) ?? []
        guard !Task.isCancelled else { return }
        mastodon = found
    }

    /// Reddit's search opens a page in a hidden web view, like X's People search, so it waits the same way. A failure keeps what's there.
    private func searchReddit(_ q: String) async {
        try? await Task.sleep(for: Self.xSearchDelay)
        guard !Task.isCancelled, let found = try? await model.searchReddit(q), !Task.isCancelled else { return }
        let typed = reddit.filter { typedCommunity in !found.contains { $0.feedUrl.lowercased() == typedCommunity.feedUrl.lowercased() } }
        reddit = typed + found
    }

    /// The account whose handle this could be, then, signed in, the accounts named this. An @handle asks only for that account.
    private func searchX(_ q: String) async {
        var profile: SourceSearchResult?
        if let handle = SourceSearch.xHandle(in: q) { profile = (try? await model.xProfile(handle: handle)) ?? nil }
        guard !Task.isCancelled else { return }
        xAccounts = profile.map { [$0] } ?? []
        guard signedInToX, !q.hasPrefix("@") else { return }
        try? await Task.sleep(for: Self.xSearchDelay)
        guard !Task.isCancelled, let named = try? await model.searchXAccounts(q), !Task.isCancelled else { return }
        xAccounts = SourceSearch.mergedXAccounts(profile: profile, named: named)
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

    /// A result's second line: "YouTube · @mkbhd · 21.4M subscribers", "Podcast · Publisher", "Reddit · About it", a site's host.
    static func subtitle(_ result: SourceSearchResult) -> String {
        switch result.place {
        case .site: return result.subtitle
        case .podcast: return "Podcast · \(result.subtitle)"
        case .reddit: return "Reddit · \(result.subtitle)"
        case .x, .youtube, .bluesky, .mastodon, .instagram:
            let parts = [result.place.name, result.handle.map { "@" + $0 }, result.audience]
            return parts.compactMap { $0 }.joined(separator: " · ")
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
    /// Worth knowing before adding it ("Plays on YouTube only").
    var warning: String?
    /// Why it can't be added; the row then has no add button.
    var note: String?
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
                    if let warning {
                        Label(warning, systemImage: "arrow.up.right")
                            .labelStyle(.titleAndIcon)
                            .font(OFFont.ui(12))
                            .foregroundStyle(.ofMuted)
                            .lineLimit(1)
                    }
                    if let note {
                        Text(note)
                            .font(OFFont.ui(12))
                            .foregroundStyle(.ofMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if note == nil { button }
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
            .clipShape(RoundedRectangle(cornerRadius: roundIcon ? 14 : 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let placeHost {
                    SourceBadge(host: placeHost, title: "", size: 13)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.ofSurface, lineWidth: 1.5))
                        .offset(x: 4, y: 3)
                }
            }
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
