import Foundation

/// "Send to" destinations for an item.
public enum SendTarget: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case readwise, webhook
    public var id: String { rawValue }
    /// TARGET_LABEL in use-integrations.ts.
    public var label: String {
        switch self {
        case .readwise: "Readwise"
        case .webhook: "Webhook"
        }
    }
}

/// What Settings and the reader's Send button need to know (IntegrationsResponse). The token itself is never exposed.
public struct IntegrationsState: Sendable, Hashable {
    public var readwiseConfigured: Bool
    /// "…abcd" (last four characters) or nil.
    public var readwiseTokenHint: String?
    public var webhookURL: String?

    public init(readwiseConfigured: Bool = false, readwiseTokenHint: String? = nil, webhookURL: String? = nil) {
        self.readwiseConfigured = readwiseConfigured
        self.readwiseTokenHint = readwiseTokenHint
        self.webhookURL = webhookURL
    }

    public var webhookConfigured: Bool { webhookURL != nil }

    /// Targets with a saved configuration, in menu order (configuredTargets).
    public var configuredTargets: [SendTarget] {
        SendTarget.allCases.filter { t in
            switch t {
            case .readwise: readwiseConfigured
            case .webhook: webhookConfigured
            }
        }
    }
}

/// JSON a webhook receives for each sent item (`test: true` on the Settings test payload). snake_case on the wire.
public struct WebhookPayload: Codable, Sendable, Hashable {
    public struct SourceInfo: Codable, Sendable, Hashable {
        public var title: String
        public var host: String
        public init(title: String, host: String) {
            self.title = title
            self.host = host
        }
    }

    public var id: Int64
    public var url: String
    public var title: String
    public var author: String?
    /// ISO 8601.
    public var publishedAt: String
    public var summary: String?
    public var source: SourceInfo
    public var test: Bool?

    enum CodingKeys: String, CodingKey {
        case id, url, title, author, summary, source, test
        case publishedAt = "published_at"
    }

    public init(id: Int64, url: String, title: String, author: String?, publishedAt: String, summary: String?, source: SourceInfo, test: Bool? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.author = author
        self.publishedAt = publishedAt
        self.summary = summary
        self.source = source
        self.test = test
    }
}
