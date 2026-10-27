import Foundation
import GRDB

/// The database side of iCloud sync, with no CloudKit in it (CloudSync drives it).
///
/// Sync works by diffing, not by hooking every write: `localRecords` reads what should be in iCloud
/// from the tables, and `sync_records` (the "shadow") holds, per record, the hash both sides last
/// agreed on plus CloudKit's system fields. A local record whose hash differs from its shadow is
/// uploaded; a shadow with no local record is deleted from iCloud. Incoming records are applied to
/// the tables and their shadow is set to the incoming hash, so they are not sent back.
public enum SyncStore {

    // MARK: Local records

    /// Every record this device would put in iCloud, by record name. `readwiseToken` comes from the
    /// Keychain (read it before opening the transaction).
    public static func localRecords(_ db: Database, readwiseToken: String?) throws -> [String: SyncRecord] {
        var out: [String: SyncRecord] = [:]
        func add(_ r: SyncRecord) { if out[r.name] == nil { out[r.name] = r } }

        let folders = try Queries.folders(db)
        var folderTitles: [Int64: String] = [:]
        for f in folders {
            folderTitles[f.id] = f.title
            add(folderRecord(f))
        }
        for s in try Queries.sources(db) {
            add(sourceRecord(s, folderTitle: s.folderId.flatMap { folderTitles[$0] }))
        }
        for (item, feedUrl) in try savedItems(db) {
            add(savedItemRecord(item, sourceFeedUrl: feedUrl))
        }
        for h in try Highlight.fetchAll(db) {
            add(highlightRecord(h))
        }
        if let json = try Queries.meta(db, MetaKey.syncedSettings) {
            add(SyncRecord(type: .settings, name: SyncRecord.settingsName, fields: ["json": .string(json)]))
        }
        var integrations: [String: SyncField] = [:]
        if let url = try Queries.meta(db, MetaKey.webhookURL) { integrations["webhookURL"] = .string(url) }
        if let token = readwiseToken, !token.isEmpty { integrations["readwiseToken"] = .secret(token) }
        if !integrations.isEmpty {
            integrations["hasReadwiseToken"] = .bool(integrations["readwiseToken"] != nil)
            add(SyncRecord(type: .integrations, name: SyncRecord.integrationsName, fields: integrations))
        }
        return out
    }

    static func folderRecord(_ f: Folder) -> SyncRecord {
        SyncRecord(type: .folder, name: SyncRecord.folderName(title: f.title), fields: [
            "title": .string(f.title),
            "position": .int(Int64(f.position)),
        ])
    }

    static func sourceRecord(_ s: Source, folderTitle: String?) -> SyncRecord {
        var fields: [String: SyncField] = [
            "feedUrl": .string(s.feedUrl),
            "title": .string(s.title),
            "url": .string(s.url),
            "kind": .string(s.kind.rawValue),
            "group": .string(s.group),
            "position": .int(Int64(s.position)),
            "isHidden": .bool(s.isHidden),
            "createdAt": .date(s.createdAt),
        ]
        if let folderTitle { fields["folder"] = .string(folderTitle) }
        if let pinned = s.pinnedAt { fields["pinnedAt"] = .date(pinned) }
        if let icon = s.iconUrl { fields["iconUrl"] = .string(icon) }
        return SyncRecord(type: .source, name: SyncRecord.sourceName(feedUrl: s.feedUrl), fields: fields)
    }

    static func savedItemRecord(_ it: Item, sourceFeedUrl: String) -> SyncRecord {
        var fields: [String: SyncField] = [
            "sourceFeedUrl": .string(sourceFeedUrl),
            "guid": .string(it.guid),
            "url": .string(it.url),
            "title": .string(it.title),
            "publishedAt": .date(it.publishedAt),
        ]
        if let v = it.summary { fields["summary"] = .string(v) }
        if let v = it.author { fields["author"] = .string(v) }
        if let v = it.thumbnailUrl { fields["thumbnailUrl"] = .string(v) }
        if let v = it.videoId { fields["videoId"] = .string(v) }
        if let v = it.durationSec { fields["durationSec"] = .int(Int64(v)) }
        if let v = it.audioUrl { fields["audioUrl"] = .string(v) }
        return SyncRecord(type: .savedItem, name: SyncRecord.savedItemName(sourceFeedUrl: sourceFeedUrl, guid: it.guid), fields: fields)
    }

