import Foundation

/// YouTube's own search (the innertube `search` endpoint the website uses, no key) and the iTunes Search API (episodes).
/// Both are unofficial in the sense that their answers aren't a promised format: the YouTube one in particular is walked for the
/// renderers it needs rather than decoded, so a reshuffled page still yields whatever videos are left in it.
public struct DefaultExploreSearch: ExploreSearching {
    /// GET when `body` is nil, otherwise a JSON POST.
    typealias Fetch = @Sendable (_ url: String, _ body: Data?) async throws -> (Data, HTTPURLResponse)

    static let timeout: TimeInterval = 8
    static let videoLimit = 20
    static let channelLimit = 5
    static let episodeLimit = 20
    /// Asked of iTunes; most of the answer is one show's episodes for a name query, which the per-show cap drops.
    static let episodeFetchLimit = 50
    static let searchURL = "https://www.youtube.com/youtubei/v1/search?prettyPrint=false"
    static let clientVersion = "2.20250101.00.00"

    let fetch: Fetch
    let language: String
    let region: String

    public init() {
        self.init(fetch: { url, body in
            var headers = ["Accept": "application/json"]
            if body != nil { headers["Content-Type"] = "application/json" }
            return try await HTTP.fetch(url, timeout: Self.timeout, method: body == nil ? "GET" : "POST", headers: headers, body: body)
        })
    }

    /// Tests inject a fake network. `language` and `region` are YouTube's `hl` and `gl`, and iTunes' store.
    init(fetch: @escaping Fetch, language: String = Locale.current.language.languageCode?.identifier ?? "en",
         region: String = Locale.current.region?.identifier ?? "US") {
        self.fetch = fetch
        self.language = language
        self.region = Self.isCountryCode(region) ? region.uppercased() : "US"
    }

    private static func isCountryCode(_ s: String) -> Bool { s.count == 2 && s.allSatisfy { $0.isASCII && $0.isLetter } }

    // MARK: Videos

    public func videos(_ query: String) async throws -> ExploreVideoResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ExploreVideoResults() }
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": Self.clientVersion, "hl": language, "gl": region]],
            "query": q,
        ]
        let (data, res) = try await fetch(Self.searchURL, try JSONSerialization.data(withJSONObject: body))
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        return try Self.results(inSearch: data)
    }

    /// The videos and channels in a search answer, in page order. Throws when the answer isn't JSON.
    static func results(inSearch data: Data) throws -> ExploreVideoResults {
        let json = try JSONSerialization.jsonObject(with: data)
        var videos: [ExploreVideo] = []
        var channels: [SourceSearchResult] = []
        var seenVideos: Set<String> = []
        var seenChannels: Set<String> = []
        walk(json) { renderer, node in
            switch renderer {
            case "videoRenderer":
                guard videos.count < videoLimit, let v = video(node), seenVideos.insert(v.id).inserted else { return }
                videos.append(v)
            case "channelRenderer":
                guard channels.count < channelLimit, let c = channel(node), seenChannels.insert(c.feedUrl).inserted else { return }
                channels.append(c)
            default:
                break
            }
        }
        return ExploreVideoResults(videos: videos, channels: channels)
    }

    /// Calls `visit` with the name and value of every `videoRenderer` and `channelRenderer` below `node`, in page order
    /// (a dictionary's keys sorted, which only matters for a dictionary holding several). A renderer's own children aren't searched.
    private static func walk(_ node: Any, _ visit: (_ renderer: String, _ node: [String: Any]) -> Void) {
        if let dict = node as? [String: Any] {
            for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                if key == "videoRenderer" || key == "channelRenderer", let inner = value as? [String: Any] {
                    visit(key, inner)
                } else {
                    walk(value, visit)
                }
            }
        } else if let array = node as? [Any] {
            for element in array { walk(element, visit) }
        }
    }

    /// A video result; nil for what can't be played in the reader: a live or upcoming stream (no length) and a Short.
    static func video(_ r: [String: Any]) -> ExploreVideo? {
        guard let id = r["videoId"] as? String, !id.isEmpty, let duration = text(r["lengthText"]),
              (r["navigationEndpoint"] as? [String: Any])?["reelWatchEndpoint"] == nil,
              let title = text(r["title"]) else { return nil }
        let owner = (r["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]]
        let browse = (owner?.first?["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
        return ExploreVideo(
            id: id, title: title, channel: owner?.first?["text"] as? String ?? text(r["ownerText"]) ?? "",
            channelID: browse?["browseId"] as? String, views: text(r["shortViewCountText"]) ?? text(r["viewCountText"]),
            published: text(r["publishedTimeText"]), duration: duration, thumbnailUrl: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
    }

    /// A channel result as a source to follow. The two count fields have come in both orders (the `@handle` in
    /// `subscriberCountText` and the subscribers in `videoCountText`, and the other way round), and with the
    /// words localized, so the handle is told by its `@` and the count by naming subscribers or by elimination.
    static func channel(_ r: [String: Any]) -> SourceSearchResult? {
        let browse = (r["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
        guard let id = (r["channelId"] as? String) ?? (browse?["browseId"] as? String), id.hasPrefix("UC"), id.count == 24,
              let title = text(r["title"]) else { return nil }
        let subs = text(r["subscriberCountText"])
        let fields = [subs, text(r["videoCountText"])].compactMap { $0 }
        let counts = fields.filter { !$0.hasPrefix("@") }
        let hasHandle = fields.count > counts.count
        let subscribers = counts.first { $0.localizedCaseInsensitiveContains("subscriber") }
            ?? (hasHandle ? counts.first : counts.first { $0 == subs })
        var avatar = ((r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?.last?["url"] as? String
        if let a = avatar, a.hasPrefix("//") { avatar = "https:" + a }
        return SourceSearchResult(
            title: title, subtitle: subscribers.map { "YouTube · \($0)" } ?? "YouTube", feedUrl: FeedDetection.youtubeFeedURL(channelID: id),
            siteUrl: "https://www.youtube.com/channel/\(id)", kind: .youtube, imageUrl: avatar)
    }

    /// A YouTube text object: `simpleText`, or `runs` joined. nil when empty.
    private static func text(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        let s: String
        if let simple = dict["simpleText"] as? String {
            s = simple
        } else if let runs = dict["runs"] as? [[String: Any]] {
            s = runs.compactMap { $0["text"] as? String }.joined()
        } else {
            return nil
        }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Episodes

    public func episodes(_ query: String) async throws -> [ExploreEpisode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            URLQueryItem(name: "media", value: "podcast"), URLQueryItem(name: "entity", value: "podcastEpisode"),
            URLQueryItem(name: "limit", value: String(Self.episodeFetchLimit)), URLQueryItem(name: "country", value: region),
            URLQueryItem(name: "term", value: q),
        ]
        let (data, res) = try await fetch(c.string!, nil)
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        return try ApplePodcastEpisode.exploreEpisodes(search: data, country: region.lowercased(), limit: Self.episodeLimit)
    }
}
