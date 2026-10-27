import Foundation

/// The HTTP side of the integrations (sendToReadwise, verifyReadwiseToken, sendToWebhook in integrations.ts).
/// Every failure is thrown as `IntegrationError.send` with the web app's message.
public enum IntegrationRequests {
    public static let readwiseSaveURL = "https://readwise.io/api/v3/save/"
    /// Answers 204 for a valid token and 401 otherwise; Settings' test uses it so it saves nothing.
    public static let readwiseAuthURL = "https://readwise.io/api/v2/auth/"
    public static let readwiseTimeout: TimeInterval = 15
    public static let webhookTimeout: TimeInterval = 10

    /// JSON body for Readwise Reader's save endpoint.
    public static func readwiseBody(_ item: FeedItem) throws -> Data {
        let summary = String(TextFormat.stripHTML(item.item.summary).prefix(1000))
        var body: [String: String] = [
            "url": item.item.url,
            "title": item.item.title,
            "published_date": ISO8601.string(from: item.item.publishedAt),
            "saved_using": "opendispatch",
        ]
        if let author = item.item.author, !author.isEmpty { body["author"] = author }
        if !summary.isEmpty { body["summary"] = summary }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public static func sendToReadwise(token: String, item: FeedItem, session: URLSession = HTTP.session) async throws {
        let body = try readwiseBody(item)
        let (data, res) = try await perform("Readwise", session: session) {
            try await HTTP.fetch(readwiseSaveURL, timeout: readwiseTimeout, method: "POST",
                                 headers: ["Authorization": "Token \(token)", "Content-Type": "application/json"],
                                 body: body, session: session)
        }
        // 201 = saved, 200 = already in the library.
        if res.statusCode == 200 || res.statusCode == 201 { return }
        throw IntegrationError.send(message: upstreamError(data, response: res, label: "Readwise"), status: 502)
    }

    public static func verifyReadwiseToken(_ token: String, session: URLSession = HTTP.session) async throws {
        let (data, res) = try await perform("Readwise", session: session) {
            try await HTTP.fetch(readwiseAuthURL, timeout: readwiseTimeout,
                                 headers: ["Authorization": "Token \(token)"], session: session)
        }
        if (200..<300).contains(res.statusCode) { return }
        if res.statusCode == 401 { throw IntegrationError.send(message: "Readwise rejected the token", status: 502) }
        throw IntegrationError.send(message: upstreamError(data, response: res, label: "Readwise"), status: 502)
    }

    public static func sendToWebhook(url: String, payload: WebhookPayload, session: URLSession = HTTP.session) async throws {
        let body = try payload.webhookJSON()
        let (data, res) = try await perform("Webhook", session: session) {
            try await HTTP.fetch(url, timeout: webhookTimeout, method: "POST",
                                 headers: ["Content-Type": "application/json"], body: body, session: session)
        }
        if (200..<300).contains(res.statusCode) { return }
        throw IntegrationError.send(message: upstreamError(data, response: res, label: "Webhook"), status: 502)
    }

    /// Upstream error text: JSON `detail` (Readwise/DRF style), `error`, flattened field errors, or a
    /// short non-HTML body. "<Label> returned <status>[: detail]".
    public static func upstreamError(_ data: Data, response: HTTPURLResponse, label: String) -> String {
        let text = HTTP.text(data, response: response).trimmingCharacters(in: .whitespacesAndNewlines)
        var detail = ""
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
            if let o = json as? [String: Any] {
                if let d = o["detail"] as? String {
                    detail = d
                } else if let e = o["error"] as? String {
                    detail = e
                } else {
                    detail = o.keys.sorted().map { k in
                        let v = o[k]
                        let s: String
                        if let arr = v as? [Any] { s = arr.map(jsString).joined(separator: " ") } else { s = jsString(v) }
                        return "\(k): \(s)"
                    }.joined(separator: "; ")
                }
            }
        } else {
            // Not JSON: use the body unless it is an HTML error page.
            detail = text.hasPrefix("<") ? "" : text
        }
        detail = String(detail.prefix(200))
        return "\(label) returned \(response.statusCode)\(detail.isEmpty ? "" : ": \(detail)")"
    }

    /// Roughly JavaScript's String(v) for JSON values.
    private static func jsString(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull: return "null"
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let a as [Any]: return a.map(jsString).joined(separator: ",")
        default: return "[object Object]"
        }
    }

    /// Wraps a network failure (timeout, DNS, refused, bad URL) as a 504/502 send error.
    static func perform(
        _ label: String, session: URLSession, _ op: () async throws -> (Data, HTTPURLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await op()
        } catch let e as IntegrationError {
            throw e
        } catch {
            let msg = HTTP.message(error)
            throw IntegrationError.send(message: "\(label): \(msg)", status: msg == "Timed out" ? 504 : 502)
        }
    }

    /// Normalised http(s) URL, or nil when the input is not one (parseWebhookUrl).
    public static func parseWebhookURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: trimmed),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty
        else { return nil }
        c.scheme = scheme
        c.host = host.lowercased()
        if c.path.isEmpty { c.path = "/" }
        if (scheme == "http" && c.port == 80) || (scheme == "https" && c.port == 443) { c.port = nil }
        return c.string
    }
}
