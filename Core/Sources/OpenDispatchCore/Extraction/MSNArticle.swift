import Foundation

/// MSN's article pages (msn.com/<locale>/…/ar-<id>) are drawn by script; the HTML is an empty shell. MSN's content
/// API returns the article as JSON: its HTML `body`, with each picture a reference (`<img data-document-id=…>`) into
/// `imageResources`. The reader shows that body with the pictures and their captions put back.
enum MSNArticle {
    private typealias DOM = ExtractionDOM
    private typealias P = ExtractionDOM.Pattern

    private static let articleURL = P("^https?://(?:www\\.)?msn\\.com/([a-z]{2}-[a-z]{2})/(?:[^?#]*/)?ar-([A-Za-z0-9]+)", caseInsensitive: true)
    private static let imageRef = P("<img\\b[^>]*\\bdata-document-id=\"([^\"]+)\"[^>]*>", caseInsensitive: true)

    /// The content API address for an MSN article page, or nil for any other address.
    static func apiURL(_ url: String) -> String? {
        guard let m = articleURL.firstMatch(url), let locale = m[1], let id = m[2] else { return nil }
        return "https://assets.msn.com/content/view/v2/Detail/\(locale.lowercased())/\(id)"
    }

    /// The article from the API's JSON, or nil when it isn't an article with a body.
    static func render(_ data: Data, pageURL: String) -> ExtractResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "article", let body = json["body"] as? String else { return nil }
        let images = (json["imageResources"] as? [[String: Any]]) ?? []
        var byID: [String: [String: Any]] = [:]
        for image in images { if let id = image["cmsId"] as? String { byID[id] = image } }
        let html = imageRef.replacing(body) { groups in
            guard let id = groups[1], let image = byID[id], let src = image["url"] as? String else { return "" }
            return figure(src: src, image: image)
        }
        let out = ArticleExtraction.extractFromFeedHTML(html, pageURL: pageURL)
        guard let content = out.contentHtml else { return nil }
        let lead = (images.first?["url"] as? String) ?? out.leadImage
        return ExtractResult(contentHtml: content, leadImage: lead)
    }

    /// A picture with its caption and credit.
    private static func figure(src: String, image: [String: Any]) -> String {
        let alt = DOM.squash((image["title"] as? String) ?? "")
        let caption = DOM.squash((image["caption"] as? String) ?? "")
        let credit = DOM.squash((image["attribution"] as? String) ?? "")
        var text = caption
        if !credit.isEmpty, !caption.localizedCaseInsensitiveContains(credit) { text += text.isEmpty ? credit : " (\(credit))" }
        let img = "<img src=\"\(DOM.escapeAttr(src))\" alt=\"\(DOM.escapeAttr(alt))\">"
        return text.isEmpty ? "<figure>\(img)</figure>" : "<figure>\(img)<figcaption>\(DOM.escapeHTML(text))</figcaption></figure>"
    }
}
