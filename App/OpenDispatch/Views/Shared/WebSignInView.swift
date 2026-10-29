import OpenDispatchCore
import SwiftUI
import WebKit

/// The sheet that signs the app in to a site (X, Reddit): the site's own sign-in page in a web view that shares the app's
/// data store (`WebAccount.dataStore`) with the hidden views that read posts and replies, so the session carries over.
/// It closes by itself once the site's session cookie appears; Done closes it any time.
struct WebSignInView: View {
    let account: WebAccount
    @Environment(\.dismiss) private var dismiss
    @State private var signedIn = false

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to \(account.name)")
                    .font(OFFont.ui(14, .semibold))
                    .foregroundStyle(.ofInk)
                if signedIn {
                    Text("Signed in")
                        .font(OFFont.ui(12.5))
                        .foregroundStyle(.ofOK)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(Color.ofHairline).frame(height: 1)
            page
        }
        .frame(width: 520, height: 700)
        #else
        NavigationStack {
            page
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign in to \(account.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #endif
    }

    private var page: some View {
        WebSignInPage(account: account)
            .task {
                // Checked every second: the page signs in with its own requests, which no navigation event marks.
                while !Task.isCancelled {
                    if await account.isSignedIn() {
                        signedIn = true
                        try? await Task.sleep(for: .milliseconds(800))
                        dismiss()
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}

#if os(macOS)
private struct WebSignInPage: NSViewRepresentable {
    let account: WebAccount
    func makeCoordinator() -> WebSignInCoordinator { WebSignInCoordinator() }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView(account) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
private struct WebSignInPage: UIViewRepresentable {
    let account: WebAccount
    func makeCoordinator() -> WebSignInCoordinator { WebSignInCoordinator() }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView(account) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

/// Opens a sign-in popup (Google, Apple) in the same view rather than nowhere.
@MainActor
final class WebSignInCoordinator: NSObject, WKUIDelegate {
    func makeWebView(_ account: WebAccount) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebAccount.dataStore
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = WebAccount.browserUserAgent
        view.uiDelegate = self
        view.load(URLRequest(url: account.signInURL))
        return view
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}
