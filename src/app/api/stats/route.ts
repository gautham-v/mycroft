import { connection } from "next/server";
import { eq, sql } from "drizzle-orm";
import { getDb } from "@/db/client";
import { items, sources } from "@/db/schema";
import { getLastRefreshAt } from "@/lib/fetcher";
import { errMsg, errorJson, json } from "@/lib/http";
import type { Stats } from "@/lib/types";

export async function GET() {
  await connection();
  try {
    const db = await getDb();
    const [row] = await db
      .select({
        unread: sql<number>`count(*) filter (where ${items.isRead} = false)::int`,
        saved: sql<number>`count(*) filter (where ${items.isSaved} = true)::int`,
        video: sql<number>`count(*) filter (where ${sources.kind} = 'youtube' and ${items.isRead} = false)::int`,
      })
      .from(items)
      .innerJoin(sources, eq(items.sourceId, sources.id));
    const body: Stats = {
      unread: Number(row?.unread ?? 0),
      saved: Number(row?.saved ?? 0),
      video: Number(row?.video ?? 0),
      lastRefreshAt: await getLastRefreshAt(),
    };
    return json(body);
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
