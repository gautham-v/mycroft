// Scrape a listing page with no feed and print what a 'page' source would store.
// Usage: pnpm tsx scripts/scrape-check.ts https://claude.com/resources/articles [more URLs...]
import { detectFeed } from "../src/lib/feed-detect";
import { scrapePage } from "../src/lib/scrape";

async function check(url: string) {
  const t0 = Date.now();
  const src = await detectFeed(url);
  console.log(`\n${src.title}  [kind=${src.kind}]  ${src.feedUrl}`);
  if (src.kind !== "page") return console.log("  (has a feed; not a scraped page)");
  const r = await scrapePage(src.feedUrl, new Set(), { budgetMs: 60_000 });
  console.log(`  ${r.links.length} links, ${r.items.length} items, ${r.processed.length - r.items.length} skipped, ${Date.now() - t0}ms`);
  const items = [...r.items].sort((a, b) => b.publishedAt.getTime() - a.publishedAt.getTime());
  for (const it of items) {
    console.log(`  ${it.publishedAt.toISOString().slice(0, 10)}  ${it.title}`);
    console.log(`              ${it.url}${it.thumbnailUrl ? "  [img]" : ""}${it.author ? `  by ${it.author}` : ""}`);
  }
  const skipped = r.links.filter((l) => !r.items.some((i) => i.url === l));
  if (skipped.length) console.log(`  not items: ${skipped.join(", ")}`);
}

async function main() {
  const urls = process.argv.slice(2);
  if (!urls.length) {
    console.error("usage: tsx scripts/scrape-check.ts <listing-url> [...]");
    process.exit(1);
  }
  for (const u of urls) {
    try {
      await check(u);
    } catch (e) {
      console.log(`\nERR ${u}: ${(e as Error).message}`);
    }
  }
}
main();
