import { SEED_SOURCES, FEED_FALLBACKS } from "../src/db/seed";
import { fetchWithTimeout } from "../src/lib/http";
import { parseFeedXml } from "../src/lib/parse";
import { extractArticle } from "../src/lib/extract";
import { parseHTML } from "linkedom";
import assert from "node:assert/strict";

async function main() {
  await Promise.all(SEED_SOURCES.map(async (s) => {
    for (const url of [s.feedUrl, ...(FEED_FALLBACKS[s.feedUrl] ?? [])]) {
      try {
        const r = await fetchWithTimeout(url, 15000);
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const f = await parseFeedXml(await r.text(), s.kind, url);
        const i = f.items[0];
        console.log(`OK ${s.title}: ${f.items.length} items | ${i?.title?.slice(0,40)} | thumb=${!!i?.thumbnailUrl} hn=${i?.hnPoints}/${i?.hnComments}`);
        return;
      } catch (e) { console.log(`ERR ${s.title} ${url}: ${(e as Error).message}`); }
    }
  }));
  const a = await extractArticle("https://simonwillison.net/2024/Dec/31/llms-in-2024/").catch((e) => ({ err: String(e) }));
  console.log("extract:", "contentHtml" in a ? a.contentHtml?.length : a);
  await checkFigures();
  await checkVimeoFigure();
  await checkFullArticles();
  await checkRecentItems(["Ars Technica AI", "Simon Willison", "Google DeepMind Blog"]);
  await checkAuditPages();
}

/** Every <img src> and <source srcset> candidate in the HTML, as absolute URLs. */
function imageUrls(html: string): string[] {
  const { document } = parseHTML(`<!doctype html><html><body>${html}</body></html>`);
  const imgs = [...document.querySelectorAll("img[src]")].map((i) => i.getAttribute("src")!);
  const sources = [...document.querySelectorAll("source[srcset]")].map((s) => s.getAttribute("srcset")!.split(/\s/)[0]);
  return [...imgs, ...sources];
}

