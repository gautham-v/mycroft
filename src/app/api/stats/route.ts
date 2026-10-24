import { connection } from "next/server";
import { sql } from "drizzle-orm";
import { getDb } from "@/db/client";
import { items } from "@/db/schema";
import { getLastRefreshAt } from "@/lib/fetcher";
import { errMsg, errorJson, json } from "@/lib/http";
import type { Stats } from "@/lib/types";

export async function GET() {
  await connection();
  try {
    const db = await getDb();
    const [row] = await db
      .select({ unread: sql<number>`count(*) filter (where ${items.isRead} = false)::int` })
      .from(items);
    const body: Stats = {
      unread: Number(row?.unread ?? 0),
      lastRefreshAt: await getLastRefreshAt(),
    };
    return json(body);
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
