import { eq } from "drizzle-orm";
import { getDb } from "@/db/client";
import { sources } from "@/db/schema";
import { errMsg, errorJson, json } from "@/lib/http";

export async function DELETE(_req: Request, ctx: { params: Promise<{ id: string }> }) {
  try {
    const id = Number((await ctx.params).id);
    if (!Number.isInteger(id)) return errorJson("Invalid id", 400);
    const db = await getDb();
    const r = await db.delete(sources).where(eq(sources.id, id)).returning({ id: sources.id });
    if (!r.length) return errorJson("Not found", 404);
    return json({ ok: true, id });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
