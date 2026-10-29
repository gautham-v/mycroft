import OpenDispatchCore
import SwiftUI

/// Integrations pane (IntegrationsPane): Readwise Reader token and webhook URL, saved together with
/// Save; each configured target has a test button and Remove. The token never comes back from the
/// Keychain: the field starts empty and the status shows its hint ("Token …abcd"). Below them, the
/// Copy as Markdown line that starts every copy; unlike the rest it applies as you leave the field. Last, the sites
/// the app is signed in to (X for Explore's posts and their replies, Reddit optionally), each with Sign In… or Sign Out.
struct SettingsIntegrationsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact

    private enum Field: Hashable { case token, webhook, copyPrompt }
    private enum TestState: Equatable {
        case running
        case ok(String)
        case error(String)
    }

    @State private var token = ""
    /// nil = untouched (the field shows the saved URL).
    @State private var webhookDraft: String?
    /// nil = untouched (the field shows the saved prompt).
    @State private var promptDraft: String?
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?
    @State private var tests: [SendTarget: TestState] = [:]
    @State private var savedFlash: Task<Void, Never>?
    /// The sign-in sheet opened from here (Settings is itself a sheet on iOS, so RootView's can't show over it).
    @State private var signingIn: WebAccount?
    @FocusState private var focus: Field?

    private var state: IntegrationsState { model.integrations }
    private var savedURL: String { state.webhookURL ?? "" }
    private var webhook: String { webhookDraft ?? savedURL }
    private var dirty: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || webhook.trimmingCharacters(in: .whitespacesAndNewlines) != savedURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(
                title: "Integrations",
                hint: "Send an item from the reader to Readwise Reader or your own webhook, and your highlights to Readwise. Stored on this device; the token is kept in the Keychain."
            )
            readwiseSection
            webhookSection
            footer
            copySection
            accountsSection
        }
        .sheet(item: $signingIn, onDismiss: { Task { await model.didCloseSignIn() } }) { account in
            WebSignInView(account: account)
        }
        .task { await model.accounts.refresh() }
        .onChange(of: focus) { old, _ in if old == .copyPrompt { commitPrompt() } }
        .onDisappear {
            savedFlash?.cancel()
            commitPrompt()
        }
    }

    // MARK: Sections

    private var readwiseSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Readwise Reader", on: state.readwiseConfigured,
                   status: state.readwiseConfigured ? "Token \(state.readwiseTokenHint ?? "saved")" : "Not set up")
            HStack(spacing: 0) {
                Text("Access token from ")
                Link("readwise.io/access_token", destination: Self.readwiseTokenURL)
                    .foregroundStyle(.ofAccent)
                Text(state.readwiseConfigured ? ". Paste a new one to replace it." : ".")
            }
            .font(OFFont.ui(compact ? 13.5 : 12))
            .foregroundStyle(.ofMuted)
            .lineLimit(2)

            SecureField(
                state.readwiseConfigured ? "Saved (\(state.readwiseTokenHint ?? "…"))" : "Paste your access token",
                text: $token
            )
            .focused($focus, equals: .token)
            .settingsFieldChrome(focused: focus == .token)
            .textContentType(.password)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit { Task { await save() } }
            .padding(.top, 6)
            .accessibilityLabel("Readwise Reader access token")

            if state.readwiseConfigured { actions(.readwise, testLabel: "Check token") }

            if state.readwiseConfigured {
                SettingsRow(label: "Send highlights to Readwise", hint: "Highlights and notes you make on this device") {
                    Toggle("Send highlights to Readwise", isOn: Binding(
                        get: { model.settings.sendHighlightsToReadwise },
                        set: { model.settings.sendHighlightsToReadwise = $0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.ofOK)
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                }
                .padding(.top, 12)
            }
        }
        .settingsSectionChrome()
    }

    private var webhookSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Webhook", on: state.webhookConfigured, status: state.webhookConfigured ? "On" : "Not set up")
            Text("Each sent item is POSTed as JSON: id, url, title, author, published_at, summary, source.")
                .font(OFFont.ui(compact ? 13.5 : 12))
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://example.com/hooks/opendispatch", text: Binding(
                get: { webhook },
                set: { value in
                    // A result for the saved URL no longer describes what the field shows.
                    if value != webhook { tests[.webhook] = nil }
                    webhookDraft = value
                }
            ))
            .focused($focus, equals: .webhook)
            .settingsFieldChrome(focused: focus == .webhook)
            .textContentType(.URL)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit { Task { await save() } }
            .padding(.top, 6)
            .accessibilityLabel("Webhook URL")

            if state.webhookConfigured { actions(.webhook, testLabel: "Send a test") }
        }
        .settingsSectionChrome()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error {
                Text(error)
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            if saved {
                Text("Saved")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofOK)
                    .transition(.opacity)
            }
            Button(saving ? "Saving…" : "Save") { Task { await save() } }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(!dirty || saving)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, compact ? 0 : 12)
        .padding(.bottom, compact ? 22 : 0)
        .overlay(alignment: .top) { if !compact { SettingsHairline() } }
        .animation(.easeOut(duration: 0.15), value: saved)
    }

    private var copySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Copy as Markdown")
                .font(OFFont.ui(compact ? 17 : 14))
                .foregroundStyle(.ofInk)
            TextField("Start copied text with", text: Binding(
                get: { promptDraft ?? model.settings.copyPrompt },
                set: { promptDraft = $0 }
            ), prompt: Text("e.g. Summarize this in 5 bullets"))
            .focused($focus, equals: .copyPrompt)
            .settingsFieldChrome(focused: focus == .copyPrompt)
            .onSubmit { commitPrompt() }
            .padding(.top, 6)
            Text("Added above the copied text, for when you always ask your AI the same thing.")
                .font(OFFont.ui(compact ? 13.5 : 12))
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .padding(.top, compact ? 0 : 12)
        .settingsSectionChrome()
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Signed-in sites")
                .font(OFFont.ui(compact ? 17 : 14))
                .foregroundStyle(.ofInk)
            Text("OpenDispatch keeps its own sign-ins; it can\u{2019}t use your browser\u{2019}s. Posts and replies are read only when you search or open them.")
                .font(OFFont.ui(compact ? 13.5 : 12))
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            ForEach(WebAccount.allCases) { account in
                let on = model.accounts.isSignedIn(account)
                SettingsRow(label: account.name, hint: accountHint(account, signedIn: on)) {
                    Button(on ? "Sign Out" : "Sign In\u{2026}") {
                        if on { Task { await model.accounts.signOut(account) } } else { signingIn = account }
                    }
                    .buttonStyle(SettingsSmallButtonStyle(quiet: on))
                }
            }
        }
        .padding(.top, compact ? 0 : 12)
        .settingsSectionChrome()
    }

    private func accountHint(_ account: WebAccount, signedIn: Bool) -> String {
        switch (account, signedIn) {
        case (.x, true): "Signed in. Explore shows posts from X, and the reader their replies."
        case (.x, false): "Sign in to see posts from X in Explore and their replies in the reader."
        case (.reddit, true): "Signed in. Reddit is read as you."
        case (.reddit, false): "Optional: Reddit posts and comments are read without an account."
        }
    }

    private func header(_ title: String, on: Bool, status: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(OFFont.ui(compact ? 17 : 14))
                .foregroundStyle(.ofInk)
            Spacer(minLength: 0)
            Text(status)
                .font(OFFont.ui(12))
                .foregroundStyle(on ? Color.ofOK : Color.ofFaint)
        }
    }

    private func actions(_ target: SendTarget, testLabel: String) -> some View {
        let t = tests[target]
        return HStack(spacing: 8) {
            Button(t == .running ? "Testing…" : testLabel) { Task { await test(target) } }
                .buttonStyle(SettingsSmallButtonStyle())
                .disabled(t == .running)
            Button("Remove") { Task { await remove(target) } }
                .buttonStyle(SettingsSmallButtonStyle(quiet: true))
                .accessibilityLabel("Remove \(target == .readwise ? "Readwise token" : "webhook")")
            switch t {
            case .ok(let message):
                Text(message).font(OFFont.ui(12.5)).foregroundStyle(.ofOK).lineLimit(2)
            case .error(let message):
                Text(message).font(OFFont.ui(12.5)).foregroundStyle(.ofDanger).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            case .running, nil:
                EmptyView()
            }
        }
        .padding(.top, 8)
    }

    // MARK: Actions

    static let readwiseTokenURL = URL(string: "https://readwise.io/access_token") ?? URL(fileURLWithPath: "/")

    private func apply() {
        token = ""
        webhookDraft = nil
        tests = [:]
    }

    /// Stores the prompt field's text (trimmed) in the settings.
    private func commitPrompt() {
        guard let draft = promptDraft else { return }
        promptDraft = nil
        model.settings.copyPrompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() async {
        guard dirty, !saving else { return }
        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let newURL = webhook.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        error = nil
        defer { saving = false }
        do {
            // The web sent both in one PUT; validate the URL first so a bad URL doesn't half-save.
            if newURL != savedURL { try await model.setWebhookURL(newURL.isEmpty ? nil : newURL) }
            if !newToken.isEmpty { try await model.setReadwiseToken(newToken) }
            apply()
            saved = true
            savedFlash?.cancel()
            savedFlash = Task {
                try? await Task.sleep(for: .milliseconds(1500))
                if !Task.isCancelled { saved = false }
            }
        } catch {
            self.error = HTTP.message(error)
        }
    }

    private func remove(_ target: SendTarget) async {
        error = nil
        do {
            switch target {
            case .readwise: try await model.setReadwiseToken(nil)
            case .webhook: try await model.setWebhookURL(nil)
            }
            apply()
        } catch {
            self.error = HTTP.message(error)
        }
    }

    private func test(_ target: SendTarget) async {
        tests[target] = .running
        do {
            try await model.testIntegration(target)
            tests[target] = .ok(target == .readwise ? "Token works" : "Test payload delivered")
        } catch {
            tests[target] = .error(HTTP.message(error))
        }
    }
}
