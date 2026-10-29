import Foundation
import NaturalLanguage

/// The languages a topic shows: the user's (`Locale.preferredLanguages`). Bing News is asked for the user's market, and a
/// searched result whose title is clearly in another language is dropped, as Bing, Hacker News, Reddit, YouTube and
/// iTunes all answer in every language.
public struct TopicLanguages: Sendable, Hashable {
    /// The languages that are fine, as bare codes ("en", "el", "zh").
    public var codes: Set<String>
    /// Bing's market for the user ("en-US"), nil when no region is known.
    public var market: String?

    /// A title shorter than this (letters) is never judged: a handful of words can't be told apart reliably.
    static let minLetters = 12
    /// The recognizer must put at least this much on one language for it to count as the title's language...
    static let minConfidence = 0.6
    /// ...and no more than this on all of the user's languages together.
    static let maxOwnLanguage = 0.3

    public init(preferred: [String] = Locale.preferredLanguages, region: String? = Locale.current.region?.identifier) {
        codes = Set(preferred.compactMap { Self.code(of: $0) })
        if let first = preferred.first, let language = Self.code(of: first) {
            let own = Locale(identifier: first).region?.identifier ?? region
            market = own.map { "\(language)-\($0)" }
        }
    }

    /// The user's languages, as the system has them now.
    public static var current: TopicLanguages { TopicLanguages() }

    /// "en-US" → "en", "zh-Hans-CN" → "zh".
    static func code(of identifier: String) -> String? {
        let first = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased()
        return first.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The title is plainly in a language the user doesn't read: the recognizer is confident of one other language and puts
    /// little on the user's own. Short titles, titles of no letters (numbers, symbols) and an empty set of languages never are.
    /// A title mostly in a non-Latin script is judged without its Latin words (product names such as "Firefox" and "PWA" mislead
    /// the recognizer: a Russian title with them reads as Dutch).
    public func rejects(_ title: String) -> Bool {
        guard !codes.isEmpty else { return false }
        var text = title
        var needed = Self.minLetters
        let letters = title.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if !letters.isEmpty, Double(letters.filter { !Self.isLatin($0) }.count) / Double(letters.count) >= Self.nonLatinShare {
            text = title.split(whereSeparator: \.isWhitespace).filter { !$0.unicodeScalars.contains { Self.isLatin($0) && CharacterSet.letters.contains($0) } }
                .joined(separator: " ")
            needed = Self.minNonLatinLetters
        }
        guard text.lazy.filter(\.isLetter).count >= needed else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        guard let best = hypotheses.max(by: { $0.value < $1.value }), best.value >= Self.minConfidence,
              let bestCode = Self.code(of: best.key.rawValue), !codes.contains(bestCode) else { return false }
        let own = hypotheses.filter { Self.code(of: $0.key.rawValue).map(codes.contains) == true }.map(\.value).reduce(0, +)
        return own <= Self.maxOwnLanguage
    }

    /// From this share of non-Latin letters the Latin words are set aside before judging.
    static let nonLatinShare = 0.3
    /// Letters a non-Latin title keeps after that for it to be judged.
    static let minNonLatinLetters = 4

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x250 || (0x1E00...0x1EFF).contains(scalar.value)
    }
}
