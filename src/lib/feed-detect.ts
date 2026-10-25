import { fetchWithTimeout } from "./http";
import { parseFeedXml } from "./parse";
import { canonicalUrl, findArticleLinks, listingTitle } from "./scrape";
import { normalizeSourceUrl, wwwAlternate } from "./source-url";
import type { SourceKind } from "./types";

const TIMEOUT = 15_000;

export interface DetectedFeed {
  title: string;
  url: string;
  feedUrl: string;
  kind: SourceKind;
  group: string;
}

const YT_FEED = (id: string) => `https://www.youtube.com/feeds/videos.xml?channel_id=${id}`;

export function youtubeChannelIdFromUrl(u: URL): string | null {
  const m = u.pathname.match(/^\/channel\/(UC[\w-]{22})/);
  return m ? m[1] : null;
}

export function isYoutubeUrl(u: URL): boolean {
  return /(^|\.)youtube\.com$/i.test(u.hostname);
}

export function findChannelIdInHtml(html: string): string | null {
  const m =
    html.match(/"channelId":"(UC[\w-]{22})"/) ??
    html.match(/"externalId":"(UC[\w-]{22})"/) ??
    html.match(/channel_id=(UC[\w-]{22})/);
  return m ? m[1] : null;
}

export function findAlternateFeeds(html: string, base: string): string[] {
  const out: string[] = [];
  for (const tag of html.match(/<link\b[^>]*>/gi) ?? []) {
    const attr = (n: string) => tag.match(new RegExp(`\\b${n}\\s*=\\s*["']([^"']+)["']`, "i"))?.[1];
    const rel = attr("rel")?.toLowerCase() ?? "";
    const type = attr("type")?.toLowerCase() ?? "";
    const href = attr("href");
    if (rel.split(/\s+/).includes("alternate") && /application\/(rss|atom)\+xml/.test(type) && href) {
      try {
        out.push(new URL(href.replace(/&amp;/g, "&"), base).toString());
      } catch {}
    }
  }
  return out;
}

function looksLikeFeed(text: string): boolean {
  const head = text.slice(0, 2000).toLowerCase();
  return /<rss\b|<feed\b|<rdf:rdf\b/.test(head);
}

function siteFrom(link: string | null, fallback: string): string {
  try {
    return new URL(link ?? fallback).origin;
  } catch {
    return fallback;
  }
}

async function tryFeed(feedUrl: string, kind: SourceKind, text?: string): Promise<DetectedFeed | null> {
  let body = text;
  if (body === undefined) {
    const res = await fetchWithTimeout(feedUrl, TIMEOUT);
    if (!res.ok) return null;
    body = await res.text();
  }
  if (!looksLikeFeed(body)) return null;
  const feed = await parseFeedXml(body, kind, feedUrl);
  if (kind === "youtube") {
    const id = feedUrl.split("channel_id=")[1];
    return {
      title: feed.title ?? "YouTube channel",
      url: `https://www.youtube.com/channel/${id}`,
      feedUrl,
      kind,
      group: "youtube",
    };
  }
  return {
    title: feed.title ?? new URL(feedUrl).hostname,
    url: siteFrom(feed.link, feedUrl),
    feedUrl,
    kind,
    group: "blogs",
  };
}

/**
 * Fetch a user-supplied URL; if that fails (network error or non-2xx) retry once with `www.`
 * added to or removed from the host. Returns the first OK response and the URL it ended up at
 * after redirects, or the original failure (thrown error or non-OK response) if neither works.
 */
async function fetchUserUrl(url: string, init?: RequestInit): Promise<{ res: Response; url: string }> {
  let first: Response | null = null;
  let firstErr: unknown = null;
  try {
    first = await fetchWithTimeout(url, TIMEOUT, init);
    if (first.ok) return { res: first, url: first.url || url };
  } catch (e) {
    // A timeout already spent the budget; don't spend it twice.
    if (e instanceof Error && e.name === "AbortError") throw e;
    firstErr = e;
  }
  const alt = wwwAlternate(url);
  if (alt) {
    try {
      const res = await fetchWithTimeout(alt, TIMEOUT, init);
      if (res.ok) return { res, url: res.url || alt };
    } catch {}
  }
  if (first) return { res: first, url: first.url || url };
  // undici's bare "fetch failed" (DNS, refused, TLS) says nothing useful to the user.
  if (firstErr instanceof TypeError && firstErr.message === "fetch failed") throw new Error(`Could not reach ${new URL(url).hostname}`);
  throw firstErr;
}

/** Detect a feed from a user-supplied URL (site, feed, or YouTube channel). */
export async function detectFeed(input: string): Promise<DetectedFeed> {
  const u = new URL(normalizeSourceUrl(input));

  if (isYoutubeUrl(u)) {
    if (u.pathname.startsWith("/feeds/videos.xml")) {
      const id = u.searchParams.get("channel_id");
      if (id) {
        const r = await tryFeed(YT_FEED(id), "youtube");
        if (r) return r;
      }
    }
    let id = youtubeChannelIdFromUrl(u);
    if (!id) {
      const { res } = await fetchUserUrl(u.toString(), {
        headers: { "Accept-Language": "en-US,en;q=0.9", Cookie: "CONSENT=YES+1" },
      });
      if (!res.ok) throw new Error(`YouTube page returned HTTP ${res.status}`);
      id = findChannelIdInHtml(await res.text());
    }
    if (!id) throw new Error("Could not find YouTube channel id");
    const r = await tryFeed(YT_FEED(id), "youtube");
    if (!r) throw new Error("YouTube feed not available for this channel");
    return r;
  }

  const { res, url: finalUrl } = await fetchUserUrl(u.toString());
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const text = await res.text();

  if (looksLikeFeed(text)) {
    const r = await tryFeed(finalUrl, "rss", text);
    if (r) return r;
  }

  const candidates = findAlternateFeeds(text, finalUrl);
  for (const c of candidates) {
    try {
      const r = await tryFeed(c, "rss");
      if (r) return { ...r, url: siteFrom(null, finalUrl) };
    } catch {}
  }

  // No feed anywhere: fall back to scraping the page for article links (kind 'page').
  if (findArticleLinks(text, finalUrl).length > 0) {
    const listing = new URL(finalUrl);
    // Keep the query (it may select a category); drop the fragment and trailing slash.
    const pageUrl = canonicalUrl(listing) + listing.search;
    return { title: listingTitle(text, finalUrl), url: pageUrl, feedUrl: pageUrl, kind: "page", group: "blogs" };
  }
  throw new Error("No RSS/Atom feed or article links found at that URL");
}
