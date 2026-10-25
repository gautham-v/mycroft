import { enclosingObjectAt, isObj, rscPayload, textBefore, type Obj } from "./rsc";

/**
 * Video players mounted client-side (openai.com's Vimeo media items) may be missing from the
 * server HTML, or a rendered copy may catch them before they mount: the figure is an empty slot.
 * Their props are in the RSC payload: `{"altText":…,"videoEmbedUrl":"https://player.vimeo.com/…",
 * "videoEmbedTitle":…,"posterImage":{"title":…,"file":{"url":…}}}`.
 */
export interface PayloadVideo {
  src: string;
  /** The Vimeo/YouTube video id: what identifies this video in a page's HTML. */
  key: string;
  title: string | null;
  /** Texts that name it on the page: the player's alt text, the poster image's title. */
  names: string[];
  /** The poster's file name, as it appears in a poster <img src>. */
  posterFile: string | null;
  /** The last paragraph of text before the player in page order. */
  anchor: string | null;
}

const MARKER = /"videoEmbedUrl"\s*:\s*"/g;
const EMBED = /^https:\/\/(?:player\.vimeo\.com\/video\/|(?:www\.)?youtube(?:-nocookie)?\.com\/embed\/)([\w-]+)/;

const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : null);

export function findPayloadVideos(html: string): PayloadVideo[] {
  if (!html.includes("videoEmbedUrl")) return [];
  const text = rscPayload(html);
  const out: PayloadVideo[] = [];
  for (const m of text.matchAll(MARKER)) {
    const found = enclosingObjectAt(text, m.index, (o) => typeof o.videoEmbedUrl === "string");
    if (!found) continue;
    const o = found.value;
    const src = str(o.videoEmbedUrl);
    const key = src ? EMBED.exec(src)?.[1] : null;
    if (!src || !key || out.some((v) => v.key === key)) continue;
    const poster: Obj = isObj(o.posterImage) ? o.posterImage : {};
    const file = isObj(poster.file) ? poster.file : {};
    const posterUrl = str(file.url);
    out.push({
      src,
      key,
      title: str(o.videoEmbedTitle),
      names: [str(o.altText), str(poster.title)].filter((x): x is string => !!x),
      posterFile: str(file.fileName) ?? (posterUrl ? posterUrl.split("/").pop() ?? null : null),
      anchor: textBefore(text, found.start),
    });
  }
  return out;
}
