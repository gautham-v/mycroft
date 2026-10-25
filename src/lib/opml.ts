import type { SourceKind } from "./types";

/**
 * OPML 2.0 import/export. Pure and dependency-free: a small tokenizer over `<outline>` tags is
 * enough for subscription lists and, unlike linkedom's XML mode, decodes entities in attributes.
 */

/** A feed as it appears in an OPML file. `kind` is only set by Openfeed's own exports. */
export interface OpmlSource {
  title: string;
  feedUrl: string;
  htmlUrl: string | null;
  kind: SourceKind | null;
}

export interface OpmlDoc {
  folders: { title: string; sources: OpmlSource[] }[];
  unfiled: OpmlSource[];
}

/** Minimal shapes so both DB rows and wire types can be exported. */
export interface OpmlFolderIn {
  id: number;
  title: string;
}
export interface OpmlSourceIn {
  title: string;
  url: string;
  feedUrl: string;
  kind: SourceKind;
  folderId: number | null;
}

const KINDS: SourceKind[] = ["rss", "youtube", "page", "podcast"];
/** Namespace for the non-standard `openfeed:kind` attribute, so scraped pages and podcasts round-trip. */
const NS = "https://github.com/gautham-v/openfeed";

// --- serialize -----------------------------------------------------------------

function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/[\r\n\t]+/g, " ");
}

function feedOutline(s: OpmlSourceIn, indent: string): string {
  const t = esc(s.title);
  return `${indent}<outline type="rss" text="${t}" title="${t}" xmlUrl="${esc(s.feedUrl)}" htmlUrl="${esc(s.url)}" openfeed:kind="${s.kind}"/>`;
}

/** Folders (in the order given) as nested outlines, then unfiled sources at the top level. */
export function serialize(folders: OpmlFolderIn[], sources: OpmlSourceIn[], now = new Date()): string {
  const lines = [
    `<?xml version="1.0" encoding="UTF-8"?>`,
    `<opml version="2.0" xmlns:openfeed="${NS}">`,
    `  <head>`,
    `    <title>Openfeed subscriptions</title>`,
    `    <dateCreated>${now.toUTCString()}</dateCreated>`,
    `  </head>`,
    `  <body>`,
  ];
  const known = new Set(folders.map((f) => f.id));
  for (const f of folders) {
    const list = sources.filter((s) => s.folderId === f.id);
    if (!list.length) continue;
    const t = esc(f.title);
    lines.push(`    <outline text="${t}" title="${t}">`, ...list.map((s) => feedOutline(s, "      ")), `    </outline>`);
  }
  // Sources whose folder wasn't passed in are exported unfiled rather than dropped.
  lines.push(...sources.filter((s) => s.folderId == null || !known.has(s.folderId)).map((s) => feedOutline(s, "    ")));
  lines.push(`  </body>`, `</opml>`, ``);
  return lines.join("\n");
}

// --- parse ---------------------------------------------------------------------

const NAMED: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };
const ENTITY = /&(#x[0-9a-f]+|#\d+|[a-z]+);/gi;

function decodeOnce(s: string): string {
  return s.replace(ENTITY, (m, e: string) => {
    if (e[0] === "#") {
      const n = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(n) && n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : m;
    }
    return NAMED[e.toLowerCase()] ?? m;
  });
}

/** Decode entities; a second pass undoes the double escaping some exporters do (`&amp;amp;`). */
export function decodeEntities(s: string): string {
  const once = decodeOnce(s);
  return /&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-f]+);/i.test(once) ? decodeOnce(once) : once;
}

/** Attributes keyed by lowercased name (OPML in the wild mixes `xmlUrl`, `xmlurl`, `XMLURL`). */
function attrs(raw: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of raw.matchAll(/([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) {
    out[m[1].toLowerCase()] = decodeEntities(m[2] ?? m[3] ?? "").trim();
  }
  return out;
}

function toSource(a: Record<string, string>): OpmlSource | null {
  let feedUrl = a.xmlurl || a.url || "";
  if (!feedUrl) return null;
  // `feed://` and `feed:https://` are old subscribe-link schemes for plain http(s).
  feedUrl = feedUrl.replace(/^feed:(\/\/)?(?=https?:)/i, "").replace(/^feed:\/\//i, "https://");
  const kind = a["openfeed:kind"];
  return {
    title: a.title || a.text || "",
    feedUrl,
    htmlUrl: a.htmlurl || null,
    kind: KINDS.includes(kind as SourceKind) ? (kind as SourceKind) : null,
  };
}

/**
 * Parse an OPML document. Outlines with an `xmlUrl` are feeds (a `type` attribute isn't required);
 * outlines without one are folders. Openfeed folders are flat, so a feed goes in its nearest
 * enclosing folder, and folders with the same title (any case) are merged. Duplicate feeds keep
 * their first occurrence. Throws when the text has no OPML body.
 */
export function parse(xml: string): OpmlDoc {
  // Comments and CDATA could hide or fake outline tags.
  const text = xml.replace(/<!--[\s\S]*?-->/g, "").replace(/<!\[CDATA\[[\s\S]*?\]\]>/g, "");
  const bodyStart = text.search(/<body\b[^>]*>/i);
  if (!/<opml\b/i.test(text) || bodyStart < 0) throw new Error("Not an OPML file");
  const body = text.slice(bodyStart);

  const doc: OpmlDoc = { folders: [], unfiled: [] };
  const byTitle = new Map<string, OpmlDoc["folders"][number]>();
  const seen = new Set<string>();
  // Folder title (or null) for each open outline; feeds that wrap children push their parent's.
  const stack: (string | null)[] = [];

  for (const m of body.matchAll(/<(\/?)outline\b((?:[^>"']|"[^"]*"|'[^']*')*?)(\/?)>/gi)) {
    const [, closing, raw, selfClosing] = m;
    if (closing) {
      stack.pop();
      continue;
    }
    const a = attrs(raw);
    const parent = stack.length ? stack[stack.length - 1] : null;
    const src = toSource(a);
    if (src) {
      if (!seen.has(src.feedUrl)) {
        seen.add(src.feedUrl);
        if (parent == null) doc.unfiled.push(src);
        else {
          const key = parent.toLowerCase();
          let f = byTitle.get(key);
          if (!f) {
            f = { title: parent, sources: [] };
            byTitle.set(key, f);
            doc.folders.push(f);
          }
          f.sources.push(src);
        }
      }
      if (!selfClosing) stack.push(parent);
    } else if (!selfClosing) {
      // A folder; an untitled one passes its parent's folder through.
      stack.push(a.title || a.text || parent);
    }
  }
  return doc;
}
