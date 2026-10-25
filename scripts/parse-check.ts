import { parseFeedXml } from "../src/lib/parse";
import assert from "node:assert/strict";
import { extractArticle, extractFromHtml } from "../src/lib/extract";
import { detectFeed, findAlternateFeeds, findChannelIdInHtml } from "../src/lib/feed-detect";
import { normalizeSourceUrl, wwwAlternate } from "../src/lib/source-url";
import { relativeTime } from "../src/lib/time";
import { extractArticleMeta, findArticleLinks, listingTitle } from "../src/lib/scrape";

const HN = `<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>Hacker News: Newest</title><link>https://news.ycombinator.com/newest</link>
<item><title>Show HN: A tiny thing</title><description><![CDATA[
<p>Article URL: <a href="https://example.com/post">https://example.com/post</a></p>
<p>Comments URL: <a href="https://news.ycombinator.com/item?id=4242">https://news.ycombinator.com/item?id=4242</a></p>
<p>Points: 187</p>
<p># Comments: 64</p>
]]></description><pubDate>Fri, 23 Oct 2026 18:01:02 +0000</pubDate><link>https://example.com/post</link><dc:creator>pg</dc:creator><comments>https://news.ycombinator.com/item?id=4242</comments><guid isPermaLink="false">https://news.ycombinator.com/item?id=4242</guid></item>
</channel></rss>`;

const YT = `<?xml version="1.0" encoding="UTF-8"?><feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
<title>Fireship</title><link rel="alternate" href="https://www.youtube.com/channel/UCsBjURrPoezykLs9EqgamOA"/>
<entry><id>yt:video:dQw4w9WgXcQ</id><yt:videoId>dQw4w9WgXcQ</yt:videoId><yt:channelId>UCsBjURrPoezykLs9EqgamOA</yt:channelId><title>Rust in 100 seconds</title><link rel="alternate" href="https://www.youtube.com/watch?v=dQw4w9WgXcQ"/><author><name>Fireship</name></author><published>2026-10-22T14:00:00+00:00</published><updated>2026-10-22T15:00:00+00:00</updated>
<media:group><media:title>Rust in 100 seconds</media:title><media:content url="https://www.youtube.com/v/dQw4w9WgXcQ?version=3" type="application/x-shockwave-flash" width="640" height="390"/><media:thumbnail url="https://i2.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg" width="480" height="360"/><media:description>Learn Rust fast. Links &amp; more below.</media:description></media:group></entry></feed>`;

const BLOG = `<?xml version="1.0"?><rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Blog</title><link>https://blog.example.com/</link>
<item><title>Hello</title><link>/posts/hello</link><guid>abc</guid><pubDate>Thu, 22 Oct 2026 10:00:00 GMT</pubDate><description>Short &lt;b&gt;desc&lt;/b&gt;</description><content:encoded><![CDATA[<p>Body <img src="/img/a.png"></p>]]></content:encoded></item>
<item><title>With media</title><link>https://blog.example.com/m</link><media:content url="https://cdn.example.com/x.jpg" medium="image"/></item>
</channel></rss>`;

const ARTICLE = `<html><head><meta property="og:image" content="/og.png"><title>T</title></head><body><nav>menu</nav><article><h1>Title</h1>
${"<p>This is a long paragraph of meaningful article text that Readability should keep, with a <a href=\"/rel/link\">relative link</a>. </p>".repeat(8)}
<img src="pics/one.jpg" alt="x"><script>alert(1)</script><iframe src="https://evil.com/x"></iframe><iframe src="https://www.youtube-nocookie.com/embed/abc"></iframe></article></body></html>`;

