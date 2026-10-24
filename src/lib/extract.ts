import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";
import sanitizeHtml from "sanitize-html";
import { fetchWithTimeout } from "./http";

const EXTRACT_TIMEOUT_MS = 10_000;

const SANITIZE: sanitizeHtml.IOptions = {
  // prettier-ignore
  allowedTags: [
    "p", "br", "hr", "b", "strong", "i", "em", "u", "s", "sub", "sup", "small", "mark",
    "a", "img", "pre", "code", "kbd", "samp",
    "h1", "h2", "h3", "h4", "h5", "h6",
    "ul", "ol", "li", "dl", "dt", "dd",
    "blockquote", "figure", "figcaption", "video", "source", "iframe",
    "table", "thead", "tbody", "tr", "th", "td", "span", "div",
  ],
  allowedAttributes: {
    a: ["href", "title"],
    img: ["src", "srcset", "alt", "title", "width", "height"],
    video: ["src", "controls", "poster", "width", "height"],
    source: ["src", "type"],
    iframe: ["src", "width", "height", "allow", "allowfullscreen", "frameborder"],
    code: ["class"],
    pre: ["class"],
    th: ["colspan", "rowspan"],
    td: ["colspan", "rowspan"],
  },
  allowedSchemes: ["http", "https", "mailto"],
  allowedIframeHostnames: ["www.youtube-nocookie.com"],
  transformTags: {
    a: (tagName, attribs) => ({
      tagName,
      attribs: { ...attribs, target: "_blank", rel: "noopener noreferrer" },
    }),
    img: (tagName, attribs) => ({ tagName, attribs: { ...attribs, loading: "lazy" } }),
  },
};
// allow the attributes injected by transformTags
SANITIZE.allowedAttributes = {
  ...(SANITIZE.allowedAttributes as Record<string, string[]>),
  a: ["href", "title", "target", "rel"],
  img: ["src", "srcset", "alt", "title", "width", "height", "loading"],
};

function abs(u: string | null, base: string): string | null {
  if (!u) return null;
  try {
    return new URL(u, base).toString();
  } catch {
    return null;
  }
}

type Doc = ReturnType<typeof parseHTML>["document"];

function absolutizeDom(root: Doc | Element, base: string) {
  root.querySelectorAll("a[href]").forEach((el) => {
    const v = abs(el.getAttribute("href"), base);
    if (v) el.setAttribute("href", v);
  });
  root.querySelectorAll("img").forEach((el) => {
    // lazy-load patterns
    const lazy = el.getAttribute("data-src") ?? el.getAttribute("data-lazy-src") ?? el.getAttribute("data-original");
    if (lazy && (!el.getAttribute("src") || el.getAttribute("src")!.startsWith("data:"))) el.setAttribute("src", lazy);
    const v = abs(el.getAttribute("src"), base);
    if (v) el.setAttribute("src", v);
    const ss = el.getAttribute("srcset");
    if (ss) {
      el.setAttribute(
        "srcset",
        ss
          .split(",")
          .map((part) => {
            const [u, d] = part.trim().split(/\s+/, 2);
            const a = abs(u, base);
            return a ? [a, d].filter(Boolean).join(" ") : "";
          })
          .filter(Boolean)
          .join(", "),
      );
    }
  });
  root.querySelectorAll("video[src],source[src],iframe[src]").forEach((el) => {
    const v = abs(el.getAttribute("src"), base);
    if (v) el.setAttribute("src", v);
  });
}

const TINY_IMG = 64;
const AUTHOR_HREF = /\/(authors?|author-profile|people|staff|contributors?)\//i;

function isTinyImg(img: Element): boolean {
  const w = Number(img.getAttribute("width"));
  const h = Number(img.getAttribute("height"));
  return w > 0 && h > 0 && w <= TINY_IMG && h <= TINY_IMG;
}

/**
 * Readability keeps inline author cards (avatar + name + one-line bio) that sit inside the
 * article container. Drop short blocks that carry an avatar-sized image or an author link,
 * and any remaining avatar-sized images.
 */
