import { connection } from "next/server";
import { getDb } from "@/db/client";
import { errMsg, errorJson, json } from "@/lib/http";
import {
  READWISE_TOKEN_KEY,
  WEBHOOK_URL_KEY,
  integrationsResponse,
  parseWebhookUrl,
  readIntegrations,
  writeIntegration,
} from "@/lib/integrations";
import type { PutIntegrationsBody } from "@/lib/types";

export async function GET() {
  try {
    await connection();
    const db = await getDb();
    return json(integrationsResponse(await readIntegrations(db)));
  } catch (e) {
    return errorJson(errMsg(e));
  }
}

/** Sets (string) or clears (null or "") each value; omitted keys are left alone. */
export async function PUT(req: Request) {
  try {
    const body = (await req.json().catch(() => null)) as PutIntegrationsBody | null;
    if (!body || typeof body !== "object") return errorJson("Invalid body", 400);
    const { readwise_token: token, webhook_url: url } = body;
    if (token !== undefined && token !== null && typeof token !== "string") return errorJson("Invalid readwise_token", 400);
    if (url !== undefined && url !== null && typeof url !== "string") return errorJson("Invalid webhook_url", 400);

    // Validate everything before writing anything.
    const webhook = url ? parseWebhookUrl(url) : null;
    if (url?.trim() && !webhook) return errorJson("Webhook URL must start with http:// or https://", 400);

    const db = await getDb();
    if (token !== undefined) await writeIntegration(db, READWISE_TOKEN_KEY, token?.trim() || null);
    if (url !== undefined) await writeIntegration(db, WEBHOOK_URL_KEY, webhook);
    return json(integrationsResponse(await readIntegrations(db)));
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
