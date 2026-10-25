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

/** POST /api/opml result. */
export interface OpmlImportResult {
  added: number;
  /** Feeds already subscribed (or repeated in the file). */
  skipped: number;
  folders_created: number;
  /** One line per outline that couldn't be imported (e.g. an invalid feed URL). */
  errors: string[];
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

/** "Send to" destinations for an item. */
export type SendTarget = "readwise" | "webhook";

/** GET/PUT /api/integrations. The Readwise token never leaves the server; only its last 4 characters. */
export interface IntegrationsResponse {
  readwise: { configured: boolean; token_hint: string | null };
  webhook: { configured: boolean; url: string | null };
}

/** PUT /api/integrations: a string sets a value, null clears it, an omitted key is left alone. */
export interface PutIntegrationsBody {
  readwise_token?: string | null;
  webhook_url?: string | null;
}

/** POST /api/items/[id]/send and POST /api/integrations/test. */
export interface SendBody {
  target: SendTarget;
}

/** JSON a webhook receives for each sent item (`test: true` on the Settings test payload). */
export interface WebhookPayload {
  id: number;
  url: string;
  title: string;
  author: string | null;
  published_at: string;
  summary: string | null;
  source: { title: string; host: string };
  test?: boolean;
}

/** Success body of the send and test routes; failures are ApiError with a non-2xx status. */
export interface SendResult {
  ok: true;
}
