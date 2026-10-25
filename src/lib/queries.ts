import { and, eq, ilike, lt, notInArray, or, sql, type SQL } from "drizzle-orm";
import { folders, items, sources, type FolderRow, type ItemRow, type SourceRow } from "@/db/schema";
import { isPostSource, POST_SOURCE_RE } from "./folders";
import { hostOf } from "./http";
import type { Folder, Item, Source, SourceType, View } from "./types";

const VIEWS: View[] = ["all", "saved", "articles", "posts", "video", "podcasts"];
export function parseView(v: string | null | undefined): View {
  return VIEWS.includes(v as View) ? (v as View) : "all";
}

/** Longest search query the API accepts; longer input is truncated. */
export const MAX_QUERY = 200;
/** At most this many whitespace-separated terms are matched (each adds four ILIKEs). */
const MAX_TERMS = 8;

/** Search condition: every whitespace-separated term must appear (case-insensitively) in the
 *  title, summary, author or cached full text. LIKE wildcards in the input match literally. */
export function searchCondition(q: string | null | undefined): SQL | undefined {
  const terms = (q ?? "").trim().slice(0, MAX_QUERY).split(/\s+/).filter(Boolean).slice(0, MAX_TERMS);
  if (terms.length === 0) return undefined;
  return and(
    ...terms.map((t) => {
      // Backslash is Postgres' default LIKE escape character.
      const pat = `%${t.replace(/[\\%_]/g, "\\$&")}%`;
      return or(ilike(items.title, pat), ilike(items.summary, pat), ilike(items.author, pat), ilike(items.contentHtml, pat));
    }),
  );
}

/** WHERE conditions for view/source/folder/search (requires join on sources). */
export function itemConditions(opts: {
  view?: View;
  source?: number | null;
  folder?: number | null;
  q?: string | null;
}): SQL[] {
  const c: SQL[] = [];
  const isPost = sql`${sources.url} ~* ${POST_SOURCE_RE}`;
  if (opts.view === "saved") c.push(eq(items.isSaved, true));
  if (opts.view === "video") c.push(eq(sources.kind, "youtube"));
  if (opts.view === "podcasts") c.push(eq(sources.kind, "podcast"));
  if (opts.view === "posts") c.push(isPost);
  if (opts.view === "articles") c.push(notInArray(sources.kind, ["youtube", "podcast"]), sql`NOT (${isPost})`);
  if (opts.source) c.push(eq(items.sourceId, opts.source));
  if (opts.folder) c.push(eq(sources.folderId, opts.folder));
  const search = searchCondition(opts.q);
  if (search) c.push(search);
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
    audio_url: i.audioUrl,
    hn_points: i.hnPoints,
    hn_comments: i.hnComments,
    hn_comments_url: i.hnCommentsUrl,
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

export function sourceType(s: Pick<SourceRow, "kind" | "url">): SourceType {
  if (s.kind === "youtube") return "video";
  if (s.kind === "podcast") return "podcast";
  return isPostSource(s.url) ? "post" : "article";
}

export function toSource(s: SourceRow): Source {
  return {
    id: s.id,
    title: s.title,
    url: s.url,
    feed_url: s.feedUrl,
    kind: s.kind,
    group: s.group,
    type: sourceType(s),
    icon_url: s.iconUrl,
    host: hostOf(s.url),
    folder_id: s.folderId,
    position: s.position,
    last_fetched_at: s.lastFetchedAt?.toISOString() ?? null,
    last_error: s.lastError,
    created_at: s.createdAt.toISOString(),
  };
}

export function toFolder(f: FolderRow): Folder {
  return { id: f.id, title: f.title, position: f.position };
}

export { and, folders };
