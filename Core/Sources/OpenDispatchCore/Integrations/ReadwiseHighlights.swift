import Foundation

/// Readwise's v2 highlights API (https://readwise.io/api_deets). Failures are thrown as `IntegrationError.send`
/// like the Reader requests; `retryable` ones (network, 429, 5xx) leave the work queued.
extension IntegrationRequests {
    public static let readwiseHighlightsURL = "https://readwise.io/api/v2/highlights/"
    public static let readwiseSourceType = "opendispatch"
    /// Readwise's limits: text and note 8191 characters, title 511, author 1024.
    static let readwiseTextLimit = 8191

    /// The unique URL Readwise wants for a single highlight: the article's URL with a fragment naming
    /// the highlight. Opening it opens the article.
    public static func readwiseHighlightURL(_ h: Highlight) -> String {
        let base = h.itemUrl.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? h.itemUrl
        return "\(base)#opendispatch-highlight-\(h.id)"
    }

    /// `POST /api/v2/highlights/` body for one highlight.
    public static func readwiseHighlightBody(_ h: Highlight) throws -> Data {
        var item: [String: String] = [
            "text": String(h.text.prefix(readwiseTextLimit)),
            "title": String(h.itemTitle.prefix(511)),
            "source_url": h.itemUrl,
            "source_type": readwiseSourceType,
            "category": "articles",
            "highlighted_at": ISO8601.string(from: h.createdAt),
            "highlight_url": readwiseHighlightURL(h),
        ]
        if let author = h.itemAuthor, !author.isEmpty { item["author"] = String(author.prefix(1024)) }
        if !h.note.isEmpty { item["note"] = String(h.note.prefix(readwiseTextLimit)) }
        return try JSONSerialization.data(withJSONObject: ["highlights": [item]], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Creates the highlight (or finds the identical one Readwise already has) and returns its Readwise id,
    /// read from `modified_highlights` in the response. nil when Readwise reports none.
    public static func createReadwiseHighlight(token: String, _ h: Highlight, session: URLSession = HTTP.session) async throws -> Int64? {
        let body = try readwiseHighlightBody(h)
        let (data, res) = try await perform("Readwise", session: session) {
            try await HTTP.fetch(readwiseHighlightsURL, timeout: readwiseTimeout, method: "POST",
                                 headers: ["Authorization": "Token \(token)", "Content-Type": "application/json"],
                                 body: body, session: session)
        }
        guard (200..<300).contains(res.statusCode) else { throw readwiseFailure(data, res) }
        return modifiedHighlightIDs(data).first
    }

    /// `PATCH /api/v2/highlights/<id>/` with the note and, when it has one, the color. Returns false when
    /// Readwise no longer has the highlight (404).
    public static func updateReadwiseHighlight(token: String, readwiseId: Int64, note: String?, color: HighlightColor?, session: URLSession = HTTP.session) async throws -> Bool {
        var fields: [String: String] = [:]
        if let note { fields["note"] = String(note.prefix(readwiseTextLimit)) }
        if let color = color?.readwiseColor { fields["color"] = color }
        guard !fields.isEmpty else { return true }
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let (data, res) = try await perform("Readwise", session: session) {
            try await HTTP.fetch("\(readwiseHighlightsURL)\(readwiseId)/", timeout: readwiseTimeout, method: "PATCH",
                                 headers: ["Authorization": "Token \(token)", "Content-Type": "application/json"],
                                 body: body, session: session)
        }
        if res.statusCode == 404 { return false }
        guard (200..<300).contains(res.statusCode) else { throw readwiseFailure(data, res) }
        return true
    }

    /// `DELETE /api/v2/highlights/<id>/`; already gone (404) counts as deleted.
    public static func deleteReadwiseHighlight(token: String, readwiseId: Int64, session: URLSession = HTTP.session) async throws {
        let (data, res) = try await perform("Readwise", session: session) {
            try await HTTP.fetch("\(readwiseHighlightsURL)\(readwiseId)/", timeout: readwiseTimeout, method: "DELETE",
                                 headers: ["Authorization": "Token \(token)"], session: session)
        }
        if (200..<300).contains(res.statusCode) || res.statusCode == 404 { return }
        throw readwiseFailure(data, res)
    }

    /// Every id in the `modified_highlights` lists of a create response (a list of books).
    static func modifiedHighlightIDs(_ data: Data) -> [Int64] {
        guard let books = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return books.flatMap { ($0["modified_highlights"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value } }
    }

    private static func readwiseFailure(_ data: Data, _ res: HTTPURLResponse) -> IntegrationError {
        let message: String
        switch res.statusCode {
        case 401: message = "Readwise rejected the token"
        case 429: message = "Readwise is rate limiting requests"
        default: message = upstreamError(data, response: res, label: "Readwise")
        }
        return .send(message: message, status: 502)
    }
}

/// Sends the highlights changed on this device to Readwise, one request each, and deletes the ones removed.
/// Nothing blocks on it: the app calls `send()` in a background task after a change, on launch and when
/// "Send highlights to Readwise" is turned on, and a failure leaves the work queued in the database
/// (`readwise_pending`, `readwise_deletes`) for the next call. Concurrent calls collapse into one run.
public actor ReadwiseHighlightSync {
    public struct Outcome: Sendable, Equatable {
        public var sent = 0
        public var deleted = 0
        /// Changes still queued after this run.
        public var remaining = 0
        /// The first error that stopped the run, for the sync status line.
        public var error: String?
    }

    let database: AppDatabase
    let tokenStore: any ReadwiseTokenStore
    let session: URLSession
    private var running = false
    private var again = false
    private var last = Outcome()

    public init(database: AppDatabase) {
        self.init(database: database, tokenStore: KeychainReadwiseTokenStore(), session: HTTP.session)
    }

    public init(database: AppDatabase, tokenStore: any ReadwiseTokenStore, session: URLSession = HTTP.session) {
        self.database = database
        self.tokenStore = tokenStore
        self.session = session
    }

    /// Changes waiting to be sent.
    public func pendingCount() async -> Int {
        (try? await database.reader.read { db in
            try Queries.pendingReadwiseHighlights(db).count + Queries.pendingReadwiseDeletes(db).count
        }) ?? 0
    }

    /// Drains the queue. A call made while a run is under way asks it to go round once more and returns
    /// the previous outcome.
    @discardableResult
    public func send() async -> Outcome {
        if running {
            again = true
            return last
        }
        running = true
        defer { running = false }
        repeat {
            again = false
            last = await drain()
        } while again && last.error == nil
        return last
    }

    private func drain() async -> Outcome {
        var out = Outcome()
        guard let token = (try? tokenStore.readToken()).flatMap({ $0 }), !token.isEmpty else {
            out.remaining = await pendingCount()
            return out
        }
        do {
            let deletes = try await database.reader.read { db in try Queries.pendingReadwiseDeletes(db) }
            for rid in deletes {
                try await IntegrationRequests.deleteReadwiseHighlight(token: token, readwiseId: rid, session: session)
                try await database.writer.write { db in try Queries.clearReadwiseDelete(db, readwiseId: rid) }
                out.deleted += 1
            }
            let pending = try await database.reader.read { db in try Queries.pendingReadwiseHighlights(db) }
            for h in pending {
                let id = try await push(h, token: token)
                try await database.writer.write { db in try Queries.markReadwiseSent(db, sent: h, readwiseId: id) }
                out.sent += 1
            }
        } catch {
            out.error = HTTP.message(error)
        }
        out.remaining = await pendingCount()
        return out
    }

    /// Creates or updates one highlight in Readwise and returns its Readwise id.
    private func push(_ h: Highlight, token: String) async throws -> Int64? {
        if let rid = h.readwiseId {
            if try await IntegrationRequests.updateReadwiseHighlight(token: token, readwiseId: rid, note: h.note, color: h.color, session: session) {
                return rid
            }
            // Deleted in Readwise since: make it again.
        }
        let created = try await IntegrationRequests.createReadwiseHighlight(token: token, h, session: session)
        if let created, h.color.readwiseColor != nil {
            // Create has no color field. Best effort: the highlight is already there if this fails.
            _ = try? await IntegrationRequests.updateReadwiseHighlight(token: token, readwiseId: created, note: nil, color: h.color, session: session)
        }
        return created
    }
}
