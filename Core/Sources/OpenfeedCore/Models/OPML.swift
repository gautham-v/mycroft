import Foundation

/// A feed as it appears in an OPML file. `kind` is only set by Openfeed's own exports (`openfeed:kind`).
public struct OPMLSource: Sendable, Hashable {
    public var title: String
    public var feedUrl: String
    public var htmlUrl: String?
    public var kind: SourceKind?

    public init(title: String, feedUrl: String, htmlUrl: String? = nil, kind: SourceKind? = nil) {
        self.title = title
        self.feedUrl = feedUrl
        self.htmlUrl = htmlUrl
        self.kind = kind
    }
}

public struct OPMLFolder: Sendable, Hashable {
    public var title: String
    public var sources: [OPMLSource]

    public init(title: String, sources: [OPMLSource]) {
        self.title = title
        self.sources = sources
    }
}

/// Port of `OpmlDoc` (src/lib/opml.ts).
public struct OPMLDocument: Sendable, Hashable {
    public var folders: [OPMLFolder]
    public var unfiled: [OPMLSource]

    public init(folders: [OPMLFolder] = [], unfiled: [OPMLSource] = []) {
        self.folders = folders
        self.unfiled = unfiled
    }
}

/// Port of `OpmlImportResult`.
public struct OPMLImportResult: Sendable, Hashable {
    public var added: Int
    /// Feeds already subscribed (or repeated in the file).
    public var skipped: Int
    public var foldersCreated: Int
    /// One line per outline that couldn't be imported.
    public var errors: [String]

    public init(added: Int = 0, skipped: Int = 0, foldersCreated: Int = 0, errors: [String] = []) {
        self.added = added
        self.skipped = skipped
        self.foldersCreated = foldersCreated
        self.errors = errors
    }
}
