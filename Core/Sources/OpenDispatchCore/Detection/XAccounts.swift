import Foundation
import SwiftSoup

/// Finds X accounts for "Add sources". X has no open search, so without a sign-in an account is found only by its exact handle,
/// from the same public profile page an X source reads (`PageScraping`). A name needs the People search, in the hidden web
/// view that shares the app's X sign-in (`DiscussionWeb`).
public protocol XAccountSearching: Sendable {
    /// The account with this handle; nil when there is none.
    func profile(handle: String) async throws -> SourceSearchResult?
    /// Accounts matching a name, most relevant first. Throws `DiscussionError.signInRequired` when the app isn't signed in to X.
    func search(_ name: String) async throws -> [SourceSearchResult]
}

public struct DefaultXAccounts: XAccountSearching {
    typealias Fetch = @Sendable (_ url: String) async throws -> (Data, HTTPURLResponse)

    static let timeout: TimeInterval = 8
    /// How many a name search shows.
    static let searchLimit = 5

    let fetch: Fetch

    public init() {
        self.init(fetch: { url in try await HTTP.fetch(url, timeout: Self.timeout) })
    }

    /// Tests inject a fake network.
    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func profile(handle: String) async throws -> SourceSearchResult? {
        let (data, res) = try await fetch("\(XPages.origin)/\(handle)")
        if res.statusCode == 404 { return nil }
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        return XAccounts.profile(html: HTTP.text(data, response: res), handle: handle)
    }

    public func search(_ name: String) async throws -> [SourceSearchResult] {
        #if canImport(WebKit)
        let page = try await DiscussionWeb.shared.xPage(XPages.peopleSearchURL(name), scrolls: 0)
        return Array(page.answers.flatMap(XPages.accounts(inTimeline:)).prefix(Self.searchLimit))
        #else
        throw DiscussionError.unavailable
        #endif
    }
}

enum XAccounts {
    /// An account as a search result: its profile page is what gets added.
    static func result(name: String, handle: String, followers: Int?, avatar: String?) -> SourceSearchResult {
        let url = "\(XPages.origin)/\(handle)"
        return SourceSearchResult(title: name, subtitle: "X", feedUrl: url, siteUrl: url, kind: .page, imageUrl: avatar,
                                  handle: handle, audience: followers.map(Self.followers), place: .x)
    }

    /// "4.4M followers", "248K followers", "1.2K followers".
    static func followers(_ count: Int) -> String {
        let n = Double(count)
        let short = switch count {
        case 1_000_000...: String(format: "%.1fM", n / 1e6)
        case 10_000...: String(format: "%.0fK", n / 1e3)
        case 1_000...: String(format: "%.1fK", n / 1e3)
        default: String(count)
        }
        return count == 1 ? "1 follower" : "\(short) followers"
    }

    private static let title = ExtractionDOM.Pattern(#"^(.*) \(@([A-Za-z0-9_]+)\) / X$"#)
    private static let count = ExtractionDOM.Pattern(#"^(\d+) followers"#)

    /// The account a profile page is of, by its title ("Name (@handle) / X"), which must name the handle asked for; X writes
    /// the follower count at the start of the description on some profiles.
    static func profile(html: String, handle: String) -> SourceSearchResult? {
        guard let doc = try? SwiftSoup.parse(html), let text = try? doc.title(), let m = title.firstMatch(text),
              let name = m[1], let found = m[2], found.lowercased() == handle.lowercased() else { return nil }
        func meta(_ property: String) -> String? {
            let value = try? doc.select("meta[property=\(property)]").first()?.attr("content")
            return value?.isEmpty == false ? value : nil
        }
        let followers = meta("og:description").flatMap { count.firstMatch($0)?[1] ?? nil }.flatMap { Int($0) }
        return result(name: name, handle: found, followers: followers, avatar: meta("og:image"))
    }
}
