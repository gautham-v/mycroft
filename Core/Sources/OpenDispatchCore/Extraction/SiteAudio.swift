import Foundation
import SwiftSoup

/// A story told as audio with its text beside it (NPR's segments: an audio module above the story, its file named in
/// `data-audio` JSON). The module is page chrome to the reader ("Download", an "Embed" iframe snippet, the segment's
/// title again); the extraction drops it and leads the content with a marker naming the file, and the reader plays
/// that file in its own player above the text.
public enum SiteAudio {
    private typealias DOM = ExtractionDOM

    public struct Audio: Equatable, Sendable {
        public var url: String
        public var duration: Int?
    }

    static let prefix = "<!--opendispatch:audio "
    /// A module holding more text than this is part of the story, not a player.
    static let maxModuleText = 400

    /// The audio a marked content leads with, or nil.
    public static func audio(in html: String?) -> Audio? {
        guard let html, html.hasPrefix(prefix), let end = html.range(of: "-->") else { return nil }
        let fields = html[html.index(html.startIndex, offsetBy: prefix.count)..<end.lowerBound].split(separator: " ")
        guard let field = fields.first, let data = Data(base64Encoded: String(field)),
              let url = String(data: data, encoding: .utf8) else { return nil }
        return Audio(url: url, duration: fields.dropFirst().first.flatMap { Int($0) })
    }

    /// The marker for `audio`, put before sanitized content (a comment, so anything that doesn't know it shows the
    /// text). The address is base64, which can't close the comment.
    static func marker(_ audio: Audio) -> String {
        prefix + Data(audio.url.utf8).base64EncodedString() + (audio.duration.map { " \($0)" } ?? "") + "-->"
    }

    /// Takes the page's audio modules out of `document` and returns the first playable one's file.
    static func take(_ document: Element) -> Audio? {
        var found: Audio?
        for el in DOM.select(document, "[data-audio]") where found == nil {
            guard let data = DOM.attr(el, "data-audio")?.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["available"] as? Bool) != false, let url = json["audioUrl"] as? String,
                  url.lowercased().hasPrefix("http") else { continue }
            found = Audio(url: url, duration: (json["duration"] as? NSNumber)?.intValue)
        }
        // NPR's module has no data-audio while the audio is "available later today".
        for el in DOM.select(document, "[data-audio], .audio-module") where DOM.isConnected(el) {
            // The module: the widest wrapper that is still only the player.
            var module: Element = el
            while let p = module.parent(), !(p is Document), !DOM.isTag(p, ["body", "html", "main"]),
                  DOM.textLen(DOM.text(p)) <= maxModuleText, DOM.select(p, "p").allSatisfy({ DOM.contains(module, $0) }) {
                module = p
            }
            DOM.remove(module)
        }
        return found ?? ArticlePasses.podcastAudio(document)
    }
}
