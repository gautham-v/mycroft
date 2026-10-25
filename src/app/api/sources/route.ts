import { connection } from "next/server";
import { asc, eq } from "drizzle-orm";
import { getDb } from "@/db/client";
import { sources } from "@/db/schema";
import { detectFeed } from "@/lib/feed-detect";
import { refreshSource } from "@/lib/fetcher";
import { errMsg, errorJson, json } from "@/lib/http";
import { toSource } from "@/lib/queries";

// Adding a scraped-page source fetches its listing and article pages before responding.
export const maxDuration = 60;

export async function GET() {
  await connection();
  try {
    const db = await getDb();
    const rows = await db.select().from(sources).orderBy(asc(sources.group), asc(sources.title));
    return json({ sources: rows.map(toSource) });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}

export async function POST(req: Request) {
  try {
    const body = (await req.json().catch(() => ({}))) as { url?: string; group?: string };
    if (!body.url || typeof body.url !== "string") return errorJson("url is required", 400);
    let found;
    try {
      found = await detectFeed(body.url.trim());
    } catch (e) {
      return errorJson(errMsg(e), 422);
    }
    const db = await getDb();
    const [existing] = await db.select().from(sources).where(eq(sources.feedUrl, found.feedUrl));
    if (existing) return json({ source: toSource(existing), existed: true });
    const [created] = await db
      .insert(sources)
      .values({ ...found, group: typeof body.group === "string" && body.group ? body.group : found.group })
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
