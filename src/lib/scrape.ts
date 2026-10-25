import { parseHTML } from "linkedom";
import { fetchWithTimeout } from "./http";
import { ldArticle, metaReader, pageImage, str, type Doc } from "./page-meta";
import type { ParsedItem } from "./parse";

// Scraped-page sources (kind 'page'): a listing page with no RSS/Atom feed, e.g.
// https://www.anthropic.com/news. We pick article-like links off the listing and read
// each article's Open Graph / JSON-LD metadata. Pure helpers first, network last.

const LISTING_TIMEOUT_MS = 15_000;
const ARTICLE_TIMEOUT_MS = 10_000;
const MAX_LINKS = 30;
const CONCURRENCY = 4;
/** Stop starting new article fetches after this; the rest are picked up next refresh. */
const DEFAULT_BUDGET_MS = 25_000;
const HTML_ACCEPT = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5";

/** Path segments that are listing furniture, not articles. */
const STOP_SEGMENTS = new Set([
  "page", "pages", "tag", "tags", "category", "categories", "topic", "topics", "author", "authors",
  "feed", "rss", "atom", "search", "archive", "archives", "all", "latest", "index", "subscribe",
  "login", "signup", "about", "contact", "privacy", "terms",
]);
const LOCALES = new Set(
  "ar bg cs da de el en es et fa fi fr he hi hr hu id it ja ko lt lv ms nb nl no pl pt ro ru sk sl sr sv th tr uk vi zh".split(" "),
);
/** "de", "pt-br", "zh_hans". */
const isLocale = (seg: string) => LOCALES.has(seg.toLowerCase().split(/[-_]/)[0]) && /^[a-z]{2}(?:[-_][a-z]{2,4})?$/i.test(seg);
const FILE_EXT = /\.(xml|json|rss|atom|pdf|zip|png|jpe?g|gif|webp|svg|ico|css|js|mp3|mp4)$/i;
/** Hyphenated words, at least one letter: "claude-duet", "2026-us-midterms". */
const SLUG = /^(?=.*[a-z])[a-z0-9]+(?:[-_][a-z0-9]+)+$/i;

const words = (s: string): string[] => s.toLowerCase().match(/[a-z0-9]+/g) ?? [];

/** X / Twitter profile pages: the server-rendered HTML lists posts as /<user>/status/<id>. */
const isXHost = (host: string) => /^(?:www\.|mobile\.)?(?:x|twitter)\.com$/i.test(host);
const TWEET_PATH = /^\/[^/]+\/status\/\d+$/;
/** Handle of the profile being scraped, set for the duration of scrapePage on an X profile. */
let currentListingUser = "";

/** Canonical form used as item url/guid and for "already seen" checks: no hash, no query, no trailing slash. */
export function canonicalUrl(u: URL): string {
  const path = u.pathname.replace(/\/+$/, "") || "/";
  return `${u.origin}${path}`;
}

const bareHost = (h: string) => h.toLowerCase().replace(/^www\./, "");

interface Link {
  url: string;
  segs: string[];
  texts: string[];
  order: number;
}

