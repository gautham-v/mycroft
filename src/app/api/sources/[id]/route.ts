import { eq } from "drizzle-orm";
import { getDb } from "@/db/client";
import { folders, sources } from "@/db/schema";
import { errMsg, errorJson, json } from "@/lib/http";
import { toSource } from "@/lib/queries";

/** Move a source to a folder (null = Unfiled) or rename it. */
export async function PATCH(req: Request, ctx: { params: Promise<{ id: string }> }) {
  try {
    const id = Number((await ctx.params).id);
    if (!Number.isInteger(id)) return errorJson("Invalid id", 400);
    const body = (await req.json().catch(() => ({}))) as { folder_id?: number | null; title?: string };
    const set: Partial<typeof sources.$inferInsert> = {};
    const db = await getDb();
    if ("folder_id" in body) {
      if (body.folder_id !== null && !Number.isInteger(body.folder_id)) return errorJson("folder_id must be an id or null", 400);
      if (body.folder_id !== null) {
        const [f] = await db.select({ id: folders.id }).from(folders).where(eq(folders.id, body.folder_id as number));
        if (!f) return errorJson("Folder not found", 404);
      }
      set.folderId = body.folder_id as number | null;
    }
    if (typeof body.title === "string") {
      const title = body.title.trim();
      if (!title) return errorJson("title cannot be empty", 400);
      set.title = title;
    }
    if (!Object.keys(set).length) return errorJson("Nothing to update", 400);
    const [row] = await db.update(sources).set(set).where(eq(sources.id, id)).returning();
    if (!row) return errorJson("Not found", 404);
    return json({ source: toSource(row) });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}

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
