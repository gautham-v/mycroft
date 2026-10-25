import { eq } from "drizzle-orm";
import { getDb } from "@/db/client";
import { items, sources } from "@/db/schema";
import { errMsg, errorJson, json } from "@/lib/http";
import {
  SendError,
  readIntegrations,
  sendToReadwise,
  sendToWebhook,
  webhookPayload,
} from "@/lib/integrations";
import { toItem } from "@/lib/queries";
import type { SendBody } from "@/lib/types";

/** Sends an item to Readwise Reader or the configured webhook. */
export async function POST(req: Request, ctx: { params: Promise<{ id: string }> }) {
  try {
    const id = Number((await ctx.params).id);
    if (!Number.isInteger(id)) return errorJson("Invalid id", 400);
    const body = (await req.json().catch(() => null)) as SendBody | null;
    const target = body?.target;
    if (target !== "readwise" && target !== "webhook") return errorJson("Unknown target", 400);

    const db = await getDb();
    const cfg = await readIntegrations(db);
    if (target === "readwise" && !cfg.readwiseToken) return errorJson("Readwise is not set up", 400);
    if (target === "webhook" && !cfg.webhookUrl) return errorJson("Webhook is not set up", 400);

    const [row] = await db.select().from(items).where(eq(items.id, id));
    if (!row) return errorJson("Not found", 404);
    const [src] = await db.select().from(sources).where(eq(sources.id, row.sourceId));
    const item = toItem(row, src);

    if (target === "readwise") await sendToReadwise(cfg.readwiseToken!, item);
    else await sendToWebhook(cfg.webhookUrl!, webhookPayload(item));
    return json({ ok: true });
  } catch (e) {
    if (e instanceof SendError) return errorJson(e.message, e.status);
    return errorJson(errMsg(e));
  }
}
