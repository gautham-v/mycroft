import OpenDispatchCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Explore on the Mac and iPad: the New Tab page's field, its recent searches and its results. The field
/// searches on Return, or opens a web address typed or pasted into it (the New Tab page's old address field).
/// Results are Videos (a grid), Articles (news), Posts (Reddit, X, Bluesky, Hacker News), Podcast episodes, Sources to follow and a last
/// row that searches the web;
/// each section lands on its own. A result opens in this tab, or ⌘-click (the menu's Open in New Tab) in a
/// tab after it, leaving the page and its results in place.
struct ExploreSearchField: View {
    let pane: Int
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @FocusState private var focused: Bool

    private var openingURL: String? {
        model.panes.indices.contains(pane) ? model.panes[pane].activeTab.openingURL : nil
    }

    var body: some View {
        @Bindable var explore = model.explore
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                OFIcon.search.image
                    .font(.system(size: 13))
                    .foregroundStyle(.ofMuted)
                    .accessibilityHidden(true)
                TextField("", text: $explore.draft,
                          prompt: Text("Search videos, news, posts, podcasts and sources, or enter a link").foregroundStyle(.ofFaint))
                    .textFieldStyle(.plain)
                    .font(OFFont.ui(14))
                    .foregroundStyle(.ofInk)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .focused($focused)
                    .disabled(openingURL != nil)
                    .accessibilityLabel("Search or enter a link")
                    .onSubmit(submit)
                    .onChange(of: explore.draft) { error = nil }
                if openingURL != nil {
                    ProgressView().controlSize(.small)
                } else if !explore.draft.isEmpty {
                    Button { explore.draft = ""; focused = true } label: {
                        OFIcon.close.image
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.ofMuted)
                            .frame(width: 18, height: 18)
                            .background(Color.ofBorder.opacity(0.6), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                } else {
                    #if os(macOS)
                    Text("\u{2318}L")
                        .font(OFFont.ui(11))
                        .foregroundStyle(.ofFaint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.ofBorder, lineWidth: 1))
                        .accessibilityHidden(true)
                    #endif
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color.ofCode, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.ofAccent.opacity(focused ? 0.6 : 0), lineWidth: 1)
            )
            if let message = error ?? explore.openError {
                Text(message)
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofDanger)
                    .padding(.leading, 2)
            }
        }
        .onAppear { if pane == model.focusedPane { focused = true } }
        .onChange(of: model.addressFocusRequests) { if pane == model.focusedPane { focused = true } }
    }

    /// Return: a web address opens in this tab, anything else is searched; blank clears the results.
    private func submit() {
        let text = model.explore.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard openingURL == nil else { return }
        guard !text.isEmpty else { return model.explore.clear() }
        model.focusPane(pane)
        if ExploreStore.link(in: text) != nil {
            Task { error = await model.openLink(text, inPane: pane) }
        } else {
            model.explore.search(text)
        }
    }
}

/// The last few searches on the New Tab page, each a tap away from running again.
struct ExploreRecentSearches: View {
    let pane: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let recents = model.explore.recents
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Recent searches")
                        .font(OFFont.ui(13))
                        .foregroundStyle(.ofMuted)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button("Clear") { model.explore.clearRecents() }
                        .buttonStyle(.plain)
                        .font(OFFont.ui(13))
                        .foregroundStyle(.ofAccent)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                ForEach(recents, id: \.self) { query in
                    ExploreRecentRow(query: query) {
                        model.focusPane(pane)
                        model.explore.search(query)
                    }
                }
            }
        }
    }
}

private struct ExploreRecentRow: View {
    let query: String
    let action: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                OFIcon.history.image
                    .font(.system(size: 12))
                    .foregroundStyle(.ofMuted)
                    .frame(width: 16)
                Text(query)
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(hovering ? Color.ofHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { Button("Remove from Recent Searches") { model.explore.removeRecent(query) } }
        .accessibilityLabel("Search for \(query)")
    }
}

/// The results for the submitted query.
struct ExploreDesktopResults: View {
    let pane: Int
    @Environment(AppModel.self) private var model
    @State private var allVideos = false
    @State private var allArticles = false
    @State private var allPosts = false
    @State private var allEpisodes = false
    @State private var allSources = false

