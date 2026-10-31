import OpenDispatchCore
import SwiftUI

/// The sheet for a new topic and for editing one (Mac, iPad and iPhone): the keyword and Notify on New Matches, then under
/// Advanced, whose collapsed row sums it up, words to leave out, Everything or Notable only, which places to search and what is
/// blocked (blocking happens from a row's menu; this is where it is taken back). New Topic opens with Advanced closed, Edit Topic
/// with it open. Adding stores the topic, selects it and searches it at once; Done saves an edit, which searches again when
/// the keyword or the places changed. An existing topic can also be removed from here.
struct TopicEditorView: View {
    let request: TopicEditorRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var keyword: String
    @State private var leaveOut: String
    @State private var notableOnly: Bool
    @State private var news: Bool
    @State private var hackerNews: Bool
    @State private var reddit: Bool
    @State private var x: Bool
    @State private var bluesky: Bool
    @State private var media: Bool
    @State private var subscriptions: Bool
    /// Not edited here any more (the lists mark or hide paywalled articles); kept as it was so synced topics round-trip.
    private let skipPaywalled: Bool
    @State private var blocked: [String]
    @State private var notify: Bool
    @State private var showsAdvanced: Bool
    #if os(iOS)
    @State private var detent: PresentationDetent
    #endif
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingRemove = false
    @FocusState private var keywordFocused: Bool

    init(request: TopicEditorRequest) {
        self.request = request
        let options: TopicOptions
        let opensAdvanced: Bool
        switch request {
        case .new(let start):
            options = start
            opensAdvanced = false
            _notify = State(initialValue: false)
        case .edit(let topic):
            options = topic.topicOptions ?? TopicOptions(keyword: topic.title)
            opensAdvanced = true
            _notify = State(initialValue: topic.notifies)
        }
        _showsAdvanced = State(initialValue: opensAdvanced)
        #if os(iOS)
        _detent = State(initialValue: opensAdvanced ? .large : .medium)
        #endif
        _keyword = State(initialValue: options.keyword)
        _leaveOut = State(initialValue: options.excludedText)
        _notableOnly = State(initialValue: options.notableOnly)
        _news = State(initialValue: options.places.news)
        _hackerNews = State(initialValue: options.places.hackerNews)
        _reddit = State(initialValue: options.places.reddit)
        _x = State(initialValue: options.places.x)
        _bluesky = State(initialValue: options.places.bluesky)
        _media = State(initialValue: options.places.media)
        _subscriptions = State(initialValue: options.places.subscriptions)
        skipPaywalled = options.skipPaywalled
        _blocked = State(initialValue: options.blocked)
    }

    private var existing: Source? {
        if case .edit(let topic) = request { topic } else { nil }
    }

