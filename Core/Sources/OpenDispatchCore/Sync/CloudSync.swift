import CloudKit
#if targetEnvironment(simulator)
import MachO
#endif
import Foundation
import GRDB
import os

/// Sync state for Settings → Data.
public enum CloudSyncStatus: Sendable, Equatable {
    /// Turned off on this device.
    case off
    /// Can't sync: no iCloud account, iCloud restricted, or a build without the iCloud entitlement.
    case unavailable(String)
    case syncing
    /// Up to date as of the last fetch or send.
    case synced(Date)
    case failed(String)
}

public enum CloudSyncEvent: Sendable {
    case status(CloudSyncStatus)
    /// Changes from iCloud were written to the database (or the first merge pruned the seed).
    case applied(SyncStore.ApplyResult)
}

/// iCloud sync over the user's private CloudKit database, with no account of our own: the Apple ID
/// the device is signed in to is the account. CKSyncEngine does the fetching, sending, retries and
/// push subscriptions; SyncStore decides what changed. One zone ("OpenDispatch") holds every record.
///
///     let sync = CloudSync(database: db) { event in await model.handle(event) }
///     await sync.setEnabled(true)
///
/// Local writes are noticed by watching the synced tables (sources, folders, items, meta, highlights, history) and
/// diffing a moment later, so nothing else in the app has to call into sync.
///
/// Highlight and History are record types added after the first release (`SyncRecordType.late`), and
/// CloudKit's Production schema only has the types that were deployed to it. Until one is deployed, saving
/// it fails; that must not hold up the other types, so each late type is sent in batches of its own and,
/// when one is rejected, the whole type is held back for a while (`typeHold`). Its records stay in the
/// local database, are never shadowed, and go up on the first send after the schema is deployed.
public actor CloudSync: CKSyncEngineDelegate {
    public static let containerIdentifier = "iCloud.com.gauthamv.openfeed"
    static let zoneID = CKRecordZone.ID(zoneName: "OpenDispatch", ownerName: CKCurrentUserDefaultName)

    let database: AppDatabase
    let tokenStore: any ReadwiseTokenStore
    private let onEvent: @Sendable (CloudSyncEvent) async -> Void
    private let log = Logger(subsystem: "com.gauthamv.openfeed", category: "sync")

    private var container: CKContainer?
    private var engine: CKSyncEngine?
    private var observer: AnyDatabaseCancellable?
    private var diffTask: Task<Void, Never>?
    private var enabled = false
    private var joined = false
    /// The generation a join is running in, so a second one doesn't start beside it.
    private var joiningGeneration: Int?
    /// Bumped when sync is turned on or off and when the engine is replaced. Work begun under an
    /// older generation stops at its next suspension point instead of acting on the new state.
    private var generation = 0
    /// Hash of each record as last handed to CloudKit. A saved record is shadowed with this, not with
    /// the echoed copy, which may come back without its encrypted values.
    private var inFlight: [String: String] = [:]
    /// Records CloudKit refused for a reason retrying won't fix, held back until the date.
    private var backoff: [String: Date] = [:]
    /// Record types CloudKit refused (not in the schema yet), held back until the date. In memory, so a
    /// relaunch tries again.
    private var typeHold: [SyncRecordType: Date] = [:]
    public private(set) var status: CloudSyncStatus = .off

    public init(
        database: AppDatabase, tokenStore: any ReadwiseTokenStore = KeychainReadwiseTokenStore(),
        onEvent: @escaping @Sendable (CloudSyncEvent) async -> Void
    ) {
        self.database = database
        self.tokenStore = tokenStore
        self.onEvent = onEvent
    }

    // MARK: Control

    /// Start or stop syncing on this device. Stopping keeps the sync state, so turning it back on
    /// picks up what changed on either side in between.
    public func setEnabled(_ on: Bool) async {
        guard on != enabled else { return }
        enabled = on
        generation += 1
        if on {
            await start()
        } else {
            stop()
            await setStatus(.off)
        }
    }

    /// Fetch from iCloud and send anything pending (app came to the foreground, or "Sync now").
    public func syncNow() async {
        guard enabled, let engine else { return }
        if !joined { return await join() }
        let gen = generation
        await setStatus(.syncing)
        do {
            try await engine.fetchChanges()
            guard isCurrent(gen, engine) else { return }
            await runDiff()
            try await engine.sendChanges()
            guard isCurrent(gen, engine) else { return }
            await setStatus(.synced(Date()))
        } catch {
            if isCurrent(gen, engine) { await fail(error) }
        }
    }

    /// Still enabled, with the same engine, since `gen` was taken.
    private func isCurrent(_ gen: Int, _ engine: CKSyncEngine) -> Bool {
        enabled && generation == gen && self.engine === engine
    }

    private func start() async {
        guard Self.isEntitled else {
            await setStatus(.unavailable("iCloud isn't available in this build."))
            return
        }
        let container = self.container ?? CKContainer(identifier: Self.containerIdentifier)
        self.container = container
        joined = (try? await database.reader.read { db in try SyncStore.syncMeta(db, SyncStore.Key.joined) }) != nil
        // Turned off again while that read was suspended.
        guard enabled else { return }
        makeEngine(container: container)
        observeLocalChanges()
        let gen = generation
        let status = (try? await container.accountStatus()) ?? .couldNotDetermine
        guard enabled, generation == gen else { return }
        switch status {
        case .available:
            await join()
        case .noAccount:
            await setStatus(.unavailable("Sign in to iCloud to sync."))
        case .restricted:
            await setStatus(.unavailable("iCloud is restricted on this device."))
        case .temporarilyUnavailable:
            await setStatus(.unavailable("iCloud is temporarily unavailable."))
        default:
            await setStatus(.unavailable("Couldn't reach iCloud."))
        }
    }

    private func stop() {
        observer?.cancel()
        observer = nil
        diffTask?.cancel()
        diffTask = nil
        engine = nil
    }

    private func makeEngine(container: CKContainer) {
        let saved = try? database.writer.read { db in try SyncStore.syncMeta(db, SyncStore.Key.engineState) }
        let state = saved.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: Data($0.utf8)) }
        engine = CKSyncEngine(CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: state, delegate: self))
        generation += 1
        inFlight = [:]
    }

    /// Diff a moment after any write to a synced table; a refresh's burst of item writes collapses into one.
    private func observeLocalChanges() {
        let observation = DatabaseRegionObservation(tracking: Table("sources"), Table("folders"), Table("items"), Table("meta"), Table("highlights"), Table("history"))
        observer = observation.start(in: database.writer, onError: { _ in }, onChange: { [weak self] _ in
            Task { await self?.scheduleDiff() }
        })
    }

    private func scheduleDiff() {
        diffTask?.cancel()
        diffTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await runDiff()
        }
    }

    /// First sync on this device: fetch everything, drop seeded sources iCloud doesn't have (when it
    /// has a library), then upload what's left. Nothing is uploaded before this finishes.
    private func join() async {
        guard let engine, joiningGeneration != generation else { return }
        if joined {
            await syncNow()
            return
        }
        let gen = generation
        joiningGeneration = gen
        defer { if joiningGeneration == gen { joiningGeneration = nil } }
        await setStatus(.syncing)
        do {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            try await engine.fetchChanges()
            guard isCurrent(gen, engine) else { return }
            let pruned = try await database.writer.write { db in
                let pruned = try SyncStore.pruneSeedForJoin(db)
                try SyncStore.setSyncMeta(db, SyncStore.Key.joined, ISO8601.string(from: Date()))
                return pruned
            }
            guard isCurrent(gen, engine) else { return }
            joined = true
            if pruned {
                var r = SyncStore.ApplyResult()
                r.libraryChanged = true
                await onEvent(.applied(r))
            }
            await runDiff()
            try await engine.sendChanges()
            guard isCurrent(gen, engine) else { return }
            await setStatus(.synced(Date()))
        } catch {
            if isCurrent(gen, engine) { await fail(error) }
        }
    }

    /// Queue uploads and deletions for whatever differs from the shadow.
    private func runDiff() async {
        guard enabled, joined, let engine else { return }
        let (token, tokenReadable) = readToken()
        guard let (local, shadows) = try? await database.reader.read({ db in
            (try SyncStore.localRecords(db, readwiseToken: token), try SyncStore.shadows(db))
        }), engine === self.engine else { return }
        var changes = SyncStore.diff(local: local, shadows: shadows)
        let now = Date()
        backoff = backoff.filter { $0.value > now }
        typeHold = typeHold.filter { $0.value > now }
        for (type, _) in typeHold {
            changes.saves.removeAll { SyncRecordType.lateType(ofName: $0) == type }
            changes.deletes.removeAll { SyncRecordType.lateType(ofName: $0) == type }
        }
        // An unreadable Keychain (locked during a background wake) is not a removed token.
        let skip = tokenReadable ? Set(backoff.keys) : Set(backoff.keys).union([SyncRecord.integrationsName])
        changes.saves.removeAll { skip.contains($0) }
        changes.deletes.removeAll { skip.contains($0) }
        let pending = Set(engine.state.pendingRecordZoneChanges)
        var add: [CKSyncEngine.PendingRecordZoneChange] = []
        var drop: [CKSyncEngine.PendingRecordZoneChange] = []
        for name in changes.saves {
            let id = Self.recordID(name)
            if !pending.contains(.saveRecord(id)) { add.append(.saveRecord(id)) }
            if pending.contains(.deleteRecord(id)) { drop.append(.deleteRecord(id)) }
        }
        for name in changes.deletes {
            let id = Self.recordID(name)
            if !pending.contains(.deleteRecord(id)) { add.append(.deleteRecord(id)) }
            if pending.contains(.saveRecord(id)) { drop.append(.saveRecord(id)) }
        }
        // A delete queued before the record came back unchanged (removed, then re-added as it was).
        for case .deleteRecord(let id) in pending where local[id.recordName] != nil && !drop.contains(.deleteRecord(id)) {
            drop.append(.deleteRecord(id))
        }
        if !drop.isEmpty { engine.state.remove(pendingRecordZoneChanges: drop) }
        if !add.isEmpty {
            log.debug("queued \(changes.saves.count) saves, \(changes.deletes.count) deletes")
            engine.state.add(pendingRecordZoneChanges: add)
        }
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let e):
            if let data = try? JSONEncoder().encode(e.stateSerialization), let json = String(data: data, encoding: .utf8) {
                try? await database.writer.write { db in try SyncStore.setSyncMeta(db, SyncStore.Key.engineState, json) }
            }

        case .accountChange(let e):
            await handleAccountChange(e.changeType)

        case .fetchedDatabaseChanges(let e):
            // The zone was deleted (iCloud data removed in Settings, or an encryption reset): forget
            // what was synced and upload this device's library again.
            if e.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                log.notice("sync zone deleted; re-joining")
                await resetSyncState()
                Task { await self.join() }
            }

        case .fetchedRecordZoneChanges(let e):
            let mods = e.modifications.compactMap { m in
                Self.syncRecord(from: m.record).map { SyncStore.Incoming(record: $0, systemFields: Self.systemFields(m.record)) }
            }
            let dels = e.deletions.compactMap { d in
                SyncRecordType(rawValue: d.recordType).map { SyncStore.IncomingDeletion(name: d.recordID.recordName, type: $0) }
            }
            await apply(modifications: mods, deletions: dels)

        case .sentRecordZoneChanges(let e):
            await handleSent(e, syncEngine: syncEngine)

        case .sentDatabaseChanges(let e):
            for f in e.failedZoneSaves { log.error("zone save failed: \(f.error.localizedDescription)") }

        case .willFetchChanges, .willSendChanges:
            await setStatus(.syncing)

        case .didFetchChanges, .didSendChanges:
            if joined { await setStatus(.synced(Date())) }

        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let (token, tokenReadable) = readToken()
        let integrations = Self.recordID(SyncRecord.integrationsName)
        let now = Date()
        let held = Set(typeHold.filter { $0.value > now }.keys)
        var changes = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
                && (tokenReadable || ($0 != .saveRecord(integrations) && $0 != .deleteRecord(integrations)))
                && !(Self.lateType($0).map(held.contains) ?? false)
                && (backoff[Self.recordName($0)] ?? .distantPast) <= now
        }
        // Each late type goes in a batch of its own, after everything else: one CloudKit rejects (type not
        // deployed) can't take the other records of its batch down with it.
        let others = changes.filter { Self.lateType($0) == nil }
        if !others.isEmpty {
            changes = others
        } else if let first = changes.first.flatMap(Self.lateType) {
            changes = changes.filter { Self.lateType($0) == first }
        }
        guard !changes.isEmpty else { return nil }
        guard let (local, shadows) = try? await database.reader.read({ db in
            (try SyncStore.localRecords(db, readwiseToken: token), try SyncStore.shadows(db))
        }) else { return nil }
        for case .saveRecord(let id) in changes {
            if let r = local[id.recordName] { inFlight[id.recordName] = r.hash }
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { id in
            // Gone since it was queued: the next diff queues its deletion instead.
            guard let r = local[id.recordName] else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                return nil
            }
            return Self.ckRecord(r, systemFields: shadows[id.recordName]?.systemFields)
        }
    }

    // MARK: Events

    /// Joining runs in a task of its own: the engine delivers events one at a time, so awaiting
    /// fetchChanges inside an event handler would wait on itself forever.
    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) async {
        switch change {
        case .signIn:
            Task { await self.join() }
        case .signOut:
            // Keep the library on this device; only the link to the old account goes.
            await resetSyncState()
            if let container { makeEngine(container: container) }
            await setStatus(.unavailable("Sign in to iCloud to sync."))
        case .switchAccounts:
            await resetSyncState()
            if let container { makeEngine(container: container) }
            Task { await self.join() }
        @unknown default:
            break
        }
    }

    private func resetSyncState() async {
        joined = false
        try? await database.writer.write { db in try SyncStore.reset(db) }
    }

    private func apply(modifications: [SyncStore.Incoming], deletions: [SyncStore.IncomingDeletion]) async {
        guard !modifications.isEmpty || !deletions.isEmpty else { return }
        do {
            var result = try await database.writer.write { db in
                try SyncStore.apply(db, modifications: modifications, deletions: deletions)
            }
            if let token = result.readwiseToken {
                let current = try? tokenStore.readToken()
                if current != token {
                    try? tokenStore.writeToken(token)
                    result.integrationsChanged = true
                }
                result.readwiseToken = nil
            }
            log.debug("applied \(modifications.count) changes, \(deletions.count) deletions")
            await onEvent(.applied(result))
        } catch {
            log.error("apply failed: \(error.localizedDescription)")
        }
    }

    private func handleSent(_ e: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) async {
        let saved = e.savedRecords.compactMap { r -> SyncStore.Shadow? in
            guard let sr = Self.syncRecord(from: r) else { return nil }
            let hash = inFlight.removeValue(forKey: sr.name) ?? sr.hash
            return SyncStore.Shadow(name: sr.name, type: sr.type, hash: hash, systemFields: Self.systemFields(r))
        }
        let deleted = e.deletedRecordIDs.map(\.recordName) + e.failedRecordDeletes.filter { $0.value.code == .unknownItem }.map(\.key.recordName)
        var serverWins: [SyncStore.Incoming] = []
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var clearShadow: [String] = []
        var needsZone = false
        let holdUntil = Date().addingTimeInterval(15 * 60)
        for failure in e.failedRecordSaves {
            let id = failure.record.recordID
            inFlight[id.recordName] = nil
            switch failure.error.code {
            case .serverRecordChanged:
                // Another device saved first: its copy wins and is applied here.
                if let server = failure.error.serverRecord, let r = Self.syncRecord(from: server) {
                    serverWins.append(SyncStore.Incoming(record: r, systemFields: Self.systemFields(server)))
                } else {
                    backoff[id.recordName] = holdUntil
                }
            case .batchRequestFailed:
                // Failed only because another record in its batch did; that one reports its own error.
                retry.append(.saveRecord(id))
            case .zoneNotFound:
                needsZone = true
                clearShadow.append(id.recordName)
                retry.append(.saveRecord(id))
            case .unknownItem:
                // Deleted on the server while edited here: the edit wins and the record is created again.
                clearShadow.append(id.recordName)
                retry.append(.saveRecord(id))
            case _ where Self.isTransient(failure.error.code):
                break // CKSyncEngine retries these.
            case .quotaExceeded:
                backoff[id.recordName] = holdUntil
                await setStatus(.failed("iCloud storage is full."))
            default:
                // Retrying as is won't help; the diff after each send would otherwise queue it again at once.
                backoff[id.recordName] = holdUntil
                if let type = SyncRecordType(rawValue: failure.record.recordType), SyncRecordType.late.contains(type) {
                    // Most likely the type isn't in the Production schema yet: hold all of them.
                    typeHold[type] = Date().addingTimeInterval(30 * 60)
                }
                log.error("save \(id.recordName) failed: \(failure.error.localizedDescription)")
            }
        }
        for (id, error) in e.failedRecordDeletes where error.code != .unknownItem && !Self.isTransient(error.code) {
            backoff[id.recordName] = holdUntil
            log.error("delete \(id.recordName) failed: \(error.localizedDescription)")
        }
        let removed = deleted + clearShadow
        try? await database.writer.write { db in
            for s in saved { try SyncStore.setShadow(db, s) }
            for name in removed { try SyncStore.removeShadow(db, name: name) }
        }
        if needsZone { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]) }
        if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
        if !serverWins.isEmpty { await apply(modifications: serverWins, deletions: []) }
        // Writes made while this batch was in flight.
        scheduleDiff()
    }

    private static func lateType(_ change: CKSyncEngine.PendingRecordZoneChange) -> SyncRecordType? {
        SyncRecordType.lateType(ofName: recordName(change))
    }

    private static func recordName(_ change: CKSyncEngine.PendingRecordZoneChange) -> String {
        switch change {
        case .saveRecord(let id), .deleteRecord(let id): id.recordName
        @unknown default: ""
        }
    }

    private static func isTransient(_ code: CKError.Code) -> Bool {
        [.networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
         .operationCancelled, .requestRateLimited].contains(code)
    }

    /// The Readwise token, and whether the Keychain could be read at all.
    private func readToken() -> (String?, Bool) {
        do { return (try tokenStore.readToken(), true) } catch { return (nil, false) }
    }

    private func setStatus(_ s: CloudSyncStatus) async {
        guard s != status else { return }
        status = s
        await onEvent(.status(s))
    }

    private func fail(_ error: any Error) async {
        log.error("sync failed: \(error.localizedDescription)")
        if let ck = error as? CKError, ck.code == .notAuthenticated {
            await setStatus(.unavailable("Sign in to iCloud to sync."))
        } else {
            await setStatus(.failed(error.localizedDescription))
        }
    }

    // MARK: CKRecord mapping

    static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    /// A CKRecord for `r`, on top of the last server version's system fields when there is one. Every
    /// schema field is written (nil for absent ones) so a cleared value clears on the server too.
    static func ckRecord(_ r: SyncRecord, systemFields: Data?) -> CKRecord {
        let id = recordID(r.name)
        var record: CKRecord?
        if let systemFields, let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) {
            coder.requiresSecureCoding = true
            record = CKRecord(coder: coder)
            coder.finishDecoding()
            if record?.recordID != id || record?.recordType != r.type.rawValue { record = nil }
        }
        let out = record ?? CKRecord(recordType: r.type.rawValue, recordID: id)
        for (key, kind) in r.type.schema {
            let value = r.fields[key]
            let v: (any CKRecordValue)? = switch kind {
            case .string, .secret: value?.stringValue as NSString?
            case .int: value?.intValue.map { NSNumber(value: $0) }
            case .bool: value?.boolValue.map { NSNumber(value: $0 ? 1 : 0) }
            case .date: value?.dateValue as NSDate?
            }
            if kind == .secret { out.encryptedValues[key] = v } else { out[key] = v }
        }
        return out
    }

    /// The SyncRecord in a CKRecord; nil for a record type this version doesn't know.
    static func syncRecord(from record: CKRecord) -> SyncRecord? {
        guard let type = SyncRecordType(rawValue: record.recordType) else { return nil }
        var fields: [String: SyncField] = [:]
        for (key, kind) in type.schema {
            switch kind {
            case .string:
                if let s = record[key] as? String { fields[key] = .string(s) }
            case .int:
                if let n = record[key] as? NSNumber { fields[key] = .int(n.int64Value) }
            case .bool:
                if let n = record[key] as? NSNumber { fields[key] = .bool(n.boolValue) }
            case .date:
                if let d = record[key] as? Date { fields[key] = .date(d) }
            case .secret:
                if let s = record.encryptedValues[key] as? String { fields[key] = .secret(s) }
            }
        }
        return SyncRecord(type: type, name: record.recordID.recordName, fields: fields)
    }

    static func systemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// Whether this process may use CloudKit. Without the entitlement, CKContainer raises an exception,
    /// so builds signed without it (ad hoc, CI) must not touch CloudKit at all.
    static var isEntitled: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
        #elseif targetEnvironment(simulator)
        // Simulator builds carry their entitlements in a __TEXT,__entitlements section of the main
        // executable; a build made without signing has none.
        guard let header = _dyld_get_image_header(0) else { return false }
        var size: UInt = 0
        let mh = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        guard let data = getsectiondata(mh, "__TEXT", "__entitlements", &size), size > 0 else { return false }
        return String(decoding: UnsafeBufferPointer(start: data, count: Int(size)), as: UTF8.self)
            .contains("com.apple.developer.icloud-services")
        #else
        return true
        #endif
    }
}
