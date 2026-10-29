import Foundation

/// Whether an extracted article is only the part a site shows non-subscribers. A page is walled when it carries a paywall
/// signal and the article extracted from it is short; the length gate matters because a signed-in reader's page still says
/// `isAccessibleForFree: false` while holding the whole story. Two exceptions: a page that says outright where the preview
/// stops (`ArticlePasses.paywallMarker`) is walled whatever the length (Le Monde's three paragraphs plus page chrome run past
/// 300 words), and a page that declares itself free (`article:content_tier` free, JSON-LD `isAccessibleForFree: true`) is not
/// walled by a modal's class name, a "sign in" line or a site on the known list.
public enum PaywallDetection {
    private typealias DOM = ExtractionDOM

    /// An article under this many words counts as short when the page declares no length of its own.
    static let shortWords = 300
    /// With a JSON-LD `wordCount`, an article under this share of it is short. Declared counts under `minDeclared` are not trusted.
    static let shortShare = 0.6
    static let minDeclared = 100
    /// A page whose own JSON-LD `articleBody` holds under this share of its declared `wordCount` was cut by the server.
    static let servedShare = 0.5

    public static func isWalled(pageHTML: String, articleHTML: String?, url: String) -> Bool {
        if statesCutOff(pageHTML) { return true }
        let words = DOM.plainText(articleHTML).split(whereSeparator: { $0.isWhitespace }).count
        let declared = declaredWords(pageHTML)
        let short = declared >= minDeclared ? Double(words) < Double(declared) * shortShare : words < shortWords
        guard short else { return false }
        return hasSignal(pageHTML: pageHTML, articleHTML: articleHTML, url: url)
    }

    // MARK: Signals

    private static let ldBlock = DOM.Pattern("<script[^>]*application/ld\\+json[^>]*>([\\s\\S]*?)</script>", caseInsensitive: true)
    private static let notFree = DOM.Pattern("\"isAccessibleForFree\"\\s*:\\s*(?:false|\"false\")", caseInsensitive: true)
    private static let wordCount = DOM.Pattern("\"wordCount\"\\s*:\\s*\"?(\\d+)", caseInsensitive: true)
    private static let articleBody = DOM.Pattern("\"articleBody\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"", caseInsensitive: true)
    private static let contentTier = DOM.Pattern(
        "<meta[^>]+property=[\"']article:content_tier[\"'][^>]+content=[\"'](?:locked|metered)[\"']|<meta[^>]+content=[\"'](?:locked|metered)[\"'][^>]+property=[\"']article:content_tier[\"']",
        caseInsensitive: true)
    private static let freeTier = DOM.Pattern(
        "<meta[^>]+property=[\"']article:content_tier[\"'][^>]+content=[\"']free[\"']|<meta[^>]+content=[\"']free[\"'][^>]+property=[\"']article:content_tier[\"']",
        caseInsensitive: true)
    private static let scriptOrStyle = DOM.Pattern("<(script|style)\\b[\\s\\S]*?</\\1>", caseInsensitive: true)
    /// Piano's containers, Ghost's members-only call to action, and a class or id naming a paywall (not "no-paywall").
    private static let markup = DOM.Pattern(
        "<[^>]+(?:\\bclass|\\bid)=[\"'][^\"']*(?:\\btp-container|\\btp-modal|\\bpost-access-cta|\\bgh-post-upgrade-cta|(?<!no-)(?<!no_)paywall)", caseInsensitive: true)
    private static let phrases = DOM.Pattern(
        "subscribe to (?:continue|keep) reading|this (?:article|story|content|post) is (?:only )?for (?:paid )?(?:subscribers|members)|already a subscriber|to continue reading,? (?:please )?(?:subscribe|sign in|log in)|sign up for free access to this post",
        caseInsensitive: true)

    private static func hasSignal(pageHTML: String, articleHTML: String?, url: String) -> Bool {
        if let articleHTML, ArticleExtraction.isLoginWall(articleHTML) { return true }
        let blocks = ldBlock.allMatches(pageHTML).compactMap { $0[1] }
        let access = blocks.map(ldAccess)
        if access.contains(.walled) { return true }
        if freeTier.test(pageHTML) || (access.contains(.free) && !access.contains(.mixed)) { return false }
        if TopicPaywalls.isPaywalled(url) { return true }
        if contentTier.test(pageHTML) { return true }
        // The server's own copy of the story (JSON-LD `articleBody`) is a fraction of the length it declares: the rest is behind the gate (Japan Times).
        if blocks.contains(where: servedCut) { return true }
        let body = scriptOrStyle.replacing(pageHTML, with: " ")
        return markup.test(body) || phrases.test(DOM.plainText(body))
    }

    /// The page says where the preview stops. Scripts are left out: they hold the same sentences as templates on every page.
    static func statesCutOff(_ pageHTML: String) -> Bool {
        ArticlePasses.paywallMarker.test(DOM.plainText(scriptOrStyle.replacing(pageHTML, with: " ")))
    }

    enum LDAccess { case none, free, walled, mixed }

    /// What a JSON-LD block says about access. Google's paywall markup says false on the article and on the part behind the
    /// wall. Politico says false on the article and true on the only `hasPart` it lists, and serves the whole story: that is
    /// `mixed`, which counts for nothing. Invalid JSON falls back to looking for a `false`.
    static func ldAccess(_ block: String) -> LDAccess {
        // Raw line breaks inside strings are invalid JSON and common in JSON-LD; between tokens they are whitespace anyway.
        let flat = block.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
        guard let data = flat.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
            return notFree.test(block) ? .walled : .none
        }
        var free = false
        var mixed = false
        func isFalse(_ v: Any?) -> Bool { (v as? Bool) == false || (v as? String)?.lowercased() == "false" }
        func isTrue(_ v: Any?) -> Bool { (v as? Bool) == true || (v as? String)?.lowercased() == "true" }
        func walled(_ node: Any) -> Bool {
            if let list = node as? [Any] { return list.contains(where: walled) }
            guard let d = node as? [String: Any] else { return false }
            if isFalse(d["isAccessibleForFree"]) {
                let parts = (d["hasPart"] as? [Any]) ?? (d["hasPart"].map { [$0] } ?? [])
                if parts.isEmpty || parts.contains(where: { isFalse(($0 as? [String: Any])?["isAccessibleForFree"]) }) { return true }
                mixed = true
            } else if isTrue(d["isAccessibleForFree"]) {
                free = true
            }
            return d.values.contains(where: walled)
        }
        if walled(json) { return .walled }
        return mixed ? .mixed : free ? .free : .none
    }

    private static func servedCut(_ block: String) -> Bool {
        guard let declared = wordCount.firstMatch(block)?[1].flatMap({ Int($0) }), declared >= minDeclared,
              let body = articleBody.firstMatch(block)?[1] else { return false }
        return Double(body.split(whereSeparator: { $0.isWhitespace }).count) < Double(declared) * servedShare
    }

    /// The largest `wordCount` any JSON-LD block of the page declares; without one, the largest in the page's other
    /// data (Business Insider's analytics JSON has it, its JSON-LD doesn't: a whole 221-word story read as a teaser).
    /// 0 when the page declares none.
    static func declaredWords(_ pageHTML: String) -> Int {
        func largest(_ texts: [String]) -> Int { texts.flatMap { wordCount.allMatches($0) }.compactMap { $0[1].flatMap { Int($0) } }.max() ?? 0 }
        let ld = largest(ldBlock.allMatches(pageHTML).compactMap { $0[1] })
        return ld > 0 ? ld : largest([pageHTML])
    }
}
