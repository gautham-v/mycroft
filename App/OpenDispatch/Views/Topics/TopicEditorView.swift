import OpenDispatchCore
import SwiftUI

/// The sheet for a new topic and for editing one (Mac, iPad and iPhone): the keyword, words to leave out,
/// Everything or Notable only, which places to search, skipping paywalled sites and Notify on New Matches.
/// Adding stores the topic, selects it and searches it at once; Done saves an edit, which searches again when
/// the keyword or the places changed. An existing topic can also be removed from here.
struct TopicEditorView: View {
    let request: TopicEditorRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

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
    @State private var notify: Bool
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingRemove = false
    @FocusState private var keywordFocused: Bool

    init(request: TopicEditorRequest) {
        self.request = request
        let options: TopicOptions
        switch request {
        case .new(let start):
            options = start
            _notify = State(initialValue: false)
        case .edit(let topic):
            options = topic.topicOptions ?? TopicOptions(keyword: topic.title)
            _notify = State(initialValue: topic.notifies)
        }
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
            skipPaywalled: skipPaywalled
        ).cleaned
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
        .frame(width: 460, height: 640)
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
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .modifier(sheetBehavior)
        #endif
    }

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
            Section {
                Toggle("Notify on new matches", isOn: $notify)
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