    private static let videoLimit = 6
    private static let articleLimit = 5
    private static let postLimit = 5
    private static let episodeLimit = 4
    private static let sourceLimit = 6

    var body: some View {
        let explore = model.explore
        VStack(alignment: .leading, spacing: 26) {
            topicRow(explore)
            videos(explore)
            articles(explore)
            posts(explore)
            episodes(explore)
            sources(explore)
            ExploreWebRow(query: explore.query)
        }
    }

    // MARK: Sections

    /// The query and Follow, which makes it a topic.
    private func topicRow(_ explore: ExploreStore) -> some View {
        HStack(spacing: 10) {
            Text("Results for \u{201C}\(explore.query)\u{201D}")
                .font(OFFont.ui(15, .semibold))
                .foregroundStyle(.ofInk)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            ExploreTopicButton(query: explore.query)
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder private func videos(_ explore: ExploreStore) -> some View {
        switch explore.videos {
        case .idle:
            EmptyView()
        case .loading:
            section("Videos") { ExploreSkeleton(style: .cards) }
        case .failed(let message):
            section("Videos") { ExploreFailure(what: "YouTube", message: message, retry: explore.retryVideos) }
        case .loaded(let results):
            section("Videos", count: results.videos.count, limit: Self.videoLimit, expanded: $allVideos) {
                if results.videos.isEmpty {
                    ExploreEmptyNote(text: "No videos for \u{201C}\(explore.query)\u{201D}")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14, alignment: .top)], alignment: .leading, spacing: 18) {
                        ForEach(allVideos ? results.videos : Array(results.videos.prefix(Self.videoLimit))) { video in
                            let target = ExploreTarget.video(video)
                            ExploreVideoCard(video: video, isOpening: explore.opening == target.id) { open(target, inNewTab: $0) }
                        }
                    }
                }
            }
        }
    }

    /// News, with the paywalled sites marked or left out as the lists do (Settings › Integrations › Paywalled articles).
    @ViewBuilder private func articles(_ explore: ExploreStore) -> some View {
        switch explore.articles {
        case .idle:
            EmptyView()
        case .loading:
            section("Articles") { ExploreSkeleton(style: .rows) }
        case .failed(let message):
            section("Articles") { ExploreFailure(what: "news", message: message, retry: explore.retryArticles) }
        case .loaded(let all):
            let articles = model.shownArticles(all)
            section("Articles", count: articles.count, limit: Self.articleLimit, expanded: $allArticles) {
                if articles.isEmpty {
                    ExploreEmptyNote(text: "No articles for \u{201C}\(explore.query)\u{201D}")
                } else {
                    VStack(spacing: 0) {
                        ForEach(allArticles ? articles : Array(articles.prefix(Self.articleLimit))) { article in
                            let target = ExploreTarget.article(article)
                            ExploreArticleRow(article: article, paywall: model.paywallStatus(of: article), isOpening: explore.opening == target.id) {
                                open(target, inNewTab: $0)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func posts(_ explore: ExploreStore) -> some View {
        if !explore.query.isEmpty {
            let count = explore.posts[explore.shownPostPlace]?.value?.count ?? 0
            section("Posts", count: count, limit: Self.postLimit, expanded: $allPosts) {
                ExplorePostsSection(limit: allPosts ? nil : Self.postLimit) { open($0, inNewTab: $1) }
            }
        }
    }

    @ViewBuilder private func episodes(_ explore: ExploreStore) -> some View {
        switch explore.episodes {
        case .idle:
            EmptyView()
        case .loading:
            section("Podcast episodes") { ExploreSkeleton(style: .rows) }
        case .failed(let message):
            section("Podcast episodes") { ExploreFailure(what: "podcasts", message: message, retry: explore.retryEpisodes) }
        case .loaded(let episodes):
            section("Podcast episodes", count: episodes.count, limit: Self.episodeLimit, expanded: $allEpisodes) {
                if episodes.isEmpty {
                    ExploreEmptyNote(text: "No episodes for \u{201C}\(explore.query)\u{201D}")
                } else {
                    VStack(spacing: 0) {
                        ForEach(allEpisodes ? episodes : Array(episodes.prefix(Self.episodeLimit))) { episode in
                            let target = ExploreTarget.episode(episode)
                            ExploreEpisodeRow(episode: episode, isOpening: explore.opening == target.id) { open(target, inNewTab: $0) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func sources(_ explore: ExploreStore) -> some View {
        switch explore.sourcesPhase {
        case .idle:
            EmptyView()
        case .loading:
            section("Sources to follow") { ExploreSkeleton(style: .rows) }
        case .failed(let message):
            section("Sources to follow") { ExploreFailure(what: "sources", message: message, retry: explore.retryFeeds) }
        case .loaded(let found):
            section("Sources to follow", count: found.count, limit: Self.sourceLimit, expanded: $allSources) {
                if found.isEmpty {
                    ExploreEmptyNote(text: "No sources for \u{201C}\(explore.query)\u{201D}")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                        ForEach(allSources ? found : Array(found.prefix(Self.sourceLimit))) { result in
                            ExploreSourceItem(result: result)
                                .padding(10)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.ofHairline, lineWidth: 1))
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, count: Int = 0, limit: Int = .max, expanded: Binding<Bool> = .constant(false),
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if count > limit {
                    Button(expanded.wrappedValue ? "Show Less" : "See All") { expanded.wrappedValue.toggle() }
                        .buttonStyle(.plain)
                        .font(OFFont.ui(13))
                        .foregroundStyle(.ofAccent)
                }
            }
            .padding(.horizontal, 8)
            content()
        }
    }

    // MARK: Opening

    /// Stores the result, then shows it in this tab (or a tab after it). The tab is remembered now, so a
    /// slow open still lands in the tab it was clicked in.
    private func open(_ target: ExploreTarget, inNewTab: Bool) {
        guard model.panes.indices.contains(pane), model.explore.opening == nil else { return }
        let tabID = model.panes[pane].activeTab.id
        let newTab = inNewTab || Self.commandDown
        model.focusPane(pane)
        Task {
            guard let item = await model.explore.open(target) else { return }
            model.openExplored(item, tabID: tabID, inNewTab: newTab)
        }
    }

    private static var commandDown: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        #else
        false
        #endif
    }
}

/// A video in the grid: thumbnail with its length, title, channel · views.
private struct ExploreVideoCard: View {
    let video: ExploreVideo
    let isOpening: Bool
    /// Opens it; true for a new tab.
    let open: (Bool) -> Void
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    var body: some View {
        Button { open(false) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ExploreThumb(url: video.thumbnailUrl, duration: video.duration, isOpening: isOpening)
                Text(video.title)
                    .font(OFFont.ui(13, .medium))
                    .foregroundStyle(hovering ? Color.ofAccent : Color.ofInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ExploreFormat.videoMeta(video))
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open in New Tab") { open(true) }
            if let url = URL(string: video.watchUrl) {
                Button("Open in Browser") { openURL(url) }
                Button("Copy Link") { ReaderPasteboard.copy(url) }
            }
        }
        .help(video.title)
        .accessibilityLabel("\(video.title), \(ExploreFormat.videoMeta(video))\(video.duration.map { ", \($0)" } ?? "")")
    }
}

/// A podcast episode: artwork, title, show · date · length, and a play badge.
private struct ExploreEpisodeRow: View {
    let episode: ExploreEpisode
    let isOpening: Bool
    let open: (Bool) -> Void
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    var body: some View {
        Button { open(false) } label: {
            HStack(spacing: 10) {
                ExploreArtwork(url: episode.artworkUrl)
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title)
                        .font(OFFont.ui(13, .medium))
                        .foregroundStyle(hovering ? Color.ofAccent : Color.ofInk)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(ExploreFormat.episodeMeta(episode))
                        .font(OFFont.ui(12))
                        .foregroundStyle(.ofMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ExplorePlayBadge(isOpening: isOpening)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.ofHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open in New Tab") { open(true) }
            if let url = URL(string: episode.appleUrl) {
                Button("Open in Browser") { openURL(url) }
                Button("Copy Link") { ReaderPasteboard.copy(url) }
            }
        }
        .help(episode.title)
        .accessibilityLabel("\(episode.title), \(ExploreFormat.episodeMeta(episode))")
        .accessibilityHint("Plays the episode")
    }
}
