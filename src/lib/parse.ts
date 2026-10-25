import Parser from "rss-parser";
import type { SourceKind } from "./types";

/** Normalized item ready for DB upsert (minus source_id). */
export interface ParsedItem {
  guid: string;
  url: string;
  title: string;
  summary: string | null;
  author: string | null;
  publishedAt: Date;
  thumbnailUrl: string | null;
  videoId: string | null;
  durationSec: number | null;
  hnPoints: number | null;
  hnComments: number | null;
  hnCommentsUrl: string | null;
}

export interface ParsedFeed {
  title: string | null;
  link: string | null;
  items: ParsedItem[];
}

type Attrs = { $?: Record<string, string> };
type MediaGroup = {
  "media:description"?: string[];
  "media:thumbnail"?: Attrs[];
  "media:content"?: Attrs[];
};
type RawItem = Parser.Item & {
  author?: string;
  comments?: string;
  description?: string;
  mediaGroup?: MediaGroup;
  videoId?: string;
  id?: string;
  mediaThumbnail?: Attrs | Attrs[];
  mediaContent?: Attrs[];
  enclosure?: { url?: string; type?: string };
  "content:encoded"?: string;
};

const parser: Parser<Record<string, unknown>, RawItem> = new Parser({
  timeout: 15000,
  customFields: {
    item: [
      ["media:group", "mediaGroup"],
      ["yt:videoId", "videoId"],
      ["media:thumbnail", "mediaThumbnail"],
      ["media:content", "mediaContent", { keepArray: true }],
      ["comments", "comments"],
      ["description", "description"],
      ["author", "author"],
    ],
  },
});

export function youtubeThumb(videoId: string): string {
  return `https://i.ytimg.com/vi/${videoId}/hqdefault.jpg`;
}

const decodeEntities = (s: string) =>
  s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&#x27;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&");

export function stripHtml(html: string | undefined | null, max = 400): string | null {
  if (!html) return null;
  const text = decodeEntities(
    html
      .replace(/<(script|style)[\s\S]*?<\/\1>/gi, " ")
      .replace(/<[^>]+>/g, " "),
  )
    .replace(/\s+/g, " ")
    .trim();
  if (!text) return null;
  return text.length > max ? text.slice(0, max - 1).trimEnd() + "…" : text;
}

function absolutize(u: string | undefined | null, base: string | null): string | null {
  if (!u) return null;
  try {
    return new URL(decodeEntities(u), base ?? undefined).toString();
  } catch {
    return null;
  }
}

function firstImg(html: string | undefined | null): string | null {
  if (!html) return null;
  const m = html.match(/<img[^>]+src=["']([^"']+)["']/i);
  return m ? m[1] : null;
}

