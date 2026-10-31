import Foundation

/// Whether YouTube lets a video play in another app. Some owners (the NFL's channels) allow their embeds only on sites they
/// approve, which the reader's player learns only by failing with error 150. YouTube's embed page says so ahead of time as
/// `previewPlayabilityStatus` (UNPLAYABLE or OK), asked for with the referrer the player sends. The watch page's `playableInEmbed`
/// and oEmbed say nothing about it. Undocumented, so an answer it can't read is nil and the player's own error stays the backstop.
public protocol YouTubeEmbedChecking: Sendable {
    /// false when the video won't play in this app, nil when it can't be told. About 140 KB a video.
    func isPlayable(videoID: String) async -> Bool?
    /// The same for the channel's newest video: owners set this per channel in practice (15 of 15 in the channels tried).
    func isPlayable(channelID: String) async -> Bool?
}

public struct DefaultYouTubeEmbedCheck: YouTubeEmbedChecking {
    /// GET when `body` is nil, otherwise a JSON POST.
    typealias Fetch = @Sendable (_ url: String, _ headers: [String: String], _ body: Data?) async throws -> (Data, HTTPURLResponse)

    static let timeout: TimeInterval = 8
    /// The origin the player's page presents (`ReaderYouTube.origin` in the app).
    static let referer = "https://com.gauthamv.openfeed/"

    let fetch: Fetch

    public init() {
        self.init(fetch: { url, headers, body in
            try await HTTP.fetch(url, timeout: Self.timeout, method: body == nil ? "GET" : "POST", headers: headers, body: body)
        })
    }

    /// Tests inject a fake network.
    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func isPlayable(videoID: String) async -> Bool? {
        var headers = HTTP.browserHeaders
        headers["Referer"] = Self.referer
        guard let (data, res) = try? await fetch("https://www.youtube-nocookie.com/embed/\(videoID)", headers, nil),
              (200..<300).contains(res.statusCode) else { return nil }
        return Self.isPlayable(embedPage: HTTP.text(data, response: res))
    }

    public func isPlayable(channelID: String) async -> Bool? {
        guard let id = await newestVideoID(channelID: channelID) else { return nil }
        return await isPlayable(videoID: id)
    }

    /// One of the channel's videos: the newest from its feed, or, as that feed fails often (404 or 500 for channels that exist), any from
    /// its page, a far larger answer. Owners set this per channel in practice, so any of its videos will do.
    private func newestVideoID(channelID: String) async -> String? {
        if let (data, res) = try? await fetch(FeedDetection.youtubeFeedURL(channelID: channelID), [:], nil), (200..<300).contains(res.statusCode),
           let id = Self.newestVideoID(inFeed: HTTP.text(data, response: res)) {
            return id
        }
        let request: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": DefaultExploreSearch.clientVersion, "hl": "en", "gl": "US"]],
            "browseId": channelID,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: request),
              let (data, res) = try? await fetch("https://www.youtube.com/youtubei/v1/browse?prettyPrint=false", ["Content-Type": "application/json"], body),
              (200..<300).contains(res.statusCode) else { return nil }
        return Self.videoID(inPage: HTTP.text(data, response: res))
    }

    private static let status = ExtractionDOM.Pattern(#"previewPlayabilityStatus\W+status\W+([A-Z_]+)"#)
    private static let videoID = ExtractionDOM.Pattern(#"<yt:videoId>([^<]+)</yt:videoId>"#)
    private static let pageVideoID = ExtractionDOM.Pattern(#""videoId":"([A-Za-z0-9_-]{11})""#)

    /// What an embed page says of its video; nil without a status it knows.
    static func isPlayable(embedPage html: String) -> Bool? {
        switch status.firstMatch(html)?[1] ?? nil {
        case "OK": true
        case "UNPLAYABLE": false
        default: nil
        }
    }

    static func newestVideoID(inFeed xml: String) -> String? {
        videoID.firstMatch(xml)?[1] ?? nil
    }

    static func videoID(inPage json: String) -> String? {
        pageVideoID.firstMatch(json)?[1] ?? nil
    }
}
