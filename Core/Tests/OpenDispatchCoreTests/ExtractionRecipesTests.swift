import Foundation
import SwiftSoup
import Testing
@testable import OpenDispatchCore

/// Recipe pages: the card's ingredients and steps from the page's JSON-LD Recipe when the extraction lacks them, split
/// ingredient rows joined, and the card's controls, shopping carousel and doubled nutrition table gone (the real
/// Readability: needs WebKit, see ExtractionWebKitTests).
@Suite("Extraction: recipes", .enabled(if: ProcessInfo.processInfo.environment["OPENDISPATCH_SKIP_WEBKIT_TESTS"] != "1"))
struct ExtractionRecipesTests {
    static let para = "The braise gets better overnight, so plan to make it a day ahead and reheat it gently before serving. The braise gets better overnight, so plan to make it a day ahead."
    /// Distinct paragraphs: the same paragraph twice near the top is a teaser and its copy.
    func p(_ n: Int) -> String { "<p>\(Self.para) (note \(n))</p>" }

    func extract(_ html: String, url: String = "https://e.com/recipe/braise") async throws -> String {
        let out = try await ArticleExtraction(readability: WebKitReadability(timeout: 20)).extract(html: html, pageURL: url)
        return try #require(out.contentHtml)
    }

    func ldJSON(_ recipe: String) -> String { "<script type=\"application/ld+json\">\(recipe)</script>" }

    static let braise = """
    {"@context":"https://schema.org","@type":"Recipe","name":"Braise","description":"A slow braise of short ribs with red wine and plenty of garlic, made a day ahead so the flavors settle overnight.",
     "recipeIngredient":["3 lb. bone-in short ribs","Kosher salt","2 Tbsp. olive oil","1 large onion, chopped","6 garlic cloves, smashed","2 cups dry red wine"],
     "recipeInstructions":[{"@type":"HowToSection","name":"Ribs","itemListElement":[{"@type":"HowToStep","text":"Season the short ribs all over with salt and let them sit at room temperature for an hour."},{"@type":"HowToStep","text":"Brown the ribs in the olive oil in a heavy pot over medium-high heat, about 12 minutes."}]},
      {"@type":"HowToSection","name":"Braise","itemListElement":[{"@type":"HowToStep","text":"Cook the onion and garlic in the fat until soft, then pour in the wine and scrape up the browned bits."},{"@type":"HowToStep","text":"Return the ribs, cover and braise in a 325&deg; oven until tender, about 3 hours."}]}],
     "recipeYield":"4 servings","totalTime":"PT3H45M"}
    """

