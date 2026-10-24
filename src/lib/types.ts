// Shared API types (JSON wire format, snake_case). Imported by frontend via "@/lib/types".

export type SourceKind = "rss" | "youtube";
export type SourceGroup = "labs" | "blogs" | "news" | "aggregator" | "youtube" | (string & {});

export type View = "all" | "saved" | "video";
export type Filter = "hn100" | "labs" | "blogs";

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
  icon_url: string | null;
  host: string;
  last_fetched_at: string | null;
  last_error: string | null;
  created_at: string;
}

export interface SourcesResponse {
  sources: Source[];
}

export interface Stats {
  /** ISO or null if never refreshed */
  lastRefreshAt: string | null;
}

export interface ContentResponse {
  contentHtml: string | null;
  leadImage: string | null;
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