export function stripAuthorCards(html: string): string {
  const { document } = parseHTML(`<div id="__root">${html}</div>`);
  const root = document.getElementById("__root");
  if (!root) return html;
  const blocks = [...root.querySelectorAll("div, section, aside, p, figure")];
  for (const el of blocks) {
    if (!el.isConnected) continue;
    const text = (el.textContent ?? "").trim();
    if (text.length > 400) continue;
    const hasAvatar = [...el.querySelectorAll("img")].some(isTinyImg);
    const hasAuthorLink = [...el.querySelectorAll("a[href]")].some(
      (a) => AUTHOR_HREF.test(a.getAttribute("href") ?? "") || a.getAttribute("rel") === "author",
    );
    if (hasAvatar || hasAuthorLink) el.remove();
  }
  root.querySelectorAll("img").forEach((img) => isTinyImg(img) && img.remove());
  return root.innerHTML;
}

export function sanitizeArticle(html: string): string {
  return sanitizeHtml(html, SANITIZE);
}

export interface ExtractResult {
  contentHtml: string | null;
  leadImage: string | null;
  /** True when contentHtml came from the Jina Reader rendered-page fallback. */
  rendered?: boolean;
}

/** Extract main article from raw HTML. Pure; no network. */
export function extractFromHtml(html: string, pageUrl: string): ExtractResult {
  const { document } = parseHTML(html);
  const base = abs(document.querySelector("base[href]")?.getAttribute("href") ?? null, pageUrl) ?? pageUrl;
  const og =
    document.querySelector('meta[property="og:image"]')?.getAttribute("content") ??
    document.querySelector('meta[name="twitter:image"]')?.getAttribute("content") ??
    null;
  absolutizeDom(document, base);
  // Readability's types expect a DOM Document; linkedom is compatible at runtime.
  const article = new Readability(document as unknown as Document, { charThreshold: 200 }).parse();
  if (!article?.content) return { contentHtml: null, leadImage: abs(og, base) };
  const clean = sanitizeArticle(stripAuthorCards(article.content)).trim();
  return { contentHtml: clean || null, leadImage: abs(og, base) };
}

// The content route has maxDuration = 20s; keep plain fetch + fallback inside this budget.
const TOTAL_BUDGET_MS = 18_000;
const RENDER_TIMEOUT_MS = 12_000;
const MIN_RENDER_MS = 2_000;

async function extractPlain(url: string): Promise<ExtractResult> {
  const res = await fetchWithTimeout(url, EXTRACT_TIMEOUT_MS, {
    headers: { Accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5" },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const ct = res.headers.get("content-type") ?? "";
  if (ct && !/html|xml/i.test(ct)) throw new Error(`Unsupported content type: ${ct}`);
  const html = await res.text();
  return extractFromHtml(html, res.url || url);
}

function firstImage(html: string): string | null {
  return (
    parseHTML(`<!doctype html><html><body>${html}</body></html>`)
      .document.querySelector("img[src]")
      ?.getAttribute("src") ?? null
  );
}

/** Render a JavaScript-only page via Jina Reader (returns the rendered DOM as HTML) and extract from it. */
async function extractRendered(url: string, ms: number): Promise<ExtractResult | null> {
  const headers: Record<string, string> = { Accept: "text/html", "X-Return-Format": "html" };
  const key = process.env.JINA_API_KEY;
  if (key) headers.Authorization = `Bearer ${key}`;
  const res = await fetchWithTimeout(`https://r.jina.ai/${url}`, ms, { headers });
  if (!res.ok) return null;
  const out = extractFromHtml(await res.text(), url);
  return out.contentHtml ? { ...out, rendered: true } : null;
}

export async function extractArticle(url: string): Promise<ExtractResult> {
  const started = Date.now();
  let plain: ExtractResult | null = null;
  let plainError: unknown = null;
  try {
    plain = await extractPlain(url);
    if (plain.contentHtml) return plain;
  } catch (e) {
    plainError = e;
  }

  const ms = Math.min(RENDER_TIMEOUT_MS, TOTAL_BUDGET_MS - (Date.now() - started));
  if (/^https?:\/\//i.test(url) && ms >= MIN_RENDER_MS) {
    try {
      const r = await extractRendered(url, ms);
      if (r?.contentHtml) {
        return { ...r, leadImage: plain?.leadImage ?? r.leadImage ?? firstImage(r.contentHtml) };
      }
    } catch {
      /* fall through to the plain result */
    }
  }

  if (plainError) throw plainError;
  return plain ?? { contentHtml: null, leadImage: null };
}