function collectLinks(document: Doc, pageUrl: string): Map<string, Link> {
  const page = new URL(pageUrl);
  const baseHref = document.querySelector("base[href]")?.getAttribute("href");
  let base = page;
  try {
    if (baseHref) base = new URL(baseHref, page);
  } catch {}
  const out = new Map<string, Link>();
  let order = 0;
  for (const a of document.querySelectorAll("a[href]")) {
    const href = (a.getAttribute("href") ?? "").trim();
    if (!href || /^(#|mailto:|tel:|javascript:|data:)/i.test(href)) continue;
    let u: URL;
    try {
      u = new URL(href, base);
    } catch {
      continue;
    }
    if (!/^https?:$/.test(u.protocol) || bareHost(u.hostname) !== bareHost(page.hostname)) continue;
    const segs = u.pathname.split("/").filter(Boolean);
    let decoded: string[];
    try {
      decoded = segs.map(decodeURIComponent);
    } catch {
      continue;
    }
    // Normalise to the listing's host so www/non-www variants dedupe.
    u.hostname = page.hostname;
    const key = canonicalUrl(u);
    const text = (a.textContent ?? "").replace(/\s+/g, " ").trim();
    const prev = out.get(key);
    if (prev) {
      if (text) prev.texts.push(text);
    } else {
      out.set(key, { url: key, segs: decoded, texts: text ? [text] : [], order: order++ });
    }
  }
  return out;
}

/** Nav/category links: a one-word slug whose anchor text is just that word ("/news/policy" → "Policy"). */
function isLabelLink(l: Link): boolean {
  const last = l.segs[l.segs.length - 1].toLowerCase();
  if (!/^[a-z]+$/.test(last)) return false;
  const longest = l.texts.reduce((m, t) => (t.length > m.length ? t : m), "");
  const w = words(longest);
  return w.length === 0 || (w.length <= 2 && w.includes(last));
}

function isExcluded(l: Link, listingSegs: string[]): boolean {
  const last = l.segs[l.segs.length - 1];
  if (!last) return true;
  if (STOP_SEGMENTS.has(last.toLowerCase()) || FILE_EXT.test(last)) return true;
  if (/^\d{1,3}$/.test(last)) return true; // pagination ("/news/2")
  if (l.segs.some((s) => STOP_SEGMENTS.has(s.toLowerCase()) && !listingSegs.includes(s))) return true;
  // Localized copies: "/de/resources/articles/..." when the listing isn't under "/de".
  if (isLocale(l.segs[0]) && l.segs[0] !== listingSegs[0] && l.segs.length > 1) return true;
  return isLabelLink(l);
}

/**
 * Article-like links on a listing page, in page order (max 30).
 * Strict: same-origin paths one segment below the listing path (/news → /news/<slug>).
 * Fallback: the most common parent path among same-origin links with a slug-like last segment.
 */
export function findArticleLinks(html: string, pageUrl: string): string[] {
  const { document } = parseHTML(html);
  return articleLinksFromDoc(document, pageUrl);
}

function articleLinksFromDoc(document: Doc, pageUrl: string): string[] {
  const page = new URL(pageUrl);
  const byOrder = (a: Link, b: Link) => a.order - b.order;
  if (isXHost(page.hostname)) {
    // Only posts: profile tabs (/user/media, /user/with_replies) and compose links are furniture.
    return [...collectLinks(document, pageUrl).values()]
      .filter((l) => TWEET_PATH.test(new URL(l.url).pathname))
      .sort(byOrder)
      .slice(0, MAX_LINKS)
      .map((l) => l.url);
  }
  const listingSegs = page.pathname.split("/").filter(Boolean);
  const listingKey = listingSegs.join("/");
  const links = [...collectLinks(document, pageUrl).values()].filter(
    (l) => l.segs.length > 0 && !isExcluded(l, listingSegs),
  );

  // At the site root every nav link is one segment below the listing, so only the fallback applies there.
  const strict = listingSegs.length
    ? links.filter(
        (l) =>
          l.segs.length === listingSegs.length + 1 &&
          l.segs.slice(0, -1).join("/") === listingKey &&
          /[a-z]|\d{4,}/i.test(l.segs[l.segs.length - 1]),
      )
    : [];
  if (strict.length) return strict.sort(byOrder).slice(0, MAX_LINKS).map((l) => l.url);

  const groups = new Map<string, Link[]>();
  for (const l of links) {
    if (!SLUG.test(l.segs[l.segs.length - 1])) continue;
    const prefix = l.segs.slice(0, -1).join("/");
    groups.set(prefix, [...(groups.get(prefix) ?? []), l]);
  }
  let best: Link[] = [];
  for (const g of groups.values()) {
    if (g.length > best.length || (g.length === best.length && g[0].order < (best[0]?.order ?? Infinity))) best = g;
  }
  return best.length >= 2 ? best.sort(byOrder).slice(0, MAX_LINKS).map((l) => l.url) : [];
}

const TITLE_SEP = /\s+[|\\·•—–-]\s+/;

/** Source title for a listing page: "Claude Articles", "Anthropic Newsroom". */
export function listingTitle(html: string, pageUrl: string): string {
  const { document } = parseHTML(html);
  const meta = metaReader(document);
  const og = meta("og:title");
  const site = meta("og:site_name");
  // "Kun Chen (@kunchenguid) on X" already names the site.
  if (og && isXHost(new URL(pageUrl).hostname)) return og;
  if (og && site && !og.toLowerCase().includes(site.toLowerCase())) return `${site} ${og}`;
  const raw = (document.querySelector("title")?.textContent ?? "").replace(/\s+/g, " ").trim();
  const parts = raw.split(TITLE_SEP).filter(Boolean);
  if (parts.length === 2 && parts[1].split(" ").length <= 3) return `${parts[1]} ${parts[0]}`;
  return og ?? (raw || bareHost(new URL(pageUrl).hostname));
}

type Ld = Record<string, unknown>;

function ldAuthor(v: unknown): string | null {
  const names = (Array.isArray(v) ? v : [v])
    // Publisher-as-author ("Organization: Anthropic") adds nothing to a byline.
    .map((a) => (a && typeof a === "object" ? ((a as Ld)["@type"] === "Organization" ? null : str((a as Ld).name)) : str(a)))
    .filter((x): x is string => !!x && !/^https?:\/\//.test(x));
  return names.length ? names.join(", ") : null;
}

/** ISO calendar date with no time: "2026-10-21" (also "2026-10", "2026"). */
const ISO_DATE_ONLY = /^\d{4}(?:-\d{2}(?:-\d{2})?)?$/;
/** Any clock time ("10:30", "T10") marks a full timestamp. */
const HAS_TIME = /\d:\d|T\d/i;
/** A trailing zone on a date with no time ("Wed, 21 Oct 2026 GMT"): it names no instant, only the day. */
const TRAILING_ZONE = /(?:\s+(?:GMT|UTC|UT|[ECMP][SD]T)(?:\s*[+-]\d{2}:?\d{2})?|\s+[+-]\d{2}:?\d{2}|(?<=\d)Z)\s*$/i;

/**
 * Parse a published date. A date with no time ("2026-10-21", "October 21, 2026") is pinned
 * to noon UTC on that calendar day: midnight UTC would show as the previous day in the US. Noon
 * of a day that has only just begun is still hours away, so the result is never later than now:
 * an article dated today must not sort above everything published earlier today.
 * Full timestamps are kept as given.
 */
export function toDate(v: string | null | undefined): Date | null {
  v = v?.trim();
  if (!v) return null;
  let d = new Date(v);
  if (Number.isNaN(d.getTime())) return null;
  const dateOnly = !HAS_TIME.test(v);
  if (dateOnly) {
    // A zone on a date with no time names no instant, only the day ("Wed, 21 Oct 2026 GMT" is
    // still the 21st), so it is left off before reading the calendar day.
    const bare = v.replace(TRAILING_ZONE, "");
    const b = new Date(bare);
    const day = Number.isNaN(b.getTime()) ? d : b;
    d = ISO_DATE_ONLY.test(bare)
      ? // ISO date-only strings parse as UTC midnight.
        new Date(Date.UTC(day.getUTCFullYear(), day.getUTCMonth(), day.getUTCDate(), 12))
      : // Other date-only forms parse as local midnight.
        new Date(Date.UTC(day.getFullYear(), day.getMonth(), day.getDate(), 12));
  }
  // Ignore nonsense: far future or before the web.
  if (d.getTime() > Date.now() + 2 * 86400e3 || d.getFullYear() < 1995) return null;
  if (dateOnly && d.getTime() > Date.now()) d = new Date();
  return d;
}

function clip(s: string | null, max: number): string | null {
  if (!s) return null;
  const t = s.replace(/\s+/g, " ").trim();
  if (!t) return null;
  return t.length > max ? t.slice(0, max - 1).trimEnd() + "…" : t;
}

export interface ArticleMeta {
  title: string | null;
  summary: string | null;
  author: string | null;
  publishedAt: Date | null;
  thumbnailUrl: string | null;
  /** og:type when present ("article", "website", ...). */
  ogType: string | null;
}

/** Per-article fields from Open Graph, JSON-LD, <title> and <time>. Pure; no network. */
export function extractArticleMeta(html: string, pageUrl: string): ArticleMeta {
  const { document } = parseHTML(html);
  const meta = metaReader(document);
  const ld = ldArticle(document);
  const page = new URL(pageUrl);
  if (isXHost(page.hostname) && TWEET_PATH.test(page.pathname)) return tweetMeta(meta, ld, pageUrl);
  const docTitle = (document.querySelector("title")?.textContent ?? "").replace(/\s+/g, " ").trim();
  const h1 = (document.querySelector("h1")?.textContent ?? "").replace(/\s+/g, " ").trim();
  const docParts = docTitle.split(TITLE_SEP);
  const raw = meta("og:title", "twitter:title") ?? str(ld?.headline) ?? (h1 || null) ?? (docParts[0] || null);
  // Drop a trailing site name: "Singapore office opening | Anthropic".
  const sites = [meta("og:site_name"), docParts.length > 1 ? docParts[docParts.length - 1] : null]
    .filter((x): x is string => !!x)
    .map((x) => x.toLowerCase());
  const parts = raw?.split(TITLE_SEP) ?? [];
  const title = parts.length > 1 && sites.includes(parts[parts.length - 1].toLowerCase()) ? parts.slice(0, -1).join(" | ") : raw;
  const published =
    toDate(meta("article:published_time", "og:published_time")) ??
    toDate(str(ld?.datePublished)) ??
    toDate(meta("datepublished", "date", "pubdate", "publish-date", "parsely-pub-date", "dc.date", "dc.date.issued")) ??
    toDate(document.querySelector("article time[datetime]")?.getAttribute("datetime")) ??
    toDate(document.querySelector("time[datetime]")?.getAttribute("datetime"));
  const author = meta("author", "parsely-author") ?? ldAuthor(ld?.author) ?? null;
  return {
    title: clip(title, 300),
    summary: clip(meta("og:description", "description", "twitter:description") ?? str(ld?.description), 400),
    author: author && !/^https?:\/\//.test(author) ? clip(author, 120) : null,
    publishedAt: published,
    thumbnailUrl: pageImage(meta, ld, pageUrl),
    ogType: meta("og:type")?.toLowerCase() ?? null,
  };
}

/**
 * A post on X: og:title is the author ("Kun Chen (@kunchenguid) on X") and the post text is
 * the description, so the text becomes the title. The avatar is not a thumbnail.
 */
function tweetMeta(meta: ReturnType<typeof metaReader>, ld: ReturnType<typeof ldArticle>, pageUrl: string): ArticleMeta {
  const text = meta("og:description", "description", "twitter:description");
  const image = pageImage(meta, ld, pageUrl);
  // Headline: the first paragraph; the reader shows the whole post.
  const first = text?.split(/\n\s*\n/)[0] ?? null;
  const poster = pageUrl ? new URL(pageUrl).pathname.split("/")[1] : "";
  const author = meta("og:title")?.replace(/\s+on X$/i, "") ?? null;
  return {
    title: clip(first, 140) ?? clip(meta("og:title"), 300),
    summary: null,
    // Only name the author when the post is someone else's (a repost on the profile).
    author: poster.toLowerCase() === currentListingUser ? null : clip(author, 120),
    publishedAt: toDate(meta("article:published_time")),
    thumbnailUrl: image && !/\/profile_images\//.test(image) ? image : null,
    ogType: "article",
  };
}

export interface ScrapeResult {
  /** Final listing URL after redirects. */
  listingUrl: string;
  /** Article links found on the listing, in page order. */
  links: string[];
  /** New items (links not in `known`), ready for the shared upsert. */
  items: ParsedItem[];
  /** Links fully handled this run (item built, or not an article / gone); mark them seen. */
  processed: string[];
}

async function fetchHtml(url: string, ms: number): Promise<Response> {
  return fetchWithTimeout(url, ms, { headers: { Accept: HTML_ACCEPT, "Accept-Language": "en-US,en;q=0.9" } });
}

/**
 * Scrape a listing page: find article links, then fetch only those not in `known`
 * (bounded concurrency and time budget) and turn them into items.
 * Items without a date get the first-seen time, offset by page order so the listing order holds.
 */
export async function scrapePage(
  listingUrl: string,
  known: Set<string> = new Set(),
  opts: { budgetMs?: number } = {},
): Promise<ScrapeResult> {
  const res = await fetchHtml(listingUrl, LISTING_TIMEOUT_MS);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const finalUrl = res.url || listingUrl;
  const fu = new URL(finalUrl);
  currentListingUser = isXHost(fu.hostname) ? (fu.pathname.split("/")[1] ?? "").toLowerCase() : "";
  const links = findArticleLinks(await res.text(), finalUrl);
  if (!links.length) throw new Error("No article links found on the page");

  const todo = links.filter((l) => !known.has(l));
  const deadline = Date.now() + (opts.budgetMs ?? DEFAULT_BUDGET_MS);
  const now = Date.now();
  const built = new Map<string, ParsedItem>();
  const processed = new Set<string>();

  let next = 0;
  const worker = async () => {
    while (next < todo.length && Date.now() < deadline) {
      const url = todo[next++];
      try {
        const r = await fetchHtml(url, ARTICLE_TIMEOUT_MS);
        if (!r.ok) {
          // Gone or forbidden: don't retry every refresh. 5xx: try again next time.
          if (r.status < 500) processed.add(url);
          continue;
        }
        const ct = r.headers.get("content-type") ?? "";
        if (ct && !/html|xml/i.test(ct)) {
          processed.add(url);
          continue;
        }
        const m = extractArticleMeta(await r.text(), r.url || url);
        processed.add(url);
        // A category/landing page that slipped past the link heuristic.
        if (m.ogType && m.ogType !== "article" && !m.publishedAt) continue;
        built.set(url, {
          guid: url,
          url,
          title: m.title ?? url,
          summary: m.summary,
          author: m.author,
          publishedAt: m.publishedAt ?? new Date(now - links.indexOf(url) * 1000),
          thumbnailUrl: m.thumbnailUrl,
          videoId: null,
          durationSec: null,
          hnPoints: null,
          hnComments: null,
          hnCommentsUrl: null,
        });
      } catch {
        /* timeout / network: retry next refresh */
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, todo.length) }, worker));

  return {
    listingUrl: finalUrl,
    links,
    items: todo.filter((u) => built.has(u)).map((u) => built.get(u)!),
    processed: todo.filter((u) => processed.has(u)),
  };
}
