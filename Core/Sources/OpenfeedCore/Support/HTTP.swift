import Foundation

public enum HTTPError: Error, LocalizedError, Equatable {
    case invalidURL(String)
    case status(Int)
    case notHTTP
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let u): "Invalid URL: \(u)"
        case .status(let code): "HTTP \(code)"
        case .notHTTP: "Not an HTTP response"
        case .timedOut: "Timed out"
        }
    }
}

/// Shared HTTP helpers (port of src/lib/http.ts). Use these everywhere so the UA and timeouts stay consistent.
public enum HTTP {
    public static let userAgent = "Mozilla/5.0 (compatible; Openfeed/0.1; +https://github.com/gautham-v/openfeed)"

    /// Retry headers for pages that refuse bot User-Agents (they override `userAgent`).
    public static let browserHeaders: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    ]

    public static let feedAccept = "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.5"
    public static let htmlAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

    /// A session with no cache and no cookies persisted to disk.
    public static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpShouldSetCookies = true
        return URLSession(configuration: c)
    }()

    /// GET (or any method) with a timeout. Does NOT throw on non-2xx; check `response.statusCode`.
    /// Throws HTTPError.timedOut on timeout, HTTPError.invalidURL for unparseable URLs.
    public static func fetch(
        _ urlString: String,
        timeout: TimeInterval,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        session: URLSession = HTTP.session
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw HTTPError.invalidURL(urlString)
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw HTTPError.notHTTP }
            return (data, http)
        } catch let e as URLError where e.code == .timedOut {
            throw HTTPError.timedOut
        }
    }

    /// Fetch and require 2xx; returns body and the final URL after redirects.
    public static func fetchOK(
        _ urlString: String, timeout: TimeInterval, headers: [String: String] = [:], session: URLSession = HTTP.session
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let (data, res) = try await fetch(urlString, timeout: timeout, headers: headers, session: session)
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        return (data, res)
    }

    /// Decode a body using the charset from Content-Type, falling back to UTF-8 then Latin-1.
    public static func text(_ data: Data, response: HTTPURLResponse? = nil) -> String {
        if let ct = response?.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           let r = ct.range(of: "charset=") {
            let name = ct[r.upperBound...].split(separator: ";").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) } ?? ""
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// User-facing message for an error (port of errMsg).
    public static func message(_ error: any Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        if let e = error as? URLError, e.code == .timedOut { return "Timed out" }
        return error.localizedDescription
    }
}
