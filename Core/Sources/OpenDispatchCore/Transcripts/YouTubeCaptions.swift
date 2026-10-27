import Foundation

/// A video's caption track as listed in YouTube's player response.
struct YouTubeCaptionTrack: Sendable, Hashable {
    var baseURL: String
    var languageCode: String
    /// Auto-generated (speech recognition) rather than uploaded by the creator.
    var isGenerated: Bool
}

/// YouTube captions. YouTube has no official caption API for third parties, so this uses the same unofficial
/// endpoints as the `youtube-transcript-api` Python library (the innertube player endpoint with the ANDROID client,
/// then the watch page): it may break whenever YouTube changes them. Failure to find captions returns nil.
enum YouTubeCaptions {
    static let playerURL = "https://www.youtube.com/youtubei/v1/player"
    static let watchURL = "https://www.youtube.com/watch?v="
    static let timeout: TimeInterval = 15

    // MARK: Fetching

    /// Captions for `videoID`: innertube first, then the watch page (which also yields the innertube API key and, failing
    /// that, an embedded player response). nil when no path finds a readable track; throws when no path got through
    /// because of a network error.
    static func transcript(videoID: String, language: String? = Locale.current.language.languageCode?.identifier,
                           session: URLSession = HTTP.session) async throws -> Transcript? {
        var lastError: (any Error)?
        func attempt(_ tracks: () async throws -> [YouTubeCaptionTrack]) async throws -> Transcript? {
            do {
                guard let track = choose(try await tracks(), language: language) else { return nil }
                let segments = try await fetchTrack(track, session: session)
                return segments.isEmpty ? nil : Transcript(origin: .youtubeCaptions, segments: segments)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                return nil
            }
        }

        if let t = try await attempt({ try await innertubeTracks(videoID: videoID, apiKey: nil, session: session) }) { return t }

        var page: String?
        do {
            let (data, res) = try await HTTP.fetchOK(watchURL + videoID, timeout: timeout, headers: pageHeaders, session: session)
            page = HTTP.text(data, response: res)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
        }
        guard let page else {
            if let lastError { throw lastError }
            return nil
        }

        if let key = innertubeKey(inWatchPage: page),
           let t = try await attempt({ try await innertubeTracks(videoID: videoID, apiKey: key, session: session) }) { return t }
        if let t = try await attempt({ tracks(inWatchPage: page) }) { return t }
        if let lastError { throw lastError }
        return nil
    }

    private static let pageHeaders = ["Accept": HTTP.htmlAccept, "Accept-Language": "en-US,en;q=0.9", "Cookie": "CONSENT=YES+1"]

    /// POST to the player endpoint as the Android client, which returns caption URLs without a proof-of-origin token.
    static func innertubeTracks(videoID: String, apiKey: String?, session: URLSession) async throws -> [YouTubeCaptionTrack] {
        let body: [String: Any] = [
            "context": ["client": ["clientName": "ANDROID", "clientVersion": "20.10.38"]],
            "videoId": videoID,
        ]
        let url = playerURL + (apiKey.map { "?key=\($0)" } ?? "")
        let (data, res) = try await HTTP.fetch(
            url, timeout: timeout, method: "POST",
            headers: ["Content-Type": "application/json", "User-Agent": "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"],
            body: try JSONSerialization.data(withJSONObject: body), session: session)
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return tracks(inPlayerResponse: json)
    }

    /// Fetches a track's captions as timedtext XML (any `fmt=` is dropped, which gives the plain `<text start= dur=>` form).
    static func fetchTrack(_ track: YouTubeCaptionTrack, session: URLSession) async throws -> [Transcript.Segment] {
        let url = track.baseURL.replacingOccurrences(of: #"&fmt=[^&]*"#, with: "", options: .regularExpression)
        let (data, res) = try await HTTP.fetchOK(url, timeout: timeout, headers: ["Accept-Language": "en-US,en;q=0.9"], session: session)
        return parseTimedText(HTTP.text(data, response: res))
    }

    // MARK: Reading the player response

    static func tracks(inPlayerResponse json: [String: Any]) -> [YouTubeCaptionTrack] {
        let renderer = (json["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any]
        return tracks(fromArray: renderer?["captionTracks"] as? [[String: Any]] ?? [])
    }

    /// The `"captionTracks":[…]` array embedded in the watch page's `ytInitialPlayerResponse`.
    static func tracks(inWatchPage html: String) -> [YouTubeCaptionTrack] {
        guard let key = html.range(of: #""captionTracks":"#), let open = html[key.upperBound...].firstIndex(of: "["),
              let close = matchingBracket(in: html, from: open),
              let data = String(html[open...close]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return tracks(fromArray: array)
    }

    static func innertubeKey(inWatchPage html: String) -> String? {
        FeedParsingSupport.firstGroup(#""INNERTUBE_API_KEY":\s*"([a-zA-Z0-9_-]+)""#, in: html)
    }

    private static func tracks(fromArray array: [[String: Any]]) -> [YouTubeCaptionTrack] {
        array.compactMap { t in
            // `exp=xpe` URLs need a proof-of-origin token we can't produce; they return an empty body.
            guard let url = t["baseUrl"] as? String, !url.contains("&exp=xpe") else { return nil }
            return YouTubeCaptionTrack(baseURL: url, languageCode: t["languageCode"] as? String ?? "", isGenerated: t["kind"] as? String == "asr")
        }
    }

    /// Index of the `]` closing the `[` at `open`, skipping brackets inside JSON strings.
    private static func matchingBracket(in s: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = open
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    // MARK: Choosing and parsing

    /// Creator-made captions in the user's language, then creator-made English, then auto-generated in the user's
    /// language, then whatever is left (creator-made before generated).
    static func choose(_ tracks: [YouTubeCaptionTrack], language: String?) -> YouTubeCaptionTrack? {
        let wanted = language.map(TranscriptParsing.primaryLanguage) ?? "en"
        func lang(_ t: YouTubeCaptionTrack, _ code: String) -> Bool { TranscriptParsing.primaryLanguage(t.languageCode) == code }
        return tracks.first { !$0.isGenerated && lang($0, wanted) }
            ?? tracks.first { !$0.isGenerated && lang($0, "en") }
            ?? tracks.first { $0.isGenerated && lang($0, wanted) }
            ?? tracks.first { !$0.isGenerated }
            ?? tracks.first
    }

    /// `<transcript><text start="1.2" dur="3.4">…</text>…`. The text is XML-escaped and, usually, HTML-escaped inside that
    /// (`&amp;#39;`), so entities are decoded twice, with any tags removed between.
    static func parseTimedText(_ xml: String) -> [Transcript.Segment] {
        guard let re = try? NSRegularExpression(pattern: #"<text\b([^>]*?)(?:/>|>([\s\S]*?)</text>)"#) else { return [] }
        let ns = xml as NSString
        return re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.range(at: 2).location != NSNotFound else { return nil }
            let attrs = ns.substring(with: m.range(at: 1))
            let once = FeedParsingSupport.decodeHTMLEntities(ns.substring(with: m.range(at: 2)))
            let stripped = once.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            guard let text = TranscriptParsing.clean(FeedParsingSupport.decodeHTMLEntities(stripped)) else { return nil }
            let start = FeedParsingSupport.firstGroup(#"\bstart="([^"]*)""#, in: attrs).flatMap(Double.init)
            return Transcript.Segment(start: start, text: text)
        }
    }
}
