import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";
import sanitizeHtml from "sanitize-html";
import { BROWSER_HEADERS, fetchWithTimeout } from "./http";
import { findFeedItemHtml } from "./parse";

const EXTRACT_TIMEOUT_MS = 10_000;

// Inline SVG (diagrams, charts): shapes and presentation attributes only. No <use>, <image>,
// <foreignObject>, href, style or event handlers. The parser may hand over camelCase names
// (linearGradient, viewBox) or lowercased ones, so both spellings are listed; the browser's HTML
// parser restores SVG casing either way.
const withLower = (names: string[]) => [...new Set(names.flatMap((n) => [n, n.toLowerCase()]))];
// prettier-ignore
const SVG_TAGS = withLower([
  "svg", "g", "path", "circle", "ellipse", "line", "polyline", "polygon", "rect", "text", "tspan",
  "defs", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "marker",
]);
// prettier-ignore
const SVG_ATTRS = withLower([
  "id", "viewBox", "width", "height", "preserveAspectRatio", "role", "aria-label", "aria-hidden",
  "d", "cx", "cy", "r", "rx", "ry", "x", "y", "x1", "y1", "x2", "y2", "dx", "dy", "points", "offset",
  "transform", "opacity", "fill", "fill-opacity", "fill-rule", "clip-rule", "clip-path", "mask",
  "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-dasharray",
  "stroke-dashoffset", "stroke-miterlimit", "vector-effect", "stop-color", "stop-opacity",
  "gradientUnits", "gradientTransform", "spreadMethod", "clipPathUnits", "maskUnits",
  "marker-start", "marker-mid", "marker-end", "markerWidth", "markerHeight", "markerUnits", "refX", "refY", "orient",
  "text-anchor", "dominant-baseline", "alignment-baseline", "font-size", "font-family", "font-weight", "font-style",
  "letter-spacing", "textLength",
]);
/** Paint/clip references may only point inside the document: url(#id), never an external resource. */
const svgTransform: sanitizeHtml.Transformer = (tagName, attribs) => ({
  tagName,
  attribs: Object.fromEntries(
    Object.entries(attribs).filter(([, v]) => !/url\(\s*['"]?\s*(?!#)/i.test(v)),
  ),
});

const SANITIZE: sanitizeHtml.IOptions = {
  // prettier-ignore
  allowedTags: [
    "p", "br", "hr", "b", "strong", "i", "em", "u", "s", "sub", "sup", "small", "mark",
    "a", "img", "pre", "code", "kbd", "samp",
    "h1", "h2", "h3", "h4", "h5", "h6",
    "ul", "ol", "li", "dl", "dt", "dd",
    "blockquote", "figure", "figcaption", "picture", "video", "source", "iframe",
    "table", "thead", "tbody", "tr", "th", "td", "span", "div",
    ...SVG_TAGS,
  ],
  allowedAttributes: {
    a: ["href", "title"],
    img: ["src", "srcset", "sizes", "alt", "title", "width", "height"],
    video: ["src", "controls", "poster", "width", "height", "autoplay", "loop", "muted", "playsinline", "preload"],
    // <picture> sources: media queries pick the light/dark or mobile/desktop variant.
    source: ["src", "srcset", "sizes", "media", "type", "width", "height"],
    iframe: ["src", "width", "height", "allow", "allowfullscreen", "frameborder"],
    code: ["class"],
    pre: ["class"],
    th: ["colspan", "rowspan"],
    td: ["colspan", "rowspan"],
    ...Object.fromEntries(SVG_TAGS.map((t) => [t, SVG_ATTRS])),
  },
  selfClosing: [...sanitizeHtml.defaults.selfClosing, "source"],
  allowedSchemes: ["http", "https", "mailto"],
  allowedIframeHostnames: ["www.youtube-nocookie.com"],
  transformTags: {
    a: (tagName, attribs) => ({
      tagName,
      attribs: { ...attribs, target: "_blank", rel: "noopener noreferrer" },
    }),
    img: (tagName, attribs) => ({ tagName, attribs: { ...attribs, loading: "lazy" } }),
    // Looping figure animations often ship without controls and with preload=none: show the first
    // frame and give the reader controls.
    video: (tagName, attribs) => {
      const { poster, ...rest } = attribs;
      const keepPoster = poster && !/fallback|placeholder/i.test(poster);
      return { tagName, attribs: { ...rest, ...(keepPoster ? { poster } : {}), controls: "", preload: "metadata" } };
    },
    ...Object.fromEntries(SVG_TAGS.map((t) => [t, svgTransform])),
  },
};
// allow the attributes injected by transformTags
SANITIZE.allowedAttributes = {
  ...(SANITIZE.allowedAttributes as Record<string, string[]>),
  a: ["href", "title", "target", "rel"],
  img: ["src", "srcset", "sizes", "alt", "title", "width", "height", "loading"],
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

interface SrcsetCandidate {
  url: string;
  descriptor: string;
}

/** Parse a srcset per the HTML spec's outline: URLs may contain commas (CDN transforms like w_640,c_fill). */
export function parseSrcset(srcset: string): SrcsetCandidate[] {
  const out: SrcsetCandidate[] = [];
  let i = 0;
  while (i < srcset.length) {
    while (i < srcset.length && /[\s,]/.test(srcset[i])) i++;
    if (i >= srcset.length) break;
    let j = i;
    while (j < srcset.length && !/\s/.test(srcset[j])) j++;
    let url = srcset.slice(i, j);
    let descriptor = "";
    if (url.endsWith(",")) {
      url = url.replace(/,+$/, "");
      i = j;
    } else {
      const k = srcset.indexOf(",", j);
      const end = k < 0 ? srcset.length : k;
      descriptor = srcset.slice(j, end).trim();
      i = end + 1;
    }
    if (url) out.push({ url, descriptor });
  }
  return out;
}

function absSrcset(srcset: string, base: string): string {
  return parseSrcset(srcset)
    .map(({ url, descriptor }) => {
      const a = abs(url, base);
      return a ? [a, descriptor].filter(Boolean).join(" ") : "";
    })
    .filter(Boolean)
    .join(", ");
}

/** Largest srcset candidate by w/x descriptor (a bare URL counts as 1x). */
function largestCandidate(srcset: string): string | null {
  let best: { url: string; n: number } | null = null;
  for (const { url, descriptor } of parseSrcset(srcset)) {
    const n = Number.parseFloat(descriptor) || 1;
    if (!best || n > best.n) best = { url, n };
  }
  return best?.url ?? null;
}

const LAZY_SRC = ["data-src", "data-lazy-src", "data-original", "data-lazy", "data-url"];
const LAZY_SRCSET = ["data-srcset", "data-lazy-srcset"];

const firstAttr = (el: Element, names: string[]) =>
  names.map((n) => el.getAttribute(n)).find((v): v is string => !!v && !v.startsWith("data:")) ?? null;
const isPlaceholderSrc = (v: string | null) => !v || v.startsWith("data:") || /^about:blank$/i.test(v);

/**
 * Absolutize links and media URLs, and promote lazy-load attributes (data-src, data-srcset) to the
 * real ones so images whose src is a placeholder (or missing, srcset-only) still load.
 */
function absolutizeDom(root: Doc | Element, base: string) {
  root.querySelectorAll("a[href]").forEach((el) => {
    const v = abs(el.getAttribute("href"), base);
    if (v) el.setAttribute("href", v);
  });
  root.querySelectorAll("img, source").forEach((el) => {
    const lazySet = firstAttr(el, LAZY_SRCSET);
    if (lazySet && !el.getAttribute("srcset")) el.setAttribute("srcset", lazySet);
    const ss = el.getAttribute("srcset");
    if (ss) el.setAttribute("srcset", absSrcset(ss, base));
    const lazy = firstAttr(el, LAZY_SRC);
    if (lazy && isPlaceholderSrc(el.getAttribute("src"))) el.setAttribute("src", lazy);
    // srcset-only images: give them a src so anything that reads src (sanitizer, hero pick) sees one.
    if (el.tagName === "IMG" && isPlaceholderSrc(el.getAttribute("src"))) {
      const fromSet = el.getAttribute("srcset") ? largestCandidate(el.getAttribute("srcset")!) : null;
      if (fromSet) el.setAttribute("src", fromSet);
    }
    const v = abs(el.getAttribute("src"), base);
    if (v) el.setAttribute("src", v);
  });
  root.querySelectorAll("video[src],iframe[src]").forEach((el) => {
    const v = abs(el.getAttribute("src"), base);
    if (v) el.setAttribute("src", v);
  });
  root.querySelectorAll("video[poster]").forEach((el) => {
    const v = abs(el.getAttribute("poster"), base);
    if (v) el.setAttribute("poster", v);
  });
}

// Readability scores class names: a match for /hidden|scroll|media|.../ counts against an element and
// deletes a non-prose div outright, before its figure exception applies. Image wrappers trip this
// constantly: `overflow-hidden` / `scroll-mt-[...]` on utility-CSS sites, `media__container` on
// others. So before parsing, drop (1) utility tokens that match those words anywhere, and
// (2) layout words (hidden, scroll, media, meta) inside figures and text-free media wrappers.
// Semantic junk names elsewhere (`sidebar`, `related-posts`, `ad-banner`) are kept.
const READABILITY_NEGATIVE = /hidden|scroll|media|meta|share|banner|comment|footer|related|sidebar|widget|promo|tags/i;
const UTILITY_CLASS = /[:[\]()@!/]|^-?(?:overflow|overscroll|scroll|snap|object|line-clamp|text|bg|aspect)-/;
const LAYOUT_NEGATIVE = /hidden|scroll|media|meta/i;
const MEDIA = "img, picture, video, svg";

function dropClassTokens(el: Element, drop: (token: string) => boolean) {
  const tokens = (el.getAttribute("class") ?? "").split(/\s+/).filter(Boolean);
  const kept = tokens.filter((t) => !drop(t));
  if (kept.length !== tokens.length) el.setAttribute("class", kept.join(" "));
}

function neutralizeMediaClasses(root: Doc | Element) {
  root.querySelectorAll("[class]").forEach((el) =>
    dropClassTokens(el, (t) => READABILITY_NEGATIVE.test(t) && UTILITY_CLASS.test(t)),
  );
  const inFigure = (el: Element) => el.tagName === "FIGURE" || !!el.closest("figure");
  const mediaWrapper = (el: Element) => !!el.querySelector(MEDIA) && !(el.textContent ?? "").trim();
  root.querySelectorAll("[class]").forEach((el) => {
    // A bare `hidden` really is hidden (e.g. the desktop copy of a responsive pair); keep it.
    if (inFigure(el) || mediaWrapper(el)) dropClassTokens(el, (t) => t !== "hidden" && LAYOUT_NEGATIVE.test(t));
  });
}

const DARK_TOKEN = /^(?!no[-_]|has[-_])(?:[\w-]*[-_])?dark(?:[-_]?mode)?(?:[-_](?:alt|alternative|only|variant|version|image|img))?$/i;

/**
 * Sites that ship a light and a dark copy of a figure side by side and toggle them with CSS
 * (`light-mode` / `dark-mode-alternative`, or Tailwind `dark:hidden` / `hidden dark:block`) would
 * show both here. Keep the light copy; drop the dark one when it has a sibling alternative.
 */
function dropDarkVariants(root: Doc | Element) {
  const isDark = (el: Element) => {
    const tokens = (el.getAttribute("class") ?? "").split(/\s+/);
    if (tokens.some((t) => DARK_TOKEN.test(t))) return true;
    return tokens.includes("hidden") && tokens.some((t) => /^dark:(?!hidden)/.test(t));
  };
  for (const el of [...root.querySelectorAll("img, picture, video")]) {
    if (!el.isConnected || !isDark(el)) continue;
    const siblings = [...(el.parentElement?.children ?? [])].filter((s) => s !== el && s.matches("img, picture, video"));
    if (siblings.some((s) => !isDark(s))) el.remove();
  }
}

const PLACEHOLDER = "https://openfeed.invalid/media/";

/**
 * Readability only understands <img>: a wrapper div holding just a <video> or an inline <svg> chart
 * scores as "no useful content" and is deleted. Stand each one in as a placeholder <img> while
 * Readability runs, then put the originals back with restoreMedia().
 */
function protectMedia(root: Doc | Element): string[] {
  const saved: string[] = [];
  const doc = root.ownerDocument ?? (root as Doc);
  for (const el of [...root.querySelectorAll("video, audio, svg")]) {
    if (!el.isConnected || el.parentElement?.closest("svg, video, audio")) continue;
    if (el.tagName.toLowerCase() === "svg" && isIconSvg(el)) continue;
    const img = doc.createElement("img");
    img.setAttribute("src", `${PLACEHOLDER}${saved.length}`);
    img.setAttribute("alt", el.getAttribute("aria-label") ?? "");
    saved.push(el.outerHTML);
    el.replaceWith(img);
  }
  return saved;
}

function restoreMedia(html: string, saved: string[]): string {
  if (!saved.length) return html;
  const re = new RegExp(`<img[^>]*?src="${PLACEHOLDER.replace(/[.\/]/g, "\\$&")}(\\d+)"[^>]*>`, "g");
  return html.replace(re, (_, i: string) => saved[Number(i)] ?? "");
}

const FIGURE_MEDIA = "img, picture, svg, video, audio, iframe, canvas, object, embed, table, pre, math, noscript";

/**
 * Figures whose graphic is drawn client-side (charts rendered by JavaScript into an empty div)
 * arrive as a caption with nothing above it. Say so and link to the figure on the original page,
 * rather than showing a caption for a missing image.
 */
function markClientRenderedFigures(root: Doc | Element, pageUrl: string) {
  root.querySelectorAll("figure").forEach((fig) => {
    const caption = fig.querySelector("figcaption");
    if (!caption || fig.querySelector(FIGURE_MEDIA)) return;
    const body = (fig.textContent ?? "").replace((caption.textContent ?? ""), "").trim();
    if (body) return;
    const id = fig.getAttribute("id") || fig.querySelector("[id]")?.getAttribute("id");
    const href = id ? `${pageUrl.split("#")[0]}#${encodeURIComponent(id)}` : pageUrl;
    const doc = fig.ownerDocument;
    const note = doc.createElement("p");
    const em = doc.createElement("em");
    const a = doc.createElement("a");
    a.setAttribute("href", href);
    a.textContent = "original article";
    em.append("Interactive figure not shown here. View it in the ", a, ".");
    note.append(em);
    caption.before(note);
  });
}

const TINY_IMG = 64;
const AUTHOR_HREF = /\/(authors?|author-profile|people|staff|contributors?)\//i;

const AVATAR_SRC = /gravatar\.com|\/avatars?\/|[?&]s=(?:[1-9]\d?|1[0-2]\d)(?:&|$)/i;
const AVATAR_CLASS = /\b(avatar|author)/i;
const GENERIC_LEAD = /logo|favicon|\bicon|avatar|gravatar|placeholder|default[-_]?(?:og|share|social)/i;

function isTinyImg(img: Element): boolean {
  const w = Number(img.getAttribute("width"));
  const h = Number(img.getAttribute("height"));
  if (w > 0 && h > 0 && w <= TINY_IMG && h <= TINY_IMG) return true;
  return AVATAR_SRC.test(img.getAttribute("src") ?? "") || AVATAR_CLASS.test(img.getAttribute("class") ?? "");
}

/**
 * Inline SVG icons and decoration (copy buttons, arrows, logos): aria-hidden, small declared or
 * viewBox size, or no size at all.
 */
function isIconSvg(svg: Element): boolean {
  if (svg.parentElement?.closest("svg")) return false;
  if (svg.getAttribute("aria-hidden") === "true") return true;
  const w = Number.parseFloat(svg.getAttribute("width") ?? "");
  const h = Number.parseFloat(svg.getAttribute("height") ?? "");
  if (w > 0 && h > 0) return w <= TINY_IMG && h <= TINY_IMG;
  const vb = (svg.getAttribute("viewBox") ?? svg.getAttribute("viewbox") ?? "").trim().split(/[\s,]+/).map(Number);
  if (vb.length === 4 && vb[2] > 0 && vb[3] > 0) return vb[2] <= TINY_IMG && vb[3] <= TINY_IMG;
  return true;
}

/** Site logos and avatars make poor heroes; prefer nothing over those. */
function usableLead(u: string | null): string | null {
  return u && !GENERIC_LEAD.test(u) ? u : null;
}

/**
 * Readability keeps inline author cards (avatar + name + one-line bio) that sit inside the
 * article container, and link-only navigation tables on table-layout sites. Drop both,
 * plus any remaining avatar-sized images.
 */
export function cleanArticle(html: string): string {
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
  root.querySelectorAll("svg").forEach((svg) => isIconSvg(svg) && svg.remove());
  // Navigation tables (old-school sites): mostly links, little prose.
  for (const table of [...root.querySelectorAll("table")]) {
    if (!table.isConnected) continue;
    const text = (table.textContent ?? "").replace(/\s+/g, " ").trim();
    const links = [...table.querySelectorAll("a[href]")];
    const linkText = links.reduce((n, a) => n + (a.textContent ?? "").trim().length, 0);
    if (links.length >= 4 && text.length > 0 && linkText / text.length > 0.6) table.remove();
  }
  // Section labels left with nothing under them (their section was a stripped table or card):
  // real headings, or short bold "Label:" lines on table-layout sites.
  const isLabel = (el: Element) =>
    /^H[1-6]$/.test(el.tagName) ||
    (/^(B|STRONG|P)$/.test(el.tagName) && /^[^.]{1,40}:$/.test((el.textContent ?? "").trim()));
  for (const h of [...root.querySelectorAll("h1, h2, h3, h4, h5, h6, b, strong, p")]) {
    if (!h.isConnected || !isLabel(h)) continue;
    const trailing: Element[] = [];
    let next = h.nextElementSibling;
    while (next && (/^(HR|BR)$/.test(next.tagName) || !(next.textContent ?? "").trim())) {
      trailing.push(next);
      next = next.nextElementSibling;
    }
    if (!next || isLabel(next)) {
      trailing.forEach((t) => t.remove());
      h.remove();
    }
  }
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
  dropDarkVariants(document);
  markClientRenderedFigures(document, pageUrl);
  const media = protectMedia(document);
  neutralizeMediaClasses(document);
  // Readability's types expect a DOM Document; linkedom is compatible at runtime.
  const article = new Readability(document as unknown as Document, { charThreshold: 200 }).parse();
  if (!article?.content) return { contentHtml: null, leadImage: usableLead(abs(og, base)) };
  const clean = sanitizeArticle(cleanArticle(restoreMedia(article.content, media))).trim();
  return { contentHtml: clean || null, leadImage: usableLead(abs(og, base)) ?? firstImage(clean) };
}

/**
 * Article HTML that came from the feed itself (content:encoded). No Readability: the feed already
 * holds just the article. Returns null when it is only a teaser.
 */
export function extractFromFeedHtml(html: string, pageUrl: string): ExtractResult {
  const { document } = parseHTML(`<!doctype html><html><body><div id="__root">${html}</div></body></html>`);
  const root = document.getElementById("__root");
  if (!root) return { contentHtml: null, leadImage: null };
  absolutizeDom(root, pageUrl);
  markClientRenderedFigures(root, pageUrl);
  const clean = sanitizeArticle(cleanArticle(root.innerHTML)).trim();
  const text = clean.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
  if (text.length < MIN_FEED_TEXT) return { contentHtml: null, leadImage: null };
  return { contentHtml: clean, leadImage: firstImage(clean) };
}

/** Feed HTML shorter than this is a summary, not the article. */
const MIN_FEED_TEXT = 500;

// The content route has maxDuration = 20s; keep plain fetch + fallback inside this budget.
const TOTAL_BUDGET_MS = 18_000;
const RENDER_TIMEOUT_MS = 12_000;
const MIN_RENDER_MS = 2_000;
const FEED_TIMEOUT_MS = 4_000;

/** Where the item came from, so a page that can't be fetched can fall back to the feed's own HTML. */
export interface FeedRef {
  feedUrl: string;
  guid: string;
}

async function extractFromFeed(url: string, feed: FeedRef, ms: number): Promise<ExtractResult | null> {
  const res = await fetchWithTimeout(feed.feedUrl, ms, {
    headers: { Accept: "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.5" },
  });
  if (!res.ok) return null;
  const html = await findFeedItemHtml(await res.text(), { guid: feed.guid, url });
  if (!html) return null;
  const out = extractFromFeedHtml(html, url);
  return out.contentHtml ? out : null;
}

async function extractPlain(url: string): Promise<ExtractResult> {
  let res = await fetchWithTimeout(url, EXTRACT_TIMEOUT_MS, {
    headers: { Accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5" },
  });
  // Some sites refuse bot User-Agents; retry once as a browser. Skip Cloudflare's JavaScript
  // challenge, which no header change passes (the Jina fallback handles those).
  if ((res.status === 401 || res.status === 403) && res.headers.get("cf-mitigated") !== "challenge") {
    res = await fetchWithTimeout(url, EXTRACT_TIMEOUT_MS, { headers: BROWSER_HEADERS });
  }
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const ct = res.headers.get("content-type") ?? "";
  if (ct && !/html|xml/i.test(ct)) throw new Error(`Unsupported content type: ${ct}`);
  const html = await res.text();
  return extractFromHtml(html, res.url || url);
}

/** First content image that is big enough to be a hero (declared width ≥ 400, or undeclared). */
function firstImage(html: string): string | null {
  const imgs = [...parseHTML(`<!doctype html><html><body>${html}</body></html>`).document.querySelectorAll("img[src]")];
  for (const img of imgs) {
    const w = Number(img.getAttribute("width"));
    const src = img.getAttribute("src") ?? "";
    if (isTinyImg(img) || (w > 0 && w < 400) || GENERIC_LEAD.test(src)) continue;
    return src;
  }
  return null;
}

/** Render a JavaScript-only page via Jina Reader (returns the rendered DOM as HTML) and extract from it. */
async function extractRendered(url: string, ms: number): Promise<ExtractResult | null> {
  const headers: Record<string, string> = { Accept: "text/html", "X-Return-Format": "html" };
  const key = process.env.JINA_API_KEY;
  if (key) headers.Authorization = `Bearer ${key}`;
  const res = await fetchWithTimeout(`https://r.jina.ai/${url}`, ms, { headers });
  if (!res.ok) return null;
  const out = extractFromHtml(await res.text(), url);
  if (!out.contentHtml || isLoginWall(out.contentHtml)) return null;
  return { ...out, rendered: true };
}

const LOGIN_WALL = /\b(log ?in|sign ?in|sign ?up)\b.{0,40}\b(sign ?up|continue|to (?:see|view|read))/i;

/** Rendered pages behind an auth wall come back as a short page about logging in. */
function isLoginWall(html: string): boolean {
  const text = html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");
  return text.length < 2500 && LOGIN_WALL.test(text);
}

const TWEET_RE = /^https?:\/\/(?:www\.|mobile\.)?(?:twitter|x)\.com\/([^/]+)\/status\/(\d+)/i;

/** Tweets: X's pages are JavaScript-only and render to a login wall, but the official oEmbed works unauthenticated. */
async function extractTweet(url: string): Promise<ExtractResult | null> {
  const m = TWEET_RE.exec(url);
  if (!m) return null;
  const canonical = `https://x.com/${m[1]}/status/${m[2]}`;
  const api = `https://publish.twitter.com/oembed?url=${encodeURIComponent(canonical)}&omit_script=true&dnt=true`;
  const res = await fetchWithTimeout(api, EXTRACT_TIMEOUT_MS, { headers: { Accept: "application/json" } });
  if (!res.ok) return null;
  const data = (await res.json()) as { html?: string; author_name?: string; author_url?: string };
  if (!data.html) return null;
  const { document } = parseHTML(`<div id="__root">${data.html}</div>`);
  const root = document.getElementById("__root");
  if (!root) return null;
  const body = root.querySelector("blockquote p")?.innerHTML ?? "";
  if (!body.trim()) return null;
  const by = data.author_name ? `<p><a href="${data.author_url ?? canonical}">${data.author_name}</a> on X</p>` : "";
  const html = sanitizeArticle(`<blockquote><p>${body}</p></blockquote>${by}`).trim();
  return html ? { contentHtml: html, leadImage: null } : null;
}

export async function extractArticle(url: string, feed?: FeedRef): Promise<ExtractResult> {
  if (TWEET_RE.test(url)) {
    try {
      const t = await extractTweet(url);
      if (t) return t;
    } catch {
      /* fall through to the normal path */
    }
  }
  const started = Date.now();
  let plain: ExtractResult | null = null;
  let plainError: unknown = null;
  try {
    plain = await extractPlain(url);
    if (plain.contentHtml) return plain;
  } catch (e) {
    plainError = e;
  }

  // The page failed or had no article: the feed's full-content HTML beats a rendered copy.
  if (feed) {
    const ms = Math.min(FEED_TIMEOUT_MS, TOTAL_BUDGET_MS - MIN_RENDER_MS - (Date.now() - started));
    if (ms >= 1_000) {
      try {
        const f = await extractFromFeed(url, feed, ms);
        if (f) return { ...f, leadImage: plain?.leadImage ?? f.leadImage };
      } catch {
        /* fall through to the rendered copy */
      }
    }
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
