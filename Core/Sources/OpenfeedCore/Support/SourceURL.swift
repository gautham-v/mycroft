import Foundation

public enum SourceURLError: Error, LocalizedError, Equatable {
    case empty
    case unsupportedScheme
    case invalid

    public var errorDescription: String? {
        switch self {
        case .empty: "url is required"
        case .unsupportedScheme: "Invalid URL: only http and https are supported"
        case .invalid: "Invalid URL"
        }
    }
}

/// Port of src/lib/source-url.ts.
public enum SourceURL {
    /// Normalize what a user typed into "Add source" into an absolute http(s) URL string.
    /// Throws SourceURLError with a user-facing message when the input can't be a site URL.
    public static func normalize(_ input: String) throws -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { throw SourceURLError.empty }
        if s.hasPrefix("//") { s = String(s.dropFirst(2)) }
        if let scheme = schemePrefix(s) {
            if scheme != "http" && scheme != "https" { throw SourceURLError.unsupportedScheme }
        } else {
            s = "https://" + s
        }
        guard var c = URLComponents(string: s), let host = c.host, !host.isEmpty else {
            throw SourceURLError.invalid
        }
        let ok = host == "localhost" || host.hasPrefix("[") || (host.contains(".") && !host.hasPrefix(".") && !host.contains(".."))
        if !ok { throw SourceURLError.invalid }
        c.scheme = c.scheme?.lowercased()
        c.host = host.lowercased()
        // WHATWG URL serializes an empty path as "/".
        if c.path.isEmpty { c.path = "/" }
        guard let out = c.string else { throw SourceURLError.invalid }
        return out
    }

    /// The same URL with `www.` added to or removed from the host, or nil for IPs/localhost.
    public static func wwwAlternate(_ url: String) -> String? {
        guard var c = URLComponents(string: url), let host = c.host, !host.isEmpty else { return nil }
        if host == "localhost" || host.hasPrefix("[") || isIPv4(host) { return nil }
        if host.hasPrefix("www.") {
            let bare = String(host.dropFirst(4))
            if !bare.contains(".") { return nil }
            c.host = bare
        } else {
            c.host = "www." + host
        }
        return c.string
    }

    /// Lowercased scheme when `s` starts with `<scheme>://`.
    private static func schemePrefix(_ s: String) -> String? {
        guard let r = s.range(of: "://") else { return nil }
        let scheme = s[s.startIndex..<r.lowerBound]
        guard let first = scheme.first, first.isLetter else { return nil }
        let allowed = scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }
        return allowed ? scheme.lowercased() : nil
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
