import { and, eq, lt, sql } from "drizzle-orm";
import { getDb } from "@/db/client";
import { items, meta, sources, type SourceRow } from "@/db/schema";
import { FEED_FALLBACKS } from "@/db/seed";
import { errMsg, fetchWithTimeout } from "./http";
import { parseFeedXml, type ParsedFeed } from "./parse";
import { isStale } from "./time";
import type { RefreshResult } from "./types";

const FEED_TIMEOUT_MS = 15_000;
const LAST_REFRESH_KEY = "last_refresh_at";
const RETENTION_DAYS = 14;

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

export async function refreshSource(src: SourceRow): Promise<{ added: number }> {
  const db = await getDb();
  try {
    const { feed } = await fetchSourceFeed(src);
    let added = 0;
    // Skip items already past the retention window so pruned rows don't come back.
    const cutoff = retentionCutoff();
    const fresh = feed.items.filter((it) => it.publishedAt >= cutoff);
    // Dedupe by guid: ON CONFLICT DO UPDATE errors if one statement touches a row twice.
    const byGuid = new Map(fresh.slice(0, 100).map((it) => [it.guid, it]));
    const rows = [...byGuid.values()].map((it) => ({ ...it, sourceId: src.id }));
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
      .set({ lastFetchedAt: new Date(), lastError: null })
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
