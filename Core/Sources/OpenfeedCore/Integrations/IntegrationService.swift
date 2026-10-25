import Foundation

/// "Send to" Readwise Reader / webhook (port of src/lib/integrations.ts and the integrations routes).
/// Owner: Integrations agent. Implementation: `DefaultIntegrationService` in Integrations/DefaultIntegrationService.swift
/// (keep the type name and `init(database: AppDatabase)`). Store the Readwise token in the Keychain
/// (service "com.gauthamv.openfeed", account "readwise_token"); the webhook URL in meta (MetaKey.webhookURL).
public protocol IntegrationService: Sendable {
    func state() async throws -> IntegrationsState
    /// nil or "" clears. Returns the new state.
    @discardableResult func setReadwiseToken(_ token: String?) async throws -> IntegrationsState
    /// nil or "" clears; anything else must be an http(s) URL (parseWebhookUrl) or this throws a user-facing error.
    @discardableResult func setWebhookURL(_ url: String?) async throws -> IntegrationsState
    /// Send an item. Errors carry a user-facing localizedDescription.
    func send(_ item: FeedItem, to target: SendTarget) async throws
    /// Settings' test button: webhook gets a sample payload with test: true; Readwise only verifies the token.
    func test(_ target: SendTarget) async throws
}