async function assertImagesLoad(urls: string[]) {
  for (const u of urls) {
    assert.match(u, /^https:\/\//, `not absolute: ${u}`);
    const r = await fetchWithTimeout(u, 15000);
    assert.ok(r.ok && /^image\//.test(r.headers.get("content-type") ?? ""), `image ${u}: ${r.status} ${r.headers.get("content-type")}`);
  }
}

// openai.com 403s server fetches (Cloudflare challenge); this goes through the feed and Jina fallbacks.
async function checkFigures() {
  const url = "https://openai.com/index/securing-our-frontier-model-training-environment/";
  const out = await extractArticle(url, { feedUrl: "https://openai.com/news/rss.xml", guid: url.replace(/\/$/, "") });
  const html = out.contentHtml ?? "";
  assert.ok(html.includes("<picture>"), "diagram <picture> kept");
  assert.match(html, /diagram-desktop-light\.png/);
  assert.match(html, /media="\(min-width: 768px\) and \(prefers-color-scheme: dark\)"/);
  assert.match(html, /We plot the cumulative number of high-priority candidate findings/);
  // The client-drawn chart, rendered from the Vega-Lite spec in the page's RSC payload.
  assert.match(html, /<svg viewbox="0 0 [\d.]+ [\d.]+" width="100%" role="img" aria-label="Red-teaming findings versus tokens spent">/i);
  assert.match(html, /<text[^>]*>Tokens spent \(billions\)<\/text>[\s\S]*We plot the cumulative number/);
  assert.doesNotMatch(html, /Interactive figure not shown here/);
  const urls = imageUrls(html);
  await assertImagesLoad(urls);
  console.log(`FIGURES: ok (rendered=${out.rendered}, ${urls.length} image URLs load, ${html.length} chars)`);
}

// The deployment-gap Vimeo clip sits in the body after the fourth paragraph (not in the header), so
// it stays in place, as a watchable player instead of a muted background loop beside its poster.
async function checkVimeoFigure() {
  const url = "https://openai.com/index/forward-deployed-engineering-means/";
  const out = await extractArticle(url, { feedUrl: "https://openai.com/news/rss.xml", guid: url.replace(/\/$/, "") });
  const html = out.contentHtml ?? "";
  assert.match(html, /<iframe [^>]*src="https:\/\/player\.vimeo\.com\/video\/1235619942\?h=4b51ea2b10&amp;[^"]*controls=1"/);
  assert.doesNotMatch(html, /controls=0|background=1|muted=1|loop=1|deployment-gap-poster|00:\d\d/);
  assert.ok(html.indexOf("the deployment gap") < html.indexOf("player.vimeo.com"), "video stays after its paragraph");
  console.log(`VIMEO FIGURE: ok (rendered=${out.rendered})`);
}

const words = (html: string | null) => (html ?? "").replace(/<[^>]+>/g, " ").split(/\s+/).filter(Boolean).length;

/**
 * Articles that came out cut short (saved 2026-10-24). Ars splits each story across several
 * .post-content blocks; its feeds carry only the first few paragraphs, so the page must supply the
 * rest. Apollo's post sits next to a longer legal disclaimer that Readability used to pick instead.
 */
async function checkFullArticles() {
  const cases = [
    {
      url: "https://arstechnica.com/information-technology/2026/10/300-tor-exit-nodes-hijacked-to-intercept-ssh-traffic-and-retrieve-plaintext-email/",
      feedUrl: "https://arstechnica.com/security/feed/",
      first: /Unknown hackers hijacked more than 300 Tor exit nodes/,
      last: /disable password authentication in favor of SSH keys/,
      minWords: 650,
    },
    {
      url: "https://arstechnica.com/security/2026/10/anthropic-warns-small-ai-models-could-self-replicate-through-iot-devices/",
      feedUrl: "https://arstechnica.com/security/feed/",
      first: /Anthropic is warning that advances in small AI models/,
      last: /emerging threat of autonomous self-replication/,
      minWords: 950,
    },
    {
      url: "https://arstechnica.com/information-technology/2026/10/reactos-reaches-major-milestone-with-ntfs-install-support/",
      feedUrl: "https://arstechnica.com/gadgets/feed/",
      first: /ReactOS has reached a major milestone/,
      last: /installed on the same filesystem as the real thing/,
      minWords: 350,
    },
    {
      url: "https://www.apollo.com/insights-news/insights/daily-spark/no-signs-of-ai-payoff-outside-the-tech-sector",
      feedUrl: null,
      first: /Despite massive investments and widespread hype/,
      last: /no evidence that revenue growth or margins are improving outside the tech sector/,
      minWords: 300,
      images: /Oct24_Chart[1-5]\.png/g,
      nImages: 5,
    },
  ];
  for (const c of cases) {
    const out = await extractArticle(c.url, c.feedUrl ? { feedUrl: c.feedUrl, guid: c.url } : undefined);
    const html = out.contentHtml ?? "";
    const n = words(html);
    const text = html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");
    assert.match(text, c.first, `${c.url}: start missing`);
    assert.match(text, c.last, `${c.url}: ending missing (cut short at ${n} words)`);
    assert.doesNotMatch(text, /This presentation may not be distributed/, `${c.url}: disclaimer picked`);
    assert.ok(n >= c.minWords, `${c.url}: ${n} words`);
    if (c.images) assert.equal(new Set(html.match(c.images)).size, c.nImages, `${c.url}: charts`);
    console.log(`FULL: ${n} words, ${(html.match(/<img /g) ?? []).length} images | ${c.url}`);
  }
}

async function checkRecentItems(titles: string[]) {
  for (const t of titles) {
    const s = SEED_SOURCES.find((x) => x.title === t)!;
    const r = await fetchWithTimeout(s.feedUrl, 15000);
    const item = (await parseFeedXml(await r.text(), s.kind, s.feedUrl)).items[0];
    const out = await extractArticle(item.url, { feedUrl: s.feedUrl, guid: item.guid });
    const urls = imageUrls(out.contentHtml ?? "");
    await assertImagesLoad(urls.slice(0, 5));
    const text = (out.contentHtml ?? "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
    assert.ok(text.length > 500, `${t}: short content (${text.length})`);
    console.log(`ITEM ${t}: ${item.title.slice(0, 50)} | ${text.length} chars | ${urls.length} images | rendered=${!!out.rendered}`);
  }
}
const headings = (html: string) => (html.match(/<h[1-6][\s>]/g) ?? []).length;
const plain = (html: string) => html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");

/**
 * Pages from the 2026-10-24 reader audit. Each prints the evidence it checks: heading counts,
 * strings that must or must not appear.
 */
async function checkAuditPages() {
  const oaiFeed = (url: string) => ({ feedUrl: "https://openai.com/news/rss.xml", guid: url });

  // Tailwind `scroll-mt-[...]` / `var(--header-h)` tokens used to delete OpenAI's headings.
  let url = "https://openai.com/index/scaling-storage-one-billion-users-part-two";
  let h = (await extractArticle(url, oaiFeed(url))).contentHtml ?? "";
  assert.ok(headings(h) >= 30, `storage: ${headings(h)} headings`);
  for (const t of ["Making multi-tenancy reliable at scale", "Phase III: Using multi-tenancy by default", "Looking ahead"]) {
    assert.match(h, new RegExp(`<h[23]>(?:<span>)?${t.replace(/[()]/g, "\\$&")}`), `storage heading ${t}`);
  }
  console.log(`AUDIT openai storage: ${headings(h)} headings`);

  // Headings, and the line-numbered code block rebuilt as <pre><code>.
  url = "https://openai.com/index/decisions-api";
  h = (await extractArticle(url, oaiFeed(url))).contentHtml ?? "";
  assert.ok(headings(h) >= 5, `decisions: ${headings(h)} headings`);
  assert.match(h, /How teams are using the Decisions API/);
  assert.match(h, /<pre><code>\{\n {2}"type": "decisions",\n {2}"event_type": "session\.input_transcript\.delta"/);
  assert.doesNotMatch(plain(h), /opens in a new window/);
  console.log(`AUDIT openai decisions: ${headings(h)} headings, code block ok`);

  // Bold lead-ins in list items; screen-reader-only "(opens in new tab)".
  url = "https://claude.com/resources/articles/building-agents-when-to-fold-subagents-into-your-main-agent-loop";
  h = (await extractArticle(url)).contentHtml ?? "";
  assert.match(h, /<li><strong>Context management: ?<\/strong> ?You need to decide/);
  assert.doesNotMatch(plain(h), /opens in (?:a )?new (?:tab|window)/);
  console.log(`AUDIT claude subagents: lead-ins kept, ${headings(h)} headings`);

  url = "https://claude.com/resources/articles/claude-duet";
  h = (await extractArticle(url)).contentHtml ?? "";
  assert.doesNotMatch(plain(h), /opens in (?:a )?new (?:tab|window)/);
  // Not fixed: the 3-card testimonial carousel (Readability never scores it; see extract.ts notes).
  console.log(`AUDIT claude duet: no sr-only text; testimonials ${/Jess gets a rundown/.test(h) ? "present" : "missing (known)"}`);

  // Custom player: data-asset / data-poster media, relative paths, player chrome.
  url = "https://dreamlabs.ai/research/dream-1/";
  h = (await extractArticle(url)).contentHtml ?? "";
  const videos = h.match(/<video[^>]*>[\s\S]*?<\/video>/g) ?? [];
  assert.ok(videos.length >= 10, `dream: ${videos.length} videos`);
  assert.ok(videos.every((v) => /src="https:/.test(v)), "dream: a video without a source");
  assert.doesNotMatch(h, /(?:src|poster|srcset)="(?!https:)/, "dream: relative URL");
  assert.doesNotMatch(plain(h), /\b00:00\b|\d+\s*[–-]\s*\d+ of \d+/);
  await assertImagesLoad(imageUrls(h).slice(0, 3));
  const firstVideo = /<video src="([^"]+)"/.exec(h)?.[1];
  if (firstVideo) {
    const r = await fetchWithTimeout(firstVideo, 15000, { method: "HEAD" });
    assert.ok(r.ok && /^video\//.test(r.headers.get("content-type") ?? ""), `video ${firstVideo}: ${r.status}`);
  }
  console.log(`AUDIT dream: ${videos.length} playable videos, ${imageUrls(h).length} images`);

  // TechCrunch boilerplate.
  url = "https://techcrunch.com/2026/10/24/blocks-new-voice-model-sounds-eerily-human/";
  h = (await extractArticle(url)).contentHtml ?? "";
  assert.match(plain(h), /Dessa/);
  assert.doesNotMatch(plain(h), /commission|View Bio|\[email|Ivan covers/i);
  console.log(`AUDIT techcrunch: ${plain(h).length} chars, no boilerplate`);

  // README badges are not a lead image.
  url = "https://aardappel.github.io/goose/";
  const g = await extractArticle(url);
  assert.ok(!/shields\.io|badgen/.test(g.leadImage ?? ""), `goose lead ${g.leadImage}`);
  console.log(`AUDIT goose: lead ${g.leadImage}`);
}
main();
