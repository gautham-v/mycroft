import Foundation

/// Errors from the "Send to" integrations. Messages match the web app's API errors
/// (src/lib/integrations.ts SendError and the integrations routes).
public enum IntegrationError: Error, LocalizedError, Equatable, Sendable {
    /// "Readwise is not set up" / "Webhook is not set up" (400 in the web app).
    case notConfigured(SendTarget)
    /// "Webhook URL must start with http:// or https://" (400).
    case invalidWebhookURL
    /// Upstream or network failure (SendError). `status` is the HTTP status the web route answered with:
    /// 504 for a timeout, 502 otherwise.
    case send(message: String, status: Int)
    /// The Readwise token could not be read from or written to the Keychain.
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let t): "\(t.label) is not set up"
        case .invalidWebhookURL: "Webhook URL must start with http:// or https://"
        case .send(let message, _): message
        case .keychain(let status): "Could not access the Keychain (\(status))"
        }
    }

    /// HTTP status the equivalent web route would answer with.
    public var status: Int {
        switch self {
        case .notConfigured, .invalidWebhookURL: 400
        case .send(_, let status): status
        case .keychain: 500
        }
    }
}
