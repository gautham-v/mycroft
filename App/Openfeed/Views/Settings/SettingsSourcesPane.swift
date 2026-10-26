import OpenfeedCore
import SwiftUI
import UniformTypeIdentifiers

/// Sources pane (SourcesPane + OpmlButtons in settings-dialog.tsx): sources grouped by folder with host,
/// type and last fetch (or the last error), a folder picker to move each one, Remove with an inline
/// Keep/Remove confirm, Add source, and OPML import/export with a result summary.
struct SettingsSourcesPane: View {
    let onAdd: () -> Void
    let onOpen: (Source) -> Void

    @Environment(AppModel.self) private var model
    @State private var confirming: Int64?
    /// Removed optimistically (hidden until the delete fails).
    @State private var removed: Set<Int64> = []
    @State private var errors: [Int64: String] = [:]
    @State private var renaming: Source?
    @State private var renameDraft = ""
    @State private var opmlStatus: SettingsOPMLStatus?

    var body: some View {
        ScrollViewReader { proxy in
            content
                // The result line lands below the buttons at the end of a long list, often under the
                // tab bar or window edge: bring it into view when it appears.
                .onChange(of: opmlStatus) { _, status in
                    guard status != nil else { return }
                    withAnimation { proxy.scrollTo(Self.statusID, anchor: .bottom) }
                }
        }
        .alert("Rename source", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { commitRename() }
        }
    }

