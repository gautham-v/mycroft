import Foundation
import Observation
import OpenDispatchCore

/// Where one section of a search stands. Sections land independently, so one failing leaves the others.
enum ExplorePhase<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { value } else { nil }
    }

    var isLoading: Bool {
        if case .loading = self { true } else { false }
    }
}

/// A search result that opens in the reader.
enum ExploreTarget: Hashable, Identifiable {
    case video(ExploreVideo)
    case episode(ExploreEpisode)
    case post(DiscussionPost)

    var id: String {
        switch self {
        case .video(let video): "video:" + video.id
        case .episode(let episode): "episode:" + episode.id
        case .post(let post): "post:" + post.id
        }
    }
}

/// Explore's searches (videos, posts, podcast episodes, sources to follow) and the last results, which
/// stay while you open one and come back (⌘T again, or back from the reader on iPhone). AppModel owns it
/// (`model.explore`); the New Tab page and the iPhone's Explore page read and drive it.
///
/// A search runs on Return, not per keystroke; a new one cancels the one before. Sources to follow are the
/// YouTube channels the video search matched, then the existing Add Source search (feeds and podcasts).
/// Posts are searched on each place of `DiscussionPlace.searched` at once, each landing on its own; X only when the app is
/// signed in to it (`WebAccountStore`), otherwise its tab offers the sign-in.
@MainActor
@Observable
final class ExploreStore {
    /// What the field holds. Emptying it clears the results.
    var draft = "" {
        didSet {
            if !query.isEmpty, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clear() }
        }
    }
    /// The query the results are for; empty before the first search and after clearing.
    private(set) var query = ""
    private(set) var videos: ExplorePhase<ExploreVideoResults> = .idle
    private(set) var episodes: ExplorePhase<[ExploreEpisode]> = .idle
    private(set) var feeds: ExplorePhase<[SourceSearchResult]> = .idle
    /// Posts by place. A place missing from it wasn't searched (X when signed out).
    private(set) var posts: [DiscussionPlace: ExplorePhase<[DiscussionPost]>] = [:]
    /// The place the posts section shows when one was picked for this search; otherwise `shownPostPlace` picks.
    private(set) var pickedPostPlace: DiscussionPlace?
    /// The last few searches, newest first. Persisted.
    private(set) var recents: [String]
    /// The result (`ExploreTarget.id`) or link being opened, which shows a spinner.
    private(set) var opening: String?
    /// Why the last open failed, shown under the field until the next search or edit.
    private(set) var openError: String?

    @ObservationIgnored private let services: OpenDispatchServices
    @ObservationIgnored private let accounts: WebAccountStore
    @ObservationIgnored private var tasks: [Part: Task<Void, Never>] = [:]
    /// Bumped by each search, so a section that lands late for an older one is dropped.
    @ObservationIgnored private var generation = 0

    private enum Part: Hashable { case videos, episodes, feeds, posts(DiscussionPlace) }

    private static let recentsKey = "openfeed.explore-recents"
    private static let maxRecents = 8

    init(services: OpenDispatchServices, accounts: WebAccountStore) {
        self.services = services
        self.accounts = accounts
        recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
    }

    // MARK: Reading

    /// The channels the video search matched, then the feeds and podcasts the source search found, with a
    /// feed that comes up twice (by `SourceSearch.feedKey`) kept once, as the channel.
    var sources: [SourceSearchResult] {
        var seen = Set<String>()
        return ((videos.value?.channels ?? []) + (feeds.value ?? [])).filter { seen.insert(SourceSearch.feedKey($0.feedUrl)).inserted }
    }

    /// The sources section: whatever has landed, else loading while either search is out, else why not.
    var sourcesPhase: ExplorePhase<[SourceSearchResult]> {
        let found = sources
        if !found.isEmpty { return .loaded(found) }
        if videos.isLoading || feeds.isLoading { return .loading }
        if case .failed(let message) = feeds { return .failed(message) }
        return query.isEmpty ? .idle : .loaded([])
    }

    /// The text is a single web address (has a dot, normalizes), which opens directly instead of searching.
    static func link(in text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace), text.contains("."), !text.hasSuffix("."),
              (try? SourceURL.normalize(text)) != nil else { return nil }
        return text
    }

    /// Google's results for the query, which the web row opens in the default browser.
    static func webSearchURL(_ query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#;")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://www.google.com/search?q=" + encoded)
    }

    /// The posts section's place: the one picked, else the first (in `DiscussionPlace.searched` order) with posts, else the
    /// first still loading, else Reddit.
    var shownPostPlace: DiscussionPlace {
        if let pickedPostPlace { return pickedPostPlace }
        let places = DiscussionPlace.searched
        return places.first { posts[$0]?.value?.isEmpty == false } ?? places.first { posts[$0]?.isLoading == true } ?? .reddit
    }

    func pickPostPlace(_ place: DiscussionPlace) { pickedPostPlace = place }

    /// Every place searched has answered with nothing (or failed), so the section has nothing to show.
    var postsAreEmpty: Bool {
        !posts.isEmpty && posts.values.allSatisfy { phase in
            switch phase {
            case .loaded(let found): found.isEmpty
            case .failed: true
            case .idle, .loading: false
            }
        }
    }

    // MARK: Searching

    /// Runs the three searches for `text` (trimmed), replacing the results. A blank query clears them.
    func search(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return clear() }
        cancelAll()
        generation += 1
        draft = q
        query = q
        openError = nil
        remember(q)
        pickedPostPlace = nil
        posts = [:]
        for section in [Part.videos, .episodes, .feeds] { load(section) }
        for place in DiscussionPlace.searched where place != .x || accounts.isSignedIn(.x) { load(.posts(place)) }
    }

    /// Searches one place's posts again (its Try Again, and X once the app has signed in to it).
    func retryPosts(_ place: DiscussionPlace) {
        guard !query.isEmpty else { return }
        load(.posts(place))
    }

    /// Runs one section again for the current query (its Try Again).
    func retryVideos() { load(.videos) }
    func retryEpisodes() { load(.episodes) }
    func retryFeeds() { load(.feeds) }

    func clear() {
        cancelAll()
        generation += 1
        query = ""
        videos = .idle
        episodes = .idle
        feeds = .idle
        posts = [:]
        pickedPostPlace = nil
        openError = nil
    }

    private func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }

    private func load(_ section: Part) {
        tasks[section]?.cancel()
        let q = query, gen = generation, explore = services.explore, search = services.search
        switch section {
        case .videos:
            videos = .loading
            tasks[section] = Task {
                let phase: ExplorePhase<ExploreVideoResults>
                do { phase = .loaded(try await explore.videos(q)) } catch { phase = .failed(HTTP.message(error)) }
                guard !Task.isCancelled, gen == generation else { return }
                videos = phase
            }
        case .episodes:
            episodes = .loading
            tasks[section] = Task {
                let phase: ExplorePhase<[ExploreEpisode]>
                do { phase = .loaded(try await explore.episodes(q)) } catch { phase = .failed(HTTP.message(error)) }
                guard !Task.isCancelled, gen == generation else { return }
                episodes = phase
            }
        case .feeds:
            feeds = .loading
            tasks[section] = Task {
                let phase: ExplorePhase<[SourceSearchResult]>
                do { phase = .loaded(try await search.search(q)) } catch { phase = .failed(HTTP.message(error)) }
                guard !Task.isCancelled, gen == generation else { return }
                feeds = phase
            }
        case .posts(let place):
            posts[place] = .loading
            let discussions = services.discussions
            tasks[section] = Task {
                let phase: ExplorePhase<[DiscussionPost]>
                do { phase = .loaded(try await discussions.search(place, query: q)) } catch { phase = .failed(HTTP.message(error)) }
                guard !Task.isCancelled, gen == generation else { return }
                posts[place] = phase
            }
        }
    }

    // MARK: Recent searches

    private func remember(_ q: String) {
        recents.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        recents.insert(q, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        saveRecents()
    }

    func removeRecent(_ q: String) {
        recents.removeAll { $0 == q }
        saveRecents()
    }

    func clearRecents() {
        recents = []
        saveRecents()
    }

    private func saveRecents() {
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }

    // MARK: Opening

    /// Stores a result as an opened video or episode, for the caller to show. Nil when another is already
    /// opening or it failed (`openError`).
    func open(_ target: ExploreTarget) async -> FeedItem? {
        await opening(target.id) {
            switch target {
            case .video(let video): try await services.openExploreVideo(video)
            case .episode(let episode): try await services.openExploreEpisode(episode)
            case .post(let post): try await services.openExplorePost(post)
            }
        }
    }

    /// Stores a typed web address as an opened link (the iPhone; the Mac's tab does this itself).
    func openLink(_ text: String) async -> FeedItem? {
        guard let url = try? SourceURL.normalize(text) else {
            openError = "Enter a web address, like example.com/article"
            return nil
        }
        return await opening(url) { try await services.openLink(url) }
    }

    /// A typed web address is opening (rather than a result).
    var isOpeningLink: Bool { opening?.hasPrefix("http") == true }

    func dismissOpenError() { openError = nil }

    private func opening(_ id: String, _ work: () async throws -> FeedItem) async -> FeedItem? {
        guard opening == nil else { return nil }
        opening = id
        openError = nil
        defer { opening = nil }
        do {
            return try await work()
        } catch {
            openError = HTTP.message(error)
            return nil
        }
    }
}
