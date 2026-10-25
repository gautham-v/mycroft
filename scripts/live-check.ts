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
  await checkRecentItems(["Ars Technica AI", "Simon Willison", "Google DeepMind Blog"]);
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
  assert.match(html, /Interactive figure not shown here[\s\S]*#urgent-high-candidate-findings-vs-tokens-spent/);
  const urls = imageUrls(html);
  await assertImagesLoad(urls);
  console.log(`FIGURES: ok (rendered=${out.rendered}, ${urls.length} image URLs load, ${html.length} chars)`);
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
main();
