import Foundation

/// Whether an extracted article is only the part a site shows non-subscribers. A page is walled when it carries a paywall
/// signal and the article extracted from it is short; the length gate matters because a signed-in reader's page still says
/// `isAccessibleForFree: false` while holding the whole story.
public enum PaywallDetection {
    private typealias DOM = ExtractionDOM

    /// An article under this many words counts as short when the page declares no length of its own.
    static let shortWords = 300
    /// With a JSON-LD `wordCount`, an article under this share of it is short. Declared counts under `minDeclared` are not trusted.
    static let shortShare = 0.6
    static let minDeclared = 100

    public static func isWalled(pageHTML: String, articleHTML: String?, url: String) -> Bool {
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
    private static let contentTier = DOM.Pattern(
        "<meta[^>]+property=[\"']article:content_tier[\"'][^>]+content=[\"'](?:locked|metered)[\"']|<meta[^>]+content=[\"'](?:locked|metered)[\"'][^>]+property=[\"']article:content_tier[\"']",
        caseInsensitive: true)
    private static let scriptOrStyle = DOM.Pattern("<(script|style)\\b[\\s\\S]*?</\\1>", caseInsensitive: true)
    /// Piano's containers, Ghost's members-only call to action, and a class or id naming a paywall (not "no-paywall").
    private static let markup = DOM.Pattern(
        "<[^>]+(?:\\bclass|\\bid)=[\"'][^\"']*(?:\\btp-container|\\btp-modal|\\bpost-access-cta|\\bgh-post-upgrade-cta|(?<!no-)(?<!no_)paywall)", caseInsensitive: true)
    private static let phrases = DOM.Pattern(
        "subscribe to (?:continue|keep) reading|this (?:article|story|content|post) is (?:only )?for (?:paid )?(?:subscribers|members)|already a subscriber|to continue reading,? (?:please )?(?:subscribe|sign in|log in)|sign up for free access to this post",
        caseInsensitive: true)

    private static func hasSignal(pageHTML: String, articleHTML: String?, url: String) -> Bool {
        if TopicPaywalls.isPaywalled(url) { return true }
        if ldBlock.allMatches(pageHTML).contains(where: { $0[1].map(notFree.test) == true }) { return true }
        if contentTier.test(pageHTML) { return true }
        if let articleHTML, ArticleExtraction.isLoginWall(articleHTML) { return true }
        let body = scriptOrStyle.replacing(pageHTML, with: " ")
        return markup.test(body) || phrases.test(DOM.plainText(body))
    }

    /// The largest `wordCount` any JSON-LD block of the page declares, 0 when none does.
    private static func declaredWords(_ pageHTML: String) -> Int {
        ldBlock.allMatches(pageHTML).compactMap { $0[1] }.flatMap { wordCount.allMatches($0) }
            .compactMap { $0[1].flatMap { Int($0) } }.max() ?? 0
    }
}
