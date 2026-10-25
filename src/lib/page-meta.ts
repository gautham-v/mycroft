import { parseHTML } from "linkedom";
import { BROWSER_HEADERS, fetchWithTimeout } from "./http";

// Page metadata shared by scraped page sources (scrape.ts) and the refresh-time thumbnail
// backfill: Open Graph / Twitter meta tags and JSON-LD. Pure helpers first, network last.

/** Stop reading a page after this much if </head> hasn't come yet. */
const MAX_HEAD_BYTES = 200_000;
export const THUMB_TIMEOUT_MS = 6_000;
const HTML_ACCEPT = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5";

export type Doc = ReturnType<typeof parseHTML>["document"];
type Ld = Record<string, unknown>;

/** Lookup over a page's <meta> tags by property / name / itemprop (case-insensitive, first wins). */
export function metaReader(document: Doc) {
  const map = new Map<string, string>();
  for (const m of document.querySelectorAll("meta[content]")) {
    const key = (m.getAttribute("property") ?? m.getAttribute("name") ?? m.getAttribute("itemprop") ?? "").toLowerCase();
    const v = (m.getAttribute("content") ?? "").trim();
    if (key && v && !map.has(key)) map.set(key, v);
  }
  return (...keys: string[]) => {
    for (const k of keys) {
      const v = map.get(k.toLowerCase());
      if (v) return v;
    }
    return null;
  };
}

const ARTICLE_TYPES = /^(Article|NewsArticle|BlogPosting|TechArticle|Report|ScholarlyArticle|AnalysisNewsArticle|PressRelease)$/;

/** The page's JSON-LD article node (looks inside arrays and @graph). */
export function ldArticle(document: Doc): Ld | null {
  const nodes: Ld[] = [];
  const walk = (v: unknown) => {
    if (Array.isArray(v)) v.forEach(walk);
    else if (v && typeof v === "object") {
      const o = v as Ld;
      nodes.push(o);
      if (o["@graph"]) walk(o["@graph"]);
    }
  };
  for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
    try {
      walk(JSON.parse(s.textContent ?? ""));
    } catch {}
  }
  return (
    nodes.find((n) => {
      const t = n["@type"];
      return (Array.isArray(t) ? t : [t]).some((x) => typeof x === "string" && ARTICLE_TYPES.test(x));
    }) ?? null
  );
}

export const str = (v: unknown): string | null => (typeof v === "string" && v.trim() ? v.trim() : null);

export function ldImage(v: unknown): string | null {
  if (Array.isArray(v)) return ldImage(v[0]);
  if (v && typeof v === "object") return str((v as Ld).url);
  return str(v);
}

export function absUrl(u: string | null, base: string): string | null {
  if (!u) return null;
  try {
    return new URL(u, base).toString();
  } catch {
    return null;
  }
}

const IMAGE_KEYS = ["og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src"];

/** Absolute http(s) URL of the page's share image: og:image, twitter:image, then JSON-LD image. */
export function pageImage(meta: ReturnType<typeof metaReader>, ld: Ld | null, pageUrl: string): string | null {
  const u = absUrl(meta(...IMAGE_KEYS) ?? ldImage(ld?.image), pageUrl);
  return u && /^https?:\/\//i.test(u) ? u : null;
}

/** Share image from page HTML (a full page or just its <head>). Pure; no network. */
export function imageFromHtml(html: string, pageUrl: string): string | null {
  const { document } = parseHTML(html);
  return pageImage(metaReader(document), ldArticle(document), pageUrl);
}

/** Share image from a flat meta map, as Jina Reader's JSON `metadata` returns it. */
export function imageFromMetaMap(map: Record<string, unknown>, pageUrl: string): string | null {
  const lower = new Map(Object.entries(map).map(([k, v]) => [k.toLowerCase(), str(v)]));
  const meta = (...keys: string[]) => keys.map((k) => lower.get(k)).find((v) => !!v) ?? null;
  return pageImage(meta, null, pageUrl);
}

