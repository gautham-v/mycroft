import Foundation

/// Content-type views (src/lib/types.ts `View`). Named FeedView so it never collides with SwiftUI.View.
/// "articles" = everything that is not a video, podcast or post source.
public enum FeedView: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case all, saved, articles, posts, video, podcasts

    public var id: String { rawValue }

    /// Display title (VIEW_TITLES in openfeed-app.tsx).
    public var title: String {
        switch self {
        case .all: "All"
        case .saved: "Saved"
        case .articles: "Articles"
        case .posts: "Posts"
        case .video: "Video"
        case .podcasts: "Podcasts"
        }
    }

    /// Lenient parse; unknown values fall back to `.all` (queries.ts `parseView`).
    public init(parsing raw: String?) {
        self = raw.flatMap(FeedView.init(rawValue:)) ?? .all
    }
}

/// Legacy filters from SPEC.md (hn100 / labs / blogs). The current web UI no longer exposes them,
/// but ItemQuery still honors them: hn100 = hn_points >= 100, labs/blogs = source group.
public enum FeedFilter: String, Codable, Sendable, CaseIterable, Hashable {
    case hn100, labs, blogs
}
