import CryptoKit
import Foundation

/// SponsorBlock's public API (https://sponsor.ajay.app): crowd-sourced segments of YouTube videos. The lookup
/// sends only the first four hex digits of the video id's SHA-256, so the server never learns which video it is,
/// and the entry for the right video is picked from what comes back. Results (empty ones too) are kept in memory
/// for a day; a failure returns nothing and isn't kept, so the next ask tries again.
public actor DefaultSponsorBlock: SponsorBlockFetching {
    static let endpoint = "https://sponsor.ajay.app/api/skipSegments/"
    static let actionTypes = ["skip", "mute", "full", "poi"]
    static let timeout: TimeInterval = 8
    static let cacheLifetime: TimeInterval = 24 * 60 * 60

    private let session: URLSession
    private let now: @Sendable () -> Date
    private var cache: [String: (date: Date, segments: [SponsorBlockSegment])] = [:]
    private var inFlight: [String: Task<[SponsorBlockSegment]?, Never>] = [:]

    public init() {
        self.init(session: HTTP.session)
    }

    init(session: URLSession, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    public func segments(forVideoID videoID: String) async -> [SponsorBlockSegment] {
        guard Self.isVideoID(videoID) else { return [] }
        if let hit = cache[videoID], now().timeIntervalSince(hit.date) < Self.cacheLifetime { return hit.segments }
        let task = inFlight[videoID] ?? Task { [session] in await Self.fetch(videoID: videoID, session: session) }
        inFlight[videoID] = task
        let fetched = await task.value
        inFlight[videoID] = nil
        guard let fetched else { return [] }
        cache[videoID] = (now(), fetched)
        return fetched
    }

    /// YouTube ids are 11 characters of A-Z a-z 0-9 _ -.
    static func isVideoID(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D }
    }

    static func url(videoID: String) -> String {
        let prefix = SHA256.hash(data: Data(videoID.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
        func array(_ values: [String]) -> String {
            let json = "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
            return json.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? json
        }
        return endpoint + prefix + "?categories=" + array(SponsorBlockCategory.allCases.map(\.rawValue))
            + "&actionTypes=" + array(actionTypes) + "&service=YouTube"
    }

    /// nil on a failure (not kept); [] when the video has no segments (404, or no entry for it).
    static func fetch(videoID: String, session: URLSession) async -> [SponsorBlockSegment]? {
        guard let (data, res) = try? await HTTP.fetch(url(videoID: videoID), timeout: timeout, headers: ["Accept": "application/json"], session: session) else { return nil }
        if res.statusCode == 404 { return [] }
        guard (200..<300).contains(res.statusCode) else { return nil }
        return parse(data, videoID: videoID)
    }

    private struct Entry: Decodable {
        var videoID: String
        var segments: [Raw]
    }

    private struct Raw: Decodable {
        var segment: [Double]
        var category: String
        var actionType: String?
        var UUID: String?
        var videoDuration: Double?
    }

    /// The entry for `videoID` in the prefix lookup's answer; nil if the body isn't SponsorBlock's.
    static func parse(_ data: Data, videoID: String) -> [SponsorBlockSegment]? {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        guard let entry = entries.first(where: { $0.videoID == videoID }) else { return [] }
        return entry.segments.compactMap { raw in
            guard raw.segment.count == 2 else { return nil }
            return SponsorBlockSegment(
                start: raw.segment[0], end: raw.segment[1], category: raw.category, actionType: raw.actionType ?? "skip",
                uuid: raw.UUID ?? "", videoDuration: raw.videoDuration ?? 0)
        }
    }
}
