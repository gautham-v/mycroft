import { and, eq, lt, sql } from "drizzle-orm";
import { getDb } from "@/db/client";
import { items, meta, sources, type SourceRow } from "@/db/schema";
import { FEED_FALLBACKS } from "@/db/seed";
import { dedupeItems } from "./dedupe";
import { errMsg, fetchWithTimeout } from "./http";
import { parseFeedXml, type ParsedFeed, type ParsedItem } from "./parse";
import { scrapePage } from "./scrape";
import { isStale } from "./time";
import type { RefreshResult } from "./types";

const FEED_TIMEOUT_MS = 15_000;
const LAST_REFRESH_KEY = "last_refresh_at";
const RETENTION_DAYS = 14;
/** Scraped-page sources remember this many handled article URLs. */
const MAX_SEEN_URLS = 300;

function retentionCutoff(): Date {
  return new Date(Date.now() - RETENTION_DAYS * 24 * 60 * 60 * 1000);
}

/** Delete unsaved items older than the retention window. Returns rows removed. */
export async function pruneOldItems(): Promise<number> {
  const db = await getDb();
  const out = await db
    .delete(items)
    .where(and(eq(items.isSaved, false), lt(items.publishedAt, retentionCutoff())))
    .returning({ id: items.id });
  return out.length;
}

export async function fetchFeedText(url: string): Promise<string> {
  const res = await fetchWithTimeout(url, FEED_TIMEOUT_MS, {
    headers: { Accept: "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.5" },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.text();
}

async function fetchSourceFeed(src: SourceRow): Promise<{ feed: ParsedFeed; feedUrl: string }> {
  const candidates = [src.feedUrl, ...(FEED_FALLBACKS[src.feedUrl] ?? [])];
  let lastErr: unknown;
  for (const url of candidates) {
    try {
      const xml = await fetchFeedText(url);
      return { feed: await parseFeedXml(xml, src.kind, url), feedUrl: url };
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr;
}

/**
 * Page sources: scrape the listing and fetch only article pages we haven't handled before
 * (stored items, plus `seen_urls` for ones that were too old to keep or weren't articles).
 */
async function scrapeSourceItems(src: SourceRow, stored: StoredItem[]): Promise<{ items: ParsedItem[]; seenUrls: string[] }> {
  const seen = src.seenUrls ?? [];
  const r = await scrapePage(src.feedUrl, new Set([...seen, ...stored.map((x) => x.url)]));
  const seenUrls = [...new Set([...r.processed, ...seen])].slice(0, MAX_SEEN_URLS);
  return { items: r.items, seenUrls };
}

type StoredItem = { guid: string; url: string; title: string };

async function sourceItems(src: SourceRow, stored: StoredItem[]): Promise<{ items: ParsedItem[]; seenUrls?: string[] }> {
  if (src.kind === "page") return scrapeSourceItems(src, stored);
  const { feed } = await fetchSourceFeed(src);
  return { items: feed.items };
}

export async function refreshSource(src: SourceRow): Promise<{ added: number }> {
  const db = await getDb();
  try {
    const stored = await db
      .select({ guid: items.guid, url: items.url, title: items.title })
      .from(items)
      .where(eq(items.sourceId, src.id));
    const { items: parsed, seenUrls } = await sourceItems(src, stored);
    let added = 0;
    // Skip items already past the retention window so pruned rows don't come back.
    const cutoff = retentionCutoff();
    const fresh = parsed.filter((it) => it.publishedAt >= cutoff);
    // By guid, then by link: a second HN submission of a stored story is skipped.
    const unique = dedupeItems(fresh.slice(0, 100), {
      stored,
      linkOnly: src.group === "aggregator" || fresh.some((it) => it.hnCommentsUrl),
      siteUrl: src.url,
    });
    const rows = unique.map((it) => ({ ...it, sourceId: src.id }));
    if (rows.length) {
      const out = await db
        .insert(items)
        .values(rows)
        .onConflictDoUpdate({
          target: [items.sourceId, items.guid],
          set: {
            title: sql`excluded.title`,
            url: sql`excluded.url`,
            summary: sql`coalesce(excluded.summary, ${items.summary})`,
            thumbnailUrl: sql`coalesce(excluded.thumbnail_url, ${items.thumbnailUrl})`,
            hnPoints: sql`excluded.hn_points`,
            hnComments: sql`excluded.hn_comments`,
            hnCommentsUrl: sql`excluded.hn_comments_url`,
          },
        })
        .returning({ inserted: sql<boolean>`(xmax = 0)` });
      added = out.filter((r) => r.inserted).length;
    }
    await db
      .update(sources)
      .set({ lastFetchedAt: new Date(), lastError: null, ...(seenUrls ? { seenUrls } : {}) })
      .where(eq(sources.id, src.id));
    return { added };
  } catch (e) {
    await db
      .update(sources)
      .set({ lastFetchedAt: new Date(), lastError: errMsg(e).slice(0, 500) })
      .where(eq(sources.id, src.id));
    throw e;
  }
}

export async function getLastRefreshAt(): Promise<string | null> {
  const db = await getDb();
  const [row] = await db.select().from(meta).where(eq(meta.key, LAST_REFRESH_KEY));
  return row?.value ?? null;
}

/** Refresh all sources if stale (>15 min) or forced. */
export async function refreshAll({ force = false }: { force?: boolean } = {}): Promise<RefreshResult> {
  const db = await getDb();
  const last = await getLastRefreshAt();
  if (!force && !isStale(last)) return { ran: false, lastRefreshAt: last };

  // Claim the refresh slot first so concurrent calls don't stampede.
  const now = new Date().toISOString();
  await db
    .insert(meta)
    .values({ key: LAST_REFRESH_KEY, value: now })
    .onConflictDoUpdate({ target: meta.key, set: { value: now } });

  const all = await db.select().from(sources);
  const settled = await Promise.allSettled(all.map((s) => refreshSource(s)));
  const results = settled.map((r, i) => ({
    sourceId: all[i].id,
    title: all[i].title,
    ok: r.status === "fulfilled",
    added: r.status === "fulfilled" ? r.value.added : 0,
    ...(r.status === "rejected" ? { error: errMsg(r.reason) } : {}),
  }));
  const pruned = await pruneOldItems();
  return { ran: true, lastRefreshAt: now, results, pruned };
}
