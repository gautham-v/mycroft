import { and, eq, gte, lt, sql, type SQL } from "drizzle-orm";
import { items, sources, type ItemRow, type SourceRow } from "@/db/schema";
import { hostOf } from "./http";
import type { Filter, Item, Source, View } from "./types";

export function parseView(v: string | null | undefined): View {
  return v === "saved" || v === "video" ? v : "all";
}
export function parseFilter(v: string | null | undefined): Filter | null {
  return v === "hn100" || v === "labs" || v === "blogs" ? v : null;
}

/** WHERE conditions for view/source/filter (requires join on sources). */
export function itemConditions(opts: { view?: View; source?: number | null; filter?: Filter | null }): SQL[] {
  const c: SQL[] = [];
  if (opts.view === "saved") c.push(eq(items.isSaved, true));
  if (opts.view === "video") c.push(eq(sources.kind, "youtube"));
  if (opts.source) c.push(eq(items.sourceId, opts.source));
  if (opts.filter === "hn100") c.push(eq(sources.group, "aggregator"), gte(items.hnPoints, 100));
  if (opts.filter === "labs") c.push(eq(sources.group, "labs"));
  if (opts.filter === "blogs") c.push(eq(sources.group, "blogs"));
  return c;
}

/** Cursor is "<iso>|<id>" (keyset over (published_at desc, id desc)); bare ISO accepted. */
export function cursorCondition(cursor: string | null): SQL | undefined {
  if (!cursor) return undefined;
  const [iso, idStr] = cursor.split("|");
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return undefined;
  const id = Number(idStr);
  if (!Number.isInteger(id)) return lt(items.publishedAt, d);
  return sql`(${items.publishedAt}, ${items.id}) < (${d.toISOString()}::timestamptz, ${id})`;
}

export function makeCursor(publishedAt: Date, id: number): string {
  return `${publishedAt.toISOString()}|${id}`;
}

export function toItem(i: ItemRow, s: SourceRow): Item {
  return {
    id: i.id,
    source_id: i.sourceId,
    url: i.url,
    title: i.title,
    summary: i.summary,
    author: i.author,
    published_at: i.publishedAt.toISOString(),
    thumbnail_url: i.thumbnailUrl,
    video_id: i.videoId,
    duration_sec: i.durationSec,
    hn_points: i.hnPoints,
    hn_comments: i.hnComments,
    hn_comments_url: i.hnCommentsUrl,
    is_read: i.isRead,
    is_saved: i.isSaved,
    has_content: i.contentHtml != null,
    source: {
      id: s.id,
      title: s.title,
      kind: s.kind,
      group: s.group,
      icon_url: s.iconUrl,
      host: hostOf(s.url),
    },
  };
}

export function toSource(s: SourceRow): Source {
  return {
    id: s.id,
    title: s.title,
    url: s.url,
    feed_url: s.feedUrl,
    kind: s.kind,
    group: s.group,
    icon_url: s.iconUrl,
    host: hostOf(s.url),
    last_fetched_at: s.lastFetchedAt?.toISOString() ?? null,
    last_error: s.lastError,
    created_at: s.createdAt.toISOString(),
  };
}

export { and };
