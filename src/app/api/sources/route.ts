import { connection } from "next/server";
import { asc, eq, sql } from "drizzle-orm";
import { getDb } from "@/db/client";
import { folders, sources } from "@/db/schema";
import { detectFeed } from "@/lib/feed-detect";
import { refreshSource } from "@/lib/fetcher";
import { errMsg, errorJson, json } from "@/lib/http";
import { toFolder, toSource } from "@/lib/queries";
import { normalizeSourceUrl } from "@/lib/source-url";
import type { ReorderSourcesBody } from "@/lib/types";

// Adding a scraped-page source fetches its listing and article pages before responding.
export const maxDuration = 60;

export async function GET() {
  await connection();
  try {
    const db = await getDb();
    const [rows, fs] = await Promise.all([
      db.select().from(sources).orderBy(asc(sources.position), asc(sources.title)),
      db.select().from(folders).orderBy(asc(folders.position), asc(folders.id)),
    ]);
    return json({ sources: rows.map(toSource), folders: fs.map(toFolder) });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}

export async function POST(req: Request) {
  try {
    const body = (await req.json().catch(() => ({}))) as { url?: string; group?: string };
    if (!body.url || typeof body.url !== "string") return errorJson("url is required", 400);
    let url: string;
    try {
      url = normalizeSourceUrl(body.url);
    } catch (e) {
      return errorJson(errMsg(e), 400);
    }
    let found;
    try {
      found = await detectFeed(url);
    } catch (e) {
      return errorJson(errMsg(e), 422);
    }
    const db = await getDb();
    const [existing] = await db.select().from(sources).where(eq(sources.feedUrl, found.feedUrl));
    if (existing) return json({ source: toSource(existing), existed: true });
    // New sources land in Unfiled, after whatever is already there.
    const [{ next }] = await db
      .select({ next: sql<number>`coalesce(max(${sources.position}), -1) + 1` })
      .from(sources)
      .where(sql`${sources.folderId} IS NULL`);
    const [created] = await db
      .insert(sources)
      .values({ ...found, group: typeof body.group === "string" && body.group ? body.group : found.group, position: Number(next) })
      .returning();
    try {
      await refreshSource(created);
    } catch {
      /* last_error recorded on source */
    }
    const [fresh] = await db.select().from(sources).where(eq(sources.id, created.id));
    return json({ source: toSource(fresh ?? created) }, { status: 201 });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}

/** Move and reorder sources: each entry gets the folder given and the position of its index within that folder. */
export async function PATCH(req: Request) {
  try {
    const body = (await req.json().catch(() => ({}))) as Partial<ReorderSourcesBody>;
    if (!Array.isArray(body.order)) return errorJson("order is required", 400);
    const db = await getDb();
    const counters = new Map<number | null, number>();
    const updates = body.order
      .filter((o) => Number.isInteger(o?.id) && (o.folder_id === null || Number.isInteger(o.folder_id)))
      .map((o) => {
        const pos = counters.get(o.folder_id) ?? 0;
        counters.set(o.folder_id, pos + 1);
        return db.update(sources).set({ folderId: o.folder_id, position: pos }).where(eq(sources.id, o.id));
      });
    await Promise.all(updates);
    return json({ ok: true, updated: updates.length });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
