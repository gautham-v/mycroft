import Foundation

extension WebhookPayload {
    /// webhookPayload(item) in integrations.ts.
    public init(item: FeedItem) {
        let summary = TextFormat.stripHTML(item.item.summary)
        self.init(
            id: item.item.id,
            url: item.item.url,
            title: item.item.title,
            author: item.item.author,
            publishedAt: ISO8601.string(from: item.item.publishedAt),
            summary: summary.isEmpty ? nil : summary,
            source: SourceInfo(title: item.source.title, host: item.source.host)
        )
    }

    /// Sample payload for Settings' "Send a test" (testWebhookPayload).
    public static func test(now: Date = Date()) -> WebhookPayload {
        WebhookPayload(
            id: 0,
            url: "https://example.com/openfeed-test",
            title: "Test from Openfeed",
            author: nil,
            publishedAt: ISO8601.string(from: now),
            summary: "A sample payload sent from Settings \u{2192} Integrations.",
            source: SourceInfo(title: "OpenDispatch", host: "example.com"),
            test: true
        )
    }

    /// The JSON body the webhook receives, matching JSON.stringify in the web app: `author` and
    /// `summary` are always present (null when empty) and `test` appears only on the test payload.
    public func webhookJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return try enc.encode(WebhookWire(self))
    }
}

private struct WebhookWire: Encodable {
    let p: WebhookPayload
    init(_ p: WebhookPayload) { self.p = p }

    enum Keys: String, CodingKey { case id, url, title, author, published_at, summary, source, test }
    enum SourceKeys: String, CodingKey { case title, host }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(p.id, forKey: .id)
        try c.encode(p.url, forKey: .url)
        try c.encode(p.title, forKey: .title)
        try c.encode(p.author, forKey: .author)          // Optional encodes null
        try c.encode(p.publishedAt, forKey: .published_at)
        try c.encode(p.summary, forKey: .summary)
        var s = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
        try s.encode(p.source.title, forKey: .title)
        try s.encode(p.source.host, forKey: .host)
        try c.encodeIfPresent(p.test, forKey: .test)
    }
}
