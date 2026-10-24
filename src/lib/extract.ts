import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";
import sanitizeHtml from "sanitize-html";
import { fetchWithTimeout } from "./http";

const EXTRACT_TIMEOUT_MS = 10_000;

const SANITIZE: sanitizeHtml.IOptions = {
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

export function sanitizeArticle(html: string): string {
  return sanitizeHtml(html, SANITIZE);
}

/** Extract main article from raw HTML. Pure; no network. */
export function extractFromHtml(html: string, pageUrl: string): { contentHtml: string | null; leadImage: string | null } {
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
  const clean = sanitizeArticle(article.content).trim();
  return { contentHtml: clean || null, leadImage: abs(og, base) };
}

export async function extractArticle(url: string): Promise<{ contentHtml: string | null; leadImage: string | null }> {
  const res = await fetchWithTimeout(url, EXTRACT_TIMEOUT_MS, {
    headers: { Accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5" },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const ct = res.headers.get("content-type") ?? "";
  if (ct && !/html|xml/i.test(ct)) throw new Error(`Unsupported content type: ${ct}`);
  const html = await res.text();
  return extractFromHtml(html, res.url || url);
}
