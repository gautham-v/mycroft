import { connection } from "next/server";
import { asc, sql } from "drizzle-orm";
import { getDb } from "@/db/client";
import { folders, sources } from "@/db/schema";
import { errMsg, errorJson, json } from "@/lib/http";
import { parse, serialize, type OpmlSource } from "@/lib/opml";
import { normalizeSourceUrl } from "@/lib/source-url";
import type { OpmlImportResult, SourceKind } from "@/lib/types";

/** Export every source as OPML 2.0, folders in sidebar order. */
export async function GET() {
  await connection();
  try {
    const db = await getDb();
    const [fs, rows] = await Promise.all([
      db.select().from(folders).orderBy(asc(folders.position), asc(folders.id)),
      db.select().from(sources).orderBy(asc(sources.position), asc(sources.title)),
    ]);
    const now = new Date();
    return new Response(serialize(fs, rows, now), {
      headers: {
        "Content-Type": "text/x-opml; charset=utf-8",
        "Content-Disposition": `attachment; filename="openfeed-${now.toISOString().slice(0, 10)}.opml"`,
        "Cache-Control": "no-store",
      },
    });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}

/** Lookup key for "already subscribed": scheme, `www.`, trailing slash and host case don't matter. */
function feedKey(url: string): string {
  return url
    .trim()
    .replace(/^https?:\/\/(www\.)?/i, "")
    .replace(/\/+$/, "")
    .replace(/^[^/?#]+/, (h) => h.toLowerCase());
}

/**
 * Source columns for an OPML feed, shaped like what POST /api/sources stores (see detectFeed) but
 * without fetching: YouTube feeds get the canonical feed URL and channel page; everything else is
 * rss unless an Openfeed export says otherwise. Podcasts are promoted on their first refresh.
 */
function sourceFields(o: OpmlSource): { title: string; url: string; feedUrl: string; kind: SourceKind; group: string } {
  const feed = new URL(normalizeSourceUrl(o.feedUrl));
  let site: string | null = null;
  if (o.htmlUrl) {
    try {
      site = normalizeSourceUrl(o.htmlUrl);
    } catch {
      /* fall back below */
    }
  }
  const isYoutube = /(^|\.)youtube\.com$/i.test(feed.hostname) && feed.pathname.startsWith("/feeds/videos.xml");
  if (isYoutube || o.kind === "youtube") {
    const channel = feed.searchParams.get("channel_id");
    return {
      title: o.title || "YouTube channel",
      url: channel ? `https://www.youtube.com/channel/${channel}` : (site ?? feed.toString()),
      feedUrl: channel ? `https://www.youtube.com/feeds/videos.xml?channel_id=${channel}` : feed.toString(),
      kind: "youtube",
      group: "youtube",
    };
  }
  const kind: SourceKind = o.kind === "page" || o.kind === "podcast" ? o.kind : "rss";
  return {
    title: o.title || feed.hostname.replace(/^www\./, ""),
    // Page sources are their own listing URL; feeds fall back to the feed's origin like detectFeed.
    url: kind === "page" ? feed.toString() : (site ?? feed.origin),
    feedUrl: feed.toString(),
    kind,
    group: kind === "podcast" ? "podcast" : "blogs",
  };
}

async function readBody(req: Request): Promise<string> {
  if ((req.headers.get("content-type") ?? "").includes("multipart/form-data")) {
    const form = await req.formData();
    const file = form.get("file");
    if (file == null) throw new Error("file is required");
    return typeof file === "string" ? file : file.text();
  }
  return req.text();
}

/**
 * Import an OPML file (multipart field "file", or the raw XML as the body). Feeds already
 * subscribed are skipped; folders are matched by title (any case) or created. Nothing is fetched
 * here: the new sources are picked up by the next refresh.
 */
export async function POST(req: Request) {
  let doc;
  try {
    doc = parse(await readBody(req));
  } catch (e) {
    return errorJson(errMsg(e), 400);
  }
  try {
    const db = await getDb();
    const [existingSources, existingFolders] = await Promise.all([
      db.select({ feedUrl: sources.feedUrl }).from(sources),
      db.select().from(folders).orderBy(asc(folders.position)),
    ]);
    const known = new Set(existingSources.map((s) => feedKey(s.feedUrl)));
    const folderIds = new Map(existingFolders.map((f) => [f.title.trim().toLowerCase(), f.id]));
    let nextFolderPos = existingFolders.reduce((m, f) => Math.max(m, f.position), -1) + 1;
    const result: OpmlImportResult = { added: 0, skipped: 0, folders_created: 0, errors: [] };

    // Next position per folder (null = Unfiled), so imports land after what's already there.
    const positions = new Map<number | null, number>();
    const nextPosition = async (folderId: number | null) => {
      if (!positions.has(folderId)) {
        const [{ next }] = await db
          .select({ next: sql<number>`coalesce(max(${sources.position}), -1) + 1` })
          .from(sources)
          .where(folderId == null ? sql`${sources.folderId} IS NULL` : sql`${sources.folderId} = ${folderId}`);
        positions.set(folderId, Number(next));
      }
      const p = positions.get(folderId)!;
      positions.set(folderId, p + 1);
      return p;
    };

    const rows: (typeof sources.$inferInsert)[] = [];
    const groups: [string | null, OpmlSource[]][] = [[null, doc.unfiled], ...doc.folders.map((f): [string, OpmlSource[]] => [f.title, f.sources])];
    for (const [folderTitle, list] of groups) {
      // Resolve every feed first so a folder holding only duplicates or bad URLs isn't created.
      const fresh: ReturnType<typeof sourceFields>[] = [];
      for (const o of list) {
        let fields;
        try {
          fields = sourceFields(o);
        } catch (e) {
          result.errors.push(`${o.title || o.feedUrl}: ${errMsg(e)}`);
          continue;
        }
        const key = feedKey(fields.feedUrl);
        if (known.has(key)) {
          result.skipped++;
          continue;
        }
        known.add(key);
        fresh.push(fields);
      }
      if (!fresh.length) continue;

      let folderId: number | null = null;
      if (folderTitle != null) {
        const key = folderTitle.trim().toLowerCase();
        folderId = folderIds.get(key) ?? null;
        if (folderId == null) {
          const [created] = await db.insert(folders).values({ title: folderTitle.trim(), position: nextFolderPos++ }).returning();
          folderId = created.id;
          folderIds.set(key, folderId);
          result.folders_created++;
        }
      }
      for (const f of fresh) rows.push({ ...f, folderId, position: await nextPosition(folderId) });
    }

    if (rows.length) {
      // The unique feed_url constraint is the backstop for exact duplicates feedKey didn't catch.
      const inserted = await db.insert(sources).values(rows).onConflictDoNothing({ target: sources.feedUrl }).returning({ id: sources.id });
      result.added = inserted.length;
      result.skipped += rows.length - inserted.length;
    }
    return json(result, { status: result.added ? 201 : 200 });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
