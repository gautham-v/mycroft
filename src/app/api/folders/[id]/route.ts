import { eq } from "drizzle-orm";
import { getDb } from "@/db/client";
import { folders } from "@/db/schema";
import { errMsg, errorJson, json } from "@/lib/http";
import { toFolder } from "@/lib/queries";

/** Rename a folder. */
export async function PATCH(req: Request, ctx: { params: Promise<{ id: string }> }) {
  try {
    const id = Number((await ctx.params).id);
    if (!Number.isInteger(id)) return errorJson("Invalid id", 400);
    const body = (await req.json().catch(() => ({}))) as { title?: string };
    const title = typeof body.title === "string" ? body.title.trim() : "";
    if (!title) return errorJson("title is required", 400);
    const db = await getDb();
    const [row] = await db.update(folders).set({ title }).where(eq(folders.id, id)).returning();
    if (!row) return errorJson("Not found", 404);
    return json({ folder: toFolder(row) });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}

/** Delete a folder. Its sources move to Unfiled (folder_id set null by the FK). */
export async function DELETE(_req: Request, ctx: { params: Promise<{ id: string }> }) {
  try {
    const id = Number((await ctx.params).id);
    if (!Number.isInteger(id)) return errorJson("Invalid id", 400);
    const db = await getDb();
    const r = await db.delete(folders).where(eq(folders.id, id)).returning({ id: folders.id });
    if (!r.length) return errorJson("Not found", 404);
    return json({ ok: true, id });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