/** hnrss description: "Points: 123", "# Comments: 45". */
export function parseHnDescription(desc: string | undefined | null): {
  points: number | null;
  comments: number | null;
} {
  const text = desc ? decodeEntities(desc.replace(/<[^>]+>/g, " ")) : "";
  const p = text.match(/Points:\s*(\d+)/i);
  const c = text.match(/#\s*Comments:\s*(\d+)/i);
  return { points: p ? Number(p[1]) : null, comments: c ? Number(c[1]) : null };
}

export function isHnFeed(feedUrl: string): boolean {
  return /(^|\.)hnrss\.org$/i.test(safeHost(feedUrl));
}
function safeHost(u: string): string {
  try {
    return new URL(u).hostname;
  } catch {
    return "";
  }
}

function toArr<T>(v: T | T[] | undefined): T[] {
  return v === undefined ? [] : Array.isArray(v) ? v : [v];
}

function pickDate(raw: RawItem): Date {
  const d = new Date(raw.isoDate ?? raw.pubDate ?? "");
  return Number.isNaN(d.getTime()) ? new Date() : d;
}

export function normalizeItem(raw: RawItem, kind: SourceKind, feedUrl: string, feedLink: string | null): ParsedItem | null {
  const base = feedLink ?? feedUrl;
  const url = absolutize(raw.link, base) ?? absolutize(raw.guid, base);
  if (!url) return null;
  const guid = (raw.guid || raw.id || url).toString();
  const title = (raw.title ?? "").trim() || "(untitled)";
  const author = raw.creator ?? raw.author ?? null;

  if (kind === "youtube") {
    const videoId =
      raw.videoId ?? (raw.id?.startsWith("yt:video:") ? raw.id.slice(9) : null) ?? null;
    const desc = raw.mediaGroup?.["media:description"]?.[0] ?? null;
    return {
      guid,
      url,
      title,
      summary: desc ? stripHtml(desc, 600) : null,
      author: typeof author === "string" ? author : null,
      publishedAt: pickDate(raw),
      thumbnailUrl: videoId ? youtubeThumb(videoId) : null,
      videoId,
      durationSec: null,
      hnPoints: null,
      hnComments: null,
      hnCommentsUrl: null,
    };
  }

  const html = raw["content:encoded"] ?? raw.content ?? raw.description ?? raw.summary;

  if (isHnFeed(feedUrl)) {
    const { points, comments } = parseHnDescription(raw.description ?? raw.content);
    return {
      guid,
      url,
      title,
      summary: null,
      author: typeof author === "string" ? author : null,
      publishedAt: pickDate(raw),
      thumbnailUrl: null,
      videoId: null,
      durationSec: null,
      hnPoints: points,
      hnComments: comments,
      hnCommentsUrl: raw.comments ?? null,
    };
  }

  const mediaContentImg = toArr(raw.mediaContent).find((m) => {
    const a = m.$ ?? {};
    return a.url && (a.medium === "image" || (a.type ?? "").startsWith("image/") || /\.(jpe?g|png|webp|gif)(\?|$)/i.test(a.url));
  })?.$?.url;
  const mediaThumb = toArr(raw.mediaThumbnail)[0]?.$?.url;
  const groupThumb = raw.mediaGroup?.["media:thumbnail"]?.[0]?.$?.url;
  const enc = raw.enclosure?.url && (raw.enclosure.type ?? "").startsWith("image/") ? raw.enclosure.url : undefined;
  const thumb = mediaContentImg ?? mediaThumb ?? groupThumb ?? enc ?? firstImg(html);

  return {
    guid,
    url,
    title,
    summary: stripHtml(raw.contentSnippet || html),
    author: typeof author === "string" ? author : null,
    publishedAt: pickDate(raw),
    thumbnailUrl: absolutize(thumb, url),
    videoId: null,
    durationSec: null,
    hnPoints: null,
    hnComments: null,
    hnCommentsUrl: null,
  };
}

export async function parseFeedXml(xml: string, kind: SourceKind, feedUrl: string): Promise<ParsedFeed> {
  const feed = await parser.parseString(xml);
  const link = feed.link ?? null;
  const items = (feed.items ?? [])
    .map((r) => normalizeItem(r, kind, feedUrl, link))
    .filter((x): x is ParsedItem => x !== null);
  return { title: feed.title ?? null, link, items };
}

/**
 * The full HTML a feed carries for one item (content:encoded, Atom content), matched by guid first
 * across every item, then by link. Links keep their query: on feeds with query-string permalinks
 * (`?p=101`, `article.php?id=7`) the query is what tells posts apart. Only the fragment and a
 * trailing slash are ignored.
 */
export async function findFeedItemHtml(xml: string, match: { guid: string; url: string }): Promise<string | null> {
  const feed = await parser.parseString(xml);
  const items = feed.items ?? [];
  const norm = (u: string) => u.trim().replace(/#.*$/, "").replace(/\/+(?=\?|$)/, "");
  const raw =
    items.find((r) => (r.guid || r.id) === match.guid) ??
    items.find((r) => !!r.link && norm(r.link) === norm(match.url));
  return raw ? (raw["content:encoded"] ?? raw.content ?? null) : null;
}
