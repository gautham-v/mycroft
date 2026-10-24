import { SEED_SOURCES, FEED_FALLBACKS } from "../src/db/seed";
import { fetchWithTimeout } from "../src/lib/http";
import { parseFeedXml } from "../src/lib/parse";
import { extractArticle } from "../src/lib/extract";

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
}
main();
