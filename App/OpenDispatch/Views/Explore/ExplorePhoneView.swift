#if os(iOS)
import OpenDispatchCore
import SwiftUI

/// Explore on the iPhone, the drawer's first row: a page in the home column with the drawer's hamburger and
/// a search field at the top. With nothing searched it lists recent searches and what was played last
/// (History). A search (Return) shows filter chips (All, Videos, Episodes, Sources) over the results, which
/// start with a row that follows the search as a topic (Follow, then Following, which opens the topic): in All,
/// videos in a row to swipe through, then three episodes and three sources, each with See All; a chip shows
/// one kind in full. A last row searches the web in the default browser. Typing a web address instead of
/// words opens it directly. A result opens in the reader pushed onto the stack, like a History row, and
/// the page and its results are as they were on coming back.
struct ExplorePhoneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.phoneDrawer) private var drawer
    @Environment(\.isFeedStackPushed) private var isFeedStackPushed
    @State private var filter: Filter = .all
    @FocusState private var focused: Bool
    /// The last `AppModel.exploreFocusRequests` acted on, so coming back from the reader doesn't raise the keyboard.
    @State private var handledFocusRequest = 0

    private enum Filter: String, CaseIterable {
        case all = "All", videos = "Videos", episodes = "Episodes", sources = "Sources"
    }

    private static let side: CGFloat = 16

    private var isSearching: Bool { !model.explore.query.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if isSearching { chips }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isSearching { results } else { start }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 48)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
        .background(Color.ofSurface.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: Binding(
            get: { model.selectedItemID != nil && model.showsExplore && !isFeedStackPushed },
            set: { presented in if !presented, model.selectedItemID != nil { model.select(nil) } })
        ) {
            ReaderView()
        }
        .onAppear(perform: focusIfRequested)
        .onChange(of: model.exploreFocusRequests) { focusIfRequested() }
    }

    /// Picking Explore in the drawer puts the cursor in the search field, once the drawer has slid away.
    private func focusIfRequested() {
        guard handledFocusRequest != model.exploreFocusRequests else { return }
        handledFocusRequest = model.exploreFocusRequests
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            focused = true
        }
    }

    // MARK: Top

    private var topBar: some View {
        @Bindable var explore = model.explore
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: drawer.open) {
                    Image("ph.menu")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.ofInk)
                        .frame(width: 46, height: 46)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Menu")
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.ofMuted)
                        .accessibilityHidden(true)
                    TextField("", text: $explore.draft, prompt: Text("Videos, podcasts and sources").foregroundStyle(.ofFaint))
                        .font(OFFont.ui(17))
                        .foregroundStyle(.ofInk)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($focused)
                        .disabled(explore.isOpeningLink)
                        .accessibilityLabel("Search videos, podcasts and sources")
                        .onSubmit(submit)
                        .onChange(of: explore.draft) { explore.dismissOpenError() }
                    if explore.isOpeningLink {
                        ProgressView().controlSize(.small)
                    } else if !explore.draft.isEmpty {
                        Button { explore.draft = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(.ofFaint)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Color.ofCardInset, in: Capsule())
            }
            if let message = explore.openError {
                Text(message)
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofDanger)
                    .padding(.horizontal, 56)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Filter.allCases, id: \.self) { chip in
                    Button { filter = chip } label: {
                        Text(chip.rawValue)
                            .font(OFFont.ui(14, .medium))
                            .foregroundStyle(filter == chip ? Color.ofSurface : Color.ofBody)
                            .padding(.horizontal, 13)
                            .frame(height: 32)
                            .background(filter == chip ? Color.ofInk : Color.ofCardInset, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == chip ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, Self.side)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 6)
    }

    private func submit() {
        let explore = model.explore
        let text = explore.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        focused = false
        guard !text.isEmpty else { return explore.clear() }
        if ExploreStore.link(in: text) != nil {
            Task {
                if let item = await explore.openLink(text) { model.select(item) }
            }
        } else {
            filter = .all
            explore.search(text)
        }
    }

    // MARK: Start

    @ViewBuilder private var start: some View {
        let recents = model.explore.recents
        let played = model.history.opened.filter { $0.sourceKind == .youtube || $0.sourceKind == .podcast }.prefix(3)
        if !recents.isEmpty {
            header("Recent searches") {
                Button("Clear") { model.explore.clearRecents() }
                    .buttonStyle(.plain)
                    .font(OFFont.ui(14, .medium))
                    .foregroundStyle(.ofAccent)
            }
            ForEach(recents, id: \.self) { query in
                HStack(spacing: 0) {
                    Button {
                        focused = false
                        filter = .all
                        model.explore.search(query)
                    } label: {
                        HStack(spacing: 10) {
                            OFIcon.history.image
                                .font(.system(size: 13))
                                .foregroundStyle(.ofBody)
                                .frame(width: 28, height: 28)
                                .background(Color.ofCardInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(query)
                                .font(OFFont.ui(16, .medium))
                                .foregroundStyle(.ofInk)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search for \(query)")
                    Button { model.explore.removeRecent(query) } label: {
                        OFIcon.close.image
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.ofFaint)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(query)")
                }
                .padding(.leading, Self.side)
                .padding(.trailing, 6)
            }
        }
        if !played.isEmpty {
            header("Recently played")
            ForEach(Array(played)) { entry in
                PlayedRow(entry: entry) {
                    if PhoneDrawerTouch.blocksRowTap { return }
                    Task { await model.open(entry) }
                }
            }
        }
        Text("Type a link instead of words to open it directly.")
            .font(OFFont.ui(13))
            .foregroundStyle(.ofFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Self.side)
            .padding(.top, 20)
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        let explore = model.explore
        followRow(explore.query)
        switch filter {
        case .all: allSections(explore)
        case .videos: videoSection(explore, all: true)
        case .episodes: episodeSection(explore, all: true)
        case .sources: sourceSection(explore, all: true)
        }
        ExploreWebRow(query: explore.query, isPhone: true)
            .padding(.horizontal, Self.side)
            .padding(.top, 18)
    }

    /// Follow / Following for the searched words as a topic, above the results.
    private func followRow(_ query: String) -> some View {
        HStack(spacing: 12) {
            OFIcon.topic.image
                .font(.system(size: 14))
                .foregroundStyle(.ofBody)
                .frame(width: 28, height: 28)
                .background(Color.ofCardInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.topic(matching: query) == nil ? "Follow as a topic" : "Following as a topic")
                    .font(OFFont.ui(15, .medium))
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                Text("New matches from news, forums, videos and podcasts")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            ExploreTopicButton(query: query)
        }
        .padding(.horizontal, Self.side)
        .padding(.top, 10)
    }

    /// All: videos, episodes and sources, each cut short with See All, and left out when it came back empty.
    @ViewBuilder private func allSections(_ explore: ExploreStore) -> some View {
        videoSection(explore, all: false)
        episodeSection(explore, all: false)
        sourceSection(explore, all: false)
        if isEmpty(explore) {
            ExploreEmptyNote(text: "No results for \u{201C}\(explore.query)\u{201D}")
                .padding(.horizontal, Self.side)
                .padding(.top, 20)
        }
    }

    private func isEmpty(_ explore: ExploreStore) -> Bool {
        (explore.videos.value?.videos.isEmpty ?? false) && (explore.episodes.value?.isEmpty ?? false)
            && (explore.sourcesPhase.value?.isEmpty ?? false)
    }

    @ViewBuilder private func videoSection(_ explore: ExploreStore, all: Bool) -> some View {
        switch explore.videos {
        case .idle:
            EmptyView()
        case .loading:
            header("Videos")
            ExploreSkeleton(style: .cards, isPhone: true).padding(.horizontal, Self.side)
        case .failed(let message):
            header("Videos")
            ExploreFailure(what: "YouTube", message: message, retry: explore.retryVideos).padding(.horizontal, Self.side)
        case .loaded(let found):
            if found.videos.isEmpty {
                if all {
                    ExploreEmptyNote(text: "No videos for \u{201C}\(explore.query)\u{201D}")
                        .padding(.horizontal, Self.side).padding(.top, 14)
                }
            } else if all {
                ForEach(found.videos) { video in
                    let target = ExploreTarget.video(video)
                    PhoneVideoRow(video: video, isOpening: explore.opening == target.id) { open(target) }
                }
            } else {
                header("Videos", seeAll: .videos)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(found.videos.prefix(10)) { video in
                            let target = ExploreTarget.video(video)
                            PhoneVideoCard(video: video, isOpening: explore.opening == target.id) { open(target) }
                        }
                    }
                    .padding(.horizontal, Self.side)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder private func episodeSection(_ explore: ExploreStore, all: Bool) -> some View {
        switch explore.episodes {
        case .idle:
            EmptyView()
        case .loading:
            header("Podcast episodes")
            ExploreSkeleton(style: .rows, isPhone: true).padding(.horizontal, Self.side)
        case .failed(let message):
            header("Podcast episodes")
            ExploreFailure(what: "podcasts", message: message, retry: explore.retryEpisodes).padding(.horizontal, Self.side)
        case .loaded(let found):
            if found.isEmpty {
                if all {
                    ExploreEmptyNote(text: "No episodes for \u{201C}\(explore.query)\u{201D}")
                        .padding(.horizontal, Self.side).padding(.top, 14)
                }
            } else {
                if !all { header("Podcast episodes", seeAll: found.count > 3 ? .episodes : nil) }
                ForEach(all ? found : Array(found.prefix(3))) { episode in
                    let target = ExploreTarget.episode(episode)
                    PhoneEpisodeRow(episode: episode, isOpening: explore.opening == target.id) { open(target) }
                }
            }
        }
    }

    @ViewBuilder private func sourceSection(_ explore: ExploreStore, all: Bool) -> some View {
        switch explore.sourcesPhase {
        case .idle:
            EmptyView()
        case .loading:
            header("Sources to follow")
            ExploreSkeleton(style: .rows, isPhone: true).padding(.horizontal, Self.side)
        case .failed(let message):
            header("Sources to follow")
            ExploreFailure(what: "sources", message: message, retry: explore.retryFeeds).padding(.horizontal, Self.side)
        case .loaded(let found):
            if found.isEmpty {
                if all {
                    ExploreEmptyNote(text: "No sources for \u{201C}\(explore.query)\u{201D}")
                        .padding(.horizontal, Self.side).padding(.top, 14)
                }
            } else {
                if !all { header("Sources to follow", seeAll: found.count > 3 ? .sources : nil) }
                ForEach(all ? found : Array(found.prefix(3))) { result in
                    ExploreSourceItem(result: result, avatarSize: 40)
                        .padding(.horizontal, Self.side)
                        .padding(.vertical, 7)
                }
            }
        }
    }

    private func open(_ target: ExploreTarget) {
        if PhoneDrawerTouch.blocksRowTap { return }
        focused = false
        Task {
            if let item = await model.explore.open(target) { model.select(item) }
        }
    }

    // MARK: Pieces

    private func header(_ title: String, seeAll: Filter? = nil) -> some View {
        header(title) {
            if let seeAll {
                Button("See All") { filter = seeAll }
                    .buttonStyle(.plain)
                    .font(OFFont.ui(14, .medium))
                    .foregroundStyle(.ofAccent)
            }
        }
    }

    private func header<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(OFFont.ui(14, .semibold))
                .foregroundStyle(.ofMuted)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, Self.side)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

/// A video in the All carousel: a 170pt thumbnail, two lines of title, channel · views.
private struct PhoneVideoCard: View {
    let video: ExploreVideo
    let isOpening: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ExploreThumb(url: video.thumbnailUrl, duration: video.duration, isOpening: isOpening, width: 170)
                    .frame(width: 170)
                Text(video.title)
                    .font(OFFont.ui(14, .medium))
                    .foregroundStyle(.ofInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 170, alignment: .leading)
                Text(ExploreFormat.videoMeta(video))
                    .font(OFFont.ui(12.5))
                    .foregroundStyle(.ofMuted)
                    .lineLimit(1)
                    .frame(width: 170, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(video.title), \(ExploreFormat.videoMeta(video))\(video.duration.map { ", \($0)" } ?? "")")
    }
}

/// A video in the Videos list: a 116pt thumbnail beside the title, channel, and views · age.
private struct PhoneVideoRow: View {
    let video: ExploreVideo
    let isOpening: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ExploreThumb(url: video.thumbnailUrl, duration: video.duration, isOpening: isOpening, width: 116)
                    .frame(width: 116)
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(OFFont.ui(15, .medium))
                        .foregroundStyle(.ofInk)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(video.channel)
                        .font(OFFont.ui(13))
                        .foregroundStyle(.ofMuted)
                        .lineLimit(1)
                    let stats = ExploreFormat.videoStats(video)
                    if !stats.isEmpty {
                        Text(stats)
                            .font(OFFont.ui(13))
                            .foregroundStyle(.ofMuted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(video.title), \(ExploreFormat.videoMeta(video))\(video.duration.map { ", \($0)" } ?? "")")
    }
}

/// A podcast episode: artwork, title, show · date · length, and a play badge.
private struct PhoneEpisodeRow: View {
    let episode: ExploreEpisode
    let isOpening: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ExploreArtwork(url: episode.artworkUrl, size: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title)
                        .font(OFFont.ui(15, .medium))
                        .foregroundStyle(.ofInk)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(ExploreFormat.episodeMeta(episode))
                        .font(OFFont.ui(13))
                        .foregroundStyle(.ofMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ExplorePlayBadge(size: 32, isOpening: isOpening)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(episode.title), \(ExploreFormat.episodeMeta(episode))")
        .accessibilityHint("Plays the episode")
    }
}

/// A video or episode played before (History), in the start state.
private struct PlayedRow: View {
    let entry: HistoryEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if entry.sourceKind == .youtube {
                    ExploreThumb(url: entry.thumbnailUrl ?? "", width: 116)
                        .frame(width: 116)
                } else {
                    ExploreArtwork(url: entry.thumbnailUrl, size: 50)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.itemTitle)
                        .font(OFFont.ui(15, .medium))
                        .foregroundStyle(.ofInk)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(entry.originLabel)
                        .font(OFFont.ui(13))
                        .foregroundStyle(.ofMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.itemTitle), \(entry.originLabel)")
    }
}
#endif
