// Dedupe a feed batch before the upsert. The guid is the primary identity (unique per
// source in the DB), but aggregators like Hacker News give each *submission* its own guid,
// so the same story submitted twice arrives as two items with one link. Pure; no network.

/** Query params that only track the click, never change the page (kept short on purpose). */
const TRACKING_PARAM = /^(utm_\w+|fbclid|gclid|dclid|msclkid|mc_cid|mc_eid|igshid|ref_src)$/i;
/** A link shared by this many items (stored + incoming) is a feed-wide link, not a story. */
const SHARED_LINK_MIN = 3;

/**
 * Comparison key for "same page": scheme, www., default port, trailing slash, tracking params
 * and in-page anchors ignored; remaining params sorted. Null for unparseable URLs and for
 * bare site roots, which many items legitimately share.
 */
export function linkKey(url: string): string | null {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  const host = u.hostname.toLowerCase().replace(/^www\./, "");
  const path = u.pathname.replace(/\/+$/, "");
  const params = [...u.searchParams].filter(([k]) => !TRACKING_PARAM.test(k)).sort(([a], [b]) => a.localeCompare(b));
  const query = params.length ? "?" + new URLSearchParams(params).toString() : "";
  // "#/route" and "#!/route" are SPA pages; any other hash is an anchor within one page.
  const hash = /^#!?\//.test(u.hash) ? u.hash : "";
  if (!path && !query && !hash) return null;
  return `${host}${u.port ? ":" + u.port : ""}${path}${query}${hash}`;
}

const titleKey = (t: string) => t.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();

export interface DedupeItem {
  guid: string;
  url: string;
  title: string;
  hnPoints?: number | null;
}

export interface DedupeOptions {
  /** Items already stored for this source. */
  stored?: { guid: string; url: string; title: string }[];
  /**
   * Aggregator feeds (Hacker News): one link is one story, whatever the title, so a
   * second submission is dropped. Elsewhere a shared link only counts as a duplicate
   * when the title matches too (a republish under a new guid).
   */
  linkOnly?: boolean;
  /** The source's site URL; items linking to it are never deduped by link. */
  siteUrl?: string | null;
}

/**
 * Drop incoming items that repeat a guid, or that repeat a stored or earlier item's link
 * (see `DedupeOptions.linkOnly`). Items whose guid is already stored always pass, so their
 * row keeps updating. Outside aggregators, links shared by `SHARED_LINK_MIN`+ items are left
 * alone. Among new duplicates the one with the most HN points wins, then feed order. Output
 * keeps feed order.
 */
export function dedupeItems<T extends DedupeItem>(incoming: T[], opts: DedupeOptions = {}): T[] {
  const stored = opts.stored ?? [];
  const storedGuids = new Set(stored.map((s) => s.guid));
  const siteKey = opts.siteUrl ? linkKey(opts.siteUrl) : null;

  // Guid first: ON CONFLICT DO UPDATE errors if one statement touches a row twice.
  const byGuid = [...new Map(incoming.map((it) => [it.guid, it])).values()];

  const keyOf = (it: { url: string; title: string }): string | null => {
    const k = linkKey(it.url);
    if (!k || k === siteKey) return null;
    return opts.linkOnly ? k : `${k} ${titleKey(it.title)}`;
  };

  // How many distinct guids share each link (by link alone, so a feed-wide link is spotted
  // even when titles differ).
  const guidsPerLink = new Map<string, Set<string>>();
  for (const it of [...stored, ...byGuid]) {
    const k = linkKey(it.url);
    if (!k) continue;
    let set = guidsPerLink.get(k);
    if (!set) guidsPerLink.set(k, (set = new Set()));
    set.add(it.guid);
  }
  // Aggregators have no feed-wide links (an Ask HN post links to its own HN page), so a
  // story submitted three times is still one story there.
  const shared = (it: { url: string }) =>
    !opts.linkOnly && (guidsPerLink.get(linkKey(it.url) ?? "")?.size ?? 0) >= SHARED_LINK_MIN;

  const claimed = new Set<string>();
  for (const s of stored) {
    const k = keyOf(s);
    if (k && !shared(s)) claimed.add(k);
  }

  const keep = new Set<T>();
  // Rows we already have claim their link before any new item can.
  for (const it of byGuid) {
    if (!storedGuids.has(it.guid)) continue;
    keep.add(it);
    const k = keyOf(it);
    if (k) claimed.add(k);
  }
  const fresh = byGuid
    .map((it, i) => ({ it, i }))
    .filter(({ it }) => !storedGuids.has(it.guid))
    .sort((a, b) => (b.it.hnPoints ?? 0) - (a.it.hnPoints ?? 0) || a.i - b.i);
  for (const { it } of fresh) {
    const k = keyOf(it);
    if (k && !shared(it)) {
      if (claimed.has(k)) continue;
      claimed.add(k);
    }
    keep.add(it);
  }
  return byGuid.filter((it) => keep.has(it));
}
