import { findFeedItemHtml, parseFeedXml } from "../src/lib/parse";
import assert from "node:assert/strict";
import {
  cleanArticle,
  extractArticle,
  extractFromFeedHtml,
  extractFromHtml,
  mergeSplitContainers,
  removePlayerChrome,
  pickedOutsideRegion,
  preferFeed,
  sanitizeArticle,
} from "../src/lib/extract";
import { parseHTML } from "linkedom";
import { detectFeed, findAlternateFeeds, findChannelIdInHtml } from "../src/lib/feed-detect";
import { normalizeSourceUrl, wwwAlternate } from "../src/lib/source-url";
import { relativeTime } from "../src/lib/time";
import { extractArticleMeta, findArticleLinks, listingTitle, toDate } from "../src/lib/scrape";
import { dedupeItems, linkKey } from "../src/lib/dedupe";
import { cachedContent, contentUpdate } from "../src/lib/content-cache";
import { schemaSql } from "../src/db/client";

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
  checkSplitArticle();
  checkHeadlineRegion();
  await checkFeedVsPage();
  checkSourceUrl();
  await checkWwwRetry();
  checkScrapeDates();
  await checkHnDedupe();
  checkGenericDedupe();
  checkRenderedCache();
  checkUtilityHeadings();
  checkLabels();
  checkScreenReaderText();
  checkCustomMedia();
  checkEmbedsAndCode();
  checkBoilerplate();
  checkBadgeLead();
}

// claude.com/resources/articles pages carry a bare calendar date (saved 2026-10-24).
const CLAUDE_ARTICLE = `<html><head><title>Claude Duet | Claude</title>
<meta property="og:title" content="Claude Duet"/><meta property="og:type" content="article"/>
<meta property="article:published_time" content="2026-10-21"/>
<script type="application/ld+json">{"@context":"https://schema.org","@type":"Article","headline":"Claude Duet","datePublished":"2026-10-21","url":"https://claude.com/resources/articles/claude-duet"}</script>
</head><body><h1>Claude Duet</h1></body></html>`;

function checkScrapeDates() {
  const m = extractArticleMeta(CLAUDE_ARTICLE, "https://claude.com/resources/articles/claude-duet");
  assert.equal(m.publishedAt?.toISOString(), "2026-10-21T12:00:00.000Z");
  const day = (d: Date | null, timeZone: string) => d?.toLocaleDateString("en-US", { timeZone });
  for (const tz of ["America/Los_Angeles", "America/New_York", "Pacific/Honolulu", "UTC", "Asia/Tokyo"]) {
    assert.equal(day(m.publishedAt, tz), "10/21/2026", tz);
  }
  // JSON-LD only, other date-only spellings.
  assert.equal(toDate("2026-10-21")?.toISOString(), "2026-10-21T12:00:00.000Z");
  assert.equal(toDate(" 2026-10-21 ")?.toISOString(), "2026-10-21T12:00:00.000Z");
  assert.equal(toDate("October 21, 2026")?.toISOString(), "2026-10-21T12:00:00.000Z");
  assert.equal(toDate("Wed, 21 Oct 2026")?.toISOString(), "2026-10-21T12:00:00.000Z");
  // Full timestamps unchanged.
  assert.equal(toDate("2026-10-20T00:00:00Z")?.toISOString(), "2026-10-20T00:00:00.000Z");
  assert.equal(toDate("2026-10-21T09:30:00-07:00")?.toISOString(), "2026-10-21T16:30:00.000Z");
  assert.equal(toDate("Wed, 21 Oct 2026 08:15:00 GMT")?.toISOString(), "2026-10-21T08:15:00.000Z");
  assert.equal(toDate("not a date"), null);
  assert.equal(toDate("1990-01-01"), null);
  // A date-only value for today is never in the future (noon UTC can be hours ahead).
  const before = Date.now();
  const today = toDate(new Date().toISOString().slice(0, 10));
  assert.ok(today && today.getTime() <= Date.now() && today.getTime() >= before - 13 * 3600e3, "today not in the future");
  // A zone on a date with no time names only the day, on any host zone.
  const hostTz = process.env.TZ;
  try {
    for (const tz of ["America/Los_Angeles", "Asia/Tokyo", "UTC"]) {
      process.env.TZ = tz;
      for (const v of ["Wed, 21 Oct 2026 GMT", "Wed, 21 Oct 2026 UTC", "Wed, 21 Oct 2026 GMT+0900", "October 21, 2026", "2026-10-21Z"]) {
        assert.equal(toDate(v)?.toISOString(), "2026-10-21T12:00:00.000Z", `${v} @ ${tz}`);
      }
      assert.equal(toDate("Wed, 21 Oct 2026 08:15:00 GMT")?.toISOString(), "2026-10-21T08:15:00.000Z", tz);
    }
  } finally {
    if (hostTz === undefined) delete process.env.TZ;
    else process.env.TZ = hostTz;
  }
  console.log("SCRAPE DATES: ok");
}

// hnrss.org/newest?points=100 on 2026-10-24: the same story submitted twice (two HN ids, one link).
const hnItem = (id: number, title: string, link: string, points: number, date: string) =>
  `<item><title><![CDATA[${title}]]></title><description><![CDATA[
<p>Comments URL: <a href="https://news.ycombinator.com/item?id=${id}">https://news.ycombinator.com/item?id=${id}</a></p>
<p>Points: ${points}</p>
<p># Comments: 1</p>
]]></description><pubDate>${date}</pubDate><link>${link}</link><dc:creator>x</dc:creator><comments>https://news.ycombinator.com/item?id=${id}</comments><guid isPermaLink="false">https://news.ycombinator.com/item?id=${id}</guid></item>`;
const HN_DUP = `<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>Hacker News: Newest</title><link>https://news.ycombinator.com/newest</link>
${hnItem(50224422, "Missileer", "https://missileer.watch", 111, "Sat, 24 Oct 2026 19:43:27 +0000")}
${hnItem(50224300, "The Goose Programming Language", "https://aardappel.github.io/goose/", 170, "Sat, 24 Oct 2026 19:27:41 +0000")}
${hnItem(50224100, "The Goose Programming Language", "https://aardappel.github.io/goose/", 231, "Sat, 24 Oct 2026 19:06:55 +0000")}
${hnItem(50223000, "Ask HN: What are you working on?", "https://news.ycombinator.com/item?id=50223000", 150, "Sat, 24 Oct 2026 18:00:00 +0000")}
${hnItem(50222000, "Ask HN: Best laptop?", "https://news.ycombinator.com/item?id=50222000", 120, "Sat, 24 Oct 2026 17:00:00 +0000")}
</channel></rss>`;

