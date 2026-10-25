import { connection, type NextRequest } from "next/server";
import { and, desc, eq } from "drizzle-orm";
import { getDb } from "@/db/client";
import { items, sources } from "@/db/schema";
import { errMsg, errorJson, json } from "@/lib/http";
import { cursorCondition, itemConditions, makeCursor, parseView, toItem } from "@/lib/queries";
import type { ItemsResponse } from "@/lib/types";

export async function GET(req: NextRequest) {
  await connection();
  try {
    const p = req.nextUrl.searchParams;
    const limit = Math.min(Math.max(Number(p.get("limit")) || 50, 1), 200);
    const source = Number(p.get("source")) || null;
    const folder = Number(p.get("folder")) || null;
    const conds = itemConditions({ view: parseView(p.get("view")), source, folder });
    const cc = cursorCondition(p.get("cursor"));
    if (cc) conds.push(cc);
    const db = await getDb();
    const rows = await db
      .select({ item: items, source: sources })
      .from(items)
      .innerJoin(sources, eq(items.sourceId, sources.id))
      .where(conds.length ? and(...conds) : undefined)
      .orderBy(desc(items.publishedAt), desc(items.id))
      .limit(limit + 1);
    const page = rows.slice(0, limit);
    const body: ItemsResponse = {
      items: page.map((r) => toItem(r.item, r.source)),
      nextCursor: rows.length > limit ? makeCursor(page[page.length - 1].item.publishedAt, page[page.length - 1].item.id) : null,
    };
    return json(body);
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
