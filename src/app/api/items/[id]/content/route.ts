import { connection } from "next/server";
import { eq } from "drizzle-orm";
import { getDb } from "@/db/client";
import { items, sources } from "@/db/schema";
import { cachedContent, contentUpdate } from "@/lib/content-cache";
import { extractArticle } from "@/lib/extract";
import { errMsg, errorJson, json } from "@/lib/http";
import type { ContentResponse } from "@/lib/types";

export const maxDuration = 20;

export async function GET(req: Request, ctx: { params: Promise<{ id: string }> }) {
  await connection();
  try {
    const id = Number((await ctx.params).id);
    if (!Number.isInteger(id)) return errorJson("Invalid id", 400);
    const db = await getDb();
    const [row] = await db
      .select({ item: items, kind: sources.kind, feedUrl: sources.feedUrl })
      .from(items)
      .innerJoin(sources, eq(items.sourceId, sources.id))
      .where(eq(items.id, id));
    if (!row) return errorJson("Not found", 404);
    const lead = row.item.thumbnailUrl;
    if (row.kind === "youtube") return json({ contentHtml: null, leadImage: lead } satisfies ContentResponse);
    // ?refresh=1 re-extracts instead of serving the cached copy (e.g. after an extractor fix).
    const refresh = new URL(req.url).searchParams.get("refresh") === "1";
    if (row.item.contentHtml && !refresh) return json(cachedContent(row.item, lead));
    try {
      const feed = row.kind === "rss" ? { feedUrl: row.feedUrl, guid: row.item.guid } : undefined;
      const out = await extractArticle(row.item.url, feed);
      const update = contentUpdate(out, lead);
      if (update) await db.update(items).set(update).where(eq(items.id, id));
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