async function checkHnDedupe() {
  const feed = await parseFeedXml(HN_DUP, "rss", "https://hnrss.org/newest?points=100");
  const ids = (xs: { guid: string }[]) => xs.map((x) => Number(x.guid.split("=")[1]));
  const hn = { linkOnly: true, siteUrl: "https://news.ycombinator.com/" };
  // Both new in one batch: one row, the more popular submission.
  assert.deepEqual(ids(dedupeItems(feed.items, hn)), [50224422, 50224100, 50223000, 50222000]);
  // First submission already stored (an earlier refresh): it keeps updating, the second is skipped.
  const stored = (id: number, url: string, title = "The Goose Programming Language") => ({
    guid: `https://news.ycombinator.com/item?id=${id}`, url, title,
  });
  assert.deepEqual(
    ids(dedupeItems(feed.items, { ...hn, stored: [stored(50224300, "https://aardappel.github.io/goose/")] })),
    [50224422, 50224300, 50223000, 50222000],
  );
  // Stored link differs only by scheme, www, trailing slash, tracking params or anchor.
  for (const url of [
    "http://www.aardappel.github.io/goose",
    "https://aardappel.github.io/goose/?utm_source=hn#intro",
    "https://AARDAPPEL.github.io/goose//",
  ]) {
    assert.deepEqual(ids(dedupeItems(feed.items, { ...hn, stored: [stored(1, url, "Goose: a language")] })), [50224422, 50223000, 50222000], url);
  }
  // Both submissions already stored as separate rows (from before this fix): both keep updating.
  const both = [stored(50224300, "https://aardappel.github.io/goose/"), stored(50224100, "https://aardappel.github.io/goose/")];
  assert.equal(dedupeItems(feed.items, { ...hn, stored: both }).length, 5);
  // A third submission of a stored story is still dropped on an aggregator.
  const third = [...feed.items, { ...feed.items[1], guid: "https://news.ycombinator.com/item?id=50229999", hnPoints: 400 }];
  assert.deepEqual(ids(dedupeItems(third, { ...hn, stored: both })), [50224422, 50224300, 50224100, 50223000, 50222000]);
  // Repeated guid in one batch (ON CONFLICT would error) collapses to one.
  assert.equal(dedupeItems([...feed.items, feed.items[0]], hn).length, 4);
  console.log("HN DEDUPE: ok");
}

function checkGenericDedupe() {
  const it = (guid: string, url: string, title: string) => ({ guid, url, title });
  const site = "https://pod.example.com/";
  // Many items sharing one non-root link (a podcast page): all kept.
  const pod = [it("e3", "https://pod.example.com/show", "Ep 3"), it("e2", "https://pod.example.com/show", "Ep 2"), it("e1", "https://pod.example.com/show", "Ep 1")];
  assert.equal(dedupeItems(pod, { siteUrl: site }).length, 3);
  // Even when titles repeat, three or more sharing a link is a feed-wide link.
  const same = pod.map((x) => ({ ...x, title: "Weekly show" }));
  assert.equal(dedupeItems(same, { siteUrl: site }).length, 3);
  assert.equal(dedupeItems([it("e4", "https://pod.example.com/show", "Weekly show")], { siteUrl: site, stored: same }).length, 1);
  // Items linking to the site root are never deduped.
  assert.equal(dedupeItems([it("a", site, "Update"), it("b", "https://www.pod.example.com", "Update")], { siteUrl: site }).length, 2);
  // Same link, different titles (live-blog updates, changelog anchors): both kept.
  assert.equal(dedupeItems([it("a", "https://b.example.com/live", "Update 1"), it("b", "https://b.example.com/live", "Update 2")]).length, 2);
  assert.equal(dedupeItems([it("a", "https://b.example.com/log#v2", "v2"), it("b", "https://b.example.com/log#v1", "v1")]).length, 2);
  // Same link and title under a new guid (a republish): dropped, against stored rows too.
  assert.deepEqual(dedupeItems([it("new", "https://b.example.com/post?utm_medium=rss", "Hello,  World!"), it("x", "https://b.example.com/other", "Other")], {
    stored: [it("old", "https://b.example.com/post/", "Hello World")],
  }).map((x) => x.guid), ["x"]);
  // Query strings that pick the page are kept; YouTube watch links stay distinct.
  assert.notEqual(linkKey("https://www.youtube.com/watch?v=a"), linkKey("https://www.youtube.com/watch?v=b"));
  assert.equal(linkKey("https://b.example.com/p?b=2&a=1&utm_source=x"), linkKey("http://b.example.com/p/?a=1&b=2"));
  assert.notEqual(linkKey("https://app.example.com/#/a"), linkKey("https://app.example.com/#/b"));
  assert.equal(linkKey("https://b.example.com/"), null);
  assert.equal(linkKey("mailto:a@b.c"), null);
  console.log("GENERIC DEDUPE: ok");
}

