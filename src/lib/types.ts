// Shared API types (JSON wire format, snake_case). Imported by frontend via "@/lib/types".

/** "page": a listing page with no feed, scraped for article links (src/lib/scrape.ts). */
export type SourceKind = "rss" | "youtube" | "page" | "podcast";
export type SourceGroup = "labs" | "blogs" | "news" | "aggregator" | "youtube" | "podcast" | (string & {});

/** Content-type views. "articles" = everything that is not a video or a post source. */
export type View = "all" | "saved" | "articles" | "posts" | "video" | "podcasts";
/** Derived from kind + url: how a source's items read. */
export type SourceType = "article" | "post" | "video" | "podcast";

/** Compact source embedded in each Item. */
export interface ItemSource {
  id: number;
  title: string;
  kind: SourceKind;
  group: SourceGroup;
  icon_url: string | null;
  /** hostname of source.url without leading "www." */
  host: string;
}

export interface Item {
  id: number;
  source_id: number;
  url: string;
  title: string;
  summary: string | null;
  author: string | null;
  /** ISO 8601 */
  published_at: string;
  thumbnail_url: string | null;
  video_id: string | null;
  duration_sec: number | null;
  /** kind 'podcast': episode audio URL. */
  audio_url: string | null;
  hn_points: number | null;
  hn_comments: number | null;
  hn_comments_url: string | null;
  is_saved: boolean;
  /** true when full text has already been extracted & cached */
  has_content: boolean;
  source: ItemSource;
}

export interface ItemsResponse {
  items: Item[];
  /** ISO published_at of last item; pass as ?cursor= for next page. null when no more. */
  nextCursor: string | null;
}

export interface Source {
  id: number;
  title: string;
  url: string;
  feed_url: string;
  kind: SourceKind;
  group: SourceGroup;
  type: SourceType;
  icon_url: string | null;
  host: string;
  /** Sidebar folder; null = Unfiled. */
  folder_id: number | null;
  /** Order within its folder. */
  position: number;
  last_fetched_at: string | null;
  last_error: string | null;
  created_at: string;
}

export interface Folder {
  id: number;
  title: string;
  position: number;
}

export interface SourcesResponse {
  sources: Source[];
  folders: Folder[];
}

/** PATCH /api/sources: move/reorder sources. Positions are assigned by array order within each folder. */
export interface ReorderSourcesBody {
  order: { id: number; folder_id: number | null }[];
}

/** PATCH /api/folders: new folder order (ids, first = top). */
export interface ReorderFoldersBody {
  order: number[];
}

export interface Stats {
  /** ISO or null if never refreshed */
  lastRefreshAt: string | null;
}

export interface ContentResponse {
  contentHtml: string | null;
  leadImage: string | null;
  /** Content came from the rendered-page (Jina Reader) fallback. */
  rendered?: boolean;
}

export interface RefreshResult {
  ran: boolean;
  lastRefreshAt: string | null;
  results?: { sourceId: number; title: string; ok: boolean; added: number; error?: string }[];
  pruned?: number;
}

export interface ApiError {
  error: string;
}

export interface PatchItemBody {
  is_saved?: boolean;
}
