import Foundation

/// Keys in the `meta` table.
public enum MetaKey {
    /// ISO 8601 time of the last refresh claim.
    public static let lastRefreshAt = "last_refresh_at"
    /// Built-in sources inserted (Seed). Present = never re-seed, so user removals stick.
    public static let seeded = "seeded"
    /// Default folders created and sources filed (Seed.seedFolders).
    public static let foldersSeeded = "folders_seeded"
    /// Integrations (web app stored these in meta; Integrations agent may move the token to the Keychain).
    public static let readwiseToken = "integration.readwise_token"
    public static let webhookURL = "integration.webhook_url"
}

/// Item retention (fetcher.ts): unsaved items older than this are pruned after each refresh,
/// and refreshes skip feed items already past it.
public enum Retention {
    public static let days = 14

    public static func cutoff(now: Date = Date()) -> Date {
        now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }
}

public enum QueryError: Error, LocalizedError, Equatable {
    case notFound(String)
    case emptyTitle
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): "\(what) not found"
        case .emptyTitle: "title is required"
        case .invalid(let msg): msg
        }
    }
}
