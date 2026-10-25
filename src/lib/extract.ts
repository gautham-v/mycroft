import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";
import sanitizeHtml from "sanitize-html";
import { renderPageCharts } from "./charts";
import { findPayloadVideos, type PayloadVideo } from "./payload-videos";
import { BROWSER_HEADERS, fetchWithTimeout } from "./http";
import { findFeedItemHtml, isHnFeed } from "./parse";

const EXTRACT_TIMEOUT_MS = 10_000;

// Inline SVG (diagrams, charts): shapes and presentation attributes only. No <use>, <image>,
// <foreignObject>, href, style or event handlers. The parser may hand over camelCase names
// (linearGradient, viewBox) or lowercased ones, so both spellings are listed; the browser's HTML
// parser restores SVG casing either way.
const withLower = (names: string[]) => [...new Set(names.flatMap((n) => [n, n.toLowerCase()]))];
// prettier-ignore
const SVG_TAGS = withLower([
  "svg", "g", "path", "circle", "ellipse", "line", "polyline", "polygon", "rect", "text", "tspan",
  "defs", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "marker",
]);
// prettier-ignore
const SVG_ATTRS = withLower([
  "id", "viewBox", "width", "height", "preserveAspectRatio", "role", "aria-label", "aria-hidden",
  "d", "cx", "cy", "r", "rx", "ry", "x", "y", "x1", "y1", "x2", "y2", "dx", "dy", "points", "offset",
  "transform", "opacity", "fill", "fill-opacity", "fill-rule", "clip-rule", "clip-path", "mask",
  "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-dasharray",
  "stroke-dashoffset", "stroke-miterlimit", "vector-effect", "stop-color", "stop-opacity",
  "gradientUnits", "gradientTransform", "spreadMethod", "clipPathUnits", "maskUnits",
  "marker-start", "marker-mid", "marker-end", "markerWidth", "markerHeight", "markerUnits", "refX", "refY", "orient",
  "text-anchor", "dominant-baseline", "alignment-baseline", "font-size", "font-family", "font-weight", "font-style",
  "letter-spacing", "textLength",
]);
/** Paint/clip references may only point inside the document: url(#id), never an external resource. */
const svgTransform: sanitizeHtml.Transformer = (tagName, attribs) => ({
  tagName,
  attribs: Object.fromEntries(
    Object.entries(attribs).filter(([, v]) => !/url\(\s*['"]?\s*(?!#)/i.test(v)),
  ),
});

const SANITIZE: sanitizeHtml.IOptions = {
  // prettier-ignore
  allowedTags: [
    "p", "br", "hr", "b", "strong", "i", "em", "u", "s", "sub", "sup", "small", "mark",
    "a", "img", "pre", "code", "kbd", "samp",
    "h1", "h2", "h3", "h4", "h5", "h6",
    "ul", "ol", "li", "dl", "dt", "dd",
    "blockquote", "figure", "figcaption", "picture", "video", "source", "iframe",
    "table", "thead", "tbody", "tr", "th", "td", "span", "div",
    ...SVG_TAGS,
  ],
  allowedAttributes: {
    a: ["href", "title"],
    img: ["src", "srcset", "sizes", "alt", "title", "width", "height"],
    video: ["src", "controls", "poster", "width", "height", "autoplay", "loop", "muted", "playsinline", "preload"],
    // <picture> sources: media queries pick the light/dark or mobile/desktop variant.
    source: ["src", "srcset", "sizes", "media", "type", "width", "height"],
    iframe: ["src", "width", "height", "allow", "allowfullscreen", "frameborder"],
    code: ["class"],
    pre: ["class"],
    th: ["colspan", "rowspan"],
    td: ["colspan", "rowspan"],
    ...Object.fromEntries(SVG_TAGS.map((t) => [t, SVG_ATTRS])),
  },
  // Posts from X are rendered as structured markup the reader styles (see tweetFromPage).
  allowedClasses: { div: ["x-*"], span: ["x-*"], a: ["x-*"], img: ["x-*"] },
  selfClosing: [...sanitizeHtml.defaults.selfClosing, "source"],
  allowedSchemes: ["http", "https", "mailto"],
  // YouTube embeds (/embed/ on any youtube.com host) are rewritten to youtube-nocookie by the iframe
  // transform below; other youtube.com pages (/watch, /redirect) refuse to be framed and are dropped.
  allowedIframeHostnames: ["www.youtube-nocookie.com", "player.vimeo.com"],
  // An iframe whose src was refused (or never had one) would be an empty 16:9 box.
  exclusiveFilter: (frame) => frame.tag === "iframe" && !frame.attribs.src,
  transformTags: {
    // Percentage sizes (width/height="100%" of a player wrapper) would fight the reader's 16:9 box.
    iframe: (tagName, attribs) => ({
      tagName,
      attribs: Object.fromEntries(
        Object.entries({ ...attribs, src: embedSrc(attribs.src) }).filter(([k, v]) => !(/^(?:width|height)$/.test(k) && v.includes("%"))),
      ),
    }),
    a: (tagName, attribs) => ({
      tagName,
      attribs: { ...attribs, target: "_blank", rel: "noopener noreferrer" },
    }),
    img: (tagName, attribs) => ({ tagName, attribs: { ...attribs, loading: "lazy" } }),
    // Looping figure animations often ship without controls and with preload=none: show the first
    // frame and give the reader controls.
    video: (tagName, attribs) => {
      const { poster, ...rest } = attribs;
      const keepPoster = poster && !/fallback|placeholder/i.test(poster);
      return { tagName, attribs: { ...rest, ...(keepPoster ? { poster } : {}), controls: "", preload: "metadata" } };
    },
    ...Object.fromEntries(SVG_TAGS.map((t) => [t, svgTransform])),
  },
};
// allow the attributes injected by transformTags
SANITIZE.allowedAttributes = {
  ...(SANITIZE.allowedAttributes as Record<string, string[]>),
  a: ["href", "title", "target", "rel"],
  img: ["src", "srcset", "sizes", "alt", "title", "width", "height", "loading"],
};

// Player settings for a muted, looping, chrome-less background clip; the reader wants a video to watch.
const BACKGROUND_PLAYER_PARAMS = ["background", "controls", "autoplay", "muted", "mute", "loop", "playlist"];

/**
 * YouTube embeds play from youtube-nocookie (no tracking cookies until play), whatever host the
 * page used. Vimeo and YouTube embeds set up as background clips (background=1, controls=0, or
 * autoplaying muted) get their controls back; `watchable` forces that.
 */
function embedSrc(src: string | undefined, watchable = false): string {
  if (!src) return "";
  try {
    const u = new URL(src, "https://invalid.invalid/");
    const youtube = /^(?:www\.|m\.)?youtube(?:-nocookie)?\.com$/i.test(u.hostname) && u.pathname.startsWith("/embed/");
    const vimeo = /^player\.vimeo\.com$/i.test(u.hostname);
    if (!youtube && !vimeo) return src;
    const q = u.searchParams;
    const background =
      watchable || q.get("background") === "1" || q.get("controls") === "0" || (q.get("autoplay") === "1" && /^1$/.test(q.get("muted") ?? q.get("mute") ?? ""));
    if (background) {
      BACKGROUND_PLAYER_PARAMS.forEach((k) => u.searchParams.delete(k));
      if (vimeo) u.searchParams.set("controls", "1");
    }
    if (youtube) {
      u.protocol = "https:";
      u.hostname = "www.youtube-nocookie.com";
    }
    return background || youtube ? u.toString() : src;
  } catch {
    /* leave it to the hostname check */
  }
  return src;
}

function abs(u: string | null, base: string): string | null {
  if (!u) return null;
  try {
    return new URL(u, base).toString();
  } catch {
    return null;
  }
}

type Doc = ReturnType<typeof parseHTML>["document"];

interface SrcsetCandidate {
  url: string;
  descriptor: string;
}

/** Parse a srcset per the HTML spec's outline: URLs may contain commas (CDN transforms like w_640,c_fill). */
export function parseSrcset(srcset: string): SrcsetCandidate[] {
  const out: SrcsetCandidate[] = [];
  let i = 0;
  while (i < srcset.length) {
    while (i < srcset.length && /[\s,]/.test(srcset[i])) i++;
    if (i >= srcset.length) break;
    let j = i;
    while (j < srcset.length && !/\s/.test(srcset[j])) j++;
    let url = srcset.slice(i, j);
    let descriptor = "";
    if (url.endsWith(",")) {
      url = url.replace(/,+$/, "");
      i = j;
    } else {
      const k = srcset.indexOf(",", j);
      const end = k < 0 ? srcset.length : k;
      descriptor = srcset.slice(j, end).trim();
      i = end + 1;
    }
    if (url) out.push({ url, descriptor });
  }
  return out;
}

function absSrcset(srcset: string, base: string): string {
  return parseSrcset(srcset)
    .map(({ url, descriptor }) => {
      const a = abs(url, base);
      return a ? [a, descriptor].filter(Boolean).join(" ") : "";
    })
    .filter(Boolean)
    .join(", ");
}

/** Largest srcset candidate by w/x descriptor (a bare URL counts as 1x). */
function largestCandidate(srcset: string): string | null {
  let best: { url: string; n: number } | null = null;
  for (const { url, descriptor } of parseSrcset(srcset)) {
    const n = Number.parseFloat(descriptor) || 1;
    if (!best || n > best.n) best = { url, n };
  }
  return best?.url ?? null;
}

// `data-asset` is a custom player's attribute (dreamlabs.ai); other sites use it for asset ids, so
// it is promoted only when it names a media file.
const LAZY_SRC = ["data-src", "data-lazy-src", "data-original", "data-lazy", "data-url", "data-asset"];
const LAZY_SRCSET = ["data-srcset", "data-lazy-srcset"];
const LAZY_POSTER = ["data-poster", "data-lazy-poster"];
const MEDIA_FILE = /\.(?:jpe?g|png|gif|webp|avif|svg|mp4|webm|mov|m4v|ogg|ogv|mp3|m4a)(?:[?#]|$)/i;

const firstAttr = (el: Element, names: string[]) =>
  names
    .map((n) => [n, el.getAttribute(n)] as const)
    .find(([n, v]) => !!v && !v.startsWith("data:") && (n !== "data-asset" || MEDIA_FILE.test(v)))?.[1] ?? null;
const isPlaceholderSrc = (v: string | null) => !v || v.startsWith("data:") || /^about:blank$/i.test(v);

/**
 * Absolutize links and media URLs, and promote lazy-load attributes (data-src, data-srcset,
 * data-poster, ...) to the real ones so media whose src is a placeholder (or missing, srcset-only)
 * still loads. Runs before Readability and again on its output, which can carry URLs it rewrote.
 */
function absolutizeDom(root: Doc | Element, base: string) {
  root.querySelectorAll("a[href]").forEach((el) => {
    const v = abs(el.getAttribute("href"), base);
    if (v) el.setAttribute("href", v);
  });
  root.querySelectorAll("video, iframe").forEach((el) => {
    const lazy = firstAttr(el, LAZY_SRC);
    // A <video> with <source> children plays those; don't add a competing src.
    const hasSources = el.tagName === "VIDEO" && !!el.querySelector("source");
    if (lazy && !hasSources && isPlaceholderSrc(el.getAttribute("src"))) el.setAttribute("src", lazy);
    const poster = el.tagName === "VIDEO" ? firstAttr(el, LAZY_POSTER) : null;
    if (poster && isPlaceholderSrc(el.getAttribute("poster"))) el.setAttribute("poster", poster);
  });
  root.querySelectorAll("img, source").forEach((el) => {
    const lazySet = firstAttr(el, LAZY_SRCSET);
    if (lazySet && !el.getAttribute("srcset")) el.setAttribute("srcset", lazySet);
    const ss = el.getAttribute("srcset");
    if (ss) el.setAttribute("srcset", absSrcset(ss, base));
    const lazy = firstAttr(el, LAZY_SRC);
    if (lazy && isPlaceholderSrc(el.getAttribute("src"))) el.setAttribute("src", lazy);
    // srcset-only images: give them a src so anything that reads src (sanitizer, hero pick) sees one.
    if (el.tagName === "IMG" && isPlaceholderSrc(el.getAttribute("src"))) {
      const fromSet = el.getAttribute("srcset") ? largestCandidate(el.getAttribute("srcset")!) : null;
      if (fromSet) el.setAttribute("src", fromSet);
    }
    const v = abs(el.getAttribute("src"), base);
    if (v) el.setAttribute("src", v);
  });
  root.querySelectorAll("video[src],iframe[src]").forEach((el) => {
    const v = abs(el.getAttribute("src"), base);
    if (v) el.setAttribute("src", v);
  });
  root.querySelectorAll("video[poster]").forEach((el) => {
    const v = abs(el.getAttribute("poster"), base);
    if (v) el.setAttribute("poster", v);
  });
}

// Readability matches class names and ids against two word lists (Readability.REGEXPS
// .unlikelyCandidates and .negative, copied here): an unlikely match deletes the element outright,
// a negative one counts against it and deletes a heading or a non-prose div. Utility-CSS sites trip
// these all the time with styling tokens: `overflow-hidden`, `scroll-mt-[...]` on every OpenAI
// heading, `[--x:var(--header-h)]` on section wrappers. Semantic names (`sidebar`, `comments`,
// `related-posts`, `ad-banner`) are what the lists are for and are kept.
const READABILITY_UNLIKELY =
  /-ad-|ai2html|banner|breadcrumbs|combx|comment|community|cover-wrap|disqus|extra|footer|gdpr|header|legends|menu|related|remark|replies|rss|shoutbox|sidebar|skyscraper|social|sponsor|supplemental|ad-break|agegate|pagination|pager|popup|yom-remote/i;
const READABILITY_NEGATIVE =
  /-ad-|hidden|^hid$|banner|combx|comment|com-|contact|footer|gdpr|masthead|media|meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|widget/i;
const readabilityJunk = (s: string) => READABILITY_UNLIKELY.test(s) || READABILITY_NEGATIVE.test(s);
/** A Tailwind-style utility token: variants (`md:`), arbitrary values (`[...]`, `(...)`), or a styling prefix. */
const UTILITY_CLASS = /[:[\]()@!/]|^-?(?:overflow|overscroll|scroll|snap|object|line-clamp|text|bg|aspect)-/;
// Layout words that say nothing about junk. On content elements (headings, paragraphs, list items,
// figures, inline text) they appear in compound names (`section-header`, `media-caption`,
// `heading-scroll-target`) that never mark the element as boilerplate.
const LAYOUT_NEGATIVE = /hidden|scroll|media|meta|header|extra|masthead|legends|remark|cover-wrap/i;
const CONTENT_TAGS =
  "h1, h2, h3, h4, h5, h6, p, li, dt, dd, figure, figcaption, picture, img, a, span, strong, b, em, i, code, pre, blockquote";
const MEDIA = "img, picture, video, svg";

function dropClassTokens(el: Element, drop: (token: string) => boolean) {
  const tokens = (el.getAttribute("class") ?? "").split(/\s+/).filter(Boolean);
  const kept = tokens.filter((t) => !drop(t));
  if (kept.length !== tokens.length) el.setAttribute("class", kept.join(" "));
}

/**
 * Before Readability: drop (1) utility tokens that match its word lists, anywhere; (2) compound
 * layout-word tokens on content elements, plus an id that would delete a heading (`related-work`);
 * (3) layout words inside figures, text-free media wrappers (`media__container`) and code-block
 * wrappers (`style-scrollbars` around a <pre>).
 */
export function neutralizeReadabilityClasses(root: Doc | Element) {
  root.querySelectorAll("[class]").forEach((el) => dropClassTokens(el, (t) => readabilityJunk(t) && UTILITY_CLASS.test(t)));
  root.querySelectorAll(CONTENT_TAGS).forEach((el) => {
    dropClassTokens(el, (t) => /[-_]/.test(t) && LAYOUT_NEGATIVE.test(t));
    if (/^H[1-6]$/.test(el.tagName) && readabilityJunk(el.getAttribute("id") ?? "")) el.removeAttribute("id");
  });
  const inFigure = (el: Element) => el.tagName === "FIGURE" || !!el.closest("figure");
  const mediaWrapper = (el: Element) => !!el.querySelector(MEDIA) && !(el.textContent ?? "").trim();
  // Text outside the code is at most a toolbar ("JSON", "Copy").
  const codeWrapper = (el: Element) => {
    const pres = [...el.querySelectorAll("pre")];
    const inCode = pres.reduce((n, p) => n + textLen(p.textContent), 0);
    return pres.length > 0 && textLen(el.textContent) - inCode <= 40;
  };
  root.querySelectorAll("[class]").forEach((el) => {
    // A bare `hidden` really is hidden (e.g. the desktop copy of a responsive pair); keep it.
    if (inFigure(el) || mediaWrapper(el) || codeWrapper(el)) dropClassTokens(el, (t) => t !== "hidden" && LAYOUT_NEGATIVE.test(t));
  });
}

// Screen-reader-only text ("(opens in new tab)", "Skip to content") is hidden by a class or an
// inline clip; sanitizing strips both, which would make it visible.
const SR_ONLY_CLASS =
  /^(?:[\w-]*__)?(?:sr-?only|sr-text|visually-?hidden|screen-?reader(?:-?text|-?only)?|a11y-?hidden|assistive-?text|show-for-sr|element-invisible|hidden-visually|u-hidden-visually)(?:__[\w-]+)?$/i;
const SR_ONLY_STYLE = /clip\s*:\s*rect\(\s*0|clip-path\s*:\s*inset\(\s*50%/i;
const ONE_PX = /(?:^|;)\s*(?:width|height)\s*:\s*1px/i;
// Tailwind's responsive undo (`sr-only sm:not-sr-only`): visible from that breakpoint up, so it is
// real text. `focus:not-sr-only` (skip links) stays hidden until focused and still goes.
const RESPONSIVE_NOT_SR_ONLY = /^(?:sm|md|lg|xl|[2-9]xl|min-\[[^\]]*\]|@[\w-]*(?:\/[\w-]+)?):not-sr-only$/;

function isScreenReaderOnly(el: Element): boolean {
  const tokens = (el.getAttribute("class") ?? "").split(/\s+/);
  if (tokens.some((t) => SR_ONLY_CLASS.test(t))) return !tokens.some((t) => RESPONSIVE_NOT_SR_ONLY.test(t));
  const style = el.getAttribute("style") ?? "";
  return SR_ONLY_STYLE.test(style) || (/position\s*:\s*absolute/i.test(style) && ONE_PX.test(style));
}

/**
 * Remove text meant only for screen readers, and aria-hidden icon glyphs (arrows, "↗") that carry
 * no words. Must run while class names are still intact.
 */
export function removeScreenReaderText(root: Doc | Element) {
  for (const el of [...root.querySelectorAll("[class], [style]")]) {
    if (el.isConnected && !el.matches("body, html") && isScreenReaderOnly(el)) el.remove();
  }
  for (const el of [...root.querySelectorAll('span[aria-hidden="true"], i[aria-hidden="true"]')]) {
    if (el.isConnected && !el.querySelector("img, picture, video") && !/[\p{L}\p{N}]/u.test(el.textContent ?? "")) el.remove();
  }
}

// Custom video players leave their controls behind as text: "00:00 / 01:59", "1–13 of 13". The
// separator may be drawn by CSS (`before:content-['|']`), leaving "00:0100:14".
const TIME_CODE = /^\d{1,2}:\d{2}(?::\d{2})?(?:\s*[/|]?\s*\d{1,2}:\d{2}(?::\d{2})?)?$/;
const N_OF_M = /^\d+(?:\s*[–—-]\s*\d+)?\s+of\s+\d+$/i;

const PLAYER_PART = 'video, audio, button, [role="slider"], [role="button"], [aria-live]';

// A time code inside a line of text (a chapter list item, a show-notes paragraph, a table cell) is
// content, even beside a video: player chrome sits in bare divs and spans.
const TEXT_BLOCK = "p, li, dt, dd, td, th, figcaption, blockquote, h1, h2, h3, h4, h5, h6, pre, code";

/** Inside a player or carousel: a live region itself, or near a control or a video (never past `root`). */
function inPlayer(el: Element, root: Doc | Element): boolean {
  if (el.hasAttribute("aria-live")) return true;
  let a: Element | null = el.parentElement;
  for (let i = 0; a && a !== root && i < 4 && !a.matches("body, article, main"); i++, a = a.parentElement) {
    if (a.querySelector(PLAYER_PART)) return true;
  }
  return false;
}

/**
 * Drop media-player chrome: sliders, toolbars, and elements whose whole text is a time code or a
 * counter, when they sit beside player controls (a timestamp in prose or a list stays).
 */
export function removePlayerChrome(root: Doc | Element) {
  for (const el of [...root.querySelectorAll('[role="slider"], [role="toolbar"], [role="progressbar"]')]) {
    if (el.isConnected && !el.matches("body, html")) el.remove();
  }
  for (const el of [...root.querySelectorAll("span, div, output, small, label, p")]) {
    if (!el.isConnected || el.querySelector(MEDIA)) continue;
    const t = (el.textContent ?? "").replace(/\s+/g, " ").trim();
    // A paragraph that is only a time code counts too; one inside a line of text never does.
    if (!t || t.length > 24 || !(TIME_CODE.test(t) || N_OF_M.test(t)) || el.parentElement?.closest(TEXT_BLOCK)) continue;
    if (inPlayer(el, root)) el.remove();
  }
}

/**
 * Code blocks that render each line as its own element with a line-number cell (OpenAI's
 * `<code><pre><div><span>1</span><div>…</div></div>…`), or that sit in a line-number table, come
 * out of Readability as a jumble of paragraphs, numbers glued to the code. Rebuild each as a plain
 * <pre><code> holding the code text, one line per row, numbers dropped.
 */
export function normalizeCodeBlocks(root: Doc | Element) {
  const doc = root.ownerDocument ?? (root as Doc);
  for (const pre of [...root.querySelectorAll("pre")]) {
    if (!pre.isConnected || pre.parentElement?.closest("pre")) continue;
    // Inside <pre> a <br> is a newline; make it one so textContent keeps it.
    pre.querySelectorAll("br").forEach((br) => br.replaceWith("\n"));
    const rows = [...pre.children].filter((c) => !/^(BR|SCRIPT|STYLE)$/.test(c.tagName));
    // Row elements, each led by its line number: drop the numbers, one line per row.
    let text: string | null = null;
    const lineNo = (row: Element, i: number) => {
      const first = row.firstElementChild;
      return first && first !== row.lastElementChild && (first.textContent ?? "").trim() === String(i + 1) ? first : null;
    };
    if (rows.length >= 2 && rows.every((r) => /^(DIV|P|SPAN|LI)$/.test(r.tagName))) {
      const numbered = rows.map(lineNo);
      if (numbered.filter(Boolean).length >= rows.length * 0.8) {
        numbered.forEach((n) => n?.remove());
        text = rows.map((r) => (r.textContent ?? "").replace(/\n$/, "")).join("\n");
      } else if (rows.every((r) => r.tagName === "DIV" || r.tagName === "P")) {
        text = rows.map((r) => (r.textContent ?? "").replace(/\n$/, "")).join("\n");
      }
    }
    // A gutter <pre> of bare sequential numbers next to the code (line-number tables): drop it.
    const t = (pre.textContent ?? "").trim();
    if (/^1(?:\s+\d+)*$/.test(t) && t.split(/\s+/).every((n, i) => Number(n) === i + 1)) {
      const table = pre.closest("table");
      if (table && [...table.querySelectorAll("pre")].some((p) => p !== pre)) {
        (pre.closest("td") ?? pre).remove();
        continue;
      }
    }
    // <code><pre>…</pre></code> is inverted; the outer <code> goes too.
    const outer = pre.parentElement?.tagName === "CODE" && pre.parentElement.children.length === 1 ? pre.parentElement : pre;
    const lang = [outer, pre, pre.querySelector("code")]
      .map((e) => e?.getAttribute("class") ?? "")
      .join(" ")
      .match(/\b(?:language|lang)-[\w+#-]+/)?.[0];
    if (text === null && outer === pre) continue;
    const fresh = doc.createElement("pre");
    const code = doc.createElement("code");
    if (lang) code.setAttribute("class", lang);
    code.textContent = text ?? pre.textContent ?? "";
    fresh.append(code);
    outer.replaceWith(fresh);
  }
  // Line-number tables: once the gutter is gone, a one-cell table is just a wrapper.
  for (const table of [...root.querySelectorAll("table")]) {
    const cells = table.querySelectorAll("td, th");
    const pre = table.querySelector("pre");
    if (cells.length === 1 && pre && (cells[0].textContent ?? "").trim() === (pre.textContent ?? "").trim()) table.replaceWith(pre);
  }
}

const DARK_TOKEN = /^(?!no[-_]|has[-_])(?:[\w-]*[-_])?dark(?:[-_]?mode)?(?:[-_](?:alt|alternative|only|variant|version|image|img))?$/i;

/**
 * Sites that ship a light and a dark copy of a figure side by side and toggle them with CSS
 * (`light-mode` / `dark-mode-alternative`, or Tailwind `dark:hidden` / `hidden dark:block`) would
 * show both here. Keep the light copy; drop the dark one when it has a sibling alternative.
 */
function dropDarkVariants(root: Doc | Element) {
  const isDark = (el: Element) => {
    const tokens = (el.getAttribute("class") ?? "").split(/\s+/);
    if (tokens.some((t) => DARK_TOKEN.test(t))) return true;
    return tokens.includes("hidden") && tokens.some((t) => /^dark:(?!hidden)/.test(t));
  };
  for (const el of [...root.querySelectorAll("img, picture, video")]) {
    if (!el.isConnected || !isDark(el)) continue;
    const siblings = [...(el.parentElement?.children ?? [])].filter((s) => s !== el && s.matches("img, picture, video"));
    if (siblings.some((s) => !isDark(s))) el.remove();
  }
}

const PLACEHOLDER = "https://openfeed.invalid/media/";

/**
 * Readability only understands <img>: a wrapper div holding just a <video> or an inline <svg> chart
 * scores as "no useful content" and is deleted. Stand each one in as a placeholder <img> while
 * Readability runs, then put the originals back with restoreMedia().
 */
function protectMedia(root: Doc | Element): string[] {
  const saved: string[] = [];
  const doc = root.ownerDocument ?? (root as Doc);
  for (const el of [...root.querySelectorAll("video, audio, svg")]) {
    if (!el.isConnected || el.parentElement?.closest("svg, video, audio")) continue;
    if (el.tagName.toLowerCase() === "svg" && isIconSvg(el)) continue;
    const img = doc.createElement("img");
    img.setAttribute("src", `${PLACEHOLDER}${saved.length}`);
    img.setAttribute("alt", el.getAttribute("aria-label") ?? "");
    saved.push(el.outerHTML);
    el.replaceWith(img);
  }
  return saved;
}

function restoreMedia(html: string, saved: string[]): string {
  if (!saved.length) return html;
  const re = new RegExp(`<img[^>]*?src="${PLACEHOLDER.replace(/[.\/]/g, "\\$&")}(\\d+)"[^>]*>`, "g");
  return html.replace(re, (_, i: string) => saved[Number(i)] ?? "");
}

const FIGURE_MEDIA = "img, picture, svg, video, audio, iframe, canvas, object, embed, table, pre, math, noscript";

/**
 * Figures whose graphic is drawn client-side (charts rendered by JavaScript into an empty div)
 * arrive as a caption with nothing above it. When the chart was rendered server-side from the
 * page's own spec (`charts`, keyed by the id of the element it draws into), put that SVG in the
 * empty element. Otherwise say so and link to the figure on the original page, rather than
 * showing a caption for a missing image.
 */
function markClientRenderedFigures(root: Doc | Element, pageUrl: string, charts?: Map<string, string>) {
  root.querySelectorAll("figure").forEach((fig) => {
    const caption = fig.querySelector("figcaption");
    if (!caption || fig.querySelector(FIGURE_MEDIA)) return;
    const body = (fig.textContent ?? "").replace((caption.textContent ?? ""), "").trim();
    if (body) return;
    const targets = [fig, ...fig.querySelectorAll("[id]")].filter((el) => el.getAttribute("id"));
    const drawn = targets.find((el) => charts?.has(el.getAttribute("id")!));
    if (drawn) {
      const svg = charts!.get(drawn.getAttribute("id")!)!;
      if (drawn === fig || drawn.contains(caption)) caption.insertAdjacentHTML("beforebegin", svg);
      else drawn.innerHTML = svg;
      return;
    }
    const id = targets[0]?.getAttribute("id");
    const href = id ? `${pageUrl.split("#")[0]}#${encodeURIComponent(id)}` : pageUrl;
    const doc = fig.ownerDocument;
    const note = doc.createElement("p");
    const em = doc.createElement("em");
    const a = doc.createElement("a");
    a.setAttribute("href", href);
    a.textContent = "original article";
    em.append("Interactive figure not shown here. View it in the ", a, ".");
    note.append(em);
    caption.before(note);
  });
}

const VIDEO_SLOT = "[data-video-container]";

/**
 * Put players that exist only in the RSC payload (findPayloadVideos) into their figures. A figure
 * is matched by its poster <img> (alt text or file name) or an alt-text label, else it is the first
 * figure after the paragraph that precedes the player in the payload, and only if that figure is
 * an empty video slot (a `data-video-container`, or no media and no text). The poster, if any, is
 * replaced; a video the page's HTML already has is left alone; an unmatched video is dropped.
 */
function placePayloadVideos(root: Doc | Element, videos: PayloadVideo[]) {
  if (!videos.length) return;
  const doc = root.ownerDocument ?? (root as Doc);
  const order = new Map([...root.querySelectorAll("*")].map((el, i) => [el, i]));
  const at = (el: Element) => order.get(el) ?? -1;
  const figures = [...root.querySelectorAll("figure")];
  const claimed = new Set<Element>();
  for (const v of videos) {
    if ([...root.querySelectorAll("iframe[src]")].some((f) => (f.getAttribute("src") ?? "").includes(v.key))) continue;
    const names = v.names.map(norm);
    const isPoster = (img: Element) =>
      names.includes(norm(img.getAttribute("alt"))) || (!!v.posterFile && (img.getAttribute("src") ?? "").includes(v.posterFile));
    const open = figures.filter((f) => !claimed.has(f));
    let poster: Element | null = null;
    let fig = open.find((f) => (poster = [...f.querySelectorAll("img")].find(isPoster) ?? null));
    fig ??= open.find((f) => [...f.querySelectorAll("span, div, p")].some((el) => names.includes(norm(el.textContent))));
    if (!fig && v.anchor) {
      const a = norm(v.anchor);
      const para = [...root.querySelectorAll("p, li, blockquote, h2, h3, h4")].find((el) => norm(el.textContent).includes(a));
      const next = para ? open.find((f) => at(f) > at(para)) : undefined;
      const slot = next && !next.querySelector("iframe, video") && (next.querySelector(VIDEO_SLOT) || (!next.querySelector(FIGURE_MEDIA) && !squash(next.textContent)));
      if (slot) fig = next;
    }
    if (!fig) continue;
    claimed.add(fig);
    const iframe = doc.createElement("iframe");
    iframe.setAttribute("src", embedSrc(v.src, true));
    iframe.setAttribute("allow", "fullscreen; picture-in-picture");
    iframe.setAttribute("allowfullscreen", "");
    if (poster) (poster as Element).replaceWith(iframe);
    else {
      const slot = fig.querySelector(VIDEO_SLOT);
      if (slot) slot.replaceChildren(iframe);
      else fig.prepend(iframe);
    }
  }
}

const TINY_IMG = 64;
const AUTHOR_HREF = /\/(authors?|author-profile|people|staff|contributors?)\//i;

const AVATAR_SRC = /gravatar\.com|\/avatars?\/|[?&]s=(?:[1-9]\d?|1[0-2]\d)(?:&|$)/i;
const AVATAR_CLASS = /\b(avatar|author)/i;
const GENERIC_LEAD = /logo|favicon|\bicon|avatar|gravatar|placeholder|default[-_]?(?:og|share|social)/i;

function isTinyImg(img: Element): boolean {
  const w = Number(img.getAttribute("width"));
  const h = Number(img.getAttribute("height"));
  if (w > 0 && h > 0 && w <= TINY_IMG && h <= TINY_IMG) return true;
  return AVATAR_SRC.test(img.getAttribute("src") ?? "") || AVATAR_CLASS.test(img.getAttribute("class") ?? "");
}

/**
 * Inline SVG icons and decoration (copy buttons, arrows, logos): aria-hidden, small declared or
 * viewBox size, or no size at all.
 */
function isIconSvg(svg: Element): boolean {
  if (svg.parentElement?.closest("svg")) return false;
  if (svg.getAttribute("aria-hidden") === "true") return true;
  const w = Number.parseFloat(svg.getAttribute("width") ?? "");
  const h = Number.parseFloat(svg.getAttribute("height") ?? "");
  if (w > 0 && h > 0) return w <= TINY_IMG && h <= TINY_IMG;
  const vb = (svg.getAttribute("viewBox") ?? svg.getAttribute("viewbox") ?? "").trim().split(/[\s,]+/).map(Number);
  if (vb.length === 4 && vb[2] > 0 && vb[3] > 0) return vb[2] <= TINY_IMG && vb[3] <= TINY_IMG;
  return true;
}

/** Site logos and avatars make poor heroes; prefer nothing over those. */
function usableLead(u: string | null): string | null {
  return u && !GENERIC_LEAD.test(u) ? u : null;
}

const squash = (s: string | null | undefined) => (s ?? "").replace(/[\s ]+/g, " ").trim();
const CONTENT_MEDIA = "img, picture, video, audio, svg, iframe, pre, table, canvas, math";
const hasMediaOrText = (el: Element) => !!squash(el.textContent) || el.matches(CONTENT_MEDIA) || !!el.querySelector(CONTENT_MEDIA);

// Boilerplate lines, matched against a block's whole text.
const BOILERPLATE_LINE = [
  /^(?:view|see|read) (?:full |author )?bio$/i,
  /^share(?: this)?(?: (?:article|story|post|page))?:?$/i,
  /^\[email ?protected\]$/i,
];
// A "Related articles" label is boilerplate when its rail is gone (the cards were stripped) and
// what follows has no links; over its own list of links it is part of the article.
const RELATED_LINE = /^(?:related|recommended) (?:articles?|stories|posts|reading|content):?$/i;
// Affiliate disclosures ("When you purchase through links in our articles, we may earn a small commission").
// Only first-person disclosures: an article about affiliate programs ("creators may earn a
// commission") is not one.
// "We earn a commission" alone is also what a company says in a quote, so that form counts only
// beside the links or purchases it is about, and a block holding a quotation is never a disclosure.
const AFFILIATE =
  /\bwhen you (?:buy|purchase|shop|click)\b.{0,80}\b(?:we|us|our)\b.{0,40}\b(?:commission|earn|compensat)|\b(?:links?|purchases?|buy|shop)\b.{0,80}\bwe (?:may |might |could )?(?:earn|receive|get) (?:a |an )?(?:small |affiliate )?(?:commission|share of (?:the )?(?:sales?|revenue))\b|\bwe (?:may |might |could )?(?:earn|receive|get) (?:a |an )?(?:small |affiliate )?(?:commission|share of (?:the )?(?:sales?|revenue))\b.{0,80}\b(?:links?|purchases?|buy|shop)|\b(?:this|our) (?:post|article|page|site|story|newsletter) (?:may )?(?:contains?|includes?|uses?) affiliate links\b/i;
const QUOTATION = /["“”«»]/;
const CF_EMAIL = /\[email ?protected\]/i;
// A trailing author bio: "Ivan covers consumer tech at TechCrunch. He is based out of India."
// A named subject, then a writer's job, or (for "based in", "previously worked") a personal
// pronoun: "Mistral is a French startup based in Paris" is the story's last line, not a bio.
const BIO_LEAD =
  /^(?:[A-Z][\p{L}’'.-]+ ){0,3}[A-Z][\p{L}’'.-]+ (?:is|was|covers|writes|reports|has (?:been|covered|written|reported))\b/u;
const BIO_ROLE = /\b(?:reporter|writer|editor|journalist|correspondent|contributor|columnist|covers|covering)\b/;
const BIO_PLACE = /\b(?:based (?:in|out of)|previously (?:worked|wrote|covered|was))\b/;
const PRONOUN = /\b(?:he|she|they|his|her|their)\b/i;
const isBio = (t: string) => {
  if (!BIO_LEAD.test(t)) return false;
  const head = t.slice(0, 300);
  return BIO_ROLE.test(head) || (BIO_PLACE.test(head) && PRONOUN.test(t));
};
// What sits beside a bio and nowhere else: a profile link, a way to reach the writer. "Follow"
// needs a person or a social network ("Follow the project on GitHub" is an ordinary line).
const BIO_SIGNAL =
  /\bview bio\b|\[email ?protected\]|\b(?:contact|reach|email|verify outreach from)\b.{0,40}\b(?:him|her|them|at)\b|\bfollow (?:him|her|them)\b|\bfollow\b.{0,40}\bon (?:twitter|x|bluesky|mastodon|threads|linkedin|instagram)\b/i;

/** The outermost ancestor (below root) holding exactly the same text: the block a line sits in. */
function lineBlock(el: Element, root: Element): Element {
  const t = squash(el.textContent);
  let b = el;
  while (b.parentElement && b.parentElement !== root && squash(b.parentElement.textContent) === t) b = b.parentElement;
  return b;
}

/**
 * Generic boilerplate Readability leaves in: affiliate disclosures, "View Bio" / "Share this" /
 * "Related articles" lines, Cloudflare's "[email protected]" placeholder, and an author bio at the
 * very end. Only short blocks are touched.
 */
function removeBoilerplate(root: Element) {
  const ps = () => [...root.querySelectorAll("p")].filter((p) => p.isConnected && squash(p.textContent));
  // Trailing bio first, while its signals ("View Bio", the email placeholder) are still there: one
  // of the last three paragraphs reads like a bio and something in that tail is a bio signal.
  // Everything from there to the end goes.
  const tail = ps().slice(-3);
  const start = tail.findIndex((p, i) => {
    const rest = tail.slice(i);
    return (
      isBio(squash(p.textContent)) &&
      rest.every((q) => squash(q.textContent).length <= 400) &&
      rest.some((q) => BIO_SIGNAL.test(squash(q.textContent)) || !!q.querySelector('a[href*="/cdn-cgi/l/email-protection"]'))
    );
  });
  if (start >= 0 && ps().length > tail.length) tail.slice(start).forEach((p) => lineBlock(p, root).remove());
  // Cloudflare-obfuscated addresses: drop a short line holding one, else just the link.
  for (const el of [...root.querySelectorAll('a[href*="/cdn-cgi/l/email-protection"], .__cf_email__')]) {
    if (!el.isConnected) continue;
    const block = el.closest("p, li");
    if (block && squash(block.textContent).length <= 400) block.remove();
    else lineBlock(el, root).remove();
  }
  for (const p of ps()) if (CF_EMAIL.test(squash(p.textContent)) && squash(p.textContent).length <= 400) p.remove();
  for (const el of [...root.querySelectorAll("p, li, div, section, aside, a, span, em, small, h2, h3, h4, h5, h6")]) {
    if (!el.isConnected) continue;
    const t = squash(el.textContent);
    if (t && BOILERPLATE_LINE.some((re) => re.test(t))) lineBlock(el, root).remove();
  }
  for (const el of [...root.querySelectorAll("p, li, div, section, aside, span, strong, b, h2, h3, h4, h5, h6")]) {
    if (!el.isConnected || !RELATED_LINE.test(squash(el.textContent))) continue;
    const block = lineBlock(el, root);
    const next = nextContent(block, root);
    const links = next?.nodeType === 1 && ((next as Element).matches("a[href]") || !!(next as Element).querySelector("a[href]"));
    if (!links) block.remove();
  }
  for (const el of [...root.querySelectorAll("p, li, div, section, aside, small")]) {
    if (!el.isConnected) continue;
    const t = squash(el.textContent);
    if (t.length <= 300 && AFFILIATE.test(t) && !QUOTATION.test(t) && !el.querySelector(CONTENT_MEDIA)) el.remove();
  }
}

const EMBED_PLAYER = 'video, iframe[src*="player.vimeo.com/"], iframe[src*="youtube.com/embed/"], iframe[src*="youtube-nocookie.com/embed/"]';

/**
 * Media left without anything to play (a custom player's <video> whose source we couldn't find)
 * would show as an empty box; a poster still beside its own video shows the frame twice. A player
 * embed's poster is an <img> in the same figure (or close wrapper) that calls itself a poster.
 */
function removeDeadMedia(root: Element) {
  for (const player of [...root.querySelectorAll(EMBED_PLAYER)]) {
    const box = player.closest("figure") ?? player.parentElement?.parentElement ?? null;
    for (const img of [...(box?.querySelectorAll("img") ?? [])]) {
      if (!/\bposter\b/i.test(`${img.getAttribute("alt") ?? ""} ${img.getAttribute("src") ?? ""}`)) continue;
      let gone: Element = img;
      // Its wrappers go too when it was all they held.
      while (gone.parentElement && gone.parentElement !== box && gone.parentElement.children.length === 1 && !squash(gone.parentElement.textContent)) {
        gone = gone.parentElement;
      }
      gone.remove();
    }
  }
  for (const v of [...root.querySelectorAll("video")]) {
    const playable = v.getAttribute("src") || [...v.querySelectorAll("source")].some((s) => s.getAttribute("src"));
    if (!playable) v.remove();
  }
  for (const img of [...root.querySelectorAll("img[src]")]) {
    const src = img.getAttribute("src");
    const siblings = [...(img.parentElement?.querySelectorAll("video[poster]") ?? [])];
    if (siblings.some((v) => v.getAttribute("poster") === src)) img.remove();
  }
}

/** The next node after `node` in document order that holds text or media, staying inside `root`. */
function nextContent(node: Node, root: Element): Node | null {
  const step = (n: Node): Node | null => {
    let cur: Node | null = n;
    while (cur && cur !== root && !cur.nextSibling) cur = cur.parentNode;
    return cur && cur !== root ? cur.nextSibling : null;
  };
  for (let cur = step(node); cur; ) {
    if (cur.nodeType === 3 && squash(cur.textContent)) return cur;
    if (cur.nodeType === 1 && !/^(HR|BR|SCRIPT|STYLE)$/.test((cur as Element).tagName) && hasMediaOrText(cur as Element)) return cur;
    cur = step(cur);
  }
  return null;
}

/**
 * Readability keeps inline author cards (avatar + name + one-line bio) that sit inside the
 * article container, and link-only navigation tables on table-layout sites. Drop both,
 * plus any remaining avatar-sized images, boilerplate lines, and player leftovers. With `base`,
 * URLs are absolutized again first (Readability's output can carry relative ones).
 */
export function cleanArticle(html: string, base?: string): string {
  const { document } = parseHTML(`<div id="__root">${html}</div>`);
  const root = document.getElementById("__root");
  if (!root) return html;
  if (base) absolutizeDom(root, base);
  removeScreenReaderText(root);
  removePlayerChrome(root);
  removeDeadMedia(root);
  const blocks = [...root.querySelectorAll("div, section, aside, p, figure")];
  for (const el of blocks) {
    if (!el.isConnected) continue;
    const text = (el.textContent ?? "").trim();
    if (text.length > 400) continue;
    const hasAvatar = [...el.querySelectorAll("img")].some(isTinyImg);
    const hasAuthorLink = [...el.querySelectorAll("a[href]")].some(
      (a) => AUTHOR_HREF.test(a.getAttribute("href") ?? "") || a.getAttribute("rel") === "author",
    );
    if (hasAvatar || hasAuthorLink) el.remove();
  }
  // After author cards: their profile links are what identifies them.
  removeBoilerplate(root);
  root.querySelectorAll("img").forEach((img) => isTinyImg(img) && img.remove());
  root.querySelectorAll("svg").forEach((svg) => isIconSvg(svg) && svg.remove());
  // Navigation tables (old-school sites): mostly links, little prose.
  for (const table of [...root.querySelectorAll("table")]) {
    if (!table.isConnected) continue;
    const text = (table.textContent ?? "").replace(/\s+/g, " ").trim();
    const links = [...table.querySelectorAll("a[href]")];
    const linkText = links.reduce((n, a) => n + (a.textContent ?? "").trim().length, 0);
    if (links.length >= 4 && text.length > 0 && linkText / text.length > 0.6) table.remove();
  }
  // Section labels left with nothing under them (their section was a stripped table or card):
  // real headings, or short bold "Label:" lines on table-layout sites. A bold run is a label only
  // when it is the whole line: `<li><strong>Context:</strong> You need…</li>` is a lead-in.
  // Whatever follows is looked for in document order, past the wrappers a heading sits in. A label
  // followed by a lower-ranked one (an h2 by its first h3) has content under it.
  const isLabel = (el: Element) => {
    if (/^H[1-6]$/.test(el.tagName)) return true;
    if (!/^(B|STRONG|P)$/.test(el.tagName) || !/^[^.]{1,40}:$/.test(squash(el.textContent))) return false;
    return el.tagName === "P" || squash(el.parentElement?.textContent) === squash(el.textContent);
  };
  const rank = (el: Element) => (/^H[1-6]$/.test(el.tagName) ? Number(el.tagName[1]) : 7);
  const leadingLabel = (n: Node | null): Element | null => {
    for (let el = n?.nodeType === 1 ? (n as Element) : null; el; ) {
      if (isLabel(el)) return el;
      if (el.matches(CONTENT_MEDIA)) return null;
      const first: ChildNode | undefined = [...el.childNodes].find((c) =>
        c.nodeType === 3 ? !!squash(c.textContent) : c.nodeType === 1 && hasMediaOrText(c as Element),
      );
      el = first?.nodeType === 1 ? (first as Element) : null;
    }
    return null;
  };
  for (const h of [...root.querySelectorAll("h1, h2, h3, h4, h5, h6, b, strong, p")]) {
    if (!h.isConnected || !isLabel(h)) continue;
    const block = lineBlock(h, root);
    const next = nextContent(block, root);
    const label = leadingLabel(next);
    if (!next || (label && rank(label) <= rank(h))) block.remove();
  }
  return root.innerHTML;
}

export function sanitizeArticle(html: string): string {
  return sanitizeHtml(html, SANITIZE);
}

export interface ExtractResult {
  contentHtml: string | null;
  leadImage: string | null;
  /** True when contentHtml came from the Jina Reader rendered-page fallback. */
  rendered?: boolean;
}

// Content-ish class tokens (post-content, entry-content, article-body, story-text). Tokens naming
// side content (comment-content, related-posts, card-body) never group article parts.
const CONTENT_TOKEN = /(?:^|[-_])(?:content|body|text|article|entry|story|post|prose|copy)(?:[-_]|$)/i;
const SIDE_TOKEN = /comment|repl|related|sidebar|footer|header|nav|menu|teaser|card|excerpt|summary|preview|promo|widget|share|caption|meta|author|bio|tag/i;
const MAX_SPLIT_DEPTH = 4;
// A comment thread: its comment bodies often share the article's content class (Tailwind `prose`).
const COMMENT_TOKEN = /^(?:[\w-]*[-_])?(?:comments?|comment-?list|repl(?:y|ies)|disqus|discussions?|responses)(?:[-_][\w-]*)?$/i;
const MAX_TEXT_BETWEEN = 200;

const textLen = (s: string | null | undefined) => (s ?? "").replace(/\s+/g, " ").trim().length;
const proseLen = (el: Element) => [...el.querySelectorAll("p")].reduce((n, p) => n + textLen(p.textContent), 0);

/** The next node after `node`'s subtree in document order. */
function nextOutside(node: Node): Node | null {
  let n: Node | null = node;
  while (n && !n.nextSibling) n = n.parentNode;
  return n?.nextSibling ?? null;
}

/**
 * What sits between two elements in document order, outside both: its text length and whether it
 * holds a heading (a heading between two blocks means they are separate stories, as on a listing).
 */
function between(a: Element, b: Element): { text: number; heading: boolean } {
  let text = 0;
  let heading = false;
  let cur = nextOutside(a);
  while (cur && cur !== b) {
    if (cur.contains(b)) {
      cur = cur.firstChild;
      continue;
    }
    if (cur.nodeType === 1) {
      const el = cur as Element;
      if (!/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(el.tagName)) {
        text += textLen(el.textContent);
        if (el.matches("h1, h2, h3") || el.querySelector("h1, h2, h3")) heading = true;
      }
    } else if (cur.nodeType === 3) {
      text += textLen(cur.textContent);
    }
    cur = nextOutside(cur);
  }
  return { text, heading };
}

function depthBelow(el: Element, ancestor: Element): number {
  let d = 0;
  for (let n: Element | null = el; n && n !== ancestor; n = n.parentElement) d++;
  return d;
}

/** True when `el` or an ancestor below `stop` is a comment thread (by tag, class token or id). */
function inComments(el: Element, stop: Element | null): boolean {
  for (let n: Element | null = el; n && n !== stop; n = n.parentElement) {
    const names = [...(n.getAttribute("class") ?? "").split(/\s+/), n.getAttribute("id") ?? ""];
    if (names.some((t) => t && COMMENT_TOKEN.test(t))) return true;
  }
  return false;
}

function commonAncestor(els: Element[]): Element | null {
  let anc: Element | null = els[0].parentElement;
  while (anc && !els.every((e) => anc!.contains(e))) anc = anc.parentElement;
  return anc;
}

/**
 * Some sites split one article across several containers with the same content class (Ars Technica
 * cuts the body into `.post-content` blocks with ads between them). Readability keeps the single
 * best-scoring container, so the article comes out cut short. Join such blocks into the first one
 * when they are near-siblings in the same <article> (or none), each holds prose, and nothing but
 * a little text (ads, labels) and no heading separates them. Blocks inside a comment thread never
 * join.
 */
export function mergeSplitContainers(root: Doc | Element) {
  const groups = new Map<string, Element[]>();
  for (const el of root.querySelectorAll("div[class], section[class], article[class]")) {
    for (const t of (el.getAttribute("class") ?? "").split(/\s+/)) {
      if (!t || !CONTENT_TOKEN.test(t) || SIDE_TOKEN.test(t) || UTILITY_CLASS.test(t)) continue;
      const key = t.toLowerCase();
      groups.set(key, [...(groups.get(key) ?? []), el]);
    }
  }
  for (const members of groups.values()) {
    const live = members.filter((m) => m.isConnected);
    // Outermost only: a .post-content nested in another .post-content is part of it already.
    const outer = live.filter((m) => !live.some((o) => o !== m && o.contains(m)));
    if (outer.length < 2) continue;
    // Comment bodies are never part of the article, wherever they sit.
    const top = commonAncestor(outer);
    const blocks = outer.filter((b) => !inComments(b, top));
    if (blocks.length < 2 || blocks.some((b) => proseLen(b) < 80)) continue;
    const art = blocks[0].closest("article");
    if (blocks.some((b) => b.closest("article") !== art)) continue;
    const anc = commonAncestor(blocks);
    if (!anc || blocks.some((b) => depthBelow(b, anc) > MAX_SPLIT_DEPTH)) continue;
    const gaps = blocks.slice(1).map((b, i) => between(blocks[i], b));
    if (gaps.some((g) => g.heading || g.text > MAX_TEXT_BETWEEN)) continue;
    const [first, ...rest] = blocks;
    for (const b of rest) {
      first.append(...b.childNodes);
      b.remove();
    }
  }
}

const norm = (s: string | null | undefined) => (s ?? "").replace(/\s+/g, " ").trim().toLowerCase();
const REGION_MIN_PROSE = 400;

/** The article's title <h1>: the one matching og:title / <title>, or the page's only <h1>. */
function headline(document: Doc): Element | null {
  const title = norm(
    document.querySelector('meta[property="og:title"]')?.getAttribute("content") ?? document.querySelector("title")?.textContent,
  );
  const h1s = [...document.querySelectorAll("h1")].filter((h) => norm(h.textContent));
  return (
    h1s.find((h) => title && (title.includes(norm(h.textContent)) || norm(h.textContent).includes(title))) ??
    (h1s.length === 1 ? h1s[0] : null)
  );
}

const VIDEO_EMBED = 'iframe[src*="player.vimeo.com/video/"], iframe[src*="youtube.com/embed/"], iframe[src*="youtube-nocookie.com/embed/"], video';
const HERO_MAX_EMBEDS = 3;
/** Text allowed between a hero video placed above the headline and the headline itself (a kicker, a date). */
const HERO_MAX_TEXT_BEFORE = 200;

interface HeroVideo {
  html: string;
  /** What identifies the video in extracted HTML (a Vimeo/YouTube id, or the file URL). */
  key: string;
  /** Paragraph texts before and after it: the whole article body must come after a hero. */
  before: Set<string>;
  after: Set<string>;
}

function videoKey(el: Element): string | null {
  if (el.tagName === "VIDEO") {
    const src = el.getAttribute("src") || el.querySelector("source[src]")?.getAttribute("src");
    return src && !src.startsWith("data:") ? src : null;
  }
  const m = /(?:player\.vimeo\.com\/video|\/embed)\/([\w-]+)/.exec(el.getAttribute("src") ?? "");
  return m?.[1] ?? null;
}

/**
 * A video at the top of the page, in the header around the headline (OpenAI's hero Vimeo clip):
 * Readability drops it with the rest of the header. Candidates are the first few video embeds after
 * the <h1>, or just above it; extractFromHtml keeps one only if the article body starts right after
 * it (heroVideoFirst). Call after absolutizeDom, before Readability.
 */
function findHeroVideos(document: Doc): HeroVideo[] {
  const h1 = headline(document);
  if (!h1) return [];
  // Document order by index (linkedom's compareDocumentPosition is unreliable across subtrees).
  const order = new Map([...document.querySelectorAll("*")].map((el, i) => [el, i]));
  const at = (el: Element) => order.get(el) ?? -1;
  const paras = [...document.querySelectorAll("p")];
  const out: HeroVideo[] = [];
  for (const el of document.querySelectorAll(VIDEO_EMBED)) {
    if (out.length >= HERO_MAX_EMBEDS || el.closest("nav, footer, aside")) continue;
    const key = videoKey(el);
    if (!key || h1.contains(el)) continue;
    if (at(el) < at(h1) && between(el, h1).text > HERO_MAX_TEXT_BEFORE) continue;
    const box = el.closest("figure") ?? el;
    const end = at(box) + box.querySelectorAll("*").length;
    const before = new Set<string>();
    const after = new Set<string>();
    for (const p of paras) {
      const t = norm(p.textContent);
      if (t.length >= 40) (at(p) < at(box) ? before : at(p) > end ? after : null)?.add(t);
    }
    if (!after.size) continue;
    out.push({ html: el.outerHTML, key, before, after });
  }
  return out;
}

/**
 * Put the hero video first when the whole extraction comes after it on the page (its first
 * paragraph follows the video; extraction keeps page order) and doesn't have it already.
 */
function heroVideoFirst(clean: string, heroes: HeroVideo[]): string {
  if (!heroes.length) return clean;
  const first = paragraphTexts(parseHTML(`<!doctype html><html><body>${clean}</body></html>`).document)[0];
  const hero = first ? heroes.find((h) => h.after.has(first) && !h.before.has(first) && !clean.includes(h.key)) : undefined;
  const html = hero ? sanitizeArticle(hero.html).trim() : "";
  return html ? html + clean : clean;
}

/**
 * The page region the headline belongs to: the nearest ancestor of the title <h1> that holds real
 * prose. Null when the headline can't be identified or the region is the whole page.
 */
function headlineRegion(document: Doc): Element | null {
  const h1 = headline(document);
  for (let el = h1?.parentElement ?? null; el && !/^(BODY|HTML)$/.test(el.tagName); el = el.parentElement) {
    if (proseLen(el) >= REGION_MIN_PROSE) return el;
  }
  return null;
}

/** Paragraph texts (long enough to be distinctive) in an HTML fragment or element. */
function paragraphTexts(root: Doc | Element): string[] {
  return [...root.querySelectorAll("p")].map((p) => norm(p.textContent)).filter((t) => t.length >= 40);
}

/**
 * True when Readability's pick lies outside the headline's region and doesn't contain it either:
 * it chose a different block of the page (a legal disclaimer, a related-posts rail) over the story.
 */
export function pickedOutsideRegion(contentHtml: string, regionHtml: string): boolean {
  const picked = parseHTML(`<!doctype html><html><body>${contentHtml}</body></html>`).document;
  const region = parseHTML(`<!doctype html><html><body>${regionHtml}</body></html>`).document;
  const regionText = norm(region.body.textContent);
  const pickedText = norm(picked.body.textContent);
  const pickedParas = paragraphTexts(picked);
  const regionParas = paragraphTexts(region);
  if (!pickedParas.length || !regionParas.length) return false;
  const inside = pickedParas.filter((p) => regionText.includes(p)).length / pickedParas.length;
  const covered = regionParas.filter((p) => pickedText.includes(p)).length / regionParas.length;
  return inside < 0.3 && covered < 0.5;
}

const plainText = (html: string | null | undefined) => (html ?? "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();

function runReadability(document: Doc, media: string[], base: string): string | null {
  // Readability's types expect a DOM Document; linkedom is compatible at runtime.
  const article = new Readability(document as unknown as Document, { charThreshold: 200 }).parse();
  if (!article?.content) return null;
  return sanitizeArticle(cleanArticle(restoreMedia(article.content, media), base)).trim() || null;
}

/** Page-wide cleanup that must happen while the page's class names and structure are intact. */
function prepareDom(root: Doc | Element, base: string, pageUrl: string, charts?: Map<string, string>, videos: PayloadVideo[] = []) {
  absolutizeDom(root, base);
  removeScreenReaderText(root);
  removePlayerChrome(root);
  normalizeCodeBlocks(root);
  dropDarkVariants(root);
  markClientRenderedFigures(root, pageUrl, charts);
  placePayloadVideos(root, videos);
}

const escapeHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** A headline-region extraction shorter than this is a dek or a teaser, not the story. */
const REGION_MIN_TEXT = 500;

/**
 * Extract main article from raw HTML. Pure; no network.
 *
 * Which candidate wins (the feed's own copy is weighed later, in preferFeed):
 * 1. Readability over the whole page, after article bodies split across same-class containers are
 *    joined (mergeSplitContainers). This is the default.
 * 2. Readability scoped to the headline's region (headlineRegion) replaces (1) when (1) lies outside
 *    that region and doesn't contain it (pickedOutsideRegion), and the scoped run keeps at least
 *    REGION_MIN_TEXT characters and half as much text as (1). Readability then scored some other
 *    block of prose (a legal disclaimer, a related-posts rail) above the story under the headline.
 *
 * `charts` holds SVGs for client-drawn charts (renderPageCharts), keyed by the element id each one
 * draws into; it is computed beforehand because rendering is async.
 */
export function extractFromHtml(html: string, pageUrl: string, charts?: Map<string, string>): ExtractResult {
  const { document } = parseHTML(html);
  const base = abs(document.querySelector("base[href]")?.getAttribute("href") ?? null, pageUrl) ?? pageUrl;
  const og =
    document.querySelector('meta[property="og:image"]')?.getAttribute("content") ??
    document.querySelector('meta[name="twitter:image"]')?.getAttribute("content") ??
    null;
  const lead = usableLead(abs(og, base));
  prepareDom(document, base, pageUrl, charts, findPayloadVideos(html));
  const heroes = findHeroVideos(document);
  const media = protectMedia(document);
  neutralizeReadabilityClasses(document);
  mergeSplitContainers(document);
  // Serialize before Readability runs: it rewrites the document in place.
  const regionHtml = headlineRegion(document)?.outerHTML ?? null;
  const title = document.querySelector("title")?.textContent ?? "";
  let clean = runReadability(document, media, base);
  if (regionHtml && (!clean || pickedOutsideRegion(clean, regionHtml))) {
    const scoped = parseHTML(
      `<!doctype html><html><head><title>${escapeHtml(title)}</title></head><body>${regionHtml}</body></html>`,
    ).document;
    const alt = runReadability(scoped, media, base);
    const n = plainText(alt).length;
    if (alt && n >= REGION_MIN_TEXT && n >= 0.5 * plainText(clean).length) clean = alt;
  }
  if (!clean) return { contentHtml: null, leadImage: lead };
  clean = heroVideoFirst(clean, heroes);
  return { contentHtml: clean, leadImage: lead ?? firstImage(clean) };
}

/** Feed HTML replaces the page's extraction when it is clearly the fuller copy of the article. */
const FEED_WIN_RATIO = 1.5;
const FEED_WIN_MIN_EXTRA = 500;

/**
 * The rule for page vs. feed: the feed's content:encoded wins only when its text is at least
 * FEED_WIN_RATIO times the page extraction's and FEED_WIN_MIN_EXTRA characters longer (and is
 * itself a full article, not a teaser). A page whose extraction came out empty loses to any
 * full-length feed copy.
 */
export function preferFeed(pageHtml: string | null, feedHtml: string | null): boolean {
  const f = plainText(feedHtml).length;
  const p = plainText(pageHtml).length;
  return f >= MIN_FEED_TEXT && f >= p * FEED_WIN_RATIO && f - p >= FEED_WIN_MIN_EXTRA;
}

/**
 * Article HTML that came from the feed itself (content:encoded). No Readability: the feed already
 * holds just the article. Returns null when it is only a teaser.
 */
export function extractFromFeedHtml(html: string, pageUrl: string): ExtractResult {
  const { document } = parseHTML(`<!doctype html><html><body><div id="__root">${html}</div></body></html>`);
  const root = document.getElementById("__root");
  if (!root) return { contentHtml: null, leadImage: null };
  prepareDom(root, pageUrl, pageUrl);
  const clean = sanitizeArticle(cleanArticle(root.innerHTML, pageUrl)).trim();
  if (plainText(clean).length < MIN_FEED_TEXT) return { contentHtml: null, leadImage: null };
  return { contentHtml: clean, leadImage: firstImage(clean) };
}

/** Feed HTML shorter than this is a summary, not the article. */
const MIN_FEED_TEXT = 500;

// The content route has maxDuration = 20s; keep plain fetch + fallback inside this budget.
const TOTAL_BUDGET_MS = 18_000;
const RENDER_TIMEOUT_MS = 12_000;
const MIN_RENDER_MS = 2_000;
const FEED_TIMEOUT_MS = 4_000;
/** Once the page has an article, how much longer the feed copy may take to be weighed against it. */
const FEED_GRACE_MS = 750;

/** `p`'s value, or null if it hasn't settled within `ms`. */
function within<T>(p: Promise<T | null>, ms: number): Promise<T | null> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<null>((resolve) => {
    timer = setTimeout(() => resolve(null), ms);
  });
  return Promise.race([p, late]).finally(() => clearTimeout(timer));
}

/** Where the item came from, so a page that can't be fetched can fall back to the feed's own HTML. */
export interface FeedRef {
  feedUrl: string;
  guid: string;
}

async function extractFromFeed(url: string, feed: FeedRef, ms: number): Promise<ExtractResult | null> {
  const res = await fetchWithTimeout(feed.feedUrl, ms, {
    headers: { Accept: "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.5" },
  });
  if (!res.ok) return null;
  const html = await findFeedItemHtml(await res.text(), { guid: feed.guid, url });
  if (!html) return null;
  const out = extractFromFeedHtml(html, url);
  return out.contentHtml ? out : null;
}

async function extractPlain(url: string): Promise<ExtractResult> {
  let res = await fetchWithTimeout(url, EXTRACT_TIMEOUT_MS, {
    headers: { Accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5" },
  });
  // Some sites refuse bot User-Agents; retry once as a browser. Skip Cloudflare's JavaScript
  // challenge, which no header change passes (the Jina fallback handles those).
  if ((res.status === 401 || res.status === 403) && res.headers.get("cf-mitigated") !== "challenge") {
    res = await fetchWithTimeout(url, EXTRACT_TIMEOUT_MS, { headers: BROWSER_HEADERS });
  }
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const ct = res.headers.get("content-type") ?? "";
  if (ct && !/html|xml/i.test(ct)) throw new Error(`Unsupported content type: ${ct}`);
  const html = await res.text();
  return extractFromHtml(html, res.url || url, await renderPageCharts(html));
}

// README badges (build status, chat, version): never a hero.
const BADGE_HOST = /(?:^|\.)(?:shields\.io|badgen\.net|badge\.fury\.io|travis-ci\.(?:org|com)|circleci\.com|codecov\.io|coveralls\.io|readthedocs\.org|deepwiki\.com|snyk\.io|bestpractices\.dev)$/i;
const BADGE_PATH = /\/badges?(?:\/|\.svg)|[/_-]badge\.svg(?:[?#]|$)|\/workflows\/[^/]+\/badge/i;

function isBadge(img: Element): boolean {
  const src = img.getAttribute("src") ?? "";
  try {
    const u = new URL(src);
    if (BADGE_HOST.test(u.hostname) || BADGE_PATH.test(u.pathname)) return true;
  } catch {
    /* relative or broken: judge by size only */
  }
  // A strip: far wider than tall and short (badges, dividers, wordmarks).
  const w = Number(img.getAttribute("width"));
  const h = Number(img.getAttribute("height"));
  return w > 0 && h > 0 && h <= 40 && w / h >= 3;
}

/** First content image that is big enough to be a hero (declared width ≥ 400, or undeclared). */
export function firstImage(html: string): string | null {
  const imgs = [...parseHTML(`<!doctype html><html><body>${html}</body></html>`).document.querySelectorAll("img[src]")];
  for (const img of imgs) {
    const w = Number(img.getAttribute("width"));
    const src = img.getAttribute("src") ?? "";
    if (isTinyImg(img) || isBadge(img) || (w > 0 && w < 400) || GENERIC_LEAD.test(src)) continue;
    return src;
  }
  return null;
}

/** Render a JavaScript-only page via Jina Reader (returns the rendered DOM as HTML) and extract from it. */
async function extractRendered(url: string, ms: number): Promise<ExtractResult | null> {
  const headers: Record<string, string> = { Accept: "text/html", "X-Return-Format": "html" };
  const key = process.env.JINA_API_KEY;
  if (key) headers.Authorization = `Bearer ${key}`;
  const res = await fetchWithTimeout(`https://r.jina.ai/${url}`, ms, { headers });
  if (!res.ok) return null;
  const html = await res.text();
  const out = extractFromHtml(html, url, await renderPageCharts(html));
  if (!out.contentHtml || isLoginWall(out.contentHtml)) return null;
  return { ...out, rendered: true };
}

const LOGIN_WALL = /\b(log ?in|sign ?in|sign ?up)\b.{0,40}\b(sign ?up|continue|to (?:see|view|read))/i;

/** Rendered pages behind an auth wall come back as a short page about logging in. */
function isLoginWall(html: string): boolean {
  const text = html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");
  return text.length < 2500 && LOGIN_WALL.test(text);
}

const TWEET_RE = /^https?:\/\/(?:www\.|mobile\.)?(?:twitter|x)\.com\/([^/]+)\/status\/(\d+)/i;

/**
 * Posts on X. The status page is server-rendered with the post's data as an escaped JSON blob:
 * the full text (long posts live under note_tweet) and the t.co link expansions. The official
 * oEmbed is the fallback; it truncates long posts.
 */
async function extractTweet(url: string): Promise<ExtractResult | null> {
  const m = TWEET_RE.exec(url);
  if (!m) return null;
  const canonical = `https://x.com/${m[1]}/status/${m[2]}`;
  try {
    const page = await tweetFromPage(canonical, m[1]);
    if (page) return page;
  } catch {
    /* fall back to oEmbed */
  }
  const api = `https://publish.twitter.com/oembed?url=${encodeURIComponent(canonical)}&omit_script=true&dnt=true`;
  const res = await fetchWithTimeout(api, EXTRACT_TIMEOUT_MS, { headers: { Accept: "application/json" } });
  if (!res.ok) return null;
  const data = (await res.json()) as { html?: string; author_name?: string; author_url?: string };
  if (!data.html) return null;
  const { document } = parseHTML(`<div id="__root">${data.html}</div>`);
  const root = document.getElementById("__root");
  if (!root) return null;
  const body = root.querySelector("blockquote p")?.innerHTML ?? "";
  if (!body.trim()) return null;
  const by = data.author_name ? `<p><a href="${data.author_url ?? canonical}">${data.author_name}</a> on X</p>` : "";
  const html = sanitizeArticle(`<blockquote><p>${body}</p></blockquote>${by}`).trim();
  return html ? { contentHtml: html, leadImage: null } : null;
}

/** A JSON string value embedded in X's escaped page data: `\"key\":\"...\"` in the raw HTML. */
function escapedJsonString(raw: string, key: string, from = 0): string | null {
  const re = new RegExp(`\\\\"${key}\\\\":\\\\"((?:\\\\\\\\.|[^\\\\])*?)\\\\"`, "g");
  re.lastIndex = from;
  const m = re.exec(raw);
  if (!m) return null;
  try {
    // Two layers: a JSON string literal holding JSON-escaped text.
    const inner = JSON.parse(`"${m[1]}"`) as string;
    return JSON.parse(`"${inner}"`) as string;
  } catch {
    return null;
  }
}

/** Post text from X's escaped page data within [from, to): long posts keep the full text under NoteTweet. */
function tweetText(raw: string, from: number, to: number): string | null {
  const region = raw.slice(from, to);
  const note = region.indexOf('\\"NoteTweet\\"');
  return (note >= 0 ? escapedJsonString(region, "text", note) : null) ?? escapedJsonString(region, "full_text");
}

/** X account data after `from`: avatar, name and handle sit together in the page data. */
function tweetUser(raw: string, from: number): { name: string; handle: string; avatar: string | null } | null {
  const re = /(?:\\"avatar\\":\{\\"image_url\\":\\"([^"\\]*)\\"\},)?\\"core\\":\{\\"name\\":\\"((?:\\\\.|[^\\])*?)\\",\\"screen_name\\":\\"([A-Za-z0-9_]+)\\"/g;
  re.lastIndex = from;
  const m = re.exec(raw);
  if (!m) return null;
  try {
    const name = JSON.parse(`"${JSON.parse(`"${m[2]}"`)}"`) as string;
    return { name, handle: m[3], avatar: m[1] ? m[1].replace(/_normal(\.\w+)$/, "_bigger$1") : null };
  } catch {
    return null;
  }
}

/** `\"created_at_ms\":1792865465000` after `from`, as a date line. */
function tweetDate(raw: string, from: number): string | null {
  const re = /\\"created_at_ms\\":(\d{10,})/g;
  re.lastIndex = from;
  const m = re.exec(raw);
  if (!m) return null;
  return new Date(Number(m[1])).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
}

/** A string binding of the post's link card: `\"key\":\"title\",\"value\":{\"string_value\":\"...\"`. */
function cardString(card: string, key: string): string | null {
  const re = new RegExp(`\\\\"key\\\\":\\\\"${key}\\\\",\\\\"value\\\\":\\{\\\\"string_value\\\\":\\\\"((?:\\\\\\\\.|[^\\\\])*?)\\\\"`);
  const m = re.exec(card);
  if (!m) return null;
  try {
    return JSON.parse(`"${JSON.parse(`"${m[1]}"`)}"`) as string;
  } catch {
    return null;
  }
}

type TweetLinks = Map<string, { display: string; expanded: string }>;

function whoHtml(u: { name: string; handle: string; avatar: string | null }, date: string | null): string {
  const av = u.avatar ? `<img class="x-avatar" src="${escapeHtml(u.avatar)}" alt="">` : "";
  const when = date ? `<span class="x-when">· ${escapeHtml(date)}</span>` : "";
  return `<div class="x-who">${av}<span class="x-name">${escapeHtml(u.name)}</span><a class="x-handle" href="https://x.com/${u.handle}">@${u.handle}</a>${when}</div>`;
}

function bodyHtml(text: string, links: TweetLinks, drop?: string | null): string {
  const paras = text
    .split(/\n\s*\n/)
    .map((p) => (drop ? p.replace(drop, "") : p).trim())
    .filter(Boolean);
  return `<div class="x-body">${paras.map((p) => `<p>${tweetInline(p, links)}</p>`).join("")}</div>`;
}

/**
 * A post rendered as a post: author row, text, the quoted post as a card, the link card, a
 * footer. The reader styles the x-* classes and drops its headline for these.
 */
async function tweetFromPage(canonical: string, user: string): Promise<ExtractResult | null> {
  const res = await fetchWithTimeout(canonical, EXTRACT_TIMEOUT_MS, { headers: BROWSER_HEADERS });
  if (!res.ok) return null;
  const raw = await res.text();
  // The quoted post's data is nested inside the main post's, after its own fields.
  const qi = raw.indexOf('\\"quoted_tweet_results\\"');
  const end = qi >= 0 ? qi : raw.length;
  const text = tweetText(raw, 0, end);
  if (!text?.trim()) return null;
  const links: TweetLinks = new Map();
  const linkRe = /\\"display_url\\":\\"([^"\\]*)\\",\\"expanded_url\\":\\"([^"\\]*)\\",\\"indices\\":\[\d+,\d+\],\\"url\\":\\"([^"\\]*)\\"/g;
  for (let lm = linkRe.exec(raw); lm; lm = linkRe.exec(raw)) links.set(lm[3], { display: lm[1], expanded: lm[2] });

  const ogName = /<meta property="og:title" content="([^"]*?)(?: \(@[^)]*\))?(?: on X)?"/.exec(raw)?.[1];
  const author = tweetUser(raw, 0) ?? { name: ogName ?? `@${user}`, handle: user, avatar: null };

  // Link card (main post only: its data comes before the quoted post's).
  let card = "";
  let cardUrl: string | null = null;
  const ci = raw.indexOf('\\"binding_values\\"');
  if (ci >= 0 && ci < end) {
    const region = raw.slice(ci, Math.min(ci + 6000, end));
    const title = cardString(region, "title");
    const domain = cardString(region, "vanity_url") ?? cardString(region, "domain");
    cardUrl = cardString(region, "card_url");
    const img = /\\"key\\":\\"thumbnail_image_large\\",\\"value\\":\{\\"image_value\\":\{\\"height\\":\d+,\\"url\\":\\"([^"\\]*)\\"/.exec(region)?.[1];
    const href = (cardUrl && links.get(cardUrl)?.expanded) ?? cardUrl;
    if (title && href) {
      const pic = img ? `<img class="x-card-img" src="${escapeHtml(img)}" alt="">` : "";
      card = `<a class="x-card" href="${escapeHtml(href)}">${pic}<span class="x-card-text"><span class="x-card-domain">${escapeHtml(domain ?? new URL(href).hostname)}</span><span class="x-card-title">${escapeHtml(title)}</span></span></a>`;
    }
  }

  let quoted = "";
  if (qi >= 0) {
    const qid = /\\"rest_id\\":\\"(\d+)\\"/.exec(raw.slice(qi, qi + 400))?.[1];
    const qu = tweetUser(raw, qi);
    const qt = tweetText(raw, qi, raw.length);
    if (qu && qt?.trim()) {
      const href = qid ? `https://x.com/${qu.handle}/status/${qid}` : `https://x.com/${qu.handle}`;
      quoted = `<div class="x-quote">${whoHtml(qu, tweetDate(raw, qi))}${bodyHtml(qt, links)}<a class="x-quote-link" href="${href}">View post</a></div>`;
    }
  }

  const foot = `<div class="x-foot"><span>${escapeHtml(tweetDate(raw, 0) ?? "")}</span><a class="x-open" href="${canonical}">Open on X</a></div>`;
  const html = sanitizeArticle(
    `<div class="x-post">${whoHtml(author, null)}${bodyHtml(text, links, card ? cardUrl : null)}${quoted}${card}${foot}</div>`,
  ).trim();
  return html ? { contentHtml: html, leadImage: null } : null;
}

/** Escape a paragraph of post text; link URLs (t.co expanded) and @mentions; keep line breaks. */
function tweetInline(p: string, links: TweetLinks): string {
  return p
    .split(/(https?:\/\/\S+|@[A-Za-z0-9_]{1,15})/)
    .map((tok, i) => {
      if (i % 2 === 0) return escapeHtml(tok).replace(/\n/g, "<br>");
      if (tok.startsWith("@")) return `<a href="https://x.com/${tok.slice(1)}">${tok}</a>`;
      const l = links.get(tok);
      const href = l?.expanded ?? tok;
      return `<a href="${escapeHtml(href)}">${escapeHtml(l?.display ?? tok)}</a>`;
    })
    .join("");
}

export async function extractArticle(url: string, feed?: FeedRef): Promise<ExtractResult> {
  if (TWEET_RE.test(url)) {
    try {
      const t = await extractTweet(url);
      if (t) return t;
    } catch {
      /* fall through to the normal path */
    }
  }
  const started = Date.now();
  // The feed's copy is fetched alongside the page: it is both the fallback when the page fails and
  // the yardstick for a page extraction that came out cut short (preferFeed). hnrss items carry only
  // points and comment counts, never the article, so their feed is not fetched.
  const fromFeed: Promise<ExtractResult | null> =
    feed && !isHnFeed(feed.feedUrl) ? extractFromFeed(url, feed, FEED_TIMEOUT_MS).catch(() => null) : Promise.resolve(null);
  let plain: ExtractResult | null = null;
  let plainError: unknown = null;
  try {
    plain = await extractPlain(url);
  } catch (e) {
    plainError = e;
  }
  if (plain?.contentHtml) {
    // The page worked: the feed only gets a short grace period, so a slow feed never holds up the
    // article. It is usually done by now, since both fetches started together.
    const f = await within(fromFeed, FEED_GRACE_MS);
    return f && preferFeed(plain.contentHtml, f.contentHtml) ? { ...f, leadImage: plain.leadImage ?? f.leadImage } : plain;
  }
  const f = await fromFeed;
  // The page failed or had no article: the feed's full-content HTML beats a rendered copy.
  if (f) return { ...f, leadImage: plain?.leadImage ?? f.leadImage };

  const ms = Math.min(RENDER_TIMEOUT_MS, TOTAL_BUDGET_MS - (Date.now() - started));
  if (/^https?:\/\//i.test(url) && ms >= MIN_RENDER_MS) {
    try {
      const r = await extractRendered(url, ms);
      if (r?.contentHtml) {
        return { ...r, leadImage: plain?.leadImage ?? r.leadImage ?? firstImage(r.contentHtml) };
      }
    } catch {
      /* fall through to the plain result */
    }
  }

  if (plainError) throw plainError;
  return plain ?? { contentHtml: null, leadImage: null };
}
