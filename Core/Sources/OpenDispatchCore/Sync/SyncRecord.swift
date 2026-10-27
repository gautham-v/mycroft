import CryptoKit
import Foundation

/// What iCloud sync carries. Feed items are not synced (each device fetches its own); saved items are,
/// as a snapshot, so a device that has not fetched (or has pruned) the item can still show it.
public enum SyncRecordType: String, Sendable, CaseIterable {
    case folder = "Folder"
    case source = "Source"
    case savedItem = "SavedItem"
    /// The app's reader/playback settings, one JSON blob (`MetaKey.syncedSettings`).
    case settings = "Settings"
    /// Webhook URL and the Readwise token (the token as an encrypted field).
    case integrations = "Integrations"

    /// Order incoming records are applied in: folders before the sources filed in them, sources
    /// before the saved items that belong to them.
    var applyOrder: Int {
        switch self {
        case .settings: 0
        case .integrations: 1
        case .folder: 2
        case .source: 3
        case .savedItem: 4
        }
    }

    /// Every field and its kind. Fields not listed here are neither sent nor read.
    var schema: [String: SyncFieldKind] {
        switch self {
        case .folder: ["title": .string, "position": .int]
        case .source: [
            "feedUrl": .string, "title": .string, "url": .string, "kind": .string, "group": .string,
            "iconUrl": .string, "folder": .string, "position": .int, "pinnedAt": .date, "isHidden": .bool,
            "createdAt": .date,
        ]
        case .savedItem: [
            "sourceFeedUrl": .string, "guid": .string, "url": .string, "title": .string, "summary": .string,
            "author": .string, "publishedAt": .date, "thumbnailUrl": .string, "videoId": .string,
            "durationSec": .int, "audioUrl": .string,
        ]
        case .settings: ["json": .string]
        // hasReadwiseToken tells a cleared token apart from one that didn't decrypt.
        case .integrations: ["webhookURL": .string, "readwiseToken": .secret, "hasReadwiseToken": .bool]
        }
    }

    /// Fields that say whether two copies of a record differ. The rest describe the record for a
    /// device that is inserting it (a source's kind and icon, a saved item's title) and are left out,
    /// because each device's own refresh can change them; hashing them would bounce edits between
    /// devices forever.
    var hashedKeys: Set<String> {
        switch self {
        case .folder: ["title", "position"]
        case .source: ["feedUrl", "title", "folder", "position", "pinnedAt", "isHidden"]
        case .savedItem: ["sourceFeedUrl", "guid"]
        case .settings: ["json"]
        case .integrations: ["webhookURL", "readwiseToken"]
        }
    }
}

enum SyncFieldKind: Sendable {
    case string, int, bool, date, secret
}

/// One field value. Dates are whole milliseconds, which both SQLite and CloudKit keep exactly.
public enum SyncField: Sendable, Hashable, Codable {
    case string(String)
    case int(Int64)
    case bool(Bool)
    case date(Int64)
    /// Stored in CloudKit's encrypted values (end-to-end encrypted with the user's iCloud keys).
    case secret(String)

    public static func date(_ d: Date) -> SyncField { .date(Int64((d.timeIntervalSince1970 * 1000).rounded())) }

    var stringValue: String? {
        switch self {
        case .string(let s), .secret(let s): s
        default: nil
        }
    }

    var intValue: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var dateValue: Date? {
        if case .date(let ms) = self { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        return nil
    }

    /// Canonical text for hashing.
    fileprivate var canonical: String {
        switch self {
        case .string(let s): "s:\(s)"
        case .int(let i): "i:\(i)"
        case .bool(let b): "b:\(b ? 1 : 0)"
        case .date(let ms): "d:\(ms)"
        case .secret(let s): "x:\(s)"
        }
    }
}

/// A synced record in neutral form: what the local database says (SyncStore.localRecords) or what
/// arrived from iCloud (CloudSync). Absent keys are nil values.
public struct SyncRecord: Sendable, Hashable {
    public var type: SyncRecordType
    /// CloudKit record name. Derived from the record's natural key, so two devices that add the same
    /// feed (or folder title) produce the same record instead of a duplicate.
    public var name: String
    public var fields: [String: SyncField]

    public init(type: SyncRecordType, name: String, fields: [String: SyncField]) {
        self.type = type
        self.name = name
        self.fields = fields
    }

    public subscript(_ key: String) -> SyncField? { fields[key] }

    /// SHA-256 of the hashed fields (SyncRecordType.hashedKeys), keys sorted.
    public var hash: String {
        let keys = type.hashedKeys.sorted()
        let text = keys.map { k in "\(k)=\(fields[k]?.canonical ?? "-")" }.joined(separator: "\n")
        return SyncRecord.hex(text)
    }

    // MARK: Record names

    public static func folderName(title: String) -> String {
        "folder-" + hex(folderKey(title))
    }

    public static func sourceName(feedUrl: String) -> String {
        "source-" + hex(feedUrl)
    }

    public static func savedItemName(sourceFeedUrl: String, guid: String) -> String {
        "saved-" + hex(sourceFeedUrl + "\n" + guid)
    }

    public static let settingsName = "settings"
    public static let integrationsName = "integrations"

    /// Folders are matched by title, ignoring case and surrounding spaces (as OPML import does).
    static func folderKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
