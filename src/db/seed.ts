import { eq, sql } from "drizzle-orm";
import type { NeonHttpDatabase } from "drizzle-orm/neon-http";
import * as schema from "./schema";

type SeedSource = {
  title: string;
  url: string;
  feedUrl: string;
  kind: "rss" | "youtube";
  group: string;
};

const yt = (title: string, channelId: string): SeedSource => ({
  title,
  url: `https://www.youtube.com/channel/${channelId}`,
  feedUrl: `https://www.youtube.com/feeds/videos.xml?channel_id=${channelId}`,
  kind: "youtube",
  group: "youtube",
});

export const SEED_SOURCES: SeedSource[] = [
  { title: "Hacker News", url: "https://news.ycombinator.com", feedUrl: "https://hnrss.org/newest?points=100", kind: "rss", group: "aggregator" },
  { title: "Ars Technica AI", url: "https://arstechnica.com", feedUrl: "https://feeds.arstechnica.com/arstechnica/technology-lab", kind: "rss", group: "news" },
  { title: "The Verge AI", url: "https://www.theverge.com", feedUrl: "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml", kind: "rss", group: "news" },
  { title: "TechCrunch AI", url: "https://techcrunch.com", feedUrl: "https://techcrunch.com/category/artificial-intelligence/feed/", kind: "rss", group: "news" },
  { title: "MIT Technology Review AI", url: "https://www.technologyreview.com", feedUrl: "https://www.technologyreview.com/topic/artificial-intelligence/feed", kind: "rss", group: "news" },
  { title: "Simon Willison", url: "https://simonwillison.net", feedUrl: "https://simonwillison.net/atom/everything/", kind: "rss", group: "blogs" },
  { title: "OpenAI News", url: "https://openai.com", feedUrl: "https://openai.com/news/rss.xml", kind: "rss", group: "labs" },
  { title: "Google DeepMind Blog", url: "https://deepmind.google", feedUrl: "https://deepmind.google/blog/rss.xml", kind: "rss", group: "labs" },
  yt("Matthew Berman", "UCawZsQWqfGSbCI5yjkdVkTA"),
  yt("Lenny's Podcast", "UC6t1O76G0jYXOAoYCm153dA"),
  yt("Ryan Peterman", "UCzB7YGrrxDC_POenf86H3_Q"),
  yt("Claude", "UCV03SRZXJEz-hchIAogeJOg"),
  yt("Anthropic", "UCrDwWp7EBBv4NwvScIpBDOA"),
  yt("Casually Explained", "UCr3cBLTYmIK9kY0F_OdFWFQ"),
  yt("Lex Clips", "UCJIfeSCssxSC_Dhc5s7woww"),
  yt("AI Engineer", "UCLKPca3kwwd-B59HNr-_lvA"),
  yt("Fireship", "UCsBjURrPoezykLs9EqgamOA"),
];

/** Fallback feed URLs tried when the primary returns an error. */
export const FEED_FALLBACKS: Record<string, string[]> = {};

const SEEDED_KEY = "seeded";

/**
 * Insert the built-in sources once per database. Guarded by a `meta` flag so a
 * source the user removed is not re-created on the next cold start.
 * Pass `force` (the `db:seed` script) to re-upsert the list anyway.
 */
export async function seedSources(db: NeonHttpDatabase<typeof schema>, opts: { force?: boolean } = {}): Promise<void> {
  if (!opts.force) {
    const [row] = await db.select().from(schema.meta).where(eq(schema.meta.key, SEEDED_KEY));
    if (row) return;
  }
  await db
    .insert(schema.sources)
    .values(SEED_SOURCES)
    .onConflictDoUpdate({
      target: schema.sources.feedUrl,
      set: {
        title: sql`excluded.title`,
        url: sql`excluded.url`,
        kind: sql`excluded.kind`,
        group: sql`excluded."group"`,
      },
    });
  await db
    .insert(schema.meta)
    .values({ key: SEEDED_KEY, value: new Date().toISOString() })
    .onConflictDoNothing();
}
