import OpenDispatchCore
import SwiftUI

/// "Add sources" sheet: search by name, or paste one or more links.
///
/// A name searches feeds (sites, newsletters, YouTube channels) and podcasts as you type; a link shows
/// one row for it above the results; several links (one per line, or separated by spaces or commas)
/// show one row each with Add All. Adding doesn't close the sheet or wait for the feed: the row shows
/// progress and the source appears in the sidebar once it is detected (`AppModel.beginAddSource`).
/// With nothing typed, the sheet explains what works and offers OPML import.
struct AddSourceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [SourceSearchResult] = []
    @State private var searching = false
    @State private var searchError = false
    @State private var importing = false
    @State private var importStatus: SettingsOPMLStatus?
    @FocusState private var fieldFocused: Bool

    /// Links in the field (empty when it holds a name).
    private var links: [String] { SourceSearch.links(in: query) }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            field
                .padding(.top, 12)
            ScrollView {
                content
                    .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
            .padding(.top, 4)
            footer
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 460, height: 520)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .background(Color.ofSurface)
        .onAppear {
            if let pending = model.pendingAddSourceURL {
                query = pending
                model.pendingAddSourceURL = nil
            }
            fieldFocused = true
        }
        .onDisappear { model.clearFinishedSourceAdds() }
        .task(id: trimmed) { await search() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.openDispatchOPML, .xml]) { result in
            switch result {
            case .success(let url): Task { await importFile(url) }
            case .failure(let error): importStatus = .init(text: "Import failed: \(HTTP.message(error))", error: true)
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack {
            Text("Add sources")
                .font(OFFont.ui(17, .semibold))
                .tracking(-0.17)
                .foregroundStyle(.ofInk)
            Spacer()
            Button {
                dismiss()
            } label: {
                OFIcon.close.image
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.ofMuted)
                    .frame(width: closeSize, height: closeSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            OFIcon.search.image
                .font(.system(size: 14))
                .foregroundStyle(.ofFaint)
            TextField("Search by name, or paste links", text: $query)
                .textFieldStyle(.plain)
                .font(OFFont.ui(15))
                .foregroundStyle(.ofBody)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .focused($fieldFocused)
                .onSubmit(submit)
                .accessibilityLabel("Search by name, or paste links")
            if searching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofGround))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(fieldFocused ? Color.ofAccent : Color.ofBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        if trimmed.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if links.count > 1 {
                    HStack {
                        sectionLabel("\(links.count) links")
                        Spacer()
                        Button("Add All") { links.forEach { model.beginAddSource(url: $0) } }
                            .buttonStyle(.plain)
                            .font(OFFont.ui(13, .medium))
                            .foregroundStyle(.ofAccent)
                    }
                    .padding(.horizontal, 8)
                }
                ForEach(links, id: \.self) { link in
                    AddSourceRow(title: Self.shortLink(link), subtitle: "Link", host: URLHost.host(of: link),
                                 imageUrl: nil, url: link, inLibrary: false)
                }
                if links.count <= 1 {
                    if !links.isEmpty, !results.isEmpty {
                        sectionLabel("Search results").padding(.horizontal, 8).padding(.top, 8)
                    }
                    ForEach(results) { r in
                        AddSourceRow(title: r.title, subtitle: r.kind == .podcast ? "Podcast · \(r.subtitle)" : r.subtitle,
                                     host: URLHost.host(of: r.siteUrl ?? r.feedUrl), imageUrl: r.imageUrl, url: r.feedUrl,
                                     inLibrary: model.hasSource(feedUrl: r.feedUrl))
                    }
                    if results.isEmpty, links.isEmpty, !searching {
                        note(searchError
                             ? "Search isn't available right now. Paste the site's link instead."
                             : "No matches for \u{201C}\(trimmed)\u{201D}. Paste the site's link instead.")
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find sites, newsletters, YouTube channels and podcasts by name, or paste a link. Paste several at once to add them together.")
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text("No feed? A news or blog listing page is checked for new posts.")
                .font(OFFont.ui(12))
                .foregroundStyle(.ofFaint)
                .fixedSize(horizontal: false, vertical: true)
            Button("Import from another reader (OPML)…") { importing = true }
                .buttonStyle(.plain)
                .font(OFFont.ui(13, .medium))
                .foregroundStyle(.ofAccent)
                .padding(.top, 4)
            if let importStatus {
                Text(importStatus.text)
                    .font(OFFont.ui(12))
                    .foregroundStyle(importStatus.error ? Color.ofDanger : Color.ofMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var footer: some View {
        let adding = model.sourceAdds.values.filter { $0 == .adding }.count
        let added = model.sourceAdds.values.filter { $0 == .added }.count
        return HStack(spacing: 8) {
            Text(Self.progress(adding: adding, added: added))
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
                .monospacedDigit()
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(OFFont.ui(14, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofAccent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Color.ofHairline).frame(height: 1) }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(OFFont.ui(11, .semibold))
            .tracking(0.6)
            .foregroundStyle(.ofMuted)
            .padding(.vertical, 6)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(OFFont.ui(13))
            .foregroundStyle(.ofMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
    }

    private var closeSize: CGFloat {
        #if os(iOS)
        Metrics.touchTarget
        #else
        Metrics.desktopIconButton
        #endif
    }

    // MARK: Actions

    /// Return adds what was pasted; a name just searches (results update as you type).
    private func submit() {
        links.forEach { model.beginAddSource(url: $0) }
    }

    /// Debounced search for a name (or a single link, which may also be a name like "node.js").
    private func search() async {
        let q = trimmed
        guard q.count >= 2, links.count <= 1 else {
            results = []
            searching = false
            searchError = false
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        searching = true
        defer { if !Task.isCancelled { searching = false } }
        do {
            let found = try await model.searchSources(q)
            guard !Task.isCancelled else { return }
            results = found
            searchError = false
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchError = true
        }
    }

    private func importFile(_ url: URL) async {
        importStatus = .init(text: "Importing…", error: false)
        do {
            let r = try await model.importOPML(from: url)
            importStatus = .init(text: SettingsOPMLButtons.summary(r), error: r.added == 0 && !r.errors.isEmpty)
            if r.added > 0 { Task { await model.refresh(force: true) } }
        } catch {
            importStatus = .init(text: "Import failed: \(HTTP.message(error))", error: true)
        }
    }

    // MARK: Formatting

    static func progress(adding: Int, added: Int) -> String {
        switch (adding, added) {
        case (0, 0): ""
        case (0, _): "Added \(added)"
        case (_, 0): "Adding \(adding)…"
        default: "Added \(added), adding \(adding)…"
        }
    }

    /// A link without its scheme or a bare trailing slash, for the row's second line.
    static func shortLink(_ url: String) -> String {
        var s = url
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// One result or pasted link: icon, title, subtitle, and an add button that shows the add's progress.
private struct AddSourceRow: View {
    let title: String
    let subtitle: String
    let host: String
    let imageUrl: String?
    /// What gets added: a feed URL from search, or the pasted link.
    let url: String
    let inLibrary: Bool

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var state: SourceAddState? { model.sourceAdds[url] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(OFFont.ui(14, .medium))
                        .foregroundStyle(.ofInk)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(OFFont.ui(12))
                        .foregroundStyle(.ofMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                button
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(hovering ? Color.ofHover : .clear))
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        if let imageUrl, let u = URL(string: imageUrl) {
            CachedAsyncImage(url: u, maxPixelSize: 56) { image in
                image.resizable().scaledToFill()
            } placeholder: { _ in
                Color.ofCode
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            SourceBadge(host: host, title: title, size: 28)
        }
    }

    @ViewBuilder
    private var button: some View {
        let done = inLibrary || state == .added
        Button {
            model.beginAddSource(url: url)
        } label: {
            ZStack {
                if state == .adding {
                    ProgressView().controlSize(.small)
                } else {
                    (done ? OFIcon.check : OFIcon.plus).image
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(done ? Color.white : Color.ofInk)
                }
            }
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(done ? Color.ofAccent : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(done ? Color.ofAccent : Color.ofBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done || state == .adding)
        .accessibilityLabel(done ? "\(title), added" : state == .adding ? "Adding \(title)" : "Add \(title)")
    }
}

#Preview {
    AddSourceView().environment(AppModel.preview())
}
