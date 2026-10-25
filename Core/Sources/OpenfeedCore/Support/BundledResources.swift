import Foundation

/// Files bundled with OpenfeedCore (Package.swift `resources`).
public enum BundledResources {
    /// URL of Mozilla Readability.js (Apache-2.0, see Readability-LICENSE.md), for the Extraction agent's hidden WKWebView.
    public static var readabilityURL: URL? {
        Bundle.module.url(forResource: "Readability", withExtension: "js")
    }

    /// Contents of Readability.js, or nil if the resource is missing.
    public static func readabilityJS() -> String? {
        guard let url = readabilityURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
