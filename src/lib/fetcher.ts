import { and, desc, eq, inArray, isNull, lt, notInArray, sql } from "drizzle-orm";
import { getDb, type DB } from "@/db/client";
import { items, meta, sources, type SourceRow } from "@/db/schema";
import { FEED_FALLBACKS } from "@/db/seed";
import { dedupeItems } from "./dedupe";
import { errMsg, fetchWithTimeout } from "./http";
import { fetchPageImages, THUMB_TIMEOUT_MS } from "./page-meta";
import { parseFeedXml, type ParsedFeed, type ParsedItem } from "./parse";
import { scrapePage } from "./scrape";
import { isStale } from "./time";
import type { RefreshResult } from "./types";

const FEED_TIMEOUT_MS = 15_000;
const LAST_REFRESH_KEY = "last_refresh_at";
const RETENTION_DAYS = 14;
/** Scraped-page sources remember this many handled article URLs. */
const MAX_SEEN_URLS = 300;
/** New items without a feed thumbnail whose page is read for og:image in the refresh that adds them. */
export const NEW_THUMB_CAP = 12;
/** Older items without a thumbnail, never tried before, read per source per refresh. */
export const OLD_THUMB_CAP = 10;
const THUMB_CONCURRENCY = 4;
/** Stop starting thumbnail fetches for a source after this; the rest are picked up next refresh. */
const THUMB_BUDGET_MS = 20_000;

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

type ThumbTarget = { id: number; url: string };

/** Items this refresh inserted that still lack a thumbnail: newest first, at most `cap`. */
export function newThumbTargets(
  rows: { id: number; url: string; thumbnailUrl: string | null; publishedAt: Date; inserted: boolean }[],
  cap = NEW_THUMB_CAP,
): ThumbTarget[] {
  return rows
    .filter((r) => r.inserted && !r.thumbnailUrl)
    .sort((a, b) => new Date(b.publishedAt).getTime() - new Date(a.publishedAt).getTime())
    .slice(0, cap)
    .map(({ id, url }) => ({ id, url }));
}

/**
 * Fill missing thumbnails from each article's og:image (feeds like openai.com/news carry no images).
 * Tries this refresh's new items, then up to OLD_THUMB_CAP older ones not tried before, and marks
 * each tried item `thumbnail_checked` so it isn't refetched. Temporary misses (429, 5xx) and items
 * the time budget didn't reach stay unmarked for a later refresh. Returns thumbnails found.
 */
export async function backfillThumbnails(db: DB, sourceId: number, fresh: ThumbTarget[]): Promise<number> {
  const old = await db
    .select({ id: items.id, url: items.url })
    .from(items)
    .where(
      and(
        eq(items.sourceId, sourceId),
        isNull(items.thumbnailUrl),
        eq(items.thumbnailChecked, false),
        fresh.length ? notInArray(items.id, fresh.map((t) => t.id)) : undefined,
      ),
    )
    .orderBy(desc(items.publishedAt))
    .limit(OLD_THUMB_CAP);
  const results = await fetchPageImages([...fresh, ...old], {
    concurrency: THUMB_CONCURRENCY,
    timeoutMs: THUMB_TIMEOUT_MS,
    budgetMs: THUMB_BUDGET_MS,
  });
  const found = results.filter((r) => r.image);
  const misses = results.filter((r) => !r.image && r.final).map((r) => r.id);
  await Promise.all([
    ...found.map((r) =>
      db
        .update(items)
        .set({ thumbnailUrl: r.image, thumbnailChecked: true })
        // The reader may have set one from the extracted lead image in the meantime.
        .where(and(eq(items.id, r.id), isNull(items.thumbnailUrl))),
    ),
    ...(misses.length ? [db.update(items).set({ thumbnailChecked: true }).where(inArray(items.id, misses))] : []),
  ]);
  return found.length;
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
    let thumbTargets: ThumbTarget[] = [];
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
            audioUrl: sql`coalesce(excluded.audio_url, ${items.audioUrl})`,
            durationSec: sql`coalesce(excluded.duration_sec, ${items.durationSec})`,
            hnPoints: sql`excluded.hn_points`,
            hnComments: sql`excluded.hn_comments`,
            hnCommentsUrl: sql`excluded.hn_comments_url`,
          },
        })
        .returning({
          id: items.id,
          url: items.url,
          thumbnailUrl: items.thumbnailUrl,
          publishedAt: items.publishedAt,
          inserted: sql<boolean>`(xmax = 0)`,
        });
      added = out.filter((r) => r.inserted).length;
      thumbTargets = newThumbTargets(out);
    }
    await db
      .update(sources)
      .set({ lastFetchedAt: new Date(), lastError: null, ...(seenUrls ? { seenUrls } : {}) })
      .where(eq(sources.id, src.id));
    // Page sources get og:image while scraping; YouTube thumbnails come from the video id. Podcast
    // episodes take the episode or show art from the feed, so only art-less ones reach the page.
    if (src.kind === "rss" || src.kind === "podcast") {
      try {
        await backfillThumbnails(db, src.id, thumbTargets);
      } catch (e) {
        console.warn(`thumbnail backfill failed for ${src.title}:`, errMsg(e));
      }
    }
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
