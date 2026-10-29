import OpenDispatchCore
import SwiftUI
import WebKit

/// The sheet that signs the app in to a site: the site's own sign-in page in a web view that shares the app's
/// data store (`WebAccount.dataStore`) with the hidden views that read posts, replies and paywalled articles, so the session
/// carries over.
/// "Sign in with Google" or Apple opens a pop-up window that reports back to the page that opened it, so a pop-up is a real
/// web view of its own, laid over the page until it closes itself (Back closes it by hand). The sheet closes by itself once
/// the site's session cookie appears (X, Reddit); Done closes it any time. Any other site has no cookie to look for: the sheet
/// has Cancel and Done, and Done is what records the sign-in (`onDone`).
struct WebSignInView: View {
    let target: SignInTarget
    /// Done on a site's sheet (not Cancel, nor an account's, which finds its own session).
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var signedIn = false
    @State private var browser = WebSignInBrowser()

    private var account: WebAccount? {
        if case .account(let account) = target { account } else { nil }
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if browser.popups > 0 {
                    Button("Back") { browser.closePopup() }
                }
                Text("Sign in to \(target.name)")
                    .font(OFFont.ui(14, .semibold))
                    .foregroundStyle(.ofInk)
                if signedIn {
                    Text("Signed in")
                        .font(OFFont.ui(12.5))
                        .foregroundStyle(.ofOK)
                }
                Spacer()
                // Esc, not Return: Return belongs to the page's fields (it submitted the username and closed the sheet).
                if account == nil {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Done") { done() }
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
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
                .navigationTitle("Sign in to \(target.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if browser.popups > 0 {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Back") { browser.closePopup() }
                        }
                    } else if account == nil {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { account == nil ? done() : dismiss() }
                    }
                }
        }
        #endif
    }

    private func done() {
        onDone()
        dismiss()
    }

    private var page: some View {
        WebSignInPage(url: target.startURL, browser: browser)
            .task {
                guard let account else { return }
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
    let url: URL
    let browser: WebSignInBrowser
    func makeNSView(context: Context) -> NSView { browser.makeView(url) }
    func updateNSView(_ view: NSView, context: Context) {}
}
#else
private struct WebSignInPage: UIViewRepresentable {
    let url: URL
    let browser: WebSignInBrowser
    func makeUIView(context: Context) -> UIView { browser.makeView(url) }
    func updateUIView(_ view: UIView, context: Context) {}
}
#endif

/// The sign-in page and the pop-ups it opens, stacked in one container view: each pop-up is made from the configuration
/// WebKit hands over (so it keeps its link to the page that opened it) and removed when it closes itself.
@MainActor
@Observable
final class WebSignInBrowser: NSObject, WKUIDelegate {
    #if os(macOS)
    typealias PlatformView = NSView
    #else
    typealias PlatformView = UIView
    #endif

    /// How many pop-ups are open over the page.
    private(set) var popups = 0
    @ObservationIgnored private var container: PlatformView?
    @ObservationIgnored private var stack: [WKWebView] = []

    func makeView(_ url: URL) -> PlatformView {
        if let container { return container }
        let view = PlatformView()
        container = view
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebAccount.dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let page = add(WKWebView(frame: .zero, configuration: config))
        page.load(URLRequest(url: url))
        return view
    }

    @discardableResult
    private func add(_ webView: WKWebView) -> WKWebView {
        webView.customUserAgent = WebAccount.browserUserAgent
        webView.uiDelegate = self
        if let container {
            webView.frame = container.bounds
            #if os(macOS)
            webView.autoresizingMask = [.width, .height]
            #else
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            #endif
            container.addSubview(webView)
        }
        stack.append(webView)
        popups = stack.count - 1
        return webView
    }

    /// Closes the top pop-up, as its own window.close() would.
    func closePopup() {
        guard stack.count > 1, let top = stack.last else { return }
        remove(top)
    }

    private func remove(_ webView: WKWebView) {
        guard stack.count > 1, let i = stack.firstIndex(where: { $0 === webView }), i > 0 else { return }
        webView.stopLoading()
        webView.removeFromSuperview()
        stack.remove(at: i)
        popups = stack.count - 1
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // WebKit loads the request into the returned view itself.
        add(WKWebView(frame: .zero, configuration: configuration))
    }

    func webViewDidClose(_ webView: WKWebView) {
        remove(webView)
    }
}