    @Test @MainActor func aCardLeftOutComesFromTheRecipe() async throws {
        let cards = (1...3).map { "<li><div><a data-buy-button=\"true\" data-offer-url=\"https://amzn.to/x\($0)\" href=\"https://cna.st/p/\($0)\"><img src=\"https://e.com/tool\($0).jpg\"></a></div><div><p>Tool \($0)</p><a data-buy-button=\"true\" href=\"https://cna.st/p/\($0)\"><p><span>\("$")\($0)0</span><span> At Amazon</span></p></a></div></li>" }.joined()
        let html = """
        <html><head><title>Braise</title>\(ldJSON(Self.braise))</head><body><main><h1>Braise</h1><div class="intro">\(p(1))\(p(2))\(p(3))</div>
        <div class="grid"><section class="carousel"><header><h2>What you’ll need</h2></header><ul>\(cards)</ul></section></div></main></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("<h2>Ingredients</h2><ul><li>3 lb. bone-in short ribs</li><li>Kosher salt</li>"))
        #expect(body.contains("<h2>Steps</h2><h3>Ribs</h3><ol><li>Season the short ribs"))
        #expect(body.contains("<h3>Braise</h3><ol start=\"3\"><li>Cook the onion"))
        #expect(body.contains("325° oven"))
        #expect(body.contains("<strong>Total time:</strong> 3 hr 45 min · <strong>Yield:</strong> 4 servings"))
        #expect(!body.contains("tool1.jpg"))
        // The page has its own intro: the description stays out.
        #expect(!body.contains("A slow braise of short ribs"))
    }

    @Test @MainActor func splitIngredientRowsBecomeAList() async throws {
        let rows = [("3", "lb. bone-in short ribs"), ("", "Kosher salt"), ("2", "Tbsp. olive oil"), ("1", "large onion, chopped"), ("6", "garlic cloves, smashed"), ("2", "cups dry red wine")]
            .map { "<p class=\"Amount\">\($0.0)</p><div class=\"Description\">\($0.1)</div>" }
        let steps = ["Season the short ribs all over with salt and let them sit at room temperature for an hour.", "Brown the ribs in the olive oil in a heavy pot over medium-high heat, about 12 minutes.",
                     "Cook the onion and garlic in the fat until soft, then pour in the wine and scrape up the browned bits.", "Return the ribs, cover and braise in a 325° oven until tender, about 3 hours."]
        let html = """
        <html><head><title>Braise</title>\(ldJSON(Self.braise))</head><body><article><h1>Braise</h1>\(p(1))\(p(2))
        <div class="InfoSlice"><h2>Recipe information</h2><ul><li><div><p>Total Time</p><p>3 hours 45 minutes</p></div></li><li><div><p>Yield</p><p>4 servings</p></div></li></ul></div>
        <div class="IngredientList"><h2>Ingredients</h2><div class="List"><h3>For the ribs</h3>\(rows[0...2].joined())<h3>For the braise</h3>\(rows[3...].joined())</div>
        <div><p><span>Need to make a substitution?</span></p><button type="button"><span>Ask AI</span></button></div></div>
        <div class="Instructions"><h2>Preparation</h2><ol><li><h3>Ribs</h3><h4>Step 1</h4><p>\(steps[0])</p><h4>Step 2</h4><p>\(steps[1])</p></li><li><h3>Braise</h3><h4>Step 3</h4><p>\(steps[2])</p><h4>Step 4</h4><p>\(steps[3])</p></li></ol></div>
        \(p(3))</article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("<h3>For the ribs</h3><ul><li>3 lb. bone-in short ribs</li><li>Kosher salt</li><li>2 Tbsp. olive oil</li></ul><h3>For the braise</h3><ul><li>1 large onion, chopped</li>"))
        #expect(body.contains("<strong>Total Time:</strong> 3 hours 45 minutes · <strong>Yield:</strong> 4 servings"))
        #expect(!body.contains("Need to make a substitution"))
        // The steps came through: not added again, and their sections are no longer list items.
        #expect(!body.contains("<h2>Steps</h2>"))
        #expect(!body.contains("<h2>Ingredients</h2><ul><li>3 lb."))
        #expect(body.components(separatedBy: "Season the short ribs").count == 2)
        #expect(!body.contains("<li><h3>Ribs</h3>"))
    }

    @Test @MainActor func aCleanCardKeepsItsListsAndLosesItsControls() async throws {
        let recipe = """
        [{"@context":"http://schema.org","@type":["Recipe","NewsArticle"],"description":"This slow cooker stuffing takes the stress out of the holidays: crumbled cornbread, celery and herbs come together while the oven stays free.",
          "recipeIngredient":["7 cups crumbled cornbread","2 stalks celery, chopped","1 teaspoon sage","2 cups chicken broth"],
          "recipeInstructions":[{"@type":"HowToStep","text":"Lightly grease the inside of a slow cooker before you start on the stuffing."},{"@type":"HowToStep","text":"Combine everything in a large bowl, mix well and transfer it to the slow cooker."},{"@type":"HowToStep","text":"Cook on High for 2 1/2 to 3 hours or on Low for 4 to 6 hours, until set."}],
          "recipeYield":"12","totalTime":"PT165M"}]
        """
        let details = [("Prep Time:", "15 mins"), ("Cook Time:", "2 hrs 30 mins"), ("Servings:", "12")]
            .map { "<div class=\"mm-recipes-details__item\"><div class=\"mm-recipes-details__label\">\($0.0)</div><div class=\"mm-recipes-details__value\">\($0.1)</div></div>" }.joined()
        let html = """
        <html><head><title>Stuffing</title>\(ldJSON(recipe))</head><body><header><h1>Stuffing</h1><p class="article-subheading">This slow cooker stuffing takes the stress out of the holidays: crumbled cornbread, celery and herbs come together while the oven stays free.</p></header>
        <div class="article-content"><div class="mm-recipes-details"><div class="mm-recipes-details__content">\(details)</div></div>
        <div class="mm-recipes-structured-ingredients"><div class="mm-recipes-screen-wake"><button></button><span>Keep Screen Awake</span></div><h2>Ingredients</h2>
        <div class="mm-recipes-serving-size-adjuster"><div><span>1/2x</span></div><div><span>1x</span></div><div><span>2x</span></div><p>Original recipe (1X) yields 12 servings</p></div>
        <ul><li><p><span>7</span> <span>cups</span> crumbled <span>cornbread</span></p></li><li><p><span>2</span> <span>stalks</span> celery, chopped</p></li><li><p><span>1</span> <span>teaspoon</span> sage</p></li><li><p><span>2</span> <span>cups</span> chicken broth</p></li></ul></div>
        <div class="mm-recipes-steps"><h2>Directions</h2><ol><li><p>Lightly grease the inside of a slow cooker before you start on the stuffing.</p></li><li><p>Combine everything in a large bowl, mix well and transfer it to the slow cooker.</p></li><li><p>Cook on High for 2 1/2 to 3 hours or on Low for 4 to 6 hours, until set.</p></li></ol></div>
        <div class="mm-recipes-nutrition-facts"><div class="mm-recipes-nutrition-facts-summary"><h2>Nutrition Facts (per serving)</h2><table><tr><td>578</td><td>Calories</td></tr><tr><td>22g</td><td>Fat</td></tr></table></div>
        <div class="mm-recipes-nutrition-facts-label"><table><tr><th>Calories 578</th></tr><tr><td>Total Fat 22g</td><td>28%</td></tr></table><div class="disclaimer"><p>** Nutrient information is not available for all ingredients.</p><p>** Nutrient information is not available for all ingredients.</p></div></div></div>
        <div class="mm-recipes-made-it"><span>Did you make this recipe?</span><button>I made it</button></div></div></body></html>
        """
        let body = try await extract(html, url: "https://e.com/stuffing-recipe")
        // The headnote sits in the page header, outside the extraction: it opens the article.
        #expect(body.replacingOccurrences(of: "<div>", with: "").hasPrefix("<p>This slow cooker stuffing"))
        #expect(body.contains("<strong>Prep Time:</strong> 15 mins · <strong>Cook Time:</strong> 2 hrs 30 mins · <strong>Servings:</strong> 12"))
        for junk in ["Keep Screen Awake", "1/2x", "Original recipe", "Did you make this recipe", "<h2>Steps</h2>"] { #expect(!body.contains(junk), "\(junk)") }
        #expect(!body.contains("<h2>Ingredients</h2><ul><li>7 cups"))
        #expect(body.components(separatedBy: "Nutrient information is not available").count == 2)
        #expect(body.components(separatedBy: "578").count == 2)
    }

    @Test func recipeJSONLDReads() throws {
        let html = """
        <html><head><script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebPage"},{"@type":"Recipe","recipeIngredient":["1 cup flour &amp; salt"],
        "recipeInstructions":"Mix.\\nBake until golden.","recipeYield":[6,"6 pancakes"],"totalTime":"P0DT1H5M"}]}</script></head><body></body></html>
        """
        let doc = try SwiftSoup.parse(html)
        let r = try #require(ArticlePasses.recipe(in: doc))
        #expect(r.ingredients == ["1 cup flour & salt"])
        #expect(r.steps == ["Mix.", "Bake until golden."])
        #expect(r.yield == "6")
        #expect(r.totalTime == "1 hr 5 min")
    }

    @Test @MainActor func pageChromeAroundRecipesGoes() async throws {
        let html = """
        <html><head><title>Soup</title></head><body><article><h1>Soup</h1>
        <figure><img src="https://e.com/soup.jpg"><figcaption><span>Credit: <p>Peyton Beckwith</p></span></figcaption></figure>\(p(1))
        <div class="table-of-content"><div class="accordion"><div class="AccordionItemContainerLabel">In this article</div><button><span>AccordionItemContainerButton</span></button></div><ul><li><a href="#one">One</a></li><li><a href="#two">Two</a></li></ul></div>
        <h2 id="one">One</h2>\(p(2))<h2 id="two">Two</h2>\(p(3))
        <div class="faq"><div class="AccordionItemContainerLabel-x"><p>Can I freeze the soup?</p></div><div class="AccordionItemContainerContent-x"><p>Yes, for up to three months in a sealed container; thaw it overnight in the fridge before reheating.</p></div></div>
        <div class="mntl-article-feedback"><div class="article-feedback__rating-section"><div>Was this page helpful?</div><button>Up</button></div><div class="article-feedback__feedback-section"><div>Tell us why!</div></div></div>
        <div class="mntl-vue-loading">Loading shell for RecipesUgcThreaded1 Vue component in Globe.</div></article></body></html>
        """
        let body = try await extract(html)
        #expect(body.contains("Credit: Peyton Beckwith"))
        #expect(body.contains("<strong>Can I freeze the soup?</strong>"))
        for junk in ["In this article", "Was this page helpful", "Tell us why", "Loading shell"] { #expect(!body.contains(junk), "\(junk)") }
    }
}
