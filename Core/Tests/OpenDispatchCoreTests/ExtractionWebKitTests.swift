import AVFoundation
import Foundation
import Testing
@testable import OpenDispatchCore

/// The real Readability-in-WebKit step. It needs WebKit's helper processes: this works under `swift test` on a
/// logged-in Mac, but not in every headless/sandboxed environment, so set OPENDISPATCH_SKIP_WEBKIT_TESTS=1 to skip it.
/// OPENDISPATCH_LIVE_URL=<article url> additionally runs the whole extractor against a live page (manual check only).
@Suite("ExtractionWebKit", .enabled(if: ProcessInfo.processInfo.environment["OPENDISPATCH_SKIP_WEBKIT_TESTS"] != "1"))
struct ExtractionWebKitTests {
    @Test @MainActor func readabilityRunsInWebKit() async throws {
        let paragraph = String(repeating: "The quick brown fox jumps over the lazy dog near the riverbank today. ", count: 8)
        let html = """
        <!doctype html><html><head><title>Story</title></head><body>
        <nav><a href="/">Home</a><a href="/about">About</a></nav>
        <article><h1>Story</h1>
        <p>\(paragraph)</p><p>\(paragraph)</p><p><a href="/next">Relative link</a> \(paragraph)</p>
        <img src="/img/hero.jpg" width="800" height="400">
        </article>
        <footer>Copyright</footer>
        <script>document.body.innerHTML = "scripts must not run";</script>
        </body></html>
        """
        let engine = WebKitReadability(timeout: 20)
        let content = try #require(try await engine.articleContent(html: html, baseURL: "https://example.com/posts/1"))
        #expect(content.contains("quick brown fox"))
        #expect(content.contains("https://example.com/next"))
        #expect(!content.contains("Copyright"))

        let extraction = ArticleExtraction(readability: engine)
        let out = try await extraction.extract(html: html, pageURL: "https://example.com/posts/1")
        let body = try #require(out.contentHtml)
        #expect(body.contains("target=\"_blank\""))
        #expect(out.leadImage == "https://example.com/img/hero.jpg")
    }

    @Test @MainActor func mediaSurvivesReadability() async throws {
        let paragraph = String(repeating: "Charts and clips should survive the article parser untouched here. ", count: 8)
        let html = """
        <!doctype html><html><head><title>Charts</title></head><body><article><h1>Charts</h1>
        <p>\(paragraph)</p>
        <div class="chart-wrap"><svg viewBox="0 0 400 300" width="400" height="300"><rect x="0" y="0" width="10" height="20" fill="url(#g)"/></svg></div>
        <p>\(paragraph)</p>
        <div class="player"><video src="/clip.mp4" poster="/poster.jpg"></video></div>
        <p>\(paragraph)</p>
        </article></body></html>
        """
        let out = try await ArticleExtraction(readability: WebKitReadability(timeout: 20)).extract(html: html, pageURL: "https://example.com/a")
        let body = try #require(out.contentHtml)
        #expect(body.contains("<svg"))
        #expect(body.contains("<rect"))
        #expect(body.contains("<video"))
        #expect(body.contains("https://example.com/clip.mp4"))
        #expect(!body.contains("opendispatch.invalid"))
    }

    /// OPENDISPATCH_LIVE_VIDEO=<video page url>: the stream the site's player plays (manual check only).
    @Test @MainActor func liveSiteVideo() async throws {
        guard let page = ProcessInfo.processInfo.environment["OPENDISPATCH_LIVE_VIDEO"], let url = URL(string: page) else { return }
        let stream = await SiteVideoResolver.stream(for: url)
        print("LIVE stream=\(stream?.absoluteString ?? "nil")")
        let asset = AVURLAsset(url: try #require(stream))
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        print("LIVE playable=\(playable) duration=\(duration.seconds)")
        #expect(playable)
    }

    /// OPENDISPATCH_LIVE_BATCH=<file of urls, one per line> OPENDISPATCH_LIVE_DIR=<dir>: extracts each page and writes
    /// <dir>/<n>.json (url, lead, rendered, paywalled, html or error) for a rendering review (manual check only).
    @Test @MainActor func liveBatch() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["OPENDISPATCH_LIVE_BATCH"], let dir = env["OPENDISPATCH_LIVE_DIR"] else { return }
        let urls = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let extractor = DefaultContentExtractor(parser: DefaultFeedParser())
        await withTaskGroup(of: Void.self) { group in
            for (n, url) in urls.enumerated() {
                if n >= 4 { await group.next() }
                group.addTask { @MainActor in
                    var record: [String: Any] = ["url": url]
                    do {
                        let out = try await extractor.extractArticle(url: url, feed: nil)
                        record["lead"] = out.leadImage ?? NSNull()
                        record["rendered"] = out.rendered
                        record["paywalled"] = out.paywalled
                        record["html"] = out.contentHtml ?? NSNull()
                    } catch {
                        record["error"] = String(describing: error)
                    }
                    let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted])
                    FileManager.default.createFile(atPath: "\(dir)/\(n).json", contents: data)
                    print("LIVE \(n) \(url) \(record["error"] ?? "ok")")
                }
            }
        }
    }

    @Test @MainActor func liveURL() async throws {
        guard let url = ProcessInfo.processInfo.environment["OPENDISPATCH_LIVE_URL"] else { return }
        let out = try await DefaultContentExtractor(parser: DefaultFeedParser()).extractArticle(url: url, feed: nil)
        let body = try #require(out.contentHtml)
        print("LIVE lead=\(out.leadImage ?? "nil") rendered=\(out.rendered) chars=\(body.count)")
        print(String(body.prefix(Int(ProcessInfo.processInfo.environment["OPENDISPATCH_LIVE_CHARS"] ?? "") ?? 3000)))
        #expect(!body.isEmpty)
    }
}