async function main() {
  const hn = await parseFeedXml(HN, "rss", "https://hnrss.org/newest?points=100");
  console.log("HN:", hn.items[0]);
  const yt = await parseFeedXml(YT, "youtube", "https://www.youtube.com/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA");
  console.log("YT:", yt.title, yt.items[0]);
  const blog = await parseFeedXml(BLOG, "rss", "https://blog.example.com/feed");
  console.log("BLOG:", blog.items);
  const ex = extractFromHtml(ARTICLE, "https://site.example.com/a/b.html");
  console.log("EXTRACT lead:", ex.leadImage);
  console.log("EXTRACT html:", ex.contentHtml?.slice(0, 300), "...", ex.contentHtml?.slice(-400));
  console.log("ALT:", findAlternateFeeds('<link rel="alternate" type="application/rss+xml" href="/feed.xml">', "https://x.com/blog"));
  console.log("CHAN:", findChannelIdInHtml('foo "channelId":"UCsBjURrPoezykLs9EqgamOA" bar'));
  console.log("TIME:", relativeTime(Date.now() - 23 * 60e3), relativeTime(Date.now() - 3 * 3600e3), relativeTime(Date.now() - 2 * 86400e3));
  await checkRenderedFallback();
  checkScrape();
  checkFigures();
  await checkFeedFallback();
  checkSourceUrl();
  await checkWwwRetry();
}

function checkSourceUrl() {
  const n = normalizeSourceUrl;
  assert.equal(n("claude.com/resources/articles"), "https://claude.com/resources/articles");
  assert.equal(n("  anthropic.com/news \n"), "https://anthropic.com/news");
  assert.equal(n("www.anthropic.com/news"), "https://www.anthropic.com/news");
  assert.equal(n("openai.com/news"), "https://openai.com/news");
  assert.equal(n("OpenAI.com"), "https://openai.com/");
  assert.equal(n("youtube.com/@fireship"), "https://youtube.com/@fireship");
  assert.equal(n("http://example.com/feed.xml"), "http://example.com/feed.xml");
  assert.equal(n("HTTPS://Example.com/a?b=1"), "https://example.com/a?b=1");
  assert.equal(n("//example.com/x"), "https://example.com/x");
  assert.equal(n("localhost:3000/feed"), "https://localhost:3000/feed");
  assert.equal(n("http://localhost:3000/feed"), "http://localhost:3000/feed");
  for (const bad of ["", "   ", "foo", "hello world", "ftp://example.com", "javascript://alert(1)", "https://", "https://nodot/x"]) {
    assert.throws(() => n(bad), /url is required|Invalid URL/, bad);
  }
  assert.equal(wwwAlternate("https://anthropic.com/news"), "https://www.anthropic.com/news");
  assert.equal(wwwAlternate("https://www.anthropic.com/news?x=1"), "https://anthropic.com/news?x=1");
  assert.equal(wwwAlternate("https://www.com/"), null);
  assert.equal(wwwAlternate("http://localhost:3000/"), null);
  assert.equal(wwwAlternate("http://127.0.0.1/"), null);
  console.log("SOURCE URL: ok");
}

async function checkWwwRetry() {
  const FEED = `<?xml version="1.0"?><rss version="2.0"><channel><title>News</title><link>https://www.acme.com/</link></channel></rss>`;
  // Bare host fails DNS -> retried with www., feed found there.
  await withFetch(
    (u) => {
      if (u.startsWith("https://acme.com/")) throw new TypeError("fetch failed");
      return html(FEED, "application/rss+xml");
    },
    async (calls) => {
      const f = await detectFeed("acme.com/feed.xml");
      assert.deepEqual(calls, ["https://acme.com/feed.xml", "https://www.acme.com/feed.xml"]);
      assert.equal(f.feedUrl, "https://www.acme.com/feed.xml");
    },
  );
  // www. host 404s -> retried without www.
  await withFetch(
    (u) => (u.startsWith("https://www.") ? new Response("", { status: 404 }) : html(FEED, "application/rss+xml")),
    async (calls) => {
      const f = await detectFeed("www.acme.com/feed.xml");
      assert.deepEqual(calls, ["https://www.acme.com/feed.xml", "https://acme.com/feed.xml"]);
      assert.equal(f.feedUrl, "https://acme.com/feed.xml");
    },
  );
  // Both fail -> the original status is reported; network errors get a readable message.
  await withFetch(
    () => new Response("", { status: 503 }),
    async () => assert.rejects(detectFeed("acme.com/news"), /HTTP 503/),
  );
  await withFetch(
    () => {
      throw new TypeError("fetch failed");
    },
    async () => assert.rejects(detectFeed("acme.com/news"), /Could not reach acme\.com/),
  );
  // Success on the first try -> no retry.
  await withFetch(
    () => html(FEED, "application/rss+xml"),
    async (calls) => {
      await detectFeed("acme.com/feed.xml");
      assert.equal(calls.length, 1);
    },
  );
  console.log("WWW RETRY: ok");
}

