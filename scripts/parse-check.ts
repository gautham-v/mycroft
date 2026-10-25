import { parseFeedXml } from "../src/lib/parse";
import assert from "node:assert/strict";
import { extractArticle, extractFromHtml } from "../src/lib/extract";
import { findAlternateFeeds, findChannelIdInHtml } from "../src/lib/feed-detect";
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
