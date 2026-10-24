import { and, eq, inArray } from "drizzle-orm";
import { getDb } from "@/db/client";
import { items, sources } from "@/db/schema";
import { errMsg, errorJson, json } from "@/lib/http";
import { itemConditions, parseFilter, parseView } from "@/lib/queries";

export async function POST(req: Request) {
  try {
    const body = (await req.json().catch(() => ({}))) as {
      ids?: unknown;
      all?: boolean;
      view?: string;
      source?: number | string;
      filter?: string;
    };
    const db = await getDb();
    if (Array.isArray(body.ids)) {
      const ids = body.ids.map(Number).filter(Number.isInteger);
      if (!ids.length) return json({ updated: 0 });
      const r = await db.update(items).set({ isRead: true }).where(inArray(items.id, ids)).returning({ id: items.id });
      return json({ updated: r.length });
    }
    if (body.all === true) {
      const conds = itemConditions({
        view: parseView(body.view),
        source: Number(body.source) || null,
        filter: parseFilter(body.filter),
      });
      conds.push(eq(items.isRead, false));
      const sub = db
        .select({ id: items.id })
        .from(items)
        .innerJoin(sources, eq(items.sourceId, sources.id))
        .where(and(...conds));
      const r = await db.update(items).set({ isRead: true }).where(inArray(items.id, sub)).returning({ id: items.id });
      return json({ updated: r.length });
    }
    return errorJson("Provide {ids} or {all: true}", 400);
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
