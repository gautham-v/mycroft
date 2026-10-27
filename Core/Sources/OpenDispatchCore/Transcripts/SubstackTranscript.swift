import Foundation

/// Substack's own transcript of a podcast or video post (Lenny's Newsletter and other shows hosted on Substack).
/// Their feeds don't link it; the post's JSON (`<site>/api/v1/posts/<slug>`) carries signed links to a speaker-labelled
/// JSON transcript and a VTT caption file. An unofficial API, so it may change.
enum SubstackTranscript {
    static let timeout: TimeInterval = 20

    /// The episode is Substack's: its audio comes from substack.com (also behind a tracking redirect such as
    /// `pscrb.fm/rss/p/api.substack.com/...`), or the post is on a *.substack.com site.
    static func isSubstack(_ item: Item) -> Bool {
        func onSubstack(_ url: String?) -> Bool {
            guard let host = url.flatMap({ URLComponents(string: $0)?.host?.lowercased() }) else { return false }
            return host == "substack.com" || host.hasSuffix(".substack.com")
        }
        return onSubstack(item.audioUrl) || item.audioUrl?.contains("/api.substack.com/") == true || onSubstack(item.url)
    }

    /// `https://www.lennysnewsletter.com/p/some-post` → `https://www.lennysnewsletter.com/api/v1/posts/some-post`.
    static func postAPIURL(_ itemURL: String) -> String? {
        guard var c = URLComponents(string: itemURL), c.host != nil else { return nil }
        let parts = c.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "p" else { return nil }
        c.path = "/api/v1/posts/\(parts[1])"
        c.query = nil
        c.fragment = nil
        return c.string
    }

    static func transcript(for item: Item, session: URLSession) async throws -> Transcript? {
        guard let api = postAPIURL(item.url) else { return nil }
        let (data, _) = try await HTTP.fetchOK(api, timeout: timeout, headers: ["Accept": "application/json"], session: session)
        let links = transcriptLinks(postJSON: data)
        var lastError: (any Error)?
        for link in links {
            do {
                let (body, res) = try await HTTP.fetchOK(link.url, timeout: timeout, headers: ["Accept": "*/*"], session: session)
                let segments = segments(HTTP.text(body, response: res), link: link)
                if !segments.isEmpty { return Transcript(origin: .substack, segments: segments) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    struct Link: Equatable {
        var url: String
        var format: TranscriptFormat
        /// "SPEAKER_0" → "Rob Snyder".
        var speakers: [String: String] = [:]
    }

    /// The JSON transcript, then the captions, from the post's podcast upload (or video upload).
    static func transcriptLinks(postJSON data: Data) -> [Link] {
        guard let post = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var links: [Link] = []
        for key in ["podcastUpload", "videoUpload"] {
            guard let t = (post[key] as? [String: Any])?["transcription"] as? [String: Any] else { continue }
            let speakers = t["speaker_map"] as? [String: String] ?? [:]
            if let url = t["cdn_url"] as? String, !url.isEmpty { links.append(Link(url: url, format: .json, speakers: speakers)) }
            for caption in t["signed_captions"] as? [[String: Any]] ?? [] {
                if let url = caption["url"] as? String, !url.isEmpty { links.append(Link(url: url, format: .vtt)) }
            }
        }
        return links
    }

    /// Segments with their speaker labels resolved to names.
    static func segments(_ body: String, link: Link) -> [Transcript.Segment] {
        TranscriptParsing.segments(body, format: link.format).map { s in
            var s = s
            if let speaker = s.speaker { s.speaker = link.speakers[speaker] ?? speaker }
            return s
        }
    }
}
