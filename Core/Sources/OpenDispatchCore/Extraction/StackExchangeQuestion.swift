import Foundation

/// Stack Overflow (and the other Stack Exchange sites) answer a page fetch with a Cloudflare challenge, but the sites'
/// public API (api.stackexchange.com, no key, 300 calls a day per address) serves the question and its answers with
/// their HTML bodies. The reader shows the question, then the accepted answer and the top answers by votes, each under
/// a heading with its score and author; the answers' code blocks, quotes and pictures come as the site wrote them
/// (their own headings are set a level lower so they sit under the answer's).
enum StackExchangeQuestion {
    private typealias DOM = ExtractionDOM
    private typealias P = ExtractionDOM.Pattern

    static let api = "https://api.stackexchange.com/2.3"
    /// The accepted answer plus the best by votes.
    static let maxAnswers = 5
    private static let questionURL = P("^https?://([a-z0-9.-]+)/(?:questions|q)/(\\d+)(?:[/?#]|$)", caseInsensitive: true)

    /// The API's `site` parameter for a host: Stack Overflow, its siblings, and `<name>.stackexchange.com`.
    static func site(forHost host: String) -> String? {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        let suffix = ".stackexchange.com"
        if h.hasSuffix(suffix) {
            let name = String(h.dropLast(suffix.count))
            return name.isEmpty || name.contains(".") ? nil : name
        }
        switch h {
        case "stackoverflow.com": return "stackoverflow"
        case "superuser.com": return "superuser"
        case "serverfault.com": return "serverfault"
        case "askubuntu.com": return "askubuntu"
        case "stackapps.com": return "stackapps"
        case "mathoverflow.net": return "mathoverflow.net"
        default: return nil
        }
    }

    /// The API site and question id of a question page's address, or nil for any other address.
    static func question(_ url: String) -> (site: String, id: String)? {
        guard let m = questionURL.firstMatch(url), let host = m[1], let id = m[2], let site = site(forHost: host) else { return nil }
        return (site, id)
    }

    /// The question and its answers, or nil when the API doesn't have them (the page is then fetched as usual).
    static func extract(url: String, fetch: @escaping @Sendable (String) async throws -> Data) async -> ExtractResult? {
        guard let (site, id) = question(url) else { return nil }
        let base = "\(api)/questions/\(id)"
        async let questionData = try? fetch("\(base)?site=\(site)&filter=withbody")
        async let answersData = try? fetch("\(base)/answers?site=\(site)&filter=withbody&sort=votes&order=desc&pagesize=\(maxAnswers)")
        guard let qd = await questionData, let question = items(qd).first else { return nil }
        var answers = await answersData.map(items) ?? []
        // The accepted answer leads even when it isn't among the best by votes.
        if let accepted = question["accepted_answer_id"] as? Int, !answers.contains(where: { ($0["answer_id"] as? Int) == accepted }),
           let d = try? await fetch("\(api)/answers/\(accepted)?site=\(site)&filter=withbody"), let a = items(d).first {
            answers.append(a)
        }
        return render(question: question, answers: answers)
    }

    private static func items(_ data: Data) -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
    }

    static func render(question: [String: Any], answers: [[String: Any]]) -> ExtractResult? {
        guard let body = question["body"] as? String, !body.isEmpty else { return nil }
        let accepted = question["accepted_answer_id"] as? Int
        func score(_ a: [String: Any]) -> Int { (a["score"] as? Int) ?? 0 }
        func isAccepted(_ a: [String: Any]) -> Bool { accepted != nil && (a["answer_id"] as? Int) == accepted }
        let ordered = answers.enumerated().sorted { l, r in
            if isAccepted(l.element) != isAccepted(r.element) { return isAccepted(l.element) }
            return score(l.element) != score(r.element) ? score(l.element) > score(r.element) : l.offset < r.offset
        }.map(\.element).prefix(maxAnswers)

        var facts = ["\(votes(score(question)))"]
        if let count = question["answer_count"] as? Int { facts.append("\(count) answer\(count == 1 ? "" : "s")") }
        if let tags = question["tags"] as? [String], !tags.isEmpty { facts.append(tags.prefix(6).joined(separator: ", ")) }
        var html = "<p><small>\(DOM.escapeHTML(facts.joined(separator: " · ")))</small></p>" + body
        for answer in ordered {
            guard let text = answer["body"] as? String, !text.isEmpty else { continue }
            var byline = votes(score(answer))
            if let name = (answer["owner"] as? [String: Any])?["display_name"] as? String, !name.isEmpty { byline += " · " + decode(name) }
            html += "<h2>\(isAccepted(answer) ? "Accepted answer" : "Answer")</h2><p><small>\(DOM.escapeHTML(byline))</small></p>" + demoteHeadings(text)
        }
        return ExtractResult(contentHtml: ArticleSanitizer.sanitize(html).trimmingCharacters(in: .whitespacesAndNewlines), leadImage: nil)
    }

    private static func votes(_ n: Int) -> String {
        "\(n.formatted(.number.grouping(.automatic))) vote\(abs(n) == 1 ? "" : "s")"
    }

    /// Display names come HTML-escaped from the API.
    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// An answer's own headings sit under the "Answer" heading: h1 and h2 become h3, the rest one level lower.
    private static func demoteHeadings(_ html: String) -> String {
        DOM.withFragment(html) { body -> String in
            for h in DOM.select(body, "h1, h2, h3, h4, h5, h6") {
                let level = Int(DOM.tag(h).dropFirst()) ?? 3
                _ = try? h.tagName("h\(min(max(level, 2) + 1, 6))")
            }
            return DOM.innerHTML(body)
        } ?? html
    }
}
