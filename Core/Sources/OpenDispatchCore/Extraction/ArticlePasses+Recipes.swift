import Foundation
import SwiftSoup

/// Recipe pages. Their recipe card is built for the kitchen, not for reading: a cook-mode toggle, a serving scaler, a
/// "Did you make this?" prompt, a shopping carousel of the equipment, a nutrition table shown twice, the times and yield
/// as a grid of label/value boxes, ingredient rows split into an amount box and a name box. And Readability may leave
/// the card out altogether (Bon Appétit's ingredients and steps sit in grid cells beside the intro). Most recipe pages
/// describe the recipe in JSON-LD (schema.org `Recipe`: recipeIngredient, recipeInstructions, recipeYield, totalTime),
/// which is the ground truth for what the card holds. `prepareRecipes` runs on the page before Readability;
/// `completeRecipe` on its output.
extension ArticlePasses {
    // MARK: Entry points

    /// Before Readability (classes are still there).
    static func prepareRecipes(_ root: Element) {
        removeRecipeWidgets(root)
        // A shopping guide's product cards are its content (GQ's product photos carry the same buy links).
        if recipe(in: root) != nil { removeShoppingCarousels(root) }
        removeTableOfContentsBoxes(root)
        joinRecipeDetails(root)
        dedupeNutrition(root)
        boldAccordionQuestions(root)
    }

    // MARK: JSON-LD

    struct Recipe {
        var description: String?
        var ingredients: [String] = []
        /// Steps by section (HowToSection's name; nil for a flat list).
        var sections: [(name: String?, steps: [String])] = []
        var yield: String?
        var totalTime: String?
        var steps: [String] { sections.flatMap(\.steps) }
    }

