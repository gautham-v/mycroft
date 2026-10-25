import { getDb } from "@/db/client";
import { errMsg, errorJson, json } from "@/lib/http";
import {
  SendError,
  readIntegrations,
  sendToWebhook,
  testWebhookPayload,
  verifyReadwiseToken,
} from "@/lib/integrations";
import type { SendBody } from "@/lib/types";

/**
 * Settings' "Send a test" for the saved configuration. The webhook gets a sample payload
 * (`test: true`); Readwise only has its token checked, so nothing lands in the library.
 */
export async function POST(req: Request) {
  try {
    const body = (await req.json().catch(() => null)) as SendBody | null;
    const target = body?.target;
    if (target !== "readwise" && target !== "webhook") return errorJson("Unknown target", 400);
    const db = await getDb();
    const cfg = await readIntegrations(db);
    if (target === "readwise") {
      if (!cfg.readwiseToken) return errorJson("Readwise is not set up", 400);
      await verifyReadwiseToken(cfg.readwiseToken);
    } else {
      if (!cfg.webhookUrl) return errorJson("Webhook is not set up", 400);
      await sendToWebhook(cfg.webhookUrl, testWebhookPayload());
    }
    return json({ ok: true });
  } catch (e) {
    if (e instanceof SendError) return errorJson(e.message, e.status);
    return errorJson(errMsg(e));
  }
}