const PROSE = "<p>This is a long paragraph of meaningful article text that Readability should keep, with enough words to score well, commas, and clauses.</p>".repeat(6);
const page = (body: string) => `<html><head><title>T</title></head><body><nav>menu</nav><article>${PROSE}${body}${PROSE}</article></body></html>`;

function checkFigures() {
  const url = "https://site.example.com/posts/a";
  const run = (body: string) => extractFromHtml(page(body), url).contentHtml ?? "";

  // Utility-CSS image wrapper (overflow-hidden, scroll-mt-*) with a <picture> of light/dark sources.
  let h = run(`<div class="group col-span-full"><figure class="grid scroll-mt-[calc(var(--x))]"><div class="relative overflow-hidden rounded-md">
    <picture><source media="(prefers-color-scheme: dark)" srcset="/d-640.png 640w, /d-1280.png 1280w"><img alt="Diagram" src="/l-1280.png" srcset="/l-640.png 640w"></picture>
    </div></figure></div>`);
  assert.match(h, /<picture><source media="\(prefers-color-scheme: dark\)" srcset="https:\/\/site\.example\.com\/d-640\.png 640w, https:\/\/site\.example\.com\/d-1280\.png 1280w" \/>/);
  assert.match(h, /<img alt="Diagram" src="https:\/\/site\.example\.com\/l-1280\.png"/);

  // Semantic "media" class names on wrappers (Readability's negative list) keep their image.
  h = run(`<figure class="media__container"><div class="media-image-block"><img src="/m.jpg" width="1440" height="810"></div><figcaption>Map</figcaption></figure>`);
  assert.match(h, /src="https:\/\/site\.example\.com\/m\.jpg"/);

  // Lazy images: data-src over a data: placeholder; srcset-only gets its largest candidate; commas inside URLs.
  h = run(`<p><img data-src="/lazy.jpg" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="></p>
    <p><img data-srcset="/c/w_640,c_fill/x.jpg 640w, /c/w_1280,c_fill/x.jpg 1280w"></p>`);
  assert.match(h, /src="https:\/\/site\.example\.com\/lazy\.jpg"/);
  assert.match(h, /src="https:\/\/site\.example\.com\/c\/w_1280,c_fill\/x\.jpg"/);
  assert.match(h, /srcset="https:\/\/site\.example\.com\/c\/w_640,c_fill\/x\.jpg 640w, https:\/\/site\.example\.com\/c\/w_1280,c_fill\/x\.jpg 1280w"/);

  // Chart drawn client-side: caption only -> note linking to the figure on the original page.
  h = run(`<figure><div><div id="chart-1" style="height:400px"></div></div><figcaption><p>We plot the cumulative number of findings.</p></figcaption></figure>`);
  assert.match(h, /Interactive figure not shown here[\s\S]*href="https:\/\/site\.example\.com\/posts\/a#chart-1"/);
  assert.match(h, /We plot the cumulative number of findings/);

  // Inline SVG chart kept (shapes only, no script/handlers/external refs); icon SVGs dropped.
  h = run(`<div class="chart"><svg viewBox="0 0 600 300" onload="alert(1)"><script>alert(2)</script><defs><linearGradient id="g"><stop offset="0" stop-color="red"/></linearGradient></defs><rect fill="url(#g)" width="1" height="1"/><rect width="10" height="20" fill="url(https://evil.example/x#p)"/><path d="M0 0L10 10" stroke="#333"/><text x="5" y="5">Tokens</text><foreignObject><div>x</div></foreignObject></svg></div>
    <p>Copy <svg width="16" height="16" viewBox="0 0 16 16"><path d="M1 1"/></svg></p>
    <p>Brand <svg aria-hidden="true" viewBox="0 0 1000 1000"><polygon points="0 0 1 1"/></svg></p>`);
  assert.match(h, /<svg viewbox="0 0 600 300">/);
  assert.match(h, /<path d="M0 0L10 10" stroke="#333" \/>|<path d="M0 0L10 10" stroke="#333"><\/path>/);
  assert.match(h, /<text x="5" y="5">Tokens<\/text>/);
  assert.match(h, /<linearGradient id="g"><stop offset="0" stop-color="red"/i);
  assert.match(h, /fill="url\(#g\)"/);
  assert.doesNotMatch(h, /onload|<script|alert|evil\.example|foreignobject|viewbox="0 0 16 16"|polygon/i);

  // Video in text-free wrappers survives Readability and gets controls; fallback poster dropped.
  h = run(`<div class="video-wrapper"><div class="media-video-container"><video autoplay loop muted poster="/static/video_poster_fallback.jpg" preload="none"><source data-src="/v.mp4" type="video/mp4">Your browser does not support the video tag.</video></div></div>`);
  assert.match(h, /<video autoplay loop muted preload="metadata" controls><source src="https:\/\/site\.example\.com\/v\.mp4" type="video\/mp4" \/>/);

  // Light and dark copies side by side: keep the light one.
  h = run(`<figure><div><picture class="image light-mode"><img src="/light.png"></picture><picture class="image dark-mode-alternative"><img src="/dark.png"></picture></div><figcaption>Fig</figcaption></figure>
    <p><img class="block dark:hidden" src="/tw-light.png"><img class="hidden dark:block" src="/tw-dark.png"></p>`);
  assert.match(h, /light\.png/);
  assert.match(h, /tw-light\.png/);
  assert.doesNotMatch(h, /dark\.png/);
  console.log("FIGURES: ok");
}

