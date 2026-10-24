import { connection } from "next/server";
import { eq } from "drizzle-orm";
import { getDb } from "@/db/client";
import { items, sources } from "@/db/schema";
import { extractArticle } from "@/lib/extract";
import { errMsg, errorJson, json } from "@/lib/http";
import type { ContentResponse } from "@/lib/types";

export const maxDuration = 20;

export async function GET(_req: Request, ctx: { params: Promise<{ id: string }> }) {
  await connection();
  try {
    const id = Number((await ctx.params).id);
    if (!Number.isInteger(id)) return errorJson("Invalid id", 400);
    const db = await getDb();
    const [row] = await db
      .select({ item: items, kind: sources.kind })
      .from(items)
      .innerJoin(sources, eq(items.sourceId, sources.id))
      .where(eq(items.id, id));
    if (!row) return errorJson("Not found", 404);
    const lead = row.item.thumbnailUrl;
    if (row.kind === "youtube") return json({ contentHtml: null, leadImage: lead } satisfies ContentResponse);
    if (row.item.contentHtml) {
      return json({ contentHtml: row.item.contentHtml, leadImage: lead } satisfies ContentResponse);
    }
    try {
      const out = await extractArticle(row.item.url);
      if (out.contentHtml) {
        await db
          .update(items)
          .set({ contentHtml: out.contentHtml, ...(lead ? {} : { thumbnailUrl: out.leadImage }) })
          .where(eq(items.id, id));
      }
      return json({
        contentHtml: out.contentHtml,
        leadImage: lead ?? out.leadImage,
        ...(out.rendered ? { rendered: true } : {}),
      } satisfies ContentResponse);
    } catch (e) {
      return json(
        { error: `Extraction failed: ${errMsg(e)}`, contentHtml: null, leadImage: lead },
        { status: 502 },
      );
    }
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
