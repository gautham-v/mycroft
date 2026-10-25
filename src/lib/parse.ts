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
  /** The episode's audio enclosure (podcast feeds; set for any feed item that carries one). */
  audioUrl: string | null;
  hnPoints: number | null;
  hnComments: number | null;
  hnCommentsUrl: string | null;
}

export interface ParsedFeed {
  title: string | null;
  link: string | null;
  /** A podcast: most items carry an audio enclosure (see feedLooksLikePodcast). */
  isPodcast: boolean;
  /** Show/channel art (itunes:image, then the RSS channel image), absolute. */
  imageUrl: string | null;
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
  itunesDuration?: XmlText;
  itunesImage?: Attrs;
  itunesSummary?: XmlText;
};
/** xml2js gives a bare string, or `{ _: text, $: attrs }` when the element has attributes. */
type XmlText = string | { _?: string };
type RawFeed = {
  itunesImage?: Attrs;
  itunesAuthor?: XmlText;
  itunesOwner?: unknown;
  itunesCategory?: unknown;
  itunesExplicit?: XmlText;
  itunesType?: XmlText;
};

const parser: Parser<RawFeed, RawItem> = new Parser({
  timeout: 15000,
  customFields: {
    // Read directly rather than via rss-parser's `itunes` object, which it only fills when the
    // <rss> element itself declares xmlns:itunes.
    feed: [
      ["itunes:image", "itunesImage"],
      ["itunes:author", "itunesAuthor"],
      ["itunes:owner", "itunesOwner"],
      ["itunes:category", "itunesCategory"],
      ["itunes:explicit", "itunesExplicit"],
      ["itunes:type", "itunesType"],
    ] as unknown as (keyof RawFeed)[],
    item: [
      ["media:group", "mediaGroup"],
      ["yt:videoId", "videoId"],
      ["media:thumbnail", "mediaThumbnail"],
      ["media:content", "mediaContent", { keepArray: true }],
      ["comments", "comments"],
      ["description", "description"],
      ["author", "author"],
      ["itunes:duration", "itunesDuration"],
      ["itunes:image", "itunesImage"],
      ["itunes:summary", "itunesSummary"],
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

const xmlText = (v: XmlText | undefined): string | null => {
  const t = typeof v === "string" ? v : v?._;
  return t?.trim() || null;
};

const AUDIO_EXT = /\.(mp3|m4a|aac|ogg|oga|opus|wav|flac)(\?|#|$)/i;

/** The enclosure URL when it is audio: an audio/* type, or (no type given) an audio file extension. */
export function audioEnclosure(enc: { url?: string; type?: string } | undefined): string | null {
  const url = enc?.url?.trim();
  if (!url) return null;
  const type = (enc?.type ?? "").trim().toLowerCase();
  if (type) return type.startsWith("audio/") || (type === "application/octet-stream" && AUDIO_EXT.test(url)) ? url : null;
  return AUDIO_EXT.test(url) ? url : null;
}

/** itunes:duration as seconds: plain seconds ("3725", "3725.4") or "HH:MM:SS" / "MM:SS". */
export function parseDuration(v: string | null | undefined): number | null {
  const s = v?.trim();
  if (!s) return null;
  const parts = s.split(":");
  if (parts.length > 3 || parts.some((p) => !/^\d+(\.\d+)?$/.test(p.trim()))) return null;
  const secs = parts.reduce((acc, p) => acc * 60 + Number(p), 0);
  return secs > 0 ? Math.round(secs) : null;
}

export function normalizeItem(
  raw: RawItem,
  kind: SourceKind,
  feedUrl: string,
  feedLink: string | null,
  showArt: string | null = null,
): ParsedItem | null {
  const base = feedLink ?? feedUrl;
  const audio = kind === "youtube" ? null : absolutize(audioEnclosure(raw.enclosure), feedUrl);
  // Episodes often have no <link> and an opaque guid: fall back to the show page, then the audio.
  const url = audio
    ? (absolutize(raw.link, base) ??
      (/^https?:\/\//i.test(raw.guid ?? "") ? absolutize(raw.guid, base) : null) ??
      absolutize(feedLink, feedUrl) ??
      audio)
    : (absolutize(raw.link, base) ?? absolutize(raw.guid, base));
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
      audioUrl: null,
      hnPoints: null,
      hnComments: null,
      hnCommentsUrl: null,
    };
  }

  const html = raw["content:encoded"] ?? raw.content ?? raw.description ?? raw.summary ?? xmlText(raw.itunesSummary) ?? undefined;

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
      audioUrl: null,
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
  // Episodes: the episode's own art, then the show's, before any image in the show notes (often a sponsor logo).
  const episodeArt = raw.itunesImage?.$?.href;
  const thumb =
    mediaContentImg ?? mediaThumb ?? groupThumb ?? enc ?? episodeArt ?? (audio ? showArt : null) ?? firstImg(html);

  return {
    guid,
    url,
    title,
    summary: stripHtml(raw.contentSnippet || html),
    author: typeof author === "string" ? author : null,
    publishedAt: pickDate(raw),
    thumbnailUrl: absolutize(thumb, url),
    videoId: null,
    durationSec: audio ? parseDuration(xmlText(raw.itunesDuration)) : null,
    audioUrl: audio,
    hnPoints: null,
    hnComments: null,
    hnCommentsUrl: null,
  };
}

/**
 * A podcast feed: at least one item has an audio enclosure, and either most items do or the
 * channel carries iTunes podcast tags. A blog that links the odd MP3 stays a blog.
 */
export function feedLooksLikePodcast(feed: { hasItunesTags: boolean; itemCount: number; audioCount: number }): boolean {
  if (feed.audioCount === 0) return false;
  return feed.audioCount * 2 >= feed.itemCount || (feed.hasItunesTags && feed.audioCount * 4 >= feed.itemCount);
}

export async function parseFeedXml(xml: string, kind: SourceKind, feedUrl: string): Promise<ParsedFeed> {
  const feed = await parser.parseString(xml);
  const link = feed.link ?? null;
  const imageUrl = absolutize(feed.itunesImage?.$?.href ?? feed.itunes?.image ?? feed.image?.url, link ?? feedUrl);
  const items = (feed.items ?? [])
    .map((r) => normalizeItem(r, kind, feedUrl, link, imageUrl))
    .filter((x): x is ParsedItem => x !== null);
  const hasItunesTags = !!(feed.itunesImage || feed.itunesAuthor || feed.itunesOwner || feed.itunesCategory || feed.itunesType);
  const isPodcast =
    kind !== "youtube" &&
    feedLooksLikePodcast({ hasItunesTags, itemCount: items.length, audioCount: items.filter((i) => i.audioUrl).length });
  return { title: feed.title ?? null, link, isPodcast, imageUrl, items };
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
  return raw ? (raw["content:encoded"] ?? raw.content ?? xmlText(raw.itunesSummary)) : null;
}