    static func highlightRecord(_ h: Highlight) -> SyncRecord {
        var fields: [String: SyncField] = [
            "sourceFeedUrl": .string(h.sourceFeedUrl),
            "itemGuid": .string(h.itemGuid),
            "itemUrl": .string(h.itemUrl),
            "itemTitle": .string(h.itemTitle),
            "sourceTitle": .string(h.sourceTitle),
            "text": .string(h.text),
            "color": .string(h.color.rawValue),
            "createdAt": .date(h.createdAt),
            "updatedAt": .date(h.updatedAt),
        ]
        if let v = h.itemAuthor { fields["itemAuthor"] = .string(v) }
        if let v = h.itemPublishedAt { fields["itemPublishedAt"] = .date(v) }
        if !h.prefix.isEmpty { fields["prefix"] = .string(h.prefix) }
        if !h.suffix.isEmpty { fields["suffix"] = .string(h.suffix) }
        if !h.note.isEmpty { fields["note"] = .string(h.note) }
        if let v = h.readwiseId { fields["readwiseId"] = .int(v) }
        return SyncRecord(type: .highlight, name: SyncRecord.highlightName(id: h.id), fields: fields)
    }

    /// Saved items with their source's feed URL.
    private static func savedItems(_ db: Database) throws -> [(Item, String)] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.*, s.feed_url AS source_feed_url FROM items i JOIN sources s ON s.id = i.source_id
            WHERE i.is_saved = 1 ORDER BY i.id
            """)
        return try rows.map { (try Item(row: $0), $0["source_feed_url"]) }
    }

    // MARK: Shadow (sync_records)

    public struct Shadow: Sendable, Hashable {
        public var name: String
        public var type: SyncRecordType
        /// SyncRecord.hash of the copy both sides last agreed on.
        public var hash: String
        /// CKRecord.encodeSystemFields output: the server's change tag, so the next save is a
        /// modification of that version instead of a conflicting create.
        public var systemFields: Data?
    }

    public static func shadows(_ db: Database) throws -> [String: Shadow] {
        var out: [String: Shadow] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT record_name, record_type, hash, system_fields FROM sync_records") {
            guard let type = SyncRecordType(rawValue: row["record_type"]) else { continue }
            let name: String = row["record_name"]
            out[name] = Shadow(name: name, type: type, hash: row["hash"], systemFields: row["system_fields"])
        }
        return out
    }

    public static func shadow(_ db: Database, name: String) throws -> Shadow? {
        guard let row = try Row.fetchOne(db, sql: "SELECT record_name, record_type, hash, system_fields FROM sync_records WHERE record_name = ?", arguments: [name]),
              let type = SyncRecordType(rawValue: row["record_type"]) else { return nil }
        return Shadow(name: name, type: type, hash: row["hash"], systemFields: row["system_fields"])
    }

    public static func setShadow(_ db: Database, _ s: Shadow) throws {
        try db.execute(sql: """
            INSERT INTO sync_records (record_name, record_type, hash, system_fields) VALUES (?, ?, ?, ?)
            ON CONFLICT(record_name) DO UPDATE SET record_type = excluded.record_type, hash = excluded.hash, system_fields = excluded.system_fields
            """, arguments: [s.name, s.type.rawValue, s.hash, s.systemFields])
    }

    public static func removeShadow(_ db: Database, name: String) throws {
        try db.execute(sql: "DELETE FROM sync_records WHERE record_name = ?", arguments: [name])
    }

    /// Forget everything about iCloud (sign-out, account switch, the zone was deleted). Local data stays.
    public static func reset(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM sync_records")
        try db.execute(sql: "DELETE FROM sync_parked")
        try db.execute(sql: "DELETE FROM sync_meta")
    }

    // MARK: Diff

    public struct Changes: Sendable, Equatable {
        public var saves: [String] = []
        public var deletes: [String] = []
        public var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }
    }

    /// Records to upload (new or changed since the shadow) and to delete (shadowed, gone locally).
    public static func diff(local: [String: SyncRecord], shadows: [String: Shadow]) -> Changes {
        var c = Changes()
        for (name, r) in local where shadows[name]?.hash != r.hash { c.saves.append(name) }
        for name in shadows.keys where local[name] == nil { c.deletes.append(name) }
        c.saves.sort()
        c.deletes.sort()
        return c
    }

    // MARK: Applying incoming changes

    public struct Incoming: Sendable {
        public var record: SyncRecord
        public var systemFields: Data?
        public init(record: SyncRecord, systemFields: Data?) {
            self.record = record
            self.systemFields = systemFields
        }
    }

    public struct IncomingDeletion: Sendable, Hashable {
        public var name: String
        public var type: SyncRecordType
        public init(name: String, type: SyncRecordType) {
            self.name = name
            self.type = type
        }
    }

    /// What applying changed, for the app to react to.
    public struct ApplyResult: Sendable, Equatable {
        /// Sources, folders or saved items changed (reload the sidebar and list).
        public var libraryChanged = false
        /// Sources inserted from iCloud; they have no items until fetched.
        public var addedSourceIDs: [Int64] = []
        /// Highlights were added, changed or removed (reload the reader's highlights and the Highlights view).
        public var highlightsChanged = false
        /// New settings JSON from iCloud.
        public var settingsJSON: String?
        /// Webhook URL or Readwise token changed.
        public var integrationsChanged = false
        /// Write this to the token store: .some(nil) clears it, nil leaves it alone.
        public var readwiseToken: String??

        public init() {}
    }

    /// Apply records and deletions from iCloud in one transaction: modifications first (folders, then
    /// sources, then saved items), then deletions, so a renamed folder's sources move before the old
    /// folder goes. Sets or removes each shadow.
    ///
    /// A saved item whose source isn't here yet is parked in `sync_parked` (CloudKit can deliver it in
    /// an earlier batch than its source, and won't deliver it again) and retried after every apply.
    public static func apply(_ db: Database, modifications: [Incoming], deletions: [IncomingDeletion], now: Date = Date()) throws -> ApplyResult {
        var result = ApplyResult()
        for inc in modifications.sorted(by: { $0.record.type.applyOrder < $1.record.type.applyOrder }) {
            let r = inc.record
            if try applyRecord(db, r, now: now, into: &result) {
                try setShadow(db, Shadow(name: r.name, type: r.type, hash: r.hash, systemFields: inc.systemFields))
                try db.execute(sql: "DELETE FROM sync_parked WHERE record_name = ?", arguments: [r.name])
            } else if r.type == .savedItem {
                try park(db, inc)
            }
        }
        for d in deletions.sorted(by: { $0.type.applyOrder > $1.type.applyOrder }) {
            try applyDeletion(db, d, into: &result)
            try removeShadow(db, name: d.name)
            try db.execute(sql: "DELETE FROM sync_parked WHERE record_name = ?", arguments: [d.name])
        }
        try retryParked(db, now: now, into: &result)
        return result
    }

    private static func park(_ db: Database, _ inc: Incoming) throws {
        let json = String(data: try JSONEncoder().encode(inc.record.fields), encoding: .utf8) ?? "{}"
        try db.execute(sql: """
            INSERT INTO sync_parked (record_name, record_type, fields, system_fields) VALUES (?, ?, ?, ?)
            ON CONFLICT(record_name) DO UPDATE SET record_type = excluded.record_type, fields = excluded.fields, system_fields = excluded.system_fields
            """, arguments: [inc.record.name, inc.record.type.rawValue, json, inc.systemFields])
    }

    private static func retryParked(_ db: Database, now: Date, into result: inout ApplyResult) throws {
        for row in try Row.fetchAll(db, sql: "SELECT record_name, record_type, fields, system_fields FROM sync_parked") {
            let name: String = row["record_name"]
            guard let type = SyncRecordType(rawValue: row["record_type"]),
                  let fields = try? JSONDecoder().decode([String: SyncField].self, from: Data((row["fields"] as String).utf8)) else {
                try db.execute(sql: "DELETE FROM sync_parked WHERE record_name = ?", arguments: [name])
                continue
            }
            let r = SyncRecord(type: type, name: name, fields: fields)
            guard try applyRecord(db, r, now: now, into: &result) else { continue }
            try setShadow(db, Shadow(name: name, type: type, hash: r.hash, systemFields: row["system_fields"]))
            try db.execute(sql: "DELETE FROM sync_parked WHERE record_name = ?", arguments: [name])
        }
    }

    /// False when the record can't be applied here yet (a saved item whose source this device doesn't
    /// have); it gets no shadow, so it is neither uploaded nor deleted from here.
    private static func applyRecord(_ db: Database, _ r: SyncRecord, now: Date, into result: inout ApplyResult) throws -> Bool {
        switch r.type {
        case .folder:
            guard let title = r["title"]?.stringValue else { return false }
            let position = Int(r["position"]?.intValue ?? 0)
            if var f = try folder(db, titled: title) {
                if f.title != title || f.position != position {
                    f.title = title
                    f.position = position
                    try f.update(db)
                    result.libraryChanged = true
                }
            } else {
                var f = Folder(title: title, position: position, createdAt: now)
                try f.insert(db)
                result.libraryChanged = true
            }
            return true

        case .source:
            guard let feedUrl = r["feedUrl"]?.stringValue else { return false }
            let folderId = try r["folder"]?.stringValue.map { try folderID(db, titled: $0, now: now, into: &result) }
            let title = r["title"]?.stringValue ?? feedUrl
            let position = Int(r["position"]?.intValue ?? 0)
            let pinnedAt = r["pinnedAt"]?.dateValue
            let isHidden = r["isHidden"]?.boolValue ?? false
            if var s = try Queries.source(db, feedUrl: feedUrl) {
                let before = s
                s.title = title
                s.folderId = folderId
                s.position = position
                s.pinnedAt = pinnedAt
                s.isHidden = isHidden
                if s != before {
                    try s.update(db)
                    result.libraryChanged = true
                }
            } else {
                var s = Source(
                    title: title, url: r["url"]?.stringValue ?? feedUrl, feedUrl: feedUrl,
                    kind: r["kind"]?.stringValue.flatMap(SourceKind.init(rawValue:)) ?? .rss,
                    group: r["group"]?.stringValue ?? SourceGroup.blogs, iconUrl: r["iconUrl"]?.stringValue,
                    folderId: folderId, position: position, createdAt: r["createdAt"]?.dateValue ?? now,
                    pinnedAt: pinnedAt, isHidden: isHidden)
                try s.insert(db)
                result.libraryChanged = true
                result.addedSourceIDs.append(s.id)
            }
            return true

        case .savedItem:
            guard let feedUrl = r["sourceFeedUrl"]?.stringValue, let guid = r["guid"]?.stringValue,
                  let source = try Queries.sourceCreatingOpenedLinks(db, feedUrl: feedUrl, now: now) else { return false }
            if let id = try Int64.fetchOne(db, sql: "SELECT id FROM items WHERE source_id = ? AND guid = ?", arguments: [source.id, guid]) {
                try db.execute(sql: "UPDATE items SET is_saved = 1 WHERE id = ? AND is_saved = 0", arguments: [id])
                if db.changesCount > 0 { result.libraryChanged = true }
            } else {
                var it = Item(
                    sourceId: source.id, guid: guid, url: r["url"]?.stringValue ?? "", title: r["title"]?.stringValue ?? "",
                    summary: r["summary"]?.stringValue, author: r["author"]?.stringValue,
                    publishedAt: r["publishedAt"]?.dateValue ?? now, thumbnailUrl: r["thumbnailUrl"]?.stringValue,
                    videoId: r["videoId"]?.stringValue, durationSec: r["durationSec"]?.intValue.map(Int.init),
                    audioUrl: r["audioUrl"]?.stringValue, isSaved: true, createdAt: now)
                try it.insert(db)
                result.libraryChanged = true
            }
            return true

        case .highlight:
            guard r.name.hasPrefix(SyncRecord.highlightPrefix),
                  let feedUrl = r["sourceFeedUrl"]?.stringValue, let guid = r["itemGuid"]?.stringValue,
                  let text = r["text"]?.stringValue else { return false }
            // Needs no item or source: a highlight stands on its own. A change from another device is
            // applied without readwise_pending, so it is not sent to Readwise from here.
            let incoming = Highlight(
                id: String(r.name.dropFirst(SyncRecord.highlightPrefix.count)), sourceFeedUrl: feedUrl, itemGuid: guid,
                itemUrl: r["itemUrl"]?.stringValue ?? "", itemTitle: r["itemTitle"]?.stringValue ?? "",
                sourceTitle: r["sourceTitle"]?.stringValue ?? "", itemAuthor: r["itemAuthor"]?.stringValue,
                itemPublishedAt: r["itemPublishedAt"]?.dateValue, text: text,
                prefix: r["prefix"]?.stringValue ?? "", suffix: r["suffix"]?.stringValue ?? "",
                note: r["note"]?.stringValue ?? "",
                color: r["color"]?.stringValue.flatMap(HighlightColor.init(rawValue:)) ?? .yellow,
                createdAt: r["createdAt"]?.dateValue ?? now, updatedAt: r["updatedAt"]?.dateValue ?? now,
                readwiseId: r["readwiseId"]?.intValue)
            if let existing = try Highlight.fetchOne(db, key: incoming.id) {
                var merged = incoming
                merged.readwisePending = existing.readwisePending
                // An id this device got from Readwise but hasn't uploaded yet must not be lost to an older copy.
                merged.readwiseId = incoming.readwiseId ?? existing.readwiseId
                if merged != existing {
                    try merged.update(db)
                    result.highlightsChanged = true
                }
            } else {
                try incoming.insert(db)
                result.highlightsChanged = true
            }
            return true

        case .settings:
            guard let json = r["json"]?.stringValue else { return false }
            if try Queries.meta(db, MetaKey.syncedSettings) != json {
                try Queries.setMeta(db, MetaKey.syncedSettings, json)
                result.settingsJSON = json
            }
            return true

        case .integrations:
            let url = r["webhookURL"]?.stringValue
            if try Queries.meta(db, MetaKey.webhookURL) != url {
                try Queries.setMeta(db, MetaKey.webhookURL, url)
                result.integrationsChanged = true
            }
            // Written by the caller, outside the transaction; it compares with the Keychain itself. A
            // token that should be there but didn't decrypt leaves the local one alone.
            if let token = r["readwiseToken"]?.stringValue {
                result.readwiseToken = .some(token)
            } else if r["hasReadwiseToken"]?.boolValue == false {
                result.readwiseToken = .some(nil)
            }
            return true
        }
    }

    private static func applyDeletion(_ db: Database, _ d: IncomingDeletion, into result: inout ApplyResult) throws {
        switch d.type {
        case .folder:
            for f in try Queries.folders(db) where SyncRecord.folderName(title: f.title) == d.name {
                try Queries.deleteFolder(db, id: f.id)
                result.libraryChanged = true
            }
        case .source:
            for s in try Queries.sources(db) where SyncRecord.sourceName(feedUrl: s.feedUrl) == d.name {
                try Queries.deleteSource(db, id: s.id)
                result.libraryChanged = true
            }
        case .savedItem:
            for (it, feedUrl) in try savedItems(db) where SyncRecord.savedItemName(sourceFeedUrl: feedUrl, guid: it.guid) == d.name {
                try Queries.setSaved(db, itemId: it.id, saved: false)
                result.libraryChanged = true
            }
        case .highlight:
            // Removed elsewhere: gone here too, and not deleted from Readwise by this device.
            if d.name.hasPrefix(SyncRecord.highlightPrefix),
               try Highlight.deleteOne(db, key: String(d.name.dropFirst(SyncRecord.highlightPrefix.count))) {
                result.highlightsChanged = true
            }
        case .settings:
            // Keep this device's settings; the next diff uploads them again.
            break
        case .integrations:
            if try Queries.meta(db, MetaKey.webhookURL) != nil {
                try Queries.setMeta(db, MetaKey.webhookURL, nil)
                result.integrationsChanged = true
            }
            result.readwiseToken = .some(nil)
        }
    }

    private static func folder(_ db: Database, titled title: String) throws -> Folder? {
        let key = SyncRecord.folderKey(title)
        return try Queries.folders(db).first { SyncRecord.folderKey($0.title) == key }
    }

    /// The folder with this title, created at the bottom if there is none (its own record, applied
    /// before or after, sets the position).
    private static func folderID(_ db: Database, titled title: String, now: Date, into result: inout ApplyResult) throws -> Int64 {
        if let f = try folder(db, titled: title) { return f.id }
        let f = try Queries.createFolder(db, title: title, now: now)
        result.libraryChanged = true
        return f.id
    }

    // MARK: Joining

    /// The first sync on a device that is still as seeded (only built-in sources, nothing saved,
    /// pinned or hidden) while iCloud already holds a library: the built-in sources and empty folders
    /// iCloud doesn't have are dropped, so a new device takes the existing library instead of bringing
    /// back sources removed elsewhere. A device that has been used keeps everything and merges.
    /// Run after the first fetch, before the first diff.
    @discardableResult
    public static func pruneSeedForJoin(_ db: Database) throws -> Bool {
        let shadowed = Set(try String.fetchAll(db, sql: "SELECT record_name FROM sync_records"))
        guard !shadowed.isEmpty else { return false }
        // Judge only what didn't come from iCloud in the first fetch.
        let seedFeeds = Set(Seed.sources.map(\.feedUrl))
        let seedFolders = Set(Seed.folderTitles.map(SyncRecord.folderKey))
        let sources = try Queries.sources(db).filter { !shadowed.contains(SyncRecord.sourceName(feedUrl: $0.feedUrl)) }
        let folders = try Queries.folders(db).filter { !shadowed.contains(SyncRecord.folderName(title: $0.title)) }
        let savedHere = try savedItems(db).contains { item, feedUrl in
            !shadowed.contains(SyncRecord.savedItemName(sourceFeedUrl: feedUrl, guid: item.guid))
        }
        let pristine = !savedHere && sources.allSatisfy { seedFeeds.contains($0.feedUrl) && !$0.isPinned && !$0.isHidden }
            && folders.allSatisfy { seedFolders.contains(SyncRecord.folderKey($0.title)) }
        guard pristine else { return false }
        var changed = false
        for s in sources {
            try Queries.deleteSource(db, id: s.id)
            changed = true
        }
        let filed = Set(try Int64.fetchAll(db, sql: "SELECT DISTINCT folder_id FROM sources WHERE folder_id IS NOT NULL"))
        for f in folders where !filed.contains(f.id) {
            try Queries.deleteFolder(db, id: f.id)
            changed = true
        }
        return changed
    }

    // MARK: Sync state (sync_meta)

    public static func syncMeta(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM sync_meta WHERE key = ?", arguments: [key])
    }

    public static func setSyncMeta(_ db: Database, _ key: String, _ value: String?) throws {
        if let value {
            try db.execute(sql: "INSERT INTO sync_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        } else {
            try db.execute(sql: "DELETE FROM sync_meta WHERE key = ?", arguments: [key])
        }
    }

    /// Keys in `sync_meta`. Kept out of `meta` so saving them doesn't wake the change observer.
    public enum Key {
        /// CKSyncEngine.State.Serialization as JSON.
        public static let engineState = "engine_state"
        /// Set once this device has done its first fetch and merge; until then nothing is uploaded.
        public static let joined = "joined"
    }
}
