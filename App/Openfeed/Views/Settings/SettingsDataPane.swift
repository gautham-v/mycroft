import GRDB
import OpenfeedCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// How often to refresh while the app is open. Persisted with @AppStorage under `storageKey`
/// (minutes; 0 = only when the app opens or comes to the foreground, which RootView always does
/// with the 15-minute stale rule). Applied by `.openfeedAutoRefresh()`.
enum RefreshIntervalSetting {
    static let storageKey = "openfeed.refresh-interval"
    static let defaultMinutes = 15
    /// (minutes, label) in menu order.
    static let options: [(Int, String)] = [
        (15, "Every 15 minutes"),
        (30, "Every 30 minutes"),
        (60, "Every hour"),
        (240, "Every 4 hours"),
        (0, "Only when opened"),
    ]

    static func label(_ minutes: Int) -> String {
        options.first { $0.0 == minutes }?.1 ?? "Every \(minutes) minutes"
    }
}

/// Refreshes every N minutes (RefreshIntervalSetting) while the scene is active. Attach once to the
/// root view: `RootView().openfeedAutoRefresh()`. Checks once a minute; refreshes (forced) when the
/// last refresh is at least the interval old. Interval 0 does nothing.
struct OpenfeedAutoRefresh: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(RefreshIntervalSetting.storageKey) private var minutes = RefreshIntervalSetting.defaultMinutes

    func body(content: Content) -> some View {
        content.task(id: "\(minutes)|\(scenePhase == .active)") {
            guard scenePhase == .active, minutes > 0 else { return }
            let interval = TimeInterval(minutes * 60)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                if let last = model.lastRefreshAt, Date().timeIntervalSince(last) < interval { continue }
                await model.refresh(force: true)
            }
        }
    }
}

extension View {
    /// See `OpenfeedAutoRefresh`.
    func openfeedAutoRefresh() -> some View { modifier(OpenfeedAutoRefresh()) }
}

/// Data pane (native): database location and size, refresh interval and Refresh now, and clearing
/// the cached article text (it is fetched again when an item is opened).
struct SettingsDataPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact
    @AppStorage(RefreshIntervalSetting.storageKey) private var refreshMinutes = RefreshIntervalSetting.defaultMinutes
    @State private var dbSize: Int64?
    @State private var cachedCount: Int?
    @State private var confirmingClear = false
    @State private var clearing = false
    @State private var clearStatus: SettingsOPMLStatus?

    private var databaseURL: URL? {
        try? AppDatabase.defaultDirectory().appendingPathComponent("openfeed.sqlite")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(title: "Data", hint: "Everything is stored on this device. Nothing is synced.")
            locationRow
            SettingsRow(label: "Refresh", hint: refreshHint) {
                Picker("Refresh", selection: $refreshMinutes) {
                    ForEach(RefreshIntervalSetting.options, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.ofInk)
                .fixedSize()
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                SettingsRow(label: "Last refresh", hint: lastRefreshHint(now: context.date)) {
                    Button(model.isRefreshing ? "Refreshing…" : "Refresh now") {
                        Task { await model.refresh(force: true) }
                    }
                    .buttonStyle(SettingsPaneButtonStyle())
                    .disabled(model.isRefreshing)
                }
            }
            SettingsRow(label: "Cached articles", hint: cacheHint) {
                if confirmingClear {
                    HStack(spacing: 6) {
                        Button("Keep") { confirmingClear = false }
                            .buttonStyle(SettingsSmallButtonStyle())
                        Button("Clear") { Task { await clearCache() } }
                            .buttonStyle(SettingsSmallButtonStyle(fill: .ofDanger))
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button(clearing ? "Clearing…" : "Clear") { confirmingClear = true }
                        .buttonStyle(SettingsPaneButtonStyle())
                        .disabled(clearing || cachedCount == 0)
                }
            }
            if let clearStatus {
                Text(clearStatus.text)
                    .font(OFFont.ui(12))
                    .foregroundStyle(clearStatus.error ? Color.ofDanger : Color.ofMuted)
                    .padding(.bottom, 8)
            }
        }
        .task { await loadStats() }
        .onChange(of: model.isRefreshing) { _, refreshing in
            if !refreshing { Task { await loadStats() } }
        }
    }

    // MARK: Rows

    private var locationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Database").font(OFFont.ui(14)).foregroundStyle(.ofInk)
                    Text(dbSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "SQLite")
                        .font(OFFont.ui(12))
                        .foregroundStyle(.ofMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                #if os(macOS)
                if let url = databaseURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(SettingsPaneButtonStyle())
                }
                #endif
            }
            if let url = databaseURL {
                Text(Self.displayPath(url))
                    .font(OFFont.ui(11.5))
                    .foregroundStyle(.ofMuted)
                    .textSelection(.enabled)
                    .lineLimit(compact ? 3 : 2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { SettingsHairline() }
    }

    private var refreshHint: String {
        refreshMinutes == 0
            ? "On open, if the last refresh is over 15 minutes old"
            : "While the app is open, and on open after 15 minutes"
    }

    private func lastRefreshHint(now: Date) -> String {
        guard let last = model.lastRefreshAt else { return "Never" }
        let rel = RelativeTime.format(last, now: now)
        let ago = rel == "now" ? "Just now" : "\(rel) ago"
        let failed = model.lastRefreshResult?.results.filter { !$0.ok }.count ?? 0
        return failed > 0 ? "\(ago) · \(failed) source\(failed == 1 ? "" : "s") failed" : ago
    }

    private var cacheHint: String {
        guard let cachedCount else { return "Article text saved for reading" }
        if cachedCount == 0 { return "Nothing cached" }
        return "\(cachedCount) article\(cachedCount == 1 ? "" : "s") saved for reading; fetched again when opened"
    }

    /// "~/Library/…" instead of the full home path.
    static func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Actions

    private func loadStats() async {
        if let url = databaseURL {
            let fm = FileManager.default
            let files = [url.path, url.path + "-wal", url.path + "-shm"]
            let total = files.compactMap { (try? fm.attributesOfItem(atPath: $0))?[.size] as? NSNumber }
                .reduce(Int64(0)) { $0 + $1.int64Value }
            dbSize = total > 0 ? total : nil
        }
        cachedCount = try? await model.database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE content_html IS NOT NULL") ?? 0
        }
    }

    private func clearCache() async {
        confirmingClear = false
        clearing = true
        clearStatus = nil
        defer { clearing = false }
        do {
            let cleared = try await model.database.writer.write { db -> Int in
                try db.execute(sql: "UPDATE items SET content_html = NULL, content_rendered = 0 WHERE content_html IS NOT NULL")
                return db.changesCount
            }
            // Give the space back; harmless if another connection is busy.
            _ = try? await model.database.writer.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
            clearStatus = .init(text: "Cleared \(cleared) article\(cleared == 1 ? "" : "s").", error: false)
            await model.loadItems(reset: true)
        } catch {
            clearStatus = .init(text: "Could not clear: \(HTTP.message(error))", error: true)
        }
        await loadStats()
    }
}