    private static let statusID = "opml-status"

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(title: "Sources", hint: "Pick a folder to move a source. Removing a source also removes its items.")
            TimelineView(.periodic(from: .now, by: 30)) { context in
                list(now: context.date)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actionButtons }
                VStack(alignment: .leading, spacing: 8) { actionButtons }
            }
            .padding(.top, 4)
            if let opmlStatus {
                Text(opmlStatus.text)
                    .font(OFFont.ui(12))
                    .foregroundStyle(opmlStatus.error ? Color.ofDanger : Color.ofMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    // Margin below so the scrolled-to line clears the tab bar.
                    .padding(.bottom, 12)
                    .id(Self.statusID)
            }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        Button(action: onAdd) {
            HStack(spacing: 6) {
                OFIcon.plus.image.font(.system(size: 13, weight: .medium))
                Text("Add source")
            }
        }
        .buttonStyle(SettingsPaneButtonStyle(tint: .ofAccent))
        SettingsOPMLButtons(status: $opmlStatus)
    }

    private var visible: [Source] { model.sources.filter { !removed.contains($0.id) } }

    private var groups: [(key: String, label: String, sources: [Source])] {
        let vis = Set(visible.map(\.id))
        var out = model.orderedFolders.map { f in
            (key: "f\(f.id)", label: f.title, sources: model.allSources(inFolder: f.id).filter { vis.contains($0.id) })
        }
        out.append((key: "unfiled", label: "Unfiled", sources: model.allSources(inFolder: nil).filter { vis.contains($0.id) }))
        return out.filter { !$0.sources.isEmpty }
    }

    @ViewBuilder private func list(now: Date) -> some View {
        if visible.isEmpty {
            Text("No sources yet")
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .overlay(alignment: .top) { SettingsHairline() }
        }
        ForEach(groups, id: \.key) { group in
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionLabel(text: group.label)
                ForEach(group.sources) { source in
                    row(source, now: now)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func row(_ s: Source, now: Date) -> some View {
        HStack(spacing: 12) {
            SourceBadge(source: s, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Button { onOpen(s) } label: {
                    Text(s.title)
                        .font(OFFont.ui(14))
                        .foregroundStyle(.ofInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help("Open \(s.title)")
                subline(s, now: now)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !model.folders.isEmpty && confirming != s.id {
                folderPicker(s)
            }
            if confirming == s.id {
                HStack(spacing: 6) {
                    Button("Keep") { confirming = nil }
                        .buttonStyle(SettingsSmallButtonStyle())
                    Button("Remove") { Task { await remove(s) } }
                        .buttonStyle(SettingsSmallButtonStyle(fill: .ofDanger))
                        .accessibilityLabel("Remove \(s.title)")
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Remove") { confirming = s.id }
                    .buttonStyle(SettingsSmallButtonStyle(quiet: true))
                    .accessibilityLabel("Remove \(s.title)")
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { SettingsHairline() }
        .contextMenu {
            Button("Open Feed") { onOpen(s) }
            Button("Rename…") {
                renameDraft = s.title
                renaming = s
            }
            Divider()
            Button("Remove", role: .destructive) { confirming = s.id }
        }
    }

    @ViewBuilder private func subline(_ s: Source, now: Date) -> some View {
        if let err = errors[s.id] {
            Text("Could not remove: \(err)")
                .font(OFFont.ui(12))
                .foregroundStyle(.ofDanger)
                .lineLimit(1)
        } else if let err = s.lastError {
            Text("Error: \(err)")
                .font(OFFont.ui(12))
                .foregroundStyle(.ofDanger)
                .lineLimit(1)
                .help(err)
        } else {
            Text("\(s.host)\(Self.typeSuffix(s)) · \(Self.fetchedLabel(s.lastFetchedAt, now: now))")
                .font(OFFont.ui(12))
                .foregroundStyle(.ofMuted)
                .lineLimit(1)
        }
    }

    private func folderPicker(_ s: Source) -> some View {
        Menu {
            Picker("Folder", selection: Binding(
                get: { s.folderId },
                set: { move(s, to: $0) }
            )) {
                ForEach(model.orderedFolders) { f in
                    Text(f.title).tag(Int64?.some(f.id))
                }
                Text("Unfiled").tag(Int64?.none)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(model.folders.first { $0.id == s.folderId }?.title ?? "Unfiled")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(OFFont.ui(12))
            .foregroundStyle(.ofMuted)
            .padding(.horizontal, 6)
            .frame(maxWidth: 120, minHeight: 28)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.ofBorder))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Folder for \(s.title)")
    }

    private func move(_ s: Source, to folderId: Int64?) {
        guard folderId != s.folderId else { return }
        Task { try? await model.moveSource(id: s.id, toFolder: folderId) }
    }

    private func remove(_ s: Source) async {
        confirming = nil
        errors[s.id] = nil
        removed.insert(s.id)
        do {
            try await model.deleteSource(id: s.id)
        } catch QueryError.notFound {
            // Already gone (the web treated 404 as success).
            await model.loadSources()
        } catch {
            removed.remove(s.id)
            errors[s.id] = HTTP.message(error)
        }
    }

    private func commitRename() {
        guard let s = renaming else { return }
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !title.isEmpty, title != s.title else { return }
        Task { try? await model.renameSource(id: s.id, title: title) }
    }

    // MARK: Labels

    /// " · posts" / " · podcast" / " · scraped page" after the host.
    static func typeSuffix(_ s: Source) -> String {
        if s.type == .post { return " · posts" }
        if s.type == .podcast || s.kind == .podcast { return " · podcast" }
        if s.kind == .page { return " · scraped page" }
        return ""
    }

    /// fetchedLabel: "Never fetched", "Fetched just now", "Fetched 5 min ago", "Fetched 3 hr ago".
    static func fetchedLabel(_ at: Date?, now: Date) -> String {
        guard let at else { return "Never fetched" }
        let rel = RelativeTime.format(at, now: now)
        if rel == "now" { return "Fetched just now" }
        guard let unitChar = rel.last, let n = Int(rel.dropLast()) else { return "Fetched \(rel) ago" }
        let units: [Character: String] = ["m": "min", "h": "hr", "d": "d", "w": "wk", "y": "yr"]
        return "Fetched \(n) \(units[unitChar] ?? String(unitChar)) ago"
    }
}

// MARK: - OPML

/// The OPML file type declared in project.yml (UTImportedTypeDeclarations).
extension UTType {
    static let openfeedOPML = UTType(importedAs: "org.opml.opml", conformingTo: .xml)
}

/// Export payload for `.fileExporter`.
struct SettingsOPMLDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.openfeedOPML, .xml]
    static let writableContentTypes: [UTType] = [.openfeedOPML]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Result line under the OPML buttons (role="status" in the web).
struct SettingsOPMLStatus: Equatable {
    var text: String
    var error: Bool
}

/// Import OPML / Export OPML buttons (OpmlButtons). The result line is shown by the parent.
struct SettingsOPMLButtons: View {
    @Binding var status: SettingsOPMLStatus?
    @Environment(AppModel.self) private var model
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var busy = false
    @State private var exportDoc: SettingsOPMLDocument?

    var body: some View {
        Button(busy ? "Importing…" : "Import OPML") { isImporting = true }
            .buttonStyle(SettingsPaneButtonStyle())
            .disabled(busy)
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.openfeedOPML, .xml]) { result in
                switch result {
                case .success(let url): Task { await importFile(url) }
                case .failure(let error): status = .init(text: "Import failed: \(HTTP.message(error))", error: true)
                }
            }
        Button("Export OPML") { Task { await export() } }
            .buttonStyle(SettingsPaneButtonStyle())
            .fileExporter(
                isPresented: $isExporting,
                document: exportDoc,
                contentType: .openfeedOPML,
                defaultFilename: String(AppModel.opmlFileName().dropLast(".opml".count))
            ) { result in
                switch result {
                case .success: status = .init(text: "Exported \(model.sources.count) source\(model.sources.count == 1 ? "" : "s").", error: false)
                case .failure(let error): status = .init(text: "Export failed: \(HTTP.message(error))", error: true)
                }
                exportDoc = nil
            }
    }

    private func importFile(_ url: URL) async {
        busy = true
        status = nil
        defer { busy = false }
        do {
            let r = try await model.importOPML(from: url)
            status = .init(text: Self.summary(r), error: r.added == 0 && !r.errors.isEmpty)
        } catch {
            status = .init(text: "Import failed: \(HTTP.message(error))", error: true)
        }
    }

    private func export() async {
        do {
            exportDoc = SettingsOPMLDocument(text: try await model.exportOPML())
            isExporting = true
        } catch {
            status = .init(text: "Export failed: \(HTTP.message(error))", error: true)
        }
    }

    /// "Added 3, skipped 1, 2 new folders, 1 failed. New sources load on the next refresh.", then the
    /// first few failures ("Title: Invalid URL") one per line so a bad entry can be found and fixed.
    static func summary(_ r: OPMLImportResult) -> String {
        var parts = ["Added \(r.added)", "skipped \(r.skipped)"]
        if r.foldersCreated > 0 { parts.append("\(r.foldersCreated) new folder\(r.foldersCreated == 1 ? "" : "s")") }
        if !r.errors.isEmpty { parts.append("\(r.errors.count) failed") }
        var lines = [parts.joined(separator: ", ") + "." + (r.added > 0 ? " New sources load on the next refresh." : "")]
        let shown = 3
        lines += r.errors.prefix(shown)
        if r.errors.count > shown { lines.append("and \(r.errors.count - shown) more") }
        return lines.joined(separator: "\n")
    }
}