    private var title: String { existing == nil ? "New Topic" : "Edit Topic" }
    private var confirmTitle: String { existing == nil ? "Add" : "Done" }
    private var canSave: Bool { !saving && !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var options: TopicOptions {
        TopicOptions(
            keyword: keyword, excluded: TopicOptions.excludedWords(from: leaveOut), notableOnly: notableOnly,
            places: TopicPlaces(news: news, hackerNews: hackerNews, reddit: reddit, x: x, bluesky: bluesky, media: media,
                                subscriptions: subscriptions),
            skipPaywalled: skipPaywalled, blocked: blocked
        ).cleaned
    }

    /// The collapsed Advanced row: "Everything · 6 of 7 places", then how many words and sites are left out.
    private var advancedSummary: String {
        let places = [news, hackerNews, reddit, x, bluesky, media, subscriptions]
        var parts = [notableOnly ? "Notable only" : "Everything", "\(places.filter { $0 }.count) of \(places.count) places"]
        let leftOut = TopicOptions.excludedWords(from: leaveOut).count
        if leftOut > 0 { parts.append("\(leftOut) left out") }
        if !blocked.isEmpty { parts.append("\(blocked.count) blocked") }
        return parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Text(title)
                .font(OFFont.ui(15, .semibold))
                .foregroundStyle(.ofInk)
                .padding(.top, 18)
                .padding(.bottom, 4)
            form
            HStack(spacing: 10) {
                if existing != nil {
                    Button("Remove Topic", role: .destructive) { confirmingRemove = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: showsAdvanced ? 640 : Self.collapsedHeight)
        .background(Color.ofSurface)
        .modifier(sheetBehavior)
        #else
        NavigationStack {
            form
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmTitle, action: save)
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .modifier(sheetBehavior)
        #endif
    }

    #if os(macOS)
    /// Title, the keyword and Notify, the Advanced row and the buttons.
    private static let collapsedHeight: CGFloat = 240
    #endif

    private var sheetBehavior: some ViewModifier {
        SheetBehavior(
            existing: existing, confirmingRemove: $confirmingRemove, error: $error,
            remove: remove, onAppear: { if existing == nil { keywordFocused = true } })
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section {
                TextField("Keyword", text: $keyword, prompt: Text("A name, topic or phrase"))
                    .focused($keywordFocused)
                    .autocorrectionDisabled()
                    .onSubmit { if canSave { save() } }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    #endif
                Toggle("Notify on new matches", isOn: $notify)
            }
            Section {
                advancedRow
            }
            if showsAdvanced {
                advancedSections
            }
            #if os(iOS)
            if existing != nil {
                Section {
                    Button("Remove Topic", role: .destructive) { confirmingRemove = true }
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.ofSurface)
        .disabled(saving)
    }

    /// Opens and closes what's below it, and says what's in there while it's closed.
    private var advancedRow: some View {
        Button(action: toggleAdvanced) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.ofMuted)
                    .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                Text("Advanced")
                    .foregroundStyle(.ofInk)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                if !showsAdvanced {
                    Text(advancedSummary)
                        .foregroundStyle(.ofMuted)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Advanced")
        .accessibilityValue(showsAdvanced ? "Expanded" : advancedSummary)
    }

    private func toggleAdvanced() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            showsAdvanced.toggle()
            #if os(iOS)
            detent = showsAdvanced ? .large : .medium
            #endif
        }
    }

    @ViewBuilder private var advancedSections: some View {
        Section {
            TextField("Leave out", text: $leaveOut, prompt: Text("Words to skip, separated by commas"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
        Section {
            Picker("Show", selection: $notableOnly) {
                Text("Everything").tag(false)
                Text("Notable only").tag(true)
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("Notable: HN 100+, Reddit 200+, X 1,000+ likes, Bluesky 100+, or from a source you follow.")
        }
        Section("Search in") {
            Toggle("News sites", isOn: $news)
            Toggle("Hacker News", isOn: $hackerNews)
            Toggle("Reddit", isOn: $reddit)
            Toggle(isOn: $x) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("X")
                    Text(model.accounts.isSignedIn(.x)
                         ? "As you, at most every 30 minutes."
                         : "Only while signed in: Settings \u{203A} Integrations.")
                        .font(OFFont.ui(12))
                        .foregroundStyle(.ofMuted)
                }
            }
            Toggle("Bluesky", isOn: $bluesky)
            Toggle("YouTube & podcasts", isOn: $media)
            Toggle("Your subscriptions", isOn: $subscriptions)
        }
        if !blocked.isEmpty {
            Section {
                ForEach(blocked, id: \.self) { entry in
                    HStack {
                        Text(entry)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Button("Unblock") { blocked.removeAll { $0 == entry } }
                            .buttonStyle(.plain)
                            .foregroundStyle(.ofAccent)
                            .accessibilityLabel("Unblock \(entry)")
                    }
                }
            } header: {
                Text("Blocked")
            } footer: {
                Text("Block a site from a row\u{2019}s menu. Saved items stay.")
            }
        }
    }

    // MARK: Actions

    private func save() {
        guard canSave else { return }
        saving = true
        let options = options, notify = notify
        Task {
            do {
                if let topic = existing {
                    try await model.updateTopic(id: topic.id, options: options, notify: notify)
                } else {
                    try await model.createTopic(options, notify: notify)
                }
                dismiss()
            } catch {
                self.error = HTTP.message(error)
                saving = false
            }
        }
    }

    private func remove() {
        guard let topic = existing else { return }
        Task {
            do {
                try await model.deleteTopic(id: topic.id)
                dismiss()
            } catch {
                self.error = HTTP.message(error)
            }
        }
    }
}

/// The sheet's confirmation for Remove Topic (worded like removing a source) and its error alert.
private struct SheetBehavior: ViewModifier {
    let existing: Source?
    @Binding var confirmingRemove: Bool
    @Binding var error: String?
    let remove: () -> Void
    let onAppear: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: onAppear)
            .confirmationDialog(
                existing.map { "Remove \($0.title)?" } ?? "Remove topic?",
                isPresented: $confirmingRemove, titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive, action: remove)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removing a topic also removes its items.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }
}
