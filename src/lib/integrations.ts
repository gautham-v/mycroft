// "Send to" integrations: Readwise Reader and a generic webhook. Secrets live in the meta table
// (server-side only); the client sees whether each target is configured and a token hint.
import { eq, inArray } from "drizzle-orm";
import type { DB } from "@/db/client";
import { meta } from "@/db/schema";
import { stripHtml } from "@/components/text";
import { errMsg, fetchWithTimeout } from "@/lib/http";
import type { IntegrationsResponse, Item, WebhookPayload } from "@/lib/types";

export const READWISE_TOKEN_KEY = "integration.readwise_token";
export const WEBHOOK_URL_KEY = "integration.webhook_url";

const READWISE_SAVE_URL = "https://readwise.io/api/v3/save/";
/** Answers 204 for a valid token and 401 otherwise; Settings' test uses it so it saves nothing. */
const READWISE_AUTH_URL = "https://readwise.io/api/v2/auth/";
const READWISE_TIMEOUT_MS = 15_000;
const WEBHOOK_TIMEOUT_MS = 10_000;

export interface IntegrationConfig {
  readwiseToken: string | null;
  webhookUrl: string | null;
}

/** A send failure with the HTTP status the route should answer with. */
export class SendError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

export async function readIntegrations(db: DB): Promise<IntegrationConfig> {
  const rows = await db
    .select()
    .from(meta)
    .where(inArray(meta.key, [READWISE_TOKEN_KEY, WEBHOOK_URL_KEY]));
  const get = (k: string) => rows.find((r) => r.key === k)?.value || null;
  return { readwiseToken: get(READWISE_TOKEN_KEY), webhookUrl: get(WEBHOOK_URL_KEY) };
}

/** Wire shape for the client: never the full token. */
export function integrationsResponse(c: IntegrationConfig): IntegrationsResponse {
  return {
    readwise: { configured: !!c.readwiseToken, token_hint: c.readwiseToken ? `…${c.readwiseToken.slice(-4)}` : null },
    webhook: { configured: !!c.webhookUrl, url: c.webhookUrl },
  };
}

/** Sets a meta value, or deletes the row for null/empty. */
export async function writeIntegration(db: DB, key: string, value: string | null): Promise<void> {
  if (!value) {
    await db.delete(meta).where(eq(meta.key, key));
    return;
  }
  await db.insert(meta).values({ key, value }).onConflictDoUpdate({ target: meta.key, set: { value } });
}

/** Normalised http(s) URL, or null when the input is not one. */
export function parseWebhookUrl(raw: string): string | null {
  try {
    const u = new URL(raw.trim());
    return u.protocol === "http:" || u.protocol === "https:" ? u.toString() : null;
  } catch {
    return null;
  }
}

/** Upstream error text: JSON `detail` (Readwise/DRF style), flattened field errors, or a short body. */
async function upstreamError(res: Response, label: string): Promise<string> {
  const text = (await res.text().catch(() => "")).trim();
  let detail = "";
  try {
    const body = JSON.parse(text) as unknown;
    if (body && typeof body === "object") {
      const o = body as Record<string, unknown>;
      detail =
        typeof o.detail === "string"
          ? o.detail
          : typeof o.error === "string"
            ? o.error
            : Object.entries(o)
                .map(([k, v]) => `${k}: ${Array.isArray(v) ? v.join(" ") : String(v)}`)
                .join("; ");
    }
  } catch {
    // Not JSON: use the body unless it is an HTML error page.
    detail = text.startsWith("<") ? "" : text;
  }
  detail = detail.slice(0, 200);
  return `${label} returned ${res.status}${detail ? `: ${detail}` : ""}`;
}

/** Wraps a network failure (timeout, DNS, refused) as a 504/502 SendError. */
function networkError(e: unknown, label: string): SendError {
  let msg = errMsg(e);
  // undici reports every connection failure as "fetch failed"; the cause carries the reason.
  const code = (e as { cause?: { code?: string } }).cause?.code;
  if (msg === "fetch failed" && code) msg = `could not connect (${code})`;
  return new SendError(`${label}: ${msg}`, msg === "Timed out" ? 504 : 502);
}

export async function sendToReadwise(token: string, item: Item): Promise<void> {
  const summary = stripHtml(item.summary).slice(0, 1000);
  let res: Response;
  try {
    res = await fetchWithTimeout(READWISE_SAVE_URL, READWISE_TIMEOUT_MS, {
      method: "POST",
      headers: { Authorization: `Token ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        url: item.url,
        title: item.title,
        ...(item.author ? { author: item.author } : {}),
        published_date: item.published_at,
        ...(summary ? { summary } : {}),
        saved_using: "openfeed",
      }),
    });
  } catch (e) {
    throw networkError(e, "Readwise");
  }
  // 201 = saved, 200 = already in the library.
  if (res.status === 200 || res.status === 201) return;
  throw new SendError(await upstreamError(res, "Readwise"), 502);
}

export async function verifyReadwiseToken(token: string): Promise<void> {
  let res: Response;
  try {
    res = await fetchWithTimeout(READWISE_AUTH_URL, READWISE_TIMEOUT_MS, {
      headers: { Authorization: `Token ${token}` },
    });
  } catch (e) {
    throw networkError(e, "Readwise");
  }
  if (res.ok) return;
  if (res.status === 401) throw new SendError("Readwise rejected the token", 502);
  throw new SendError(await upstreamError(res, "Readwise"), 502);
}

export function webhookPayload(item: Item): WebhookPayload {
  return {
    id: item.id,
    url: item.url,
    title: item.title,
    author: item.author,
    published_at: item.published_at,
    summary: stripHtml(item.summary) || null,
    source: { title: item.source.title, host: item.source.host },
  };
}

/** Sample item for Settings' "Send a test". */
export function testWebhookPayload(): WebhookPayload {
  return {
    id: 0,
    url: "https://example.com/openfeed-test",
    title: "Test from Openfeed",
    author: null,
    published_at: new Date().toISOString(),
    summary: "A sample payload sent from Settings → Integrations.",
    source: { title: "Openfeed", host: "example.com" },
    test: true,
  };
}

export async function sendToWebhook(url: string, payload: WebhookPayload): Promise<void> {
  let res: Response;
  try {
    res = await fetchWithTimeout(url, WEBHOOK_TIMEOUT_MS, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch (e) {
    throw networkError(e, "Webhook");
  }
  if (res.ok) return;
  throw new SendError(await upstreamError(res, "Webhook"), 502);
}
