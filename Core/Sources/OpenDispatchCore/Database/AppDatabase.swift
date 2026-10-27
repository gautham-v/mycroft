import Foundation
import GRDB

/// The local SQLite database (GRDB). One per app. Schema mirrors src/db/schema.ts in snake_case.
///
///     let db = try AppDatabase.openDefault()          // Application Support/OpenDispatch/openfeed.sqlite
///     let test = try AppDatabase.inMemory()           // tests: empty, unseeded
///     let page = try await db.items(ItemQuery(view: .all))
///
/// Async convenience methods live in AppDatabase+Queries.swift; the synchronous building blocks
/// (usable inside one `writer.write { db in ... }` transaction) are static functions on `Queries`.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader { writer }

    /// Runs migrations, then seeds (once per database; see Seed) when `seed` is true. The app starts
    /// empty; seeding is for tests and previews.
    public init(_ writer: any DatabaseWriter, seed: Bool = false) throws {
        self.writer = writer
        try AppDatabase.migrator.migrate(writer)
        if seed {
            try writer.write { db in try Seed.seedIfNeeded(db) }
        }
    }

    /// Configuration every connection uses: foreign keys on, and the `opendispatch_is_post(url)` SQL function.
    public static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.add(function: AppDatabase.isPostFunction)
        }
        return config
    }

    /// `opendispatch_is_post(url)` → 1 when the URL is a post source (X, Bluesky, Threads, Mastodon). See PostSource.
    public static let isPostFunction = DatabaseFunction("opendispatch_is_post", argumentCount: 1, pure: true) { values in
        guard let url = String.fromDatabaseValue(values[0]) else { return false }
        return PostSource.isPostURL(url)
    }

    /// Directory holding the database: Application Support/OpenDispatch (inside the sandbox container on macOS).
    public static func defaultDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("OpenDispatch", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Database file name in `defaultDirectory()`. Keeps the app's original name so existing databases open.
    public static let fileName = "openfeed.sqlite"

    /// The app's on-disk database (DatabasePool, WAL).
    public static func openDefault(seed: Bool = false) throws -> AppDatabase {
        let path = try defaultDirectory().appendingPathComponent(fileName).path
        return try open(path: path, seed: seed)
    }

    public static func open(path: String, seed: Bool = false) throws -> AppDatabase {
        let pool = try DatabasePool(path: path, configuration: makeConfiguration())
        return try AppDatabase(pool, seed: seed)
    }

    /// In-memory database for tests and previews. Unseeded by default.
    public static func inMemory(seed: Bool = false) throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: makeConfiguration()), seed: seed)
    }

    // MARK: Migrations

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE folders (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  title TEXT NOT NULL,
                  position INTEGER NOT NULL DEFAULT 0,
                  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE sources (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  title TEXT NOT NULL,
                  url TEXT NOT NULL,
                  feed_url TEXT NOT NULL UNIQUE,
                  kind TEXT NOT NULL CHECK (kind IN ('rss', 'youtube', 'page', 'podcast')),
                  "group" TEXT NOT NULL,
                  icon_url TEXT,
                  last_fetched_at DATETIME,
                  last_error TEXT,
                  seen_urls TEXT,
                  folder_id INTEGER REFERENCES folders(id) ON DELETE SET NULL,
                  position INTEGER NOT NULL DEFAULT 0,
                  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX sources_folder_idx ON sources(folder_id);
                CREATE TABLE items (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                  guid TEXT NOT NULL,
                  url TEXT NOT NULL,
                  title TEXT NOT NULL,
                  summary TEXT,
                  content_html TEXT,
                  content_rendered BOOLEAN NOT NULL DEFAULT 0,
                  author TEXT,
                  published_at DATETIME NOT NULL,
                  thumbnail_url TEXT,
                  thumbnail_checked BOOLEAN NOT NULL DEFAULT 0,
                  video_id TEXT,
                  duration_sec INTEGER,
                  audio_url TEXT,
                  hn_points INTEGER,
                  hn_comments INTEGER,
                  hn_comments_url TEXT,
                  is_saved BOOLEAN NOT NULL DEFAULT 0,
                  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE UNIQUE INDEX items_source_guid_uq ON items(source_id, guid);
                CREATE INDEX items_published_at_idx ON items(published_at DESC, id DESC);
                CREATE INDEX items_saved_idx ON items(is_saved) WHERE is_saved = 1;
                CREATE TABLE meta (
                  key TEXT PRIMARY KEY NOT NULL,
                  value TEXT NOT NULL
                );
                """)
        }
        // Sidebar curation: a pinned source lists under "Pinned" (ordered by pinned_at) and a hidden one is
        // left out of the tree. folder_id and position are untouched, so unpinning/unhiding restores it.
        m.registerMigration("v2-pin-hide-sources") { db in
            try db.execute(sql: """
                ALTER TABLE sources ADD COLUMN pinned_at DATETIME;
                ALTER TABLE sources ADD COLUMN is_hidden BOOLEAN NOT NULL DEFAULT 0;
                """)
        }
        // Quote posts on X show the quoted account's avatar in the list.
        m.registerMigration("v3-quote-avatar") { db in
            try db.execute(sql: "ALTER TABLE items ADD COLUMN quote_avatar_url TEXT")
        }
        // iCloud sync (SyncStore): per record, the hash both sides last agreed on and CloudKit's system
        // fields; sync_parked holds incoming saved items waiting for their source; sync_meta holds the
        // sync engine's state, apart from meta so saving it isn't a change.
        m.registerMigration("v4-sync") { db in
            try db.execute(sql: """
                CREATE TABLE sync_records (
                  record_name TEXT PRIMARY KEY NOT NULL,
                  record_type TEXT NOT NULL,
                  hash TEXT NOT NULL,
                  system_fields BLOB
                );
                CREATE TABLE sync_parked (
                  record_name TEXT PRIMARY KEY NOT NULL,
                  record_type TEXT NOT NULL,
                  fields TEXT NOT NULL,
                  system_fields BLOB
                );
                CREATE TABLE sync_meta (
                  key TEXT PRIMARY KEY NOT NULL,
                  value TEXT NOT NULL
                );
                """)
        }
        // Highlights and notes. A row holds what's needed to show it with no item (title, source, URL), so
        // highlights survive pruning and a deleted source and can be listed on a device that never had the
        // article. readwise_id says which Readwise highlight this is; readwise_pending and readwise_deletes
        // are what this device still has to send there.
        m.registerMigration("v5-highlights") { db in
            try db.execute(sql: """
                CREATE TABLE highlights (
                  id TEXT PRIMARY KEY NOT NULL,
                  source_feed_url TEXT NOT NULL,
                  item_guid TEXT NOT NULL,
                  item_url TEXT NOT NULL,
                  item_title TEXT NOT NULL,
                  source_title TEXT NOT NULL,
                  item_author TEXT,
                  item_published_at DATETIME,
                  text TEXT NOT NULL,
                  prefix TEXT NOT NULL DEFAULT '',
                  suffix TEXT NOT NULL DEFAULT '',
                  note TEXT,
                  color TEXT NOT NULL DEFAULT 'yellow' CHECK (color IN ('yellow', 'green', 'blue', 'pink', 'purple', 'underline')),
                  created_at DATETIME NOT NULL,
                  updated_at DATETIME NOT NULL,
                  readwise_id INTEGER,
                  readwise_pending BOOLEAN NOT NULL DEFAULT 0
                );
                CREATE INDEX highlights_item_idx ON highlights(source_feed_url, item_guid);
                CREATE TABLE readwise_deletes (
                  readwise_id INTEGER PRIMARY KEY NOT NULL
                );
                """)
        }
        return m
    }
}