function checkRenderedCache() {
  // Rendered (Jina) extraction is stored with its flag; the cached copy reports it on later loads.
  const up = contentUpdate({ contentHtml: "<p>x</p>", leadImage: "https://x/og.png", rendered: true }, null);
  assert.deepEqual(up, { contentHtml: "<p>x</p>", contentRendered: true, thumbnailUrl: "https://x/og.png" });
  assert.deepEqual(cachedContent({ contentHtml: "<p>x</p>", contentRendered: true }, "https://x/og.png"), {
    contentHtml: "<p>x</p>", leadImage: "https://x/og.png", rendered: true,
  });
  // A direct extraction (or a ?refresh=1 that no longer needs the fallback) clears the flag.
  assert.deepEqual(contentUpdate({ contentHtml: "<p>y</p>", leadImage: null }, "https://x/t.jpg"), { contentHtml: "<p>y</p>", contentRendered: false });
  assert.deepEqual(cachedContent({ contentHtml: "<p>y</p>", contentRendered: false }, null), { contentHtml: "<p>y</p>", leadImage: null });
  assert.equal(contentUpdate({ contentHtml: null, leadImage: null, rendered: true }, null), null);
  // Existing databases gain the column on the next cold start.
  assert.match(schemaSql(), /ALTER TABLE "items" ADD COLUMN IF NOT EXISTS "content_rendered" boolean DEFAULT false NOT NULL/);
  assert.match(schemaSql(), /"content_rendered" boolean DEFAULT false NOT NULL,\n/);
  console.log("RENDERED CACHE: ok");
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
      // The feed is fetched alongside the page, so only the set of requests is fixed.
      assert.deepEqual([...calls].sort(), ["https://blocked.example.com/feed.xml", "https://blocked.example.com/p/1", "https://blocked.example.com/p/1"]);
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
  // Matching: guid across every item first; then the link, query kept, fragment and trailing slash ignored.
  const items = (rows: string) => `<?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>M</title><link>https://m.example.com/</link>${rows}</channel></rss>`;
  const row = (link: string, guid: string | null, body: string) => `<item><title>${body}</title><link>${link}</link>${guid ? `<guid>${guid}</guid>` : ""}<content:encoded><![CDATA[<p>${body}</p>]]></content:encoded></item>`;
  const byQuery = items(row("https://m.example.com/article.php?id=1", null, "ONE") + row("https://m.example.com/article.php?id=2", null, "TWO"));
  assert.match((await findFeedItemHtml(byQuery, { guid: "x", url: "https://m.example.com/article.php?id=2" })) ?? "", /TWO/);
  assert.match((await findFeedItemHtml(byQuery, { guid: "x", url: "https://m.example.com/article.php?id=1#top" })) ?? "", /ONE/);
  assert.equal(await findFeedItemHtml(byQuery, { guid: "x", url: "https://m.example.com/article.php?id=3" }), null);
  const byGuid = items(row("https://m.example.com/p/", "g-a", "A") + row("https://m.example.com/p/", "g-b", "B"));
  assert.match((await findFeedItemHtml(byGuid, { guid: "g-b", url: "https://m.example.com/p" })) ?? "", /B/);
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

async function withFetch(routes: (url: string) => Response | Promise<Response>, fn: (calls: string[]) => Promise<void>) {
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

const para = (s: string) => `<p>${s}</p>`;
const textOf = (h: string | null | undefined) => (h ?? "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();

// Shape of an Ars Technica article (saved 2026-10-24): one story cut into .post-content blocks,
// each in its own wrapper, with ad slots between them and an author bio after the last.
const ARS_PART = (n: number) =>
  para(`Part ${n} of the story keeps going with reporting, quotes from researchers, and enough detail, commas, and clauses to score as real prose in any extractor.`).repeat(3);
const ARS_SPLIT = `<html><head><title>Exit nodes hijacked - Ars Technica</title></head><body><nav>menu</nav><main><article class="double-column h-entry post">
<header><h1>Exit nodes hijacked</h1><p>For 3 days, nodes were hacked.</p></header>
<div class="text-settings-dropdown-story"><button>Text settings</button></div>
<div class="my-2.5 mx-auto"><div class="relative lg:col-span-2"><div class="post-content post-content-double">${ARS_PART(1)}<p>First block ends here, with a final sentence from block one.</p></div></div><div class="hidden min-w-[300px]"><div class="ad-wrapper is-rail"></div></div></div>
<div class="ad-wrapper with-label is-fullwidth"><div class="ad ad--mid-content">Advertisement</div></div>
<div class="my-2.5 mx-auto"><div class="relative lg:col-span-2"><div class="post-content post-content-double">${ARS_PART(2)}</div></div></div>
<div class="ad-wrapper with-label is-fullwidth"><div class="ad ad--mid-content">Advertisement</div></div>
<div class="mt-2.5 mx-auto"><div class="relative lg:col-span-2"><div class="post-content post-content-double">${ARS_PART(3)}<p>The takeaway is the closing sentence of the whole article, from the last block.</p></div><div class="author-mini-bio"><p>Dan Goodin, Senior Security Editor</p></div></div></div>
</article></main><footer>footer</footer></body></html>`;

// A Tailwind blog without <article> (shape seen on many personal sites): the post body and each
// comment body all carry `prose`, with only a "3 comments" label between them.
const PROSE_COMMENTS = `<html><head><title>Big news</title></head><body><header><nav>Home</nav></header><main><h1>Big news</h1><div class="prose">${ARS_PART(1)}${ARS_PART(2)}</div>
<div id="comments" class="comments"><div class="font-bold">3 comments</div>${[0, 1, 2].map((i) => `<div class="comment"><div class="text-sm">user${i} · 2 days ago</div><div class="prose prose-sm"><p>COMMENT${i}: I strongly disagree with this take, the numbers in the second section do not add up at all honestly.</p></div></div>`).join("")}</div></main></body></html>`;

function checkSplitArticle() {
  const pc = parseHTML(PROSE_COMMENTS).document;
  mergeSplitContainers(pc);
  assert.equal(pc.querySelectorAll(".comment .prose").length, 3, "comment bodies stay in the thread");
  assert.doesNotMatch(extractFromHtml(PROSE_COMMENTS, "https://blog.example.com/d").contentHtml ?? "", /COMMENT\d/);
  // All three blocks come through, in order; ads and the author bio stay out.
  const h = extractFromHtml(ARS_SPLIT, "https://arstechnica.com/security/2026/10/x/").contentHtml ?? "";
  const t = textOf(h);
  assert.ok(t.indexOf("Part 1") < t.indexOf("block one") && t.indexOf("block one") < t.indexOf("Part 2"), "block order");
  assert.ok(t.indexOf("Part 2") < t.indexOf("Part 3") && t.indexOf("Part 3") < t.indexOf("closing sentence"), "block order");
  assert.doesNotMatch(t, /Advertisement|Senior Security Editor|Text settings/);

  // Merged only when the blocks are parts of one story.
  const count = (body: string) => {
    const { document } = parseHTML(`<!doctype html><html><body>${body}</body></html>`);
    mergeSplitContainers(document);
    return document.querySelectorAll(".entry-content, .comment-content, .post-content").length;
  };
  const P = ARS_PART(1);
  assert.equal(count(`<article><div><div class="entry-content">${P}</div></div><div class="ad"></div><div><div class="entry-content">${P}</div></div></article>`), 1);
  // A listing: each excerpt in its own <article>.
  assert.equal(count(`<article><div class="entry-content">${P}</div></article><article><div class="entry-content">${P}</div></article>`), 2);
  // A heading between the blocks: separate stories, not one split story.
  assert.equal(count(`<div class="post-content">${P}</div><h2>Next story</h2><div class="post-content">${P}</div>`), 2);
  // Real prose between the blocks: not ad slots.
  assert.equal(count(`<div class="post-content">${P}</div><div>${ARS_PART(9)}</div><div class="post-content">${P}</div>`), 2);
  // Comment bodies share a class but are never article parts.
  assert.equal(count(`<div class="comment-content">${P}</div><div class="comment-content">${P}</div>`), 2);
  // Far apart in the tree (different page sections).
  assert.equal(count(`<div><div><div><div><div class="post-content">${P}</div></div></div></div></div><div class="post-content">${P}</div>`), 2);
  console.log("SPLIT ARTICLE: ok");
}

// Shape of an Apollo Daily Spark post (saved 2026-10-24): a short post and charts under the
// headline; a longer, comma-heavy legal disclaimer elsewhere that Readability scored higher.
const STORY = [
  "Despite massive investments and hype around artificial intelligence, the technology has delivered zero payoff to corporate America outside of tech, see the first chart below.",
  "Companies backed by venture capital are spending more on tokens, but mainstream corporate America does not need the latest model and is unwilling to pay for it.",
  "The question looking ahead is whether mainstream corporate America can turn cheap intelligence into higher revenue growth and higher profit margins.",
  "The bottom line is that the AI story will be decided in the S&amp;P 493, not the Mag 7, and so far there is no evidence of improvement.",
].map(para).join("");
const LEGAL = para("This presentation may not be distributed, transmitted, or otherwise communicated to others, in whole or in part, without the express consent of the company, its affiliates, or its subsidiaries, and it is not advice, an offer, or a solicitation, nor a recommendation, of any kind, to anyone, anywhere.").repeat(4);
const APOLLO_PAGE = `<html><head><title>No Signs of AI Payoff Outside the Tech Sector | Apollo</title><meta property="og:title" content="No Signs of AI Payoff Outside the Tech Sector"></head><body>
<header><nav><a href="/">Home</a></nav></header><main><div class="cmp-container"><div class="blog-detail">
<div class="blog-detail-info"><span>Macroeconomic Indicators</span><p class="blog-detail-info-date">October 24, 2026</p><h1>No Signs of AI Payoff Outside the Tech Sector</h1><div class="blog-detail-info-share">Share</div></div>
<div class="blog-detail-content"><div class="blog-detail-content-fragments">${STORY}</div>
${[1, 2, 3].map((n) => `<div class="blog-detail-content-image-carousel"><figure class="blog-image-preview"><img src="/charts/chart${n}.png" alt="Chart ${n}"><figcaption><p>Sources: Bloomberg, Macrobond</p></figcaption></figure></div>`).join("")}
</div></div></div>
<div class="cmp-container"><div class="accordion"><div class="cmp-accordion disclaimer-accordion"><h3>Disclosures</h3><div class="cmp-accordion__panel accordionPanelText"><div class="container">${LEGAL}</div></div></div></div></div></main></body></html>`;

function checkHeadlineRegion() {
  const h = extractFromHtml(APOLLO_PAGE, "https://www.apollo.com/insights-news/insights/daily-spark/x").contentHtml ?? "";
  assert.match(textOf(h), /^Despite massive investments[\s\S]*no evidence of improvement/);
  assert.doesNotMatch(h, /This presentation may not be distributed/);
  for (const n of [1, 2, 3]) assert.match(h, new RegExp(`src="https://www\\.apollo\\.com/charts/chart${n}\\.png"`));

  // Without a disclaimer the page extracts the same story (the region rule is not needed).
  const plain = extractFromHtml(APOLLO_PAGE.replace(LEGAL, ""), "https://www.apollo.com/x").contentHtml ?? "";
  assert.match(textOf(plain), /^Despite massive investments/);

  // The region test itself: outside -> true; inside, or containing the region -> false.
  const region = `<div><h1>T</h1>${STORY}</div>`;
  assert.equal(pickedOutsideRegion(LEGAL, region), true);
  assert.equal(pickedOutsideRegion(STORY, region), false);
  assert.equal(pickedOutsideRegion(STORY + LEGAL, region), false);
  assert.equal(pickedOutsideRegion(`<p>short</p>`, region), false);

  // A long dek under the headline doesn't replace a much longer story elsewhere on the page.
  const dek = para("A long standfirst under the headline, with commas, clauses, and words enough to look like prose, but it is only a summary of the story below the fold, nothing more.").repeat(3);
  const story = ARS_PART(4).repeat(4);
  const split = `<html><head><title>Headline</title></head><body><section class="hero"><h1>Headline</h1>${dek}</section><section class="body"><div class="story">${story}</div></section></body></html>`;
  assert.match(textOf(extractFromHtml(split, "https://site.example.com/a").contentHtml), /Part 4 of the story/);
  console.log("HEADLINE REGION: ok");
}

async function checkFeedVsPage() {
  // The rule: feed wins only at >= 1.5x the page's text and >= 500 more characters, and only a full article.
  const chars = (n: number) => para("x".repeat(n));
  assert.equal(preferFeed(chars(1000), chars(1600)), true);
  assert.equal(preferFeed(chars(1000), chars(1400)), false, "not 1.5x");
  assert.equal(preferFeed(chars(600), chars(1000)), false, "under 500 more");
  assert.equal(preferFeed(null, chars(600)), true, "empty page");
  assert.equal(preferFeed(null, chars(300)), false, "teaser");
  assert.equal(preferFeed(chars(1000), null), false);

  const url = "https://cut.example.com/p/1";
  const FULL = ARS_PART(1) + ARS_PART(2) + ARS_PART(3) + para("The feed-only ending of the article, which the page never showed.");
  const feedXml = (body: string) => `<?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>C</title><link>https://cut.example.com/</link>
<item><title>Post</title><link>${url}</link><guid>c1</guid><content:encoded><![CDATA[${body}]]></content:encoded></item></channel></rss>`;
  const cutPage = `<html><head><meta property="og:image" content="/og.png"><title>Post</title></head><body><article><h1>Post</h1>${ARS_PART(1)}</article></body></html>`;
  const fullPage = `<html><head><title>Post</title></head><body><article><h1>Post</h1>${FULL}</article></body></html>`;
  const feedRef = { feedUrl: "https://cut.example.com/feed.xml", guid: "c1" };
  const route = (pageHtml: string, feedBody: string) => (u: string) =>
    u.endsWith("/feed.xml") ? html(feedXml(feedBody), "application/rss+xml") : html(pageHtml);

  // Page extraction cut short, feed has the whole article -> feed copy, page's og:image.
  await withFetch(route(cutPage, FULL), async (calls) => {
    const out = await extractArticle(url, feedRef);
    assert.deepEqual([...calls].sort(), [feedRef.feedUrl, url]);
    assert.match(out.contentHtml ?? "", /feed-only ending/);
    assert.equal(out.leadImage, "https://cut.example.com/og.png");
    assert.equal(out.rendered, undefined);
  });
  // Feed only a teaser (Ars's own feeds stop after a few paragraphs) -> page.
  await withFetch(route(fullPage, ARS_PART(1) + para(`<a href="${url}">Read full article</a>`)), async () => {
    const out = await extractArticle(url, feedRef);
    assert.match(out.contentHtml ?? "", /feed-only ending/);
    assert.doesNotMatch(out.contentHtml ?? "", /Read full article/);
  });
  // Query-string permalinks (WordPress ?p=N): the guid match wins over an earlier item whose link
  // differs only in its query, so a longer, different post never replaces the right page.
  const wpUrl = "https://wp.example.com/?p=202";
  const wpFeed = `<?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>W</title><link>https://wp.example.com/</link>
<item><title>Other post</title><link>https://wp.example.com/?p=101</link><guid isPermaLink="false">https://wp.example.com/?p=101</guid><content:encoded><![CDATA[${(ARS_PART(7) + para("OTHER POST body.")).repeat(5)}]]></content:encoded></item>
<item><title>Target post</title><link>${wpUrl}</link><guid isPermaLink="false">${wpUrl}</guid><content:encoded><![CDATA[${ARS_PART(1)}]]></content:encoded></item>
</channel></rss>`;
  const wpPage = `<html><head><title>Target post</title></head><body><article><h1>Target post</h1>${ARS_PART(1)}${ARS_PART(2)}</article></body></html>`;
  await withFetch(
    (u) => (u.endsWith("/feed/") ? html(wpFeed, "application/rss+xml") : html(wpPage)),
    async () => {
      const out = await extractArticle(wpUrl, { feedUrl: "https://wp.example.com/feed/", guid: wpUrl });
      assert.match(out.contentHtml ?? "", /Part 2 of the story/);
      assert.doesNotMatch(out.contentHtml ?? "", /OTHER POST|Part 7/);
    },
  );
  // A slow feed doesn't hold up a page that worked.
  await withFetch(
    (u) => (u.endsWith("/feed.xml") ? new Promise<Response>((r) => setTimeout(() => r(html(feedXml(FULL), "application/rss+xml")), 3000).unref()) : html(cutPage)),
    async () => {
      const t0 = Date.now();
      const out = await extractArticle(url, feedRef);
      assert.ok(Date.now() - t0 < 2000, `waited ${Date.now() - t0}ms for the feed`);
      assert.match(out.contentHtml ?? "", /Part 1 of the story/);
    },
  );
  // hnrss carries no article text: its feed is never fetched.
  await withFetch(
    () => html(fullPage),
    async (calls) => {
      await extractArticle(url, { feedUrl: "https://hnrss.org/newest?points=100", guid: "https://news.ycombinator.com/item?id=1" });
      assert.deepEqual(calls, [url]);
    },
  );
  // Feed fails -> page result unaffected.
  await withFetch(
    (u) => (u.endsWith("/feed.xml") ? new Response("", { status: 500 }) : html(cutPage)),
    async () => assert.match((await extractArticle(url, feedRef)).contentHtml ?? "", /Part 1 of the story/),
  );
  console.log("FEED VS PAGE: ok");
}
// OpenAI article shape (saved 2026-10-24 via Jina): every section wrapper and heading carries
// Tailwind tokens with Readability's words in them (`scroll-mt-[...]`, `var(--header-h)`).
const OAI_SECTION = (n: number) => `<div class="max-w-container @container grid [--grid-gap:8px] scroll-mt-[calc(var(--page-top-space,var(--header-h))+var(--toc-button-h)+var(--anchor-scroll-clearance))]" id="section-${n}"><div class="full-grid-content:@md:col-span-full col-span-full toc-visible:@md:col-start-2"><h2 class="text-h3 scroll-mt-[calc(var(--page-top-space,var(--header-h))+var(--toc-button-h))]"><span>Section heading ${n}</span></h2></div></div>
<div class="col-span-full @md:col-span-6 max-w-none min-w-0 in-[:where(li)]:contents not-first:mt-16"><h3 class="text-h4 scroll-mt-[calc(var(--header-h))]"><span>Sub heading ${n}</span></h3>${ARS_PART(n)}</div>`;
const OAI_PAGE = `<html><head><title>Scaling storage | OpenAI</title></head><body><div class="[--page-top-gap:0px] [--page-top-space:calc(var(--sticky-top)+var(--page-top-gap))] pt-(--page-top-space) [--sticky-top:var(--header-h)]"><main class="@container relative main"><article class="flex min-w-0 flex-col gap-12">
${[1, 2, 3, 4, 5].map(OAI_SECTION).join("\n")}
<h2 class="text-h3" id="related-work">Related work</h2>${ARS_PART(6)}
<aside class="sidebar"><p>Sidebar promo text that is long enough to be a paragraph, with commas, words, and more words in it.</p></aside>
<div class="comments"><p>Great post! This reader comment is long enough to be a paragraph, with commas, words, and more words.</p></div>
</article></main></div></body></html>`;

function checkUtilityHeadings() {
  const h = extractFromHtml(OAI_PAGE, "https://openai.com/index/x").contentHtml ?? "";
  for (const n of [1, 2, 3, 4, 5]) {
    assert.match(h, new RegExp(`<h2><span>Section heading ${n}</span></h2>`), `h2 ${n}`);
    assert.match(h, new RegExp(`<h3><span>Sub heading ${n}</span></h3>`), `h3 ${n}`);
  }
  assert.match(h, /<h2>Related work<\/h2>/, "heading id with a negative word");
  // Semantic junk containers still go.
  assert.doesNotMatch(h, /Sidebar promo text|reader comment/);
  console.log("UTILITY HEADINGS: ok");
}

function checkLabels() {
  // claude.com list items (saved 2026-10-24): bold lead-ins ending in ":" are not orphan labels.
  const h = extractFromHtml(
    page(`<p>This looks like the simplest solution but introduces immediate complexity around:</p><ul>
<li><strong>Context management: </strong>You need to decide what context is exchanged between agents.</li>
<li><strong>Subagent sprawl</strong>: Every team ships its own subagent.</li>
<li><strong>Models are more capable:</strong> starting with Opus 4.5, models manage far more in one loop.</li></ul>`),
    "https://claude.com/resources/articles/x",
  ).contentHtml ?? "";
  assert.match(h, /<li><strong>Context management: <\/strong>You need to decide/);
  assert.match(h, /<li><strong>Models are more capable:<\/strong> starting with Opus/);
  // Orphan labels still go; labels with something under them stay, even inside wrappers.
  const c = cleanArticle(`<p>Intro paragraph.</p><p><strong>Steps:</strong></p><ul><li>One</li></ul>
<div><h2>Wrapped heading</h2></div><div><p>Section body.</p></div>
<h3>Empty section</h3><h3>Next</h3><figure><img src="https://x.example/a.png"></figure>
<p><b>Projects:</b></p><p><b>Contact:</b></p><p>Write to us.</p><p><b>Trailing:</b></p>`);
  assert.match(c, /<strong>Steps:<\/strong>/);
  assert.match(c, /Wrapped heading/);
  assert.doesNotMatch(c, /Empty section|Projects:|Trailing:/);
  assert.match(c, /<h3>Next<\/h3>/, "heading over an image");
  assert.match(c, /Contact:/);
  console.log("LABELS: ok");
}

function checkScreenReaderText() {
  const body = `<p>Join the <a href="/waitlist">waitlist<span class="sr-only" lang="en" data-export-skip=""> (opens in new tab)</span></a> and read the <a href="/docs">docs<span class="visually-hidden">(opens in a new window)</span></a>.<span style="position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)">Clipped text</span> More <a href="/m">here<span aria-hidden="true">↗</span></a>. <span class="Link-module__x__srOnly">Module text</span><span class="not-sr-only">Shown text</span></p>`;
  const check = (h: string) => {
    assert.doesNotMatch(h, /opens in|Clipped text|Module text|↗/);
    assert.match(h, /waitlist<\/a>/);
    assert.match(h, /Shown text/);
  };
  check(extractFromHtml(page(body), "https://claude.com/x").contentHtml ?? "");
  check(extractFromFeedHtml(PROSE + body, "https://claude.com/x").contentHtml ?? "");
  // `sr-only sm:not-sr-only` is visible from sm up: real text. `focus:not-sr-only` (a skip link) is not.
  const responsive = extractFromHtml(page(`<p>Price: <span class="sr-only sm:not-sr-only">$499 for the base model</span>, shipping now.</p><p><a class="sr-only focus:not-sr-only" href="#main">Skip to content</a> Body text.</p>`), "https://shop.example.com/x").contentHtml ?? "";
  assert.match(responsive, /\$499 for the base model/);
  assert.doesNotMatch(responsive, /Skip to content/);
  console.log("SCREEN READER TEXT: ok");
}

// dreamlabs.ai research page shape (saved 2026-10-24): a custom player keeps every media URL in
// data-asset / data-poster, relative to the page, with its controls as text.
const DREAM_BODY = `<figure><div class="player"><img class="poster" alt="A still from the launch video" data-asset="assets/launch-still.webp"><video playsinline preload="metadata" data-poster="assets/launch-still.webp" data-asset="assets/launch.mp4"></video><span class="shade" aria-hidden="true"></span>
<div class="ctl"><div class="tl" role="slider" aria-label="Seek" aria-valuenow="0"><span class="fill"></span><span class="knob"></span></div><div class="row"><button type="button" aria-label="Play or pause"></button><span class="time"><span class="cur">00:00</span><span class="sep"> / </span><span class="tot">01:59</span></span><span class="label">Launch video</span></div></div></div><figcaption>The launch video, recorded on a real robot.</figcaption></figure>
<div class="partners"><div class="card"><video muted loop playsinline preload="none" data-poster="assets/beta/anvil.jpg"><source data-asset="assets/beta/anvil.mp4" type="video/mp4"></video></div><div class="pager" aria-live="polite">1–13 of 13</div></div>
<div class="card"><video muted loop data-asset="clip-12345"></video></div>
<p><img src="assets/robocurve.webp" alt="Robocurve arm"></p>`;

function checkCustomMedia() {
  const url = "https://dreamlabs.ai/research/dream-1/";
  const h = extractFromHtml(page(DREAM_BODY), url).contentHtml ?? "";
  const A = "https://dreamlabs\\.ai/research/dream-1/assets/";
  assert.match(h, new RegExp(`<video src="${A}launch\\.mp4"[^>]*poster="${A}launch-still\\.webp"`));
  assert.match(h, new RegExp(`poster="${A}beta/anvil\\.jpg"[^>]*><source src="${A}beta/anvil\\.mp4"`));
  assert.match(h, new RegExp(`<img src="${A}robocurve\\.webp"`));
  assert.equal((h.match(/launch-still\.webp/g) ?? []).length, 1, "poster not repeated as an image");
  assert.doesNotMatch(h, /(?:src|poster|srcset)="(?!https:)/, "relative URL left");
  assert.doesNotMatch(h, /00:00|01:59|of 13|clip-12345/);
  assert.equal((h.match(/<video/g) ?? []).length, 2, "video without a source dropped");
  // A timestamp or count in prose is not player chrome.
  assert.match(cleanArticle(`<p>The talk starts at <span>10:30</span> and covers <span>3 of 5</span> topics.</p>`), /<span>10:30<\/span>[\s\S]*<span>3 of 5<\/span>/);
  // A chapter list beside a video keeps its times, before and after Readability.
  const chapters = `<div class="video-block"><video src="https://cdn.example.com/talk.mp4" controls></video><p>Chapters:</p><ul><li><span>00:00</span> Intro</li><li><span>04:12</span> Benchmarks</li><li><span>11:30</span> Q&amp;A</li></ul><p>Show notes: the demo starts at <span>07:45</span>.</p></div>`;
  const ch = extractFromHtml(page(chapters), "https://blog.example.com/talk").contentHtml ?? "";
  assert.match(textOf(ch), /00:00 Intro 04:12 Benchmarks 11:30 Q&(?:amp;)?A/);
  assert.match(ch, /07:45/);
  assert.match(textOf(cleanArticle(chapters)), /00:00 Intro 04:12 Benchmarks/);
  const pd = parseHTML(`<html><body>${chapters}</body></html>`).document;
  removePlayerChrome(pd);
  assert.match(textOf(pd.body.innerHTML), /04:12 Benchmarks/);
  // Readability's output is absolutized too (it can hand back relative URLs).
  assert.match(cleanArticle(`<p><img src="assets/x.webp"><video src="clip.mp4"></video></p>`, url), new RegExp(`src="${A}x\\.webp"[\\s\\S]*src="https://dreamlabs\\.ai/research/dream-1/clip\\.mp4"`));
  console.log("CUSTOM MEDIA: ok");
}

// openai.com Decisions API code block (saved 2026-10-24 via Jina): <code><pre>, one row per line,
// each led by its line number.
const OAI_CODE = `<div class="flex flex-col overflow-hidden rounded-md bg-tertiary-100"><div class="relative z-1 flex justify-between p-5"><h4 class="text-p2 font-bold capitalize">JSON</h4><button type="button" aria-label="Copy code block"><svg width="16" height="16" viewBox="0 0 16 16"><path d="M1 1"/></svg></button></div><div dir="ltr" class="relative flex items-stretch overflow-auto py-5 style-scrollbars max-h-125 @md:max-h-151"><code class="flex-1 px-0 font-mono text-code-snippet omZ69a_syntaxHighlight"><pre class="flex flex-col pe-5"><div class="flex flex-row gap-4"><span class="ms-5 min-w-5 text-end text-primary-44">1</span><div class="flex-1"><span class="hljs-punctuation">{</span></div></div><div class="flex flex-row gap-4"><span class="ms-5 min-w-5 text-end text-primary-44">2</span><div class="flex-1">  <span class="hljs-attr">"type"</span><span class="hljs-punctuation">:</span> <span class="hljs-string">"decisions"</span><span class="hljs-punctuation">,</span></div></div><div class="flex flex-row gap-4"><span class="ms-5 min-w-5 text-end text-primary-44">3</span><div class="flex-1">  <span class="hljs-attr">"event_type"</span><span class="hljs-punctuation">:</span> <span class="hljs-string">"session.input_transcript.delta"</span></div></div><div class="flex flex-row gap-4"><span class="ms-5 min-w-5 text-end text-primary-44">4</span><div class="flex-1"><span class="hljs-punctuation">}</span></div></div></pre></code></div></div>`;

function checkEmbedsAndCode() {
  const url = "https://site.example.com/posts/a";
  const h = extractFromHtml(
    page(`<p><iframe src="https://player.vimeo.com/video/123456?h=abc" allowfullscreen></iframe></p>
<p><iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ?rel=0"></iframe></p>
<p><iframe src="about:blank" data-src="https://player.vimeo.com/video/999"></iframe></p>
<p>Configure it like this:</p>${OAI_CODE}<p>Then run it.</p>
<table class="highlighttable"><tr><td class="linenos"><div class="linenodiv"><pre>1
2</pre></div></td><td class="code"><div class="highlight"><pre><code class="language-py">a = 1
b = 2</code></pre></div></td></tr></table>
<pre><code class="language-js">const x = 1;</code></pre>`),
    url,
  ).contentHtml ?? "";
  assert.match(h, /<iframe src="https:\/\/player\.vimeo\.com\/video\/123456\?h=abc"/);
  assert.match(h, /<iframe src="https:\/\/www\.youtube-nocookie\.com\/embed\/dQw4w9WgXcQ\?rel=0"/);
  assert.match(h, /<iframe src="https:\/\/player\.vimeo\.com\/video\/999"/);
  assert.match(h, /<pre><code>\{\n {2}"type": "decisions",\n {2}"event_type": "session\.input_transcript\.delta"\n\}<\/code><\/pre>/);
  assert.match(h, /<pre><code>a = 1\nb = 2<\/code><\/pre>/);
  assert.doesNotMatch(h, /<pre>1\n2<\/pre>|<table/, "line-number gutter");
  assert.match(h, /<pre><code>const x = 1;<\/code><\/pre>/);
  // Refused or missing iframe src: no empty box.
  assert.equal(sanitizeArticle(`<iframe src="https://evil.example/x"></iframe><iframe></iframe>`), "");
  // Non-embed YouTube pages refuse to be framed (a blank box): dropped. Embeds on any youtube.com host play from nocookie.
  assert.equal(sanitizeArticle(`<iframe src="https://www.youtube.com/watch?v=abc"></iframe><iframe src="https://www.youtube.com/redirect?q=https://evil.example"></iframe>`), "");
  for (const src of ["//www.youtube.com/embed/abc", "https://m.youtube.com/embed/abc", "https://youtube.com/embed/abc"]) {
    assert.match(sanitizeArticle(`<iframe src="${src}"></iframe>`), /<iframe src="https:\/\/www\.youtube-nocookie\.com\/embed\/abc"/, src);
  }
  console.log("EMBEDS AND CODE: ok");
}

// TechCrunch article tail (saved 2026-10-24): affiliate disclaimer, then an author card whose bio
// carries Cloudflare's email placeholder and a "View Bio" button.
const TC_TAIL = `<p><em>When you purchase through links in our articles, <a href="https://techcrunch.com/techcrunch-affiliate-monetization-standards/">we may earn a small commission</a>. This doesn’t affect our editorial independence.</em></p>
<div><span>Share this article</span></div><h3>Related articles</h3>
<div><div><div>Ivan Mehta</div></div><div><div><p>Ivan covers global consumer tech developments at TechCrunch. He is based out of India and has previously worked at publications including Huffington Post and The Next Web.</p><p>You can contact or verify outreach from Ivan by emailing <a href="/cdn-cgi/l/email-protection#60090d"><span class="__cf_email__" data-cfemail="d1b8bc">[email&#160;protected]</span></a> or via encrypted message at ivan.42 on Signal.</p></div></div><div><a href="https://techcrunch.com/profiles/ivan-mehta/">View Bio</a></div></div>`;

function checkBoilerplate() {
  const art = (body: string) => `<html><head><title>T</title></head><body><article>${PROSE}${body}</article></body></html>`;
  const h = extractFromHtml(art(TC_TAIL), "https://techcrunch.com/2026/10/24/x/").contentHtml ?? "";
  assert.match(h, /meaningful article text/);
  assert.doesNotMatch(h, /commission|Share this|Related articles|Ivan covers|verify outreach|email|View Bio/i);
  // Article text that only looks similar stays: a story's own last paragraph about a reporter (no
  // bio signal beside it), "commission" in prose, a long paragraph quoting an obfuscated address.
  const story = cleanArticle(`${PROSE}<p>The commission said it would publish its findings next year, after a public consultation.</p><p>Under the program, creators may earn a commission on each sale.</p><p>Gershkovich was a reporter for the paper, based in Moscow, when he was detained.</p>`);
  assert.match(story, /The commission said/);
  assert.match(story, /creators may earn a commission/);
  assert.match(story, /Gershkovich was a reporter/);
  const long = `<p>${"Readers wrote in about the change, ".repeat(12)}and one sent a note from <a href="/cdn-cgi/l/email-protection#1">[email&#160;protected]</a> to say so.</p>`;
  const kept = cleanArticle(PROSE + long);
  assert.match(kept, /Readers wrote in/);
  assert.doesNotMatch(kept, /protected/);
  // A company quoted on its own commission is reporting, not a disclosure; a disclosure wrapper
  // holding an image loses nothing (the image stays).
  const quoted = extractFromHtml(art(`<p>"We earn a commission on every booking made through the app," said CEO Jane Smith.</p>${PROSE}`), "https://news.example.com/a").contentHtml ?? "";
  assert.match(quoted, /We earn a commission on every booking/);
  const fig = cleanArticle(`${PROSE}<div><img src="https://x.example/chart.png" alt="Chart">We may earn a commission when you buy through links on this page.</div>`);
  assert.match(fig, /chart\.png/);
  assert.doesNotMatch(cleanArticle(`${PROSE}<p>We may earn a commission when you buy through links on this page.</p>`), /commission/);
  // A story that ends on a company line and a pointer to the project is not an author bio.
  const ending = extractFromHtml(art(`<p>Mistral is a French startup based in Paris that has raised over a billion dollars.</p><p>Follow the project on GitHub for release notes.</p>`), "https://news.example.com/b").contentHtml ?? "";
  assert.match(ending, /Mistral is a French startup/);
  assert.match(ending, /Follow the project on GitHub/);
  // An in-article "Related reading:" heading over its list stays; one left with nothing under it goes.
  const related = extractFromHtml(art(`<h3>Related reading:</h3><ul><li><a href="/x">Our earlier investigation into the supply chain</a></li><li><a href="/y">Interview with the founder about the launch</a></li></ul>`), "https://news.example.com/e").contentHtml ?? "";
  assert.match(related, /<h3>Related reading:<\/h3>\s*<ul>/);
  assert.doesNotMatch(cleanArticle(`${PROSE}<h3>Related articles</h3>`), /Related articles/);
  console.log("BOILERPLATE: ok");
}

function checkBadgeLead() {
  // aardappel.github.io/goose README (saved 2026-10-24): badges first, no og:image.
  const imgs = `<p><img src="https://img.shields.io/badge/chat-discord-blue" alt="Discord Chat"> <img src="https://badgen.net/badge/x/y"> <img src="https://github.com/o/r/actions/workflows/ci.yml/badge.svg"> <img src="/strip.png" width="600" height="20"></p><p><img src="/hero.jpg" alt="Hero"></p>`;
  const url = "https://aardappel.github.io/goose/";
  assert.equal(extractFromHtml(page(imgs), url).leadImage, "https://aardappel.github.io/hero.jpg");
  assert.equal(extractFromFeedHtml(PROSE + imgs, url).leadImage, "https://aardappel.github.io/hero.jpg");
  assert.equal(extractFromHtml(page(`<p><img src="https://img.shields.io/badge/a-b-blue"></p>`), url).leadImage, null);
  console.log("BADGE LEAD: ok");
}
main();