    /// The page's schema.org Recipe (in a list, an `@graph`, or with `@type` a list such as ["Recipe", "NewsArticle"]).
    static func recipe(in document: Element) -> Recipe? {
        func isRecipe(_ d: [String: Any]) -> Bool {
            if let t = d["@type"] as? String { return t == "Recipe" }
            return (d["@type"] as? [Any])?.contains { ($0 as? String) == "Recipe" } ?? false
        }
        func find(_ node: Any) -> [String: Any]? {
            if let d = node as? [String: Any] {
                if isRecipe(d) { return d }
                for k in ["@graph", "mainEntity", "mainEntityOfPage"] { if let v = d[k], let r = find(v) { return r } }
            } else if let list = node as? [Any] {
                for v in list { if let r = find(v) { return r } }
            }
            return nil
        }
        for script in DOM.select(document, "script[type=application/ld+json]") {
            guard let data = script.data().data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data),
                  let d = find(json) else { continue }
            var r = Recipe()
            r.description = (d["description"] as? String).map(plain).flatMap { $0.isEmpty ? nil : $0 }
            let ingredients = d["recipeIngredient"] ?? d["ingredients"]
            r.ingredients = ((ingredients as? [Any]) ?? [ingredients as Any]).compactMap { ($0 as? String).map(plain) }.filter { !$0.isEmpty }
            r.sections = instructions(d["recipeInstructions"])
            r.yield = yieldText(d["recipeYield"])
            r.totalTime = (d["totalTime"] as? String).flatMap(duration)
            if r.ingredients.isEmpty && r.steps.isEmpty { continue }
            return r
        }
        return nil
    }

    /// Text of a JSON-LD string, which may carry entities or markup.
    private static func plain(_ s: String) -> String {
        guard s.contains("<") || s.contains("&") else { return DOM.squash(s) }
        return DOM.withFragment(s) { DOM.text($0) } ?? DOM.squash(s)
    }

    /// recipeInstructions: a string (lines, or an HTML list), a list of strings or HowToSteps, or HowToSections.
    private static func instructions(_ value: Any?) -> [(name: String?, steps: [String])] {
        func stepText(_ node: Any) -> [String] {
            if let s = node as? String {
                if s.contains("<li") || s.contains("<p") {
                    return DOM.withFragment(s) { body in DOM.select(body, "li, p").map { DOM.text($0) } } ?? []
                }
                return s.components(separatedBy: .newlines).map(plain)
            }
            guard let d = node as? [String: Any] else { return [] }
            if let t = d["text"] as? String { return [plain(t)] }
            if let items = d["itemListElement"] as? [Any] { return items.flatMap(stepText) }
            if let n = d["name"] as? String { return [plain(n)] }
            return []
        }
        var out: [(name: String?, steps: [String])] = []
        for item in (value as? [Any]) ?? (value.map { [$0] } ?? []) {
            if let d = item as? [String: Any], (d["@type"] as? String) == "HowToSection" {
                let steps = ((d["itemListElement"] as? [Any]) ?? []).flatMap(stepText).filter { !$0.isEmpty }
                if !steps.isEmpty { out.append(((d["name"] as? String).map(plain).flatMap { $0.isEmpty ? nil : $0 }, steps)) }
                continue
            }
            let steps = stepText(item).filter { !$0.isEmpty }
            if steps.isEmpty { continue }
            if let last = out.indices.last, out[last].name == nil { out[last].steps += steps } else { out.append((nil, steps)) }
        }
        return out
    }

    private static func yieldText(_ value: Any?) -> String? {
        let first = (value as? [Any])?.first ?? value
        if let n = first as? NSNumber { return n.stringValue }
        return (first as? String).map(plain).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static let isoDuration = P("^P(?:(\\d+)D)?(?:T(?:(\\d+)H)?(?:(\\d+)M)?(?:\\d+(?:\\.\\d+)?S)?)?$", caseInsensitive: true)

    /// "PT165M" → "2 hr 45 min"; free text ("20 minutes") as it is.
    private static func duration(_ s: String) -> String? {
        let t = DOM.squash(s)
        guard let m = isoDuration.firstMatch(t) else { return t.isEmpty ? nil : t }
        let parts = (1...3).map { Int(m[$0] ?? "") ?? 0 }
        let minutes: Int = parts[0] * 1440 + parts[1] * 60 + parts[2]
        guard minutes > 0 else { return nil }
        let (h, min) = (minutes / 60, minutes % 60)
        return [h > 0 ? "\(h) hr" : nil, min > 0 ? "\(min) min" : nil].compactMap { $0 }.joined(separator: " ")
    }

    /// Letters and digits only: markup, spacing and punctuation differ between the card and its JSON-LD.
    static func recipeKey(_ s: String) -> String { DOM.norm(s).filter { $0.isLetter || $0.isNumber } }

    // MARK: Completing the card

    static let recipeMinShare = 0.5
    static let maxAmountKey = 12
    static let minSplitRows = 3
    static let minRecipeIntro = 100
    static let minDescription = 80

    /// After Readability. Ingredient rows split into an amount and a name (Bon Appétit: `<p>8</p><div>garlic cloves,
    /// finely grated</div>`) are joined into list items. Ingredients or steps the extraction lacks (fewer than half
    /// of them there) come from the page's Recipe: an "Ingredients" list (after the time and yield when those are
    /// missing too) and numbered "Steps", placed where the card's other half is, else at the end. A list that came
    /// through is left as it is. An extraction that opens with the card (Allrecipes keeps its headnote in the page
    /// header) gets the recipe's description as its opening.
    static func completeRecipe(_ html: String, document: Element) -> String {
        guard let recipe = recipe(in: document) else { return html }
        return DOM.withFragment(html) { body -> String in
            let keys = recipe.ingredients.map(recipeKey).filter { $0.count >= 3 }
            joinSplitIngredients(body, keys: Set(keys))
            unwrapSectionLists(body)
            // An ingredient is there when some block is that line, not when the words occur in a step.
            let blocks = DOM.select(body, "li, p, div, td, dd").filter { DOM.first($0, "li, p, div, td, dd") == nil }.map { recipeKey(DOM.text($0)) }
            func isLine(_ b: String, _ k: String) -> Bool { b.contains(k) && b.count <= k.count * 3 / 2 + 10 }
            let lines = keys.filter { k in blocks.contains { isLine($0, k) } }
            let text = recipeKey(DOM.text(body))
            let stepKeys = recipe.steps.map { String(recipeKey($0).prefix(80)) }.filter { $0.count >= 12 }
            let needIngredients = !keys.isEmpty && Double(lines.count) < recipeMinShare * Double(keys.count)
            let needSteps = !stepKeys.isEmpty && Double(stepKeys.filter { text.contains($0) }.count) < recipeMinShare * Double(stepKeys.count)
            let wrapper = contentWrapper(body)
            let ordered = DOM.select(wrapper, "*")
            let ingredientBlock = ordered.last { el in DOM.isTag(el, ["ul", "ol"]) && DOM.select(el, "li").contains { li in keys.contains { isLine(recipeKey(DOM.text(li)), $0) } } }
            let firstStep = stepKeys.first { text.contains($0) }.flatMap { k in
                ordered.first { el in DOM.isTag(el, ["p", "li"]) && recipeKey(DOM.text(el)).contains(k) }
            }

            if needIngredients || needSteps {
                var out = ""
                if needIngredients {
                    var meta: [String] = []
                    if let t = recipe.totalTime, !text.contains(recipeKey(t)) { meta.append("<strong>Total time:</strong> \(DOM.escapeHTML(t))") }
                    if let y = recipe.yield, !text.contains(recipeKey(y)) || recipeKey(y).count < 3 { meta.append("<strong>Yield:</strong> \(DOM.escapeHTML(y))") }
                    if !meta.isEmpty && needSteps { out += "<p>\(meta.joined(separator: " · "))</p>" }
                    out += "<h2>Ingredients</h2><ul>" + recipe.ingredients.map { "<li>\(DOM.escapeHTML($0))</li>" }.joined() + "</ul>"
                }
                if needSteps {
                    out += "<h2>Steps</h2>"
                    var n = 1
                    for section in recipe.sections {
                        if let name = section.name { out += "<h3>\(DOM.escapeHTML(name))</h3>" }
                        out += (n == 1 ? "<ol>" : "<ol start=\"\(n)\">") + section.steps.map { "<li>\(DOM.escapeHTML($0))</li>" }.joined() + "</ol>"
                        n += section.steps.count
                    }
                }
                if needIngredients && !needSteps, let step = firstStep {
                    // Before the steps' list and the heading over it.
                    var at = DOM.closest(step, "ol, ul") ?? step
                    while true {
                        if let prev = try? at.previousElementSibling(), DOM.isTag(prev, DOM.headingTags) { at = prev; break }
                        guard let parent = at.parent(), parent !== wrapper, DOM.children(parent).first === at else { break }
                        at = parent
                    }
                    _ = try? at.before(out)
                } else if needSteps && !needIngredients, let list = ingredientBlock {
                    _ = try? list.after(out)
                } else {
                    _ = try? wrapper.append(out)
                }
            }

            if let description = recipe.description, description.count >= minDescription, !text.contains(recipeKey(description)) {
                let start = ingredientBlock ?? firstStep
                let order = DOM.documentOrder(wrapper)
                let limit = start.flatMap { order[ObjectIdentifier($0)] } ?? Int.max
                let intro = DOM.select(wrapper, "p").contains { p in
                    (order[ObjectIdentifier(p)] ?? 0) < limit && DOM.closest(p, "li, table, figcaption, blockquote") == nil
                        && DOM.textLen(DOM.text(p)) >= minRecipeIntro
                }
                if !intro { _ = try? wrapper.prepend("<p>\(DOM.escapeHTML(description))</p>") }
            }
            return DOM.innerHTML(body)
        } ?? html
    }

    /// The innermost wrapper that holds the whole extraction.
    private static func contentWrapper(_ body: Element) -> Element {
        var el = body
        while DOM.children(el).count == 1, let only = DOM.children(el).first, DOM.isTag(only, ["div", "section", "article", "main"]),
              DOM.textLen(el.ownText()) == 0 { el = only }
        return el
    }

    /// Runs of sibling blocks that are ingredient lines from the Recipe, alone or as an amount (a few characters,
    /// maybe empty) and a name, become a list; headings between runs stay. Only where three or more rows were split.
    static func joinSplitIngredients(_ root: Element, keys: Set<String>) {
        guard !keys.isEmpty else { return }
        for parent in DOM.select(root, "*") where DOM.isConnected(parent) && DOM.children(parent).count >= minSplitRows * 2 {
            let kids = DOM.children(parent)
            var rows: [(start: Int, count: Int)] = []
            var i = 0
            while i < kids.count {
                let a = recipeKey(DOM.text(kids[i]))
                if DOM.isTag(kids[i], DOM.headingTags) || DOM.first(kids[i], contentMedia) != nil { i += 1; continue }
                if !a.isEmpty && keys.contains(a) { rows.append((i, 1)); i += 1; continue }
                if i + 1 < kids.count, a.count <= maxAmountKey, keys.contains(a + recipeKey(DOM.text(kids[i + 1]))) {
                    rows.append((i, 2)); i += 2; continue
                }
                i += 1
            }
            guard rows.filter({ $0.count == 2 }).count >= minSplitRows else { continue }
            var list: Element?
            var row = 0
            i = 0
            while i < kids.count {
                if row < rows.count, rows[row].start == i {
                    let n = rows[row].count
                    let amount = n == 2 ? DOM.text(kids[i]) : ""
                    let name = DOM.innerHTML(kids[i + n - 1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if list == nil, let ul = DOM.createElement("ul", near: parent) { _ = try? kids[i].before(ul); list = ul }
                    _ = try? list?.append("<li>\(amount.isEmpty ? "" : DOM.escapeHTML(amount) + " ")\(name)</li>")
                    for k in i..<(i + n) { DOM.remove(kids[k]) }
                    i += n; row += 1
                    continue
                }
                if hasMediaOrText(kids[i]) { list = nil } else { DOM.remove(kids[i]) }
                i += 1
            }
        }
    }

    /// Steps grouped in a list whose items are sections (Bon Appétit: `<ol><li><h3>Eggplant and Lamb</h3><h4>Step
    /// 1</h4><p>…`): the list's numbers stood beside the section headings. The sections are plain blocks.
    static func unwrapSectionLists(_ root: Element) {
        for list in DOM.select(root, "ol, ul") where DOM.isConnected(list) {
            let items = DOM.children(list)
            guard !items.isEmpty, items.allSatisfy({ li in
                DOM.tag(li) == "li" && DOM.children(li).first.map { DOM.isTag($0, DOM.headingTags) } == true && DOM.first(li, "p") != nil
            }) else { continue }
            for li in items { _ = try? li.unwrap() }
            _ = try? list.unwrap()
        }
    }

    // MARK: Card widgets

    private static let feedbackPrompt = P("^was this (?:page|article|story|post|recipe|guide|information) helpful\\??$", caseInsensitive: true)
    private static let cardControl = P("^(?:keep screen awake|cook mode|prevent (?:your )?screen from (?:going dark|sleeping)|did you make this recipe\\??|i made it|need to make a substitution\\??)$", caseInsensitive: true)
    /// A client framework's placeholder left in the server HTML (Dotdash Meredith's `mntl-vue-loading`).
    private static let loadingShell = P("^loading shell for \\S+ (?:vue )?component\\b", caseInsensitive: true)
    /// The review bar's counts ("1 Photo", "12 Ratings"): links to the page's gallery and reviews.
    private static let reviewCount = P("^\\d[\\d,]* (?:photos?|ratings?|reviews?)$", caseInsensitive: true)
    private static let scaleFactor = P("^\\d+(?:/\\d+)?x$", caseInsensitive: true)

    /// Controls that do nothing in the reader: Dotdash Meredith's recipe toolbar (Allrecipes, Serious Eats: the
    /// screen-wake toggle, the 1/2x-1x-2x scaler with its "Original recipe (1X) yields…", "Did you make this recipe?"),
    /// a "Was this page helpful?" thumbs box, Condé Nast's "Need to make a substitution? [Ask AI]", a component's
    /// loading placeholder.
    static func removeRecipeWidgets(_ root: Element) {
        for el in DOM.select(root, "[class*=mm-recipes-screen-wake], [class*=mm-recipes-serving-size-adjuster], [class*=mm-recipes-made-it]") {
            DOM.remove(el)
        }
        for el in DOM.select(root, "p, span, div, label, h2, h3, h4") where DOM.isConnected(el) {
            let t = DOM.text(el)
            guard t.count <= 120, !t.isEmpty else { continue }
            if feedbackPrompt.test(t) {
                // The whole box: its thumbs, "Tell us why!" and the form are sections of it.
                var box = lineBlock(el, root: root)
                var up = el.parent()
                while let cur = up, !(cur is Document), DOM.textLen(DOM.text(cur)) <= 400 {
                    if DOM.matches(cur, "[class*=feedback]") { box = cur }
                    up = cur.parent()
                }
                DOM.remove(box)
            } else if cardControl.test(t) || loadingShell.test(t) || reviewCount.test(t) {
                var box = lineBlock(el, root: root)
                // With its button ("Ask AI", the toggle's slider).
                if let parent = box.parent(), !(parent is Document), DOM.textLen(DOM.text(parent)) <= t.count + 20,
                   DOM.children(parent).allSatisfy({ $0 === box || DOM.isTag($0, ["button", "span", "input", "label"]) }) { box = parent }
                DOM.remove(box)
            }
        }
        // A row of scale factors ("1/2x", "1x", "2x").
        for el in DOM.select(root, "div, ul, fieldset") where DOM.isConnected(el) {
            let kids = DOM.children(el)
            guard kids.count >= 2, kids.allSatisfy({ scaleFactor.test(DOM.text($0)) }) else { continue }
            DOM.remove(el)
        }
    }

    // MARK: Shopping carousels

    private static let maxProductCard = 80
    private static let buyLink = "a[data-offer-url], a[data-buy-button], [data-offer-retailer]"

    /// "What you'll need" under a recipe (Bon Appétit): a list of product cards, each a picture, a name and a price
    /// linked through to a store. Once the prices go it is a column of large product photos. A list whose every item
    /// is a short card with a buy link goes with its heading. Only on a recipe page.
    static func removeShoppingCarousels(_ root: Element) {
        for list in DOM.select(root, "ul, ol") where DOM.isConnected(list) {
            let items = DOM.children(list).filter { DOM.tag($0) == "li" }
            guard items.count >= 2, items.allSatisfy({ DOM.first($0, buyLink) != nil && DOM.textLen(DOM.text($0)) <= maxProductCard }) else { continue }
            var box = list
            while let parent = box.parent(), !(parent is Document), !DOM.isTag(parent, ["body", "html", "article", "main"]),
                  DOM.textLen(DOM.text(parent)) - DOM.textLen(DOM.text(box)) <= 40,
                  DOM.select(parent, contentMedia).count == DOM.select(box, contentMedia).count { box = parent }
            DOM.remove(box)
        }
    }

    /// A table-of-contents box (Condé Nast's "In this article" accordion) whose links all point into the page:
    /// Readability drops its link list and kept the label alone.
    static func removeTableOfContentsBoxes(_ root: Element) {
        for box in DOM.select(root, "[class*=table-of-content], [class*=TableOfContent]") where DOM.isConnected(box) {
            let links = DOM.select(box, "a[href]")
            guard !links.isEmpty, links.allSatisfy({ (DOM.attr($0, "href") ?? "").hasPrefix("#") }) else { continue }
            // Its label and the toggle's (Condé Nast's button is labelled "AccordionItemContainerButton").
            let other = (links + DOM.select(box, "button")).reduce(0) { $0 + DOM.textLen(DOM.text($1)) }
            if DOM.textLen(DOM.text(box)) - other <= 40 { DOM.remove(box) }
        }
    }

    // MARK: Times and yield

    private static let detailLabel = P("^(?:(?:prep(?:aration)?|cook(?:ing)?|total|active|inactive|hands[- ]on|additional|cooling|chill(?:ing)?|rest(?:ing)?|bak(?:e|ing)|marinat(?:e|ing)|ris(?:e|ing)|freez(?:e|ing)|soak(?:ing)?|proof(?:ing)?) time|servings?|serves|yields?|makes|difficulty|level)\\s*:?$", caseInsensitive: true)

    /// The card's facts as a grid of label/value boxes (Allrecipes' "Prep Time:" over "15 mins", Bon Appétit's "Total
    /// Time" over "1 hour 30 minutes"): each box became two short paragraphs, a screen of lines. One line instead:
    /// "Prep Time: 15 mins · Cook Time: 2 hrs 30 mins". Only a grid whose every box is a pair and half its labels are
    /// recipe facts.
    static func joinRecipeDetails(_ root: Element) {
        func pair(_ item: Element) -> (String, String)? {
            var el = item
            while DOM.children(el).count == 1, let only = DOM.children(el).first, DOM.text(only) == DOM.text(el) { el = only }
            let kids = DOM.children(el)
            guard kids.count == 2, kids.allSatisfy({ DOM.isTag($0, ["p", "div", "span", "dt", "dd"]) && DOM.first($0, "p, div, ul, ol, table, " + contentMedia) == nil }) else { return nil }
            let label = DOM.text(kids[0]), value = DOM.text(kids[1])
            guard (1...30).contains(label.count), (1...80).contains(value.count) else { return nil }
            return (label, value)
        }
        for box in DOM.select(root, "div, ul, dl") where DOM.isConnected(box) {
            let items = DOM.children(box)
            guard items.count >= 2 else { continue }
            let pairs = items.compactMap(pair)
            guard pairs.count == items.count, pairs.filter({ detailLabel.test($0.0) }).count * 2 >= pairs.count else { continue }
            let line = pairs.map { label, value in
                "<strong>\(DOM.escapeHTML(label.hasSuffix(":") ? label : label + ":"))</strong> \(DOM.escapeHTML(value))"
            }.joined(separator: " · ")
            DOM.replace(box, withHTML: "<p>\(line)</p>")
        }
    }

    // MARK: Nutrition

    private static let digit = P("\\d")

    /// Dotdash Meredith shows a nutrition summary (calories, fat, carbs, protein) and then the full label with the
    /// same numbers; the summary goes when the label after it has every number in it. The label's disclaimers are in
    /// the page twice; the second copy goes.
    static func dedupeNutrition(_ root: Element) {
        for box in DOM.select(root, "[class*=nutrition]") where DOM.isConnected(box) {
            let tables = DOM.select(box, "table")
            for (i, table) in tables.enumerated() where DOM.isConnected(table) && i + 1 < tables.count {
                let numbers = DOM.select(table, "td, th").map { DOM.text($0) }.filter { !$0.isEmpty && digit.test($0) }
                let later = tables[(i + 1)...].map { DOM.text($0) }.joined(separator: " ")
                if numbers.count >= 2, numbers.allSatisfy({ later.contains($0) }) { DOM.remove(table) }
            }
            var seen = Set<String>()
            for p in DOM.select(box, "p") where DOM.isConnected(p) {
                let t = DOM.norm(DOM.text(p))
                guard t.count >= 20 else { continue }
                if !seen.insert(t).inserted { DOM.remove(p) }
            }
        }
    }

    // MARK: FAQ accordions

    private static let accordionLabel = P("accordion[\\w-]*(?:label|title|question|header|heading|trigger)", caseInsensitive: true)

    /// An FAQ accordion's question (Bon Appétit's `AccordionItemContainerLabel`) is a plain paragraph once the toggle
    /// goes, and reads like its answer. Set in bold, as the page draws it.
    static func boldAccordionQuestions(_ root: Element) {
        for p in DOM.select(root, "[class*=accordion] p, [class*=Accordion] p") where DOM.isConnected(p) {
            let t = DOM.text(p)
            guard t.hasSuffix("?"), t.count <= 200, DOM.first(p, "strong, b, a") == nil,
                  let label = p.parent(), accordionLabel.test(DOM.attr(label, "class") ?? "") else { continue }
            _ = try? p.html("<strong>\(DOM.innerHTML(p))</strong>")
        }
    }

    // MARK: Captions

    /// Dotdash Meredith's caption puts the credit in a paragraph inside a span (`<span>Credit: <p>Name</p></span>`):
    /// the paragraph broke "Credit:" and the name onto two lines. After Readability (in `cleanArticle`): before it, the
    /// paragraph is part of what scores the picture's box.
    static func inlineCaptionParagraphs(_ root: Element) {
        for p in DOM.select(root, "figcaption span p, figcaption em p, figcaption small p") where DOM.isConnected(p) {
            _ = try? p.unwrap()
        }
    }
}
