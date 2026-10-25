import Foundation

/// "Send to" Readwise Reader and a generic webhook (port of src/lib/integrations.ts, api/integrations,
/// api/integrations/test and api/items/[id]/send). The Readwise token lives in the Keychain and is only
/// ever exposed as a "…abcd" hint; the webhook URL lives in meta (`MetaKey.webhookURL`).
public struct DefaultIntegrationService: IntegrationService {
    let database: AppDatabase
    let tokenStore: any ReadwiseTokenStore
    let session: URLSession

    public init(database: AppDatabase) {
        self.init(database: database, tokenStore: KeychainReadwiseTokenStore(), session: HTTP.session)
    }

    /// Injectable token store and URL session (tests, previews).
    public init(database: AppDatabase, tokenStore: any ReadwiseTokenStore, session: URLSession = HTTP.session) {
        self.database = database
        self.tokenStore = tokenStore
        self.session = session
    }

    public func state() async throws -> IntegrationsState {
        let token = try await readwiseToken()
        let url = try await database.meta(MetaKey.webhookURL)
        return Self.state(token: token, webhookURL: url)
    }

    /// integrationsResponse: never the full token.
    static func state(token: String?, webhookURL: String?) -> IntegrationsState {
        let t = (token?.isEmpty ?? true) ? nil : token
        let u = (webhookURL?.isEmpty ?? true) ? nil : webhookURL
        return IntegrationsState(
            readwiseConfigured: t != nil,
            readwiseTokenHint: t.map { "\u{2026}\($0.suffix(4))" },
            webhookURL: u
        )
    }

    @discardableResult
    public func setReadwiseToken(_ token: String?) async throws -> IntegrationsState {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try tokenStore.writeToken(trimmed.isEmpty ? nil : trimmed)
        // Never leave a copy in the database.
        if try await database.meta(MetaKey.readwiseToken) != nil {
            try await database.setMeta(MetaKey.readwiseToken, nil)
        }
        return try await state()
    }

    @discardableResult
    public func setWebhookURL(_ url: String?) async throws -> IntegrationsState {
        let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty {
            try await database.setMeta(MetaKey.webhookURL, nil)
        } else {
            guard let parsed = IntegrationRequests.parseWebhookURL(raw) else { throw IntegrationError.invalidWebhookURL }
            try await database.setMeta(MetaKey.webhookURL, parsed)
        }
        return try await state()
    }

    public func send(_ item: FeedItem, to target: SendTarget) async throws {
        switch target {
        case .readwise:
            guard let token = try await readwiseToken() else { throw IntegrationError.notConfigured(.readwise) }
            try await IntegrationRequests.sendToReadwise(token: token, item: item, session: session)
        case .webhook:
            guard let url = try await webhookURL() else { throw IntegrationError.notConfigured(.webhook) }
            try await IntegrationRequests.sendToWebhook(url: url, payload: WebhookPayload(item: item), session: session)
        }
    }

    public func test(_ target: SendTarget) async throws {
        switch target {
        case .readwise:
            guard let token = try await readwiseToken() else { throw IntegrationError.notConfigured(.readwise) }
            try await IntegrationRequests.verifyReadwiseToken(token, session: session)
        case .webhook:
            guard let url = try await webhookURL() else { throw IntegrationError.notConfigured(.webhook) }
            try await IntegrationRequests.sendToWebhook(url: url, payload: .test(), session: session)
        }
    }

    // MARK: Storage

    /// The token from the Keychain. A token left in meta (the web app's storage) is moved to the store once.
    private func readwiseToken() async throws -> String? {
        if let t = try tokenStore.readToken(), !t.isEmpty { return t }
        guard let legacy = try await database.meta(MetaKey.readwiseToken), !legacy.isEmpty else { return nil }
        try tokenStore.writeToken(legacy)
        try await database.setMeta(MetaKey.readwiseToken, nil)
        return legacy
    }

    private func webhookURL() async throws -> String? {
        guard let u = try await database.meta(MetaKey.webhookURL), !u.isEmpty else { return nil }
        return u
    }
}
