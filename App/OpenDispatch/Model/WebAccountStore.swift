import Foundation
import Observation
import OpenDispatchCore
import WebKit

/// What the sign-in sheet opens: X or Reddit (signed in once their session cookie appears), or any site, for the articles
/// behind its paywall (no cookie to look for, so the sheet's Done says when it is done).
enum SignInTarget: Identifiable, Equatable {
    case account(WebAccount)
    /// A site's key (`Paywalls.site(of:)`) and the page to start on.
    case site(String, URL)

    var id: String {
        switch self {
        case .account(let account): account.id
        case .site(let site, _): "site:" + site
        }
    }

    var name: String {
        switch self {
        case .account(let account): account.name
        case .site(let site, _): site
        }
    }

    var startURL: URL {
        switch self {
        case .account(let account): account.signInURL
        case .site(_, let url): url
        }
    }

    /// A site's sign-in sheet, started on `url` (an article of the site) or, without one, the site's front page.
    static func opening(_ site: String, startingAt url: URL? = nil) -> SignInTarget? {
        guard !site.isEmpty, let start = url ?? URL(string: "https://\(site)/") else { return nil }
        return .site(site, start)
    }
}

/// The sites the app is signed in to, through the sign-in sheet's web view. X and Reddit (`signedIn`): signing in to X is
/// what lets Explore show posts from X and the reader show their replies; a Reddit sign-in is optional (Reddit is read signed
/// out). Any other site (`signedInSites`): the sign-in the reader uses for that site's paywalled articles. The app can't see
/// a browser's sign-ins, so this asks the app's own web data store. AppModel owns it (`model.accounts`).
@MainActor
@Observable
final class WebAccountStore {
    private(set) var signedIn: Set<WebAccount> = []
    /// Whether `signedIn` has been read from the data store since launch. Until then nothing is known, so a view that needs
    /// X waits instead of asking to sign in.
    private(set) var checked = false
    /// The sites signed in to beyond X and Reddit, by `Paywalls.site(of:)`: `SiteSignIns`, on this device.
    private(set) var signedInSites: Set<String> = SiteSignIns.sites
    /// The sign-in sheet RootView presents; nil when closed.
    var signingIn: SignInTarget?
    /// Bumped whenever a sign-in changes, for whatever showed "Sign in" to try again.
    private(set) var changes = 0
    /// How many times the sheet closed on Done for a site, so an open article from it loads again.
    private(set) var siteSignIns: [String: Int] = [:]
    /// Called when `signedInSites` changes, for the lists that hide or mark paywalled sites.
    @ObservationIgnored var onSitesChange: () -> Void = {}

    func isSignedIn(_ account: WebAccount) -> Bool { signedIn.contains(account) }

    /// Reads the data store again (at launch, and when the sign-in sheet closes).
    func refresh() async {
        var now: Set<WebAccount> = []
        for account in WebAccount.allCases where await account.isSignedIn() { now.insert(account) }
        guard now != signedIn || !checked else { return }
        // A view made before the sign-in started without its cookies loaded.
        for account in now.symmetricDifference(signedIn) { DiscussionWeb.shared.forget(account) }
        signedIn = now
        checked = true
        changes += 1
    }

    func signOut(_ account: WebAccount) async {
        await account.signOut()
        signedIn.remove(account)
        changes += 1
    }

    /// Done on a site's sign-in sheet: the site counts as signed in.
    func signIn(site: String) {
        SiteSignIns.add(site)
        siteSignIns[site, default: 0] += 1
        sitesChanged()
    }

    /// Removes everything the site stored (cookies, storage), which signs the app out of it.
    func signOut(site: String) async {
        let store = WebAccount.dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records.filter { $0.displayName == site || $0.displayName.hasSuffix("." + site) })
        // A site on a shared domain (a Substack) keeps its session in a cookie of the domain above it.
        for cookie in await store.httpCookieStore.allCookies() {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if site == domain || site.hasSuffix("." + domain) || domain.hasSuffix("." + site) {
                await store.httpCookieStore.deleteCookie(cookie)
            }
        }
        SiteSignIns.remove(site)
        sitesChanged()
    }

    private func sitesChanged() {
        signedInSites = SiteSignIns.sites
        changes += 1
        onSitesChange()
    }
}