async function checkFeedFallback() {
  const FEED = `<?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>B</title><link>https://blocked.example.com/</link>
<item><title>Post</title><link>https://blocked.example.com/p/1</link><guid>g1</guid><content:encoded><![CDATA[${PROSE}<figure><img src="/fig.png"><figcaption>Cap</figcaption></figure>]]></content:encoded></item>
<item><title>Teaser</title><link>https://blocked.example.com/p/2</link><guid>g2</guid><content:encoded><![CDATA[<p>Short teaser.</p>]]></content:encoded></item>
</channel></rss>`;
  const feedRef = (guid: string) => ({ feedUrl: "https://blocked.example.com/feed.xml", guid });
  // Page 403s to both User-Agents -> full article from the feed's content:encoded, no Jina call.
  await withFetch(
    (u) => (u.endsWith("/feed.xml") ? html(FEED, "application/rss+xml") : new Response("", { status: 403 })),
    async (calls) => {
      const out = await extractArticle("https://blocked.example.com/p/1", feedRef("g1"));
      assert.deepEqual(calls, ["https://blocked.example.com/p/1", "https://blocked.example.com/p/1", "https://blocked.example.com/feed.xml"]);
      assert.match(out.contentHtml ?? "", /meaningful article text/);
      assert.match(out.contentHtml ?? "", /src="https:\/\/blocked\.example\.com\/fig\.png"/);
    },
  );
  // Feed only has a teaser -> Jina; Cloudflare challenge -> no browser-UA retry.
  await withFetch(
    (u) =>
      u.endsWith("/feed.xml")
        ? html(FEED, "application/rss+xml")
        : u.startsWith("https://r.jina.ai/")
          ? html(ARTICLE, "text/plain")
          : new Response("", { status: 403, headers: { "cf-mitigated": "challenge" } }),
    async (calls) => {
      const out = await extractArticle("https://blocked.example.com/p/2", feedRef("g2"));
      assert.equal(calls.length, 3);
      assert.equal(out.rendered, true);
    },
  );
  console.log("FEED FALLBACK: ok");
}

const LISTING = `<html><head><title>Newsroom \\ Acme</title></head><body>
<nav><a href="/news">News</a><a href="/news/policy">Policy</a><a href="/about">About</a></nav>
<a href="/news/first-post">First post<span>A summary</span></a><a href="/news/policy">Policy</a>
<a href="https://www.acme.com/news/second-post/#top">Second post</a><a href="/news/first-post?ref=x">First post</a>
<a href="/de/news/first-post">Erster</a><a href="/news/2">2</a><a href="?page=2">Next</a><a href="/news/page/2">Next</a>
<a href="https://other.com/news/elsewhere">Elsewhere</a></body></html>`;

const ARTICLE_META = `<html><head><title>Second post | Acme</title>
<meta property="og:title" content="Second post | Acme"><meta property="og:type" content="article">
<meta property="og:description" content="Desc"><meta property="og:image" content="/img/2.png">
<script type="application/ld+json">{"@graph":[{"@type":"WebSite"},{"@type":"NewsArticle","datePublished":"2026-10-20T00:00:00Z","author":[{"@type":"Person","name":"Ada"}]}]}</script>
</head><body><h1>Second post</h1></body></html>`;

