import Foundation

/// A video player that exists only in a page's RSC payload (port of `PayloadVideo`, payload-videos.ts).
public struct PayloadVideo: Sendable, Hashable {
    public var src: String
    /// The Vimeo/YouTube video id: what identifies this video in a page's HTML.
    public var key: String
    public var title: String?
    /// Texts that name it on the page: the player's alt text, the poster image's title.
    public var names: [String]
    /// The poster's file name, as it appears in a poster <img src>.
    public var posterFile: String?
    /// The last paragraph of text before the player in page order.
    public var anchor: String?

    public init(src: String, key: String, title: String? = nil, names: [String] = [], posterFile: String? = nil, anchor: String? = nil) {
        self.src = src
        self.key = key
        self.title = title
        self.names = names
        self.posterFile = posterFile
        self.anchor = anchor
    }
}

/// Video players mounted client-side (openai.com's Vimeo media items) may be missing from the server
/// HTML: the figure is an empty slot. Their props are in the RSC payload:
/// `{"altText":…,"videoEmbedUrl":"https://player.vimeo.com/…","videoEmbedTitle":…,"posterImage":{"title":…,"file":{"url":…}}}`.
/// Port of src/lib/payload-videos.ts.
public enum PayloadVideos {
    private static let embed = ScrapingText.regex(
        #"^https://(?:player\.vimeo\.com/video/|(?:www\.)?youtube(?:-nocookie)?\.com/embed/)([A-Za-z0-9_-]+)"#)

    /// findPayloadVideos(html).
    public static func find(in html: String) -> [PayloadVideo] {
        guard html.contains("videoEmbedUrl") else { return [] }
        let text = RSCPayload.bytes(RSCPayload.payload(html))
        var out: [PayloadVideo] = []
        for pos in markers(text) {
            guard let found = RSCPayload.enclosingObject(in: text, at: pos, accept: { $0["videoEmbedUrl"] is String }) else { continue }
            let o = found.value
            guard let src = ScrapingText.str(o["videoEmbedUrl"]),
                  let key = ScrapingText.firstGroups(embed, src)?[1] ?? nil,
                  !out.contains(where: { $0.key == key })
            else { continue }
            let poster = o["posterImage"] as? [String: Any] ?? [:]
            let file = poster["file"] as? [String: Any] ?? [:]
            let posterURL = ScrapingText.str(file["url"])
            let posterFile = ScrapingText.str(file["fileName"])
                ?? posterURL.map { $0.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? $0 }
            out.append(PayloadVideo(
                src: src,
                key: key,
                title: ScrapingText.str(o["videoEmbedTitle"]),
                names: [ScrapingText.str(o["altText"]), ScrapingText.str(poster["title"])].compactMap { $0 },
                posterFile: posterFile,
                anchor: RSCPayload.textBefore(text, found.start)
            ))
        }
        return out
    }

    /// Offsets of each `"videoEmbedUrl"\s*:\s*"` (the start of the key).
    private static func markers(_ text: [UInt8]) -> [Int] {
        let key = "\"videoEmbedUrl\""
        let space: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x0B]
        return RSCPayload.offsets(of: key, in: text).filter { start in
            var i = start + key.utf8.count
            while i < text.count, space.contains(text[i]) { i += 1 }
            guard i < text.count, text[i] == UInt8(ascii: ":") else { return false }
            i += 1
            while i < text.count, space.contains(text[i]) { i += 1 }
            return i < text.count && text[i] == UInt8(ascii: "\"")
        }
    }
}
