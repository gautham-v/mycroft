/**
 * Next.js App Router pages carry their React Server Components payload in the HTML as
 * `self.__next_f.push([1,"..."])` scripts. Client-rendered parts of a page (charts, video players)
 * are empty in the server HTML, but their props, data included, are in this payload.
 */

const PUSH = /self\.__next_f\.push\(\[\s*1\s*,\s*("(?:[^"\\]|\\.)*")\s*\]\)/g;
/** How far back from a marker its enclosing object may start, and how many `{` to try. */
const MAX_LOOKBACK = 2_000_000;
const MAX_TRIES = 20_000;

/** The RSC stream: every pushed string chunk, decoded and joined in order (a row can span pushes). */
export function rscPayload(html: string): string {
  let out = "";
  for (const m of html.matchAll(PUSH)) {
    try {
      out += JSON.parse(m[1]) as string;
    } catch {
      /* not a JSON string literal; skip the chunk */
    }
  }
  return out;
}

/** Index just past the JSON object/array that opens at `start`, or -1 if it never closes. */
export function balancedEnd(text: string, start: number): number {
  const open = text[start];
  if (open !== "{" && open !== "[") return -1;
  let depth = 0;
  let inString = false;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      if (c === "\\") i++;
      else if (c === '"') inString = false;
    } else if (c === '"') inString = true;
    else if (c === "{" || c === "[") depth++;
    else if (c === "}" || c === "]") {
      if (--depth === 0) return i + 1;
    }
  }
  return -1;
}

export type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
export type Obj = { [k: string]: Json };
export const isObj = (v: unknown): v is Obj => !!v && typeof v === "object" && !Array.isArray(v);

/** The innermost JSON object around `pos` that parses and passes `accept`. */
export function enclosingObject(text: string, pos: number, accept: (o: Obj) => boolean): Obj | null {
  return enclosingObjectAt(text, pos, accept)?.value ?? null;
}

/** enclosingObject, with where the object starts in `text`. */
export function enclosingObjectAt(text: string, pos: number, accept: (o: Obj) => boolean): { value: Obj; start: number } | null {
  let tries = 0;
  for (let i = text.lastIndexOf("{", pos); i >= 0 && pos - i <= MAX_LOOKBACK && tries < MAX_TRIES; i = text.lastIndexOf("{", i - 1)) {
    tries++;
    const end = balancedEnd(text, i);
    if (end <= pos) continue; // closes before the marker: a sibling, not an ancestor
    try {
      const o = JSON.parse(text.slice(i, end)) as Json;
      if (isObj(o) && accept(o)) return { value: o, start: i };
    } catch {
      /* a `{` inside a string, or a span cut by non-JSON rows; keep looking */
    }
  }
  return null;
}

/** RSC rows are `<hex id>:<json>` lines; resolve a `"$<id>"` reference to its row's value. */
function rowValue(text: string, id: string): Json | undefined {
  const m = new RegExp(`(?:^|\\n)${id}:(?=[[{])`).exec(text);
  if (!m) return undefined;
  const start = m.index + m[0].length;
  const end = balancedEnd(text, start);
  if (end < 0) return undefined;
  try {
    return JSON.parse(text.slice(start, end)) as Json;
  } catch {
    return undefined;
  }
}

/** Undo RSC string encodings inside a spec: "$undefined", "$$" escapes, "$<id>" row references. */
export function resolve(v: Json | undefined, text: string, depth = 0): Json | undefined {
  if (depth > 20) return v;
  if (typeof v === "string") {
    if (v === "$undefined") return undefined;
    if (v.startsWith("$$")) return v.slice(1);
    const ref = /^\$([0-9a-f]+)$/.exec(v);
    return ref ? resolve(rowValue(text, ref[1]), text, depth + 1) : v;
  }
  if (Array.isArray(v)) return v.map((x) => resolve(x, text, depth + 1) ?? null);
  if (isObj(v)) {
    const out: Obj = {};
    for (const [k, x] of Object.entries(v)) {
      const r = resolve(x, text, depth + 1);
      if (r !== undefined) out[k] = r;
    }
    return out;
  }
  return v;
}

const TEXT_CHILD = /"children":\[?"((?:[^"\\]|\\.){40,})"/g;

/**
 * The last run of rendered text (a paragraph's `"children":"..."`, 40+ characters) before `pos` in
 * page order. When `pos` sits in its own row (`1e9:[...]`) near the row's start, the text before the
 * place that row is referenced (`"$L1e9"`) is used instead: rows arrive out of page order.
 */
export function textBefore(text: string, pos: number): string | null {
  const lineStart = text.lastIndexOf("\n", pos) + 1;
  const row = /^([0-9a-f]+):/.exec(text.slice(lineStart, lineStart + 16));
  let end = pos;
  if (row && !lastText(text.slice(lineStart, pos))) {
    const ref = [`"$L${row[1]}"`, `"$${row[1]}"`].map((r) => text.indexOf(r)).find((i) => i >= 0);
    if (ref !== undefined) end = ref;
  }
  return lastText(text.slice(Math.max(0, end - 200_000), end));
}

function lastText(s: string): string | null {
  let last: string | null = null;
  for (const m of s.matchAll(TEXT_CHILD)) last = m[1];
  if (last === null) return null;
  try {
    return JSON.parse(`"${last}"`) as string;
  } catch {
    return null;
  }
}
