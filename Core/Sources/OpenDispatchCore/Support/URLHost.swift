import Foundation

/// Port of `hostOf` (src/lib/http.ts): hostname without a leading "www.", or "" when unparseable.
public enum URLHost {
    public static func host(of url: String) -> String {
        guard let host = URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.host, !host.isEmpty else { return "" }
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    /// Favicon URL used by SourceBadge: Google's s2 service at 64px.
    public static func faviconURL(host: String, size: Int = 64) -> URL? {
        guard !host.isEmpty else { return nil }
        var c = URLComponents(string: "https://www.google.com/s2/favicons")
        c?.queryItems = [URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: String(size))]
        return c?.url
    }
}