function checkScrape() {
  assert.deepEqual(findArticleLinks(LISTING, "https://acme.com/news"), [
    "https://acme.com/news/first-post",
    "https://acme.com/news/second-post",
  ]);
  // No links one level below the listing: fall back to the most common slug prefix.
  const home = `<a href="/blog/a-post">a</a><a href="/blog/b-post">b</a><a href="/about-us">About</a>`;
  assert.deepEqual(findArticleLinks(home, "https://acme.com/"), ["https://acme.com/blog/a-post", "https://acme.com/blog/b-post"]);
  assert.deepEqual(findArticleLinks("<a href='/x'>x</a>", "https://acme.com/news"), []);
  assert.equal(listingTitle(LISTING, "https://acme.com/news"), "Acme Newsroom");
  const m = extractArticleMeta(ARTICLE_META, "https://acme.com/news/second-post");
  assert.equal(m.title, "Second post");
  assert.equal(m.publishedAt?.toISOString(), "2026-10-20T00:00:00.000Z");
  assert.equal(m.author, "Ada");
  assert.equal(m.thumbnailUrl, "https://acme.com/img/2.png");
  console.log("SCRAPE: ok");
}

const SHELL = `<html><head><meta property="og:image" content="https://spa.example.com/og.png"></head><body><div id="root"></div><script src="/app.js"></script></body></html>`;

async function withFetch(routes: (url: string) => Response, fn: (calls: string[]) => Promise<void>) {
  const real = globalThis.fetch;
  const calls: string[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url = String(input);
    calls.push(url);
    return routes(url);
  }) as typeof fetch;
  try {
    await fn(calls);
  } finally {
    globalThis.fetch = real;
  }
}

const html = (body: string, ct = "text/html") => new Response(body, { headers: { "content-type": ct } });

async function checkRenderedFallback() {
  // Empty React shell -> Jina fallback; og:image from the original page wins.
  await withFetch(
    (u) => (u.startsWith("https://r.jina.ai/") ? html(ARTICLE, "text/plain") : html(SHELL)),
    async (calls) => {
      const out = await extractArticle("https://spa.example.com/post");
      assert.equal(calls[1], "https://r.jina.ai/https://spa.example.com/post");
      assert.equal(out.rendered, true);
      assert.match(out.contentHtml ?? "", /meaningful article text/);
      assert.equal(out.leadImage, "https://spa.example.com/og.png");
    },
  );
  // Normal article -> no fallback.
  await withFetch(
    () => html(ARTICLE),
    async (calls) => {
      const out = await extractArticle("https://site.example.com/a/b.html");
      assert.equal(calls.length, 1);
      assert.equal(out.rendered, undefined);
      assert.ok(out.contentHtml);
    },
  );
  // Shell + Jina error -> null, no throw.
  await withFetch(
    (u) => (u.startsWith("https://r.jina.ai/") ? new Response("nope", { status: 500 }) : html(SHELL)),
    async () => {
      const out = await extractArticle("https://spa.example.com/post");
      assert.equal(out.contentHtml, null);
      assert.equal(out.leadImage, "https://spa.example.com/og.png");
    },
  );
  // Original fetch fails -> fallback; lead image from rendered content when no og:image anywhere.
  const noOg = ARTICLE.replace(/<meta property="og:image"[^>]*>/, "");
  await withFetch(
    (u) => (u.startsWith("https://r.jina.ai/") ? html(noOg, "text/plain") : new Response("", { status: 403 })),
    async () => {
      const out = await extractArticle("https://site.example.com/a/b.html");
      assert.equal(out.rendered, true);
      assert.equal(out.leadImage, "https://site.example.com/a/pics/one.jpg");
    },
  );
  // Original fails and Jina fails -> original error is rethrown, as before.
  await withFetch(
    (u) => new Response("", { status: u.startsWith("https://r.jina.ai/") ? 500 : 403 }),
    async () => {
      await assert.rejects(extractArticle("https://site.example.com/a/b.html"), /HTTP 403/);
    },
  );
  console.log("RENDERED FALLBACK: ok");
}
main();