/** Read a page only up to </head> (or `maxBytes`), cancelling the rest of the download. */
export async function readHead(res: Response, deadline: number, maxBytes = MAX_HEAD_BYTES): Promise<string> {
  if (!res.body) return "";
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let text = "";
  let bytes = 0;
  // fetchWithTimeout's timer only covers the headers; this one covers the body.
  const timer = setTimeout(() => void reader.cancel().catch(() => {}), Math.max(0, deadline - Date.now()));
  try {
    while (bytes < maxBytes) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      const from = Math.max(0, text.length - 8);
      text += dec.decode(value, { stream: true });
      const end = text.slice(from).search(/<\/head\s*>/i);
      if (end >= 0) return text.slice(0, from + end);
    }
    return text;
  } finally {
    clearTimeout(timer);
    void reader.cancel().catch(() => {});
  }
}

export interface PageImageResult {
  image: string | null;
  /** False when the miss looks temporary (rate limited, 5xx): try again on a later refresh. */
  final: boolean;
  /** Which path produced the answer, for logs and checks. */
  via: "page" | "jina" | "none";
}

const transient = (status: number) => status === 429 || status >= 500;

/**
 * Jina Reader's JSON output carries the page's meta tags as `metadata`; targeting <head> keeps the
 * response to a few KB and ~100 tokens. Used for pages that refuse server fetches (Cloudflare 403).
 */
async function jinaImage(url: string, deadline: number): Promise<PageImageResult> {
  const headers: Record<string, string> = {
    Accept: "application/json",
    "X-Target-Selector": "head",
    "X-Retain-Images": "none",
  };
  const key = process.env.JINA_API_KEY;
  if (key) headers.Authorization = `Bearer ${key}`;
  const res = await fetchWithTimeout(`https://r.jina.ai/${url}`, Math.max(1, deadline - Date.now()), { headers });
  if (!res.ok) return { image: null, final: !transient(res.status), via: "none" };
  const body = (await res.json()) as { data?: { url?: string; metadata?: Record<string, unknown> } };
  const meta = body.data?.metadata;
  const image = meta ? imageFromMetaMap(meta, str(body.data?.url) ?? url) : null;
  return { image, final: true, via: image ? "jina" : "none" };
}

/**
 * The share image (og:image and friends) of an article page, reading only its <head>.
 * 401/403 (bot walls like openai.com's Cloudflare challenge) fall back to Jina Reader's metadata.
 * Never throws: a timeout or network error is a final miss, so slow sites aren't retried forever.
 */
export async function fetchPageImage(url: string, timeoutMs = THUMB_TIMEOUT_MS): Promise<PageImageResult> {
  const deadline = Date.now() + timeoutMs;
  try {
    const res = await fetchWithTimeout(url, timeoutMs, { headers: { ...BROWSER_HEADERS, Accept: HTML_ACCEPT } });
    if (res.status === 401 || res.status === 403) {
      void res.body?.cancel().catch(() => {});
      return await jinaImage(url, deadline);
    }
    if (!res.ok) {
      void res.body?.cancel().catch(() => {});
      return { image: null, final: !transient(res.status), via: "none" };
    }
    const ct = res.headers.get("content-type") ?? "";
    if (ct && !/html|xml/i.test(ct)) {
      void res.body?.cancel().catch(() => {});
      return { image: null, final: true, via: "none" };
    }
    const image = imageFromHtml(await readHead(res, deadline), res.url || url);
    return { image, final: true, via: image ? "page" : "none" };
  } catch {
    return { image: null, final: true, via: "none" };
  }
}

/**
 * Fetch share images for `targets` with bounded concurrency, stopping new fetches once `budgetMs`
 * is spent (unstarted targets are left out of the result, so they count as untried).
 */
export async function fetchPageImages<T extends { url: string }>(
  targets: T[],
  opts: { concurrency?: number; timeoutMs?: number; budgetMs?: number } = {},
): Promise<Array<T & PageImageResult>> {
  const { concurrency = 4, timeoutMs = THUMB_TIMEOUT_MS, budgetMs = 20_000 } = opts;
  const stopAt = Date.now() + budgetMs;
  const out: Array<T & PageImageResult> = [];
  let next = 0;
  const worker = async () => {
    while (next < targets.length && Date.now() < stopAt) {
      const t = targets[next++];
      out.push({ ...t, ...(await fetchPageImage(t.url, timeoutMs)) });
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, targets.length) }, worker));
  return out;
}
