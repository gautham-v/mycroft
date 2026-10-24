import { fetchWithTimeout } from "./http";
import { parseFeedXml } from "./parse";
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

/** Detect a feed from a user-supplied URL (site, feed, or YouTube channel). */
export async function detectFeed(input: string): Promise<DetectedFeed> {
  let u: URL;
  try {
    u = new URL(/^https?:\/\//i.test(input) ? input : `https://${input}`);
  } catch {
    throw new Error("Invalid URL");
  }

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
      const res = await fetchWithTimeout(u.toString(), TIMEOUT, {
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

  const res = await fetchWithTimeout(u.toString(), TIMEOUT);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const text = await res.text();
  const finalUrl = res.url || u.toString();

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
  throw new Error("No RSS/Atom feed found at that URL");
}
