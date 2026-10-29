import Foundation
import Testing
@testable import OpenDispatchCore

/// Reference and technical pages: Apple's documentation (DocC JSON), Stack Exchange questions (the sites' API),
/// MediaWiki, MDN, Sphinx, LaTeXML papers and arXiv abstracts, README badges, MathML in the sanitizer.
@Suite("Extraction: reference pages")
struct ExtractionReferenceTests {
    static let para = String(repeating: "The reader shows the whole story, cleanly, without the page around it. ", count: 4)
    var p: String { "<p>\(Self.para)</p>" }

    /// A page through the pipeline with a stand-in Readability that returns the article element.
    func extract(_ body: String, head: String = "", url: String = "https://e.com/story") async throws -> String {
        let html = "<html><head><title>T</title>\(head)</head><body><article>\(body)</article></body></html>"
        let out = try await ArticleExtraction(readability: FakeReadability()).extract(html: html, pageURL: url)
        // The test serializer indents; the real one doesn't. Compare without the indentation.
        return try #require(out.contentHtml).replacingOccurrences(of: ">\\s+", with: ">", options: .regularExpression)
            .replacingOccurrences(of: "\\s+<", with: "<", options: .regularExpression)
    }

    // MARK: Apple documentation

    @Test func appleDocumentationComesFromItsJSON() throws {
        #expect(AppleDocumentation.apiURL("https://developer.apple.com/documentation/SwiftUI/View")
                == "https://developer.apple.com/tutorials/data/documentation/swiftui/view.json")
        #expect(AppleDocumentation.apiURL("https://developer.apple.com/documentation/foundation/urlsession/data(for:delegate:)?language=objc")
                == "https://developer.apple.com/tutorials/data/documentation/foundation/urlsession/data(for:delegate:).json")
        #expect(AppleDocumentation.apiURL("https://developer.apple.com/news/") == nil)
        let json: [String: Any] = [
            "kind": "symbol",
            "metadata": ["roleHeading": "Protocol", "modules": [["name": "SwiftUI"]], "platforms": [["name": "iOS", "introducedAt": "13.0"], ["name": "macOS", "introducedAt": "10.15"]]],
            "abstract": [["type": "text", "text": "A type that represents part of your app's user interface."]],
            "primaryContentSections": [
                ["kind": "declarations", "declarations": [["languages": ["swift"], "tokens": [["kind": "keyword", "text": "protocol"], ["kind": "text", "text": " "], ["kind": "identifier", "text": "View"]]]]],
                ["kind": "content", "content": [
                    ["type": "heading", "level": 2, "text": "Overview"],
                    ["type": "paragraph", "inlineContent": [["type": "text", "text": "Declare types that conform to "], ["type": "codeVoice", "code": "View"], ["type": "text", "text": ", see "],
                                                            ["type": "reference", "identifier": "doc://x/Text", "isActive": true]]],
                    ["type": "codeListing", "syntax": "swift", "code": ["struct MyView: View {", "    var body: some View { Text(\"Hi\") }", "}"]],
                    ["type": "aside", "style": "note", "content": [["type": "paragraph", "inlineContent": [["type": "text", "text": "Mind the main actor."]]]]],
                ]],
            ],
            "topicSections": [["title": "Implementing a custom view", "identifiers": ["doc://x/body"]]],
            "references": [
                "doc://x/Text": ["title": "Text", "url": "/documentation/swiftui/text", "role": "symbol", "kind": "symbol"],
                "doc://x/body": ["title": "body", "url": "/documentation/swiftui/view/body", "role": "symbol", "abstract": [["type": "text", "text": "The content and behavior of the view."]]],
            ],
        ]
        let out = try #require(AppleDocumentation.render(try JSONSerialization.data(withJSONObject: json), pageURL: "https://developer.apple.com/documentation/swiftui/view"))
        let body = try #require(out.contentHtml)
        #expect(body.hasPrefix("<p>A type that represents part of your app's user interface.</p>"))
        #expect(body.contains("Protocol · SwiftUI · iOS 13.0+ · macOS 10.15+"))
        #expect(body.contains("<pre><code>protocol View</code></pre>"))
        #expect(body.contains("<h2>Overview</h2>"))
        #expect(body.contains("<a href=\"https://developer.apple.com/documentation/swiftui/text\" target=\"_blank\" rel=\"noopener noreferrer\"><code>Text</code></a>"))
        #expect(body.contains("language-swift"))
        #expect(body.contains("x-callout"))
        #expect(body.contains("<h2>Topics</h2><h3>Implementing a custom view</h3><ul><li><a href=\"https://developer.apple.com/documentation/swiftui/view/body\""))
        #expect(body.contains("The content and behavior of the view."))
        // A page that isn't a symbol or an article (the technologies index) is no page here.
        #expect(AppleDocumentation.render(Data(#"{"kind":"collectionGroup"}"#.utf8), pageURL: "https://developer.apple.com/documentation/x") == nil)
    }

    // MARK: Stack Exchange

    @Test func stackExchangeSitesAndQuestionsAreFoundByAddress() {
        #expect(StackExchangeQuestion.question("https://stackoverflow.com/questions/927358/how-do-i-undo")?.site == "stackoverflow")
        #expect(StackExchangeQuestion.question("https://stackoverflow.com/questions/927358/how-do-i-undo")?.id == "927358")
        #expect(StackExchangeQuestion.question("https://unix.stackexchange.com/q/123")?.site == "unix")
        #expect(StackExchangeQuestion.question("https://askubuntu.com/questions/9/x")?.site == "askubuntu")
        #expect(StackExchangeQuestion.question("https://stackoverflow.com/questions/tagged/git") == nil)
        #expect(StackExchangeQuestion.question("https://example.com/questions/12/x") == nil)
        #expect(StackExchangeQuestion.question("https://meta.unix.stackexchange.com/questions/12/x") == nil)
    }

    @Test func stackExchangeQuestionShowsTheAcceptedAnswerFirst() async throws {
        let question = #"{"items":[{"question_id":7,"title":"T","score":1200,"answer_count":3,"tags":["git","undo"],"accepted_answer_id":22,"body":"<p>How do I undo a commit?</p>"}]}"#
        let answers = #"{"items":[{"answer_id":11,"score":300,"body":"<p>Use revert.</p>","owner":{"display_name":"Ann &amp; Co"}},{"answer_id":12,"score":5,"body":"<h2>Soft</h2><pre class=\"lang-bash\"><code>git reset --soft HEAD~</code></pre>"}]}"#
        let accepted = #"{"items":[{"answer_id":22,"score":150,"body":"<p>Use reset.</p>","owner":{"display_name":"Bob"}}]}"#
        let out = await StackExchangeQuestion.extract(url: "https://stackoverflow.com/questions/7/undo") { u in
            if u.contains("/answers/22?") { return Data(accepted.utf8) }
            if u.contains("/questions/7/answers?") { return Data(answers.utf8) }
            if u.contains("/questions/7?") { return Data(question.utf8) }
            throw HTTPError.status(404)
        }
        let body = try #require(out?.contentHtml)
        #expect(body.hasPrefix("<p><small>1,200 votes · 3 answers · git, undo</small></p><p>How do I undo a commit?</p>"))
        let accepted1 = try #require(body.range(of: "<h2>Accepted answer</h2>"))
        let first = try #require(body.range(of: "Use reset."))
        let second = try #require(body.range(of: "Use revert."))
        #expect(accepted1.lowerBound < first.lowerBound && first.lowerBound < second.lowerBound)
        #expect(body.contains("150 votes · Bob"))
        #expect(body.contains("300 votes · Ann &amp; Co"))
        #expect(body.contains("<h3>Soft</h3>"))
        #expect(body.contains("<pre class=\"lang-bash\"><code>git reset --soft HEAD~</code></pre>"))
    }

    @Test func stackExchangeFailureLeavesTheRestToTheNormalFetch() async {
        let out = await StackExchangeQuestion.extract(url: "https://stackoverflow.com/questions/7/undo") { _ in throw HTTPError.status(429) }
        #expect(out == nil)
    }

    // MARK: MediaWiki

    private func wiki(_ body: String) -> String {
        """
        <div id="mw-content-text"><div class="mw-parser-output">
        <table class="infobox"><tbody><tr><td>Population 1</td></tr></tbody></table>
        <p>\(Self.para) one<sup class="reference"><a href="#cite_note-1">[1]</a></sup></p>
        \(body)
        </div></div>
        """
    }

    @Test func mediaWikiKeepsShortHeadingsAndDropsEndMatter() async throws {
        let out = try await extract(wiki("""
        <section><div class="mw-heading mw-heading2"><h2 id="History">History</h2><span class="mw-editsection"><span>[</span><a href="/w?action=edit">edit</a><span>]</span></span></div>
        <p>\(Self.para) two</p>
        <table><tbody class="mw-empty-elt"><tr></tr></tbody><caption>Teams</caption><tbody><tr><td>A</td></tr></tbody></table></section>
        <section><div class="mw-heading mw-heading2"><h2 id="See_also">See also</h2></div><ul><li><a href="/wiki/A">A</a></li><li><a href="/wiki/B">B</a></li></ul></section>
        <section><div class="mw-heading mw-heading2"><h2 id="Notes">Notes</h2></div><ol class="references"><li>Note one</li></ol>
        <section><div class="mw-heading mw-heading3"><h3 id="Sources">Sources</h3></div><ul><li>Source one</li></ul></section></section>
        <section><div class="mw-heading mw-heading2"><h2 id="References">References</h2></div><div class="reflist"><ol><li>Ref one</li></ol></div></section>
        <div class="navbox"><p>Navigation</p></div>
        """))
        #expect(out.contains(">History</h2>"))
        #expect(!out.contains("edit") && !out.contains("[1]") && !out.contains("Population"))
        #expect(out.contains("<caption>Teams</caption>"))
        #expect(out.contains(">See also</h2>"))
        #expect(!out.contains("Note one") && !out.contains("Source one") && !out.contains("Ref one") && !out.contains("Navigation"))
    }

    @Test func aLongSeeAlsoIsDropped() async throws {
        let items = (1...14).map { "<li><a href=\"/wiki/P\($0)\">Page \($0)</a></li>" }.joined()
        let out = try await extract(wiki("""
        <h2 id="History">History</h2><p>\(Self.para) two</p>
        <h2 id="See_also">See also</h2><ul>\(items)</ul>
        <h2 id="External_links">External links</h2><ul><li>Official website</li></ul>
        """))
        #expect(out.contains(">History</h2>"))
        #expect(!out.contains("Page 3") && !out.contains("See also") && !out.contains("Official website"))
    }

    @Test func aNonWikiPageKeepsItsReferencesHeading() async throws {
        let out = try await extract("\(p)<h2>References</h2><ul><li>Smith 2020</li></ul>")
        #expect(out.contains("Smith 2020"))
    }

    // MARK: MDN

    @Test func mdnSummaryJoinsTheBodyAndItsChromeGoes() async throws {
        let out = try await extract("""
        <div class="layout__header"><h1>Array.prototype.map()</h1>
        <details class="baseline-indicator"><summary>Baseline</summary><p>Widely available</p></details>
        <section class="content-section"><p>The map() method creates a new array. \(Self.para)</p></section></div>
        <div class="layout__body"><section class="content-section"><h2>Syntax</h2>
        <div class="code-example"><div class="example-header"><span class="language-name">js</span></div><pre><code>map(fn)</code></pre></div>
        <div class="notecard note"><p><strong>Note:</strong> Mind the holes in sparse arrays.</p></div></section>
        <section class="content-section"><h2>Browser compatibility</h2><mdn-compat-table-lazy><p>Enable JavaScript to view this browser compatibility table.</p></mdn-compat-table-lazy></section></div>
        """)
        let summary = try #require(out.range(of: "The map() method creates a new array."))
        let syntax = try #require(out.range(of: "Syntax"))
        #expect(summary.lowerBound < syntax.lowerBound)
        #expect(!out.contains("Widely available") && !out.contains(">js<") && !out.contains("Enable JavaScript") && !out.contains("Browser compatibility"))
        #expect(out.contains("<div class=\"x-callout\"><p>Note</p><p>") && out.contains("Mind the holes in sparse arrays."))
    }

    // MARK: Sphinx

    @Test func sphinxSignaturesBecomeHeadingsAndAdmonitionsCards() async throws {
        let out = try await extract("""
        <section><h2>functools<a class="headerlink" href="#module" title="Link to this heading">¶</a></h2>
        <dl class="py function"><dt class="sig sig-object py" id="functools.cache"><span class="sig-name">cache</span><span>(</span><em class="sig-param">user_function</em><span>)</span><a class="headerlink" href="#functools.cache" title="Link to this definition">¶</a></dt>
        <dd><p>\(Self.para)</p>
        <div class="admonition note"><p class="admonition-title">Note</p><p>Slower execution.</p></div>
        <div class="versionadded"><p><span class="versionmodified added">Added in version 3.9.</span></p></div></dd></dl></section>
        """)
        #expect(!out.contains("¶") && !out.contains("headerlink"))
        #expect(out.contains("<h3>cache(<em>user_function</em>)</h3>") || out.contains("<h3><span>cache</span>"))
        #expect(!out.contains("<dt") && !out.contains("<dl"))
        #expect(out.contains("<div class=\"x-callout\"><p>Note</p><p>Slower execution.</p></div>"))
        #expect(out.contains("<em>Added in version 3.9.</em>"))
    }

    // MARK: LaTeXML and arXiv

    @Test func latexMLMathKeepsOneCopyAndFiguresComeThrough() async throws {
        let math = #"<math class="ltx_Math" alttext="h_{t}" display="inline"><semantics><msub><mi>h</mi><mi>t</mi></msub><annotation encoding="application/x-tex">h_{t}</annotation></semantics></math>"#
        let out = try await extract("""
        <div class="ltx_authors">Ashish Vaswani Affiliation: Google Brain</div>
        <p>\(Self.para) a hidden state \(math) at position t.<span class="ltx_note ltx_role_footnote"><sup class="ltx_note_mark">1</sup><span class="ltx_note_outer"><span class="ltx_note_content"><sup class="ltx_note_mark">1</sup><span class="ltx_tag ltx_tag_note">1</span> A footnote about dot products.</span></span></span></p>
        <table class="ltx_equation ltx_eqn_table"><tbody><tr class="ltx_equation ltx_eqn_row"><td class="ltx_eqn_cell"></td><td class="ltx_eqn_cell"><math display="block" alttext="a=b"><semantics><mrow><mi>a</mi><mo>=</mo><mi>b</mi></mrow><annotation encoding="application/x-tex">a=b</annotation></semantics></math></td><td class="ltx_eqn_cell ltx_eqn_eqno"><span class="ltx_tag ltx_tag_equation">(1)</span></td></tr></tbody></table>
        <ul><li><span class="ltx_tag ltx_tag_item">•</span><p>An item of the list.</p></li></ul>
        <figure><object type="image/svg+xml" data="figs/attention.svg" width="476" height="241"></object><figcaption>Figure 3: Attention.</figcaption></figure>
        """, head: #"<meta name="generator" content="LaTeXML">"#, url: "https://arxiv.org/html/1706.03762")
        #expect(out.contains("<math display=\"inline\"><msub><mi>h</mi><mi>t</mi></msub></math>"))
        #expect(out.contains("<math display=\"block\"><mrow><mi>a</mi><mo>=</mo><mi>b</mi></mrow></math>"))
        #expect(!out.contains("h_{t}") && !out.contains("annotation") && !out.contains("semantics") && !out.contains("(1)"))
        #expect(!out.contains("Vaswani") && !out.contains("•"))
        #expect(out.contains("<sup>1</sup></p><p><small><sup>1</sup>A footnote about dot products.</small></p>"))
        #expect(out.contains("<img src=\"https://arxiv.org/html/figs/attention.svg\""))
    }

    @Test func arxivAbstractPageIsItsAbstractAndSubjects() async throws {
        let out = try await extract("""
        <div id="abs"><div class="dateline">[Submitted on 12 Jun 2017]</div><h1 class="title"><span class="descriptor">Title:</span>Attention Is All You Need</h1>
        <div class="authors"><span class="descriptor">Authors:</span><a href="/a">Ashish Vaswani</a></div>
        <a class="mobile-submission-download" href="/pdf/1706.03762">View PDF</a>
        <blockquote class="abstract mathjax"><span class="descriptor">Abstract:</span>\(Self.para)</blockquote>
        <div class="metatable"><table><tr><td class="tablecell label">Subjects:</td><td class="tablecell subjects">Computation and Language (cs.CL)</td></tr></table></div></div>
        <div class="submission-history"><h2>Submission history</h2><p>From: Llion Jones</p></div>
        """, url: "https://arxiv.org/abs/1706.03762")
        #expect(out.hasPrefix("<div><p>The reader shows the whole story"))
        #expect(!out.contains("Abstract:") && !out.contains("View PDF") && !out.contains("Submission history") && !out.contains("Vaswani") && !out.contains("Submitted on"))
        #expect(out.contains("<p><small>Subjects: Computation and Language (cs.CL)</small></p>"))
    }

    @Test func arxivPDFLinksReadAsTheirAbstractPage() {
        #expect(ArticlePasses.arxivAbstractURL(forPDF: "https://arxiv.org/pdf/2005.14165") == "https://arxiv.org/abs/2005.14165")
        #expect(ArticlePasses.arxivAbstractURL(forPDF: "https://arxiv.org/pdf/1706.03762v7.pdf") == "https://arxiv.org/abs/1706.03762v7")
        #expect(ArticlePasses.arxivAbstractURL(forPDF: "https://arxiv.org/pdf/hep-th/9901001") == "https://arxiv.org/abs/hep-th/9901001")
        #expect(ArticlePasses.arxivAbstractURL(forPDF: "https://arxiv.org/abs/2005.14165") == nil)
        #expect(ArticlePasses.arxivAbstractURL(forPDF: "https://example.com/pdf/2005.14165") == nil)
    }

    // MARK: Sanitizer and badges

    @Test func sanitizerKeepsPresentationMathMLOnly() {
        let out = ArticleSanitizer.sanitize(#"<p><math display="inline" onclick="x()" class="c"><semantics><mfrac><mn>1</mn><msqrt><mi>d</mi></msqrt></mfrac><annotation encoding="x">\frac{1}{\sqrt d}</annotation></semantics></math></p>"#)
        #expect(out == #"<p><math display="inline"><mfrac><mn>1</mn><msqrt><mi>d</mi></msqrt></mfrac></math></p>"#)
        #expect(ArticleSanitizer.sanitize("<table><caption>Teams</caption><tbody><tr><td>A</td></tr></tbody></table>").contains("<caption>Teams</caption>"))
    }

    @Test func readmeBadgesAreMarkedToSitInline() async throws {
        let out = try await extract("""
        \(p)<p><a href="https://ci.example/run"><img src="https://github.com/o/r/actions/workflows/push.yml/badge.svg" alt="Build"></a>
        <a href="https://x.example"><img src="https://camo.githubusercontent.com/abc" data-canonical-src="https://img.shields.io/github/downloads/o/r/total.svg" alt="Downloads"></a></p>
        <p><img src="https://example.com/screenshot.png" width="820" alt="Screenshot"></p>
        """)
        #expect(out.components(separatedBy: "class=\"x-badge\"").count == 3)
        #expect(out.contains("<img src=\"https://example.com/screenshot.png\" width=\"820\" alt=\"Screenshot\""))
    }

    @Test func aSphinxSocialPreviewIsNoLead() {
        #expect(LeadImage.isGenericCard("https://docs.python.org/3.15/_images/social_previews/summary_library_functools_d90ef356.png"))
    }
}
