import { connection } from "next/server";
import { asc, eq, sql } from "drizzle-orm";
import { getDb } from "@/db/client";
import { folders } from "@/db/schema";
import { errMsg, errorJson, json } from "@/lib/http";
import { toFolder } from "@/lib/queries";
import type { ReorderFoldersBody } from "@/lib/types";

export async function GET() {
  await connection();
  try {
    const db = await getDb();
    const rows = await db.select().from(folders).orderBy(asc(folders.position), asc(folders.id));
    return json({ folders: rows.map(toFolder) });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}

/** Create a folder at the bottom of the sidebar. */
export async function POST(req: Request) {
  try {
    const body = (await req.json().catch(() => ({}))) as { title?: string };
    const title = typeof body.title === "string" ? body.title.trim() : "";
    if (!title) return errorJson("title is required", 400);
    const db = await getDb();
    const [{ next }] = await db.select({ next: sql<number>`coalesce(max(${folders.position}), -1) + 1` }).from(folders);
    const [created] = await db.insert(folders).values({ title, position: Number(next) }).returning();
    return json({ folder: toFolder(created) }, { status: 201 });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}

/** Reorder folders: body.order lists ids top to bottom. */
export async function PATCH(req: Request) {
  try {
    const body = (await req.json().catch(() => ({}))) as Partial<ReorderFoldersBody>;
    if (!Array.isArray(body.order)) return errorJson("order is required", 400);
    const db = await getDb();
    await Promise.all(
      body.order.filter((id) => Number.isInteger(id)).map((id, i) => db.update(folders).set({ position: i }).where(eq(folders.id, id))),
    );
    return json({ ok: true });
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
