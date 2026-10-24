import { connection } from "next/server";
import { eq } from "drizzle-orm";
import { getDb } from "@/db/client";
import { items, sources } from "@/db/schema";
import { errMsg, errorJson, json } from "@/lib/http";
import { toItem } from "@/lib/queries";
import type { PatchItemBody } from "@/lib/types";

export async function GET(_req: Request, ctx: { params: Promise<{ id: string }> }) {
  try {
    await connection();
    const id = Number((await ctx.params).id);
    if (!Number.isInteger(id)) return errorJson("Invalid id", 400);
    const db = await getDb();
    const [row] = await db.select().from(items).where(eq(items.id, id));
    if (!row) return errorJson("Not found", 404);
    const [src] = await db.select().from(sources).where(eq(sources.id, row.sourceId));
    return json({ item: toItem(row, src) });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}

export async function PATCH(req: Request, ctx: { params: Promise<{ id: string }> }) {
  try {
    const id = Number((await ctx.params).id);
    if (!Number.isInteger(id)) return errorJson("Invalid id", 400);
    const body = (await req.json().catch(() => ({}))) as PatchItemBody;
    if (typeof body.is_saved !== "boolean") return errorJson("Nothing to update", 400);
    const db = await getDb();
    const [row] = await db.update(items).set({ isSaved: body.is_saved }).where(eq(items.id, id)).returning();
    if (!row) return errorJson("Not found", 404);
    const [src] = await db.select().from(sources).where(eq(sources.id, row.sourceId));
    return json({ item: toItem(row, src) });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
