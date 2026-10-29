import Foundation
import Observation
import OpenDispatchCore

/// The sites the app is signed in to (X, Reddit), through the sign-in sheet's web view. Signing in to X is what lets
/// Explore show posts from X and the reader show their replies; a Reddit sign-in is optional (Reddit is read signed out).
/// The app can't see a browser's sign-ins, so this asks the app's own web data store. AppModel owns it (`model.accounts`).
@MainActor
@Observable
final class WebAccountStore {
    private(set) var signedIn: Set<WebAccount> = []
    /// The sign-in sheet RootView presents; nil when closed.
    var signingIn: WebAccount?
    /// Bumped whenever a sign-in changes, for whatever showed "Sign in" to try again.
    private(set) var changes = 0

    func isSignedIn(_ account: WebAccount) -> Bool { signedIn.contains(account) }

    /// Reads the data store again (at launch, and when the sign-in sheet closes).
    func refresh() async {
        var now: Set<WebAccount> = []
        for account in WebAccount.allCases where await account.isSignedIn() { now.insert(account) }
        guard now != signedIn else { return }
        // A view made before the sign-in started without its cookies loaded.
        for account in now.symmetricDifference(signedIn) { DiscussionWeb.shared.forget(account) }
        signedIn = now
        changes += 1
    }

    func signOut(_ account: WebAccount) async {
        await account.signOut()
        signedIn.remove(account)
        changes += 1
    }
}
