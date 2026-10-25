/**
 * Charts drawn in the browser from a Vega-Lite spec (openai.com's DotcomChart) arrive as an empty
 * <div id="..."> in the server HTML. The spec itself, data included, travels in the page's Next.js
 * RSC payload (`self.__next_f.push([1,"..."])` scripts). Find those specs, keyed by the id of the
 * element the chart draws into, and render each to a static, theme-neutral SVG.
 */

import { enclosingObject, isObj, resolve, rscPayload, type Json, type Obj } from "./rsc";

const MARKER = /"reactComponent"\s*:\s*"DotcomChart"/g;
const MAX_ROWS = 20_000;
const RENDER_TIMEOUT_MS = 3_000;
const WIDTH = 480;

export interface ChartSpec {
  /** Element ids the chart draws into (DotcomChart's linkId, and its own id). */
  ids: string[];
  spec: Obj;
  aspectRatio?: number;
}

/** Vega-Lite specs in a page's RSC payload, with the ids of the elements they render into. */
export function findChartSpecs(html: string): ChartSpec[] {
  if (!html.includes("DotcomChart")) return [];
  const text = rscPayload(html);
  const out: ChartSpec[] = [];
  const seen = new Set<string>();
  for (const m of text.matchAll(MARKER)) {
    const obj = enclosingObject(text, m.index, (o) => o.reactComponent === "DotcomChart");
    if (!obj) continue;
    const data = isObj(obj.data) ? obj.data : {};
    const spec = resolve(data.vegaLiteSpec ?? data.spec ?? obj.vegaLiteSpec ?? obj.spec, text);
    if (!isObj(spec)) continue;
    const config = isObj(data.dotcomConfig) ? data.dotcomConfig : {};
    const ids = [config.linkId, obj.id].filter((x): x is string => typeof x === "string" && !!x);
    if (!ids.length || ids.some((id) => seen.has(id))) continue;
    ids.forEach((id) => seen.add(id));
    const aspectRatio = typeof config.aspectRatio === "number" && config.aspectRatio > 0 ? config.aspectRatio : undefined;
    out.push({ ids, spec, aspectRatio });
  }
  return out;
}

const C = "currentColor";
/** Text and rules take the reader's text color, so the chart reads in light and dark themes. */
const THEME: Obj = {
  font: "inherit",
  aria: false,
  background: null,
  view: { stroke: null },
  axis: {
    domainColor: C, tickColor: C, labelColor: C, titleColor: C, gridColor: C, gridOpacity: 0.15,
    labelFontSize: 12, titleFontSize: 13, titleFontWeight: "normal",
  },
  legend: { labelColor: C, titleColor: C, labelFontSize: 12, titleFontSize: 12 },
  title: { color: C, subtitleColor: C, fontSize: 15 },
  header: { labelColor: C, titleColor: C },
  mark: { color: C },
  text: { color: C },
};

function merge(a: Json | undefined, b: Json): Json {
  if (!isObj(a) || !isObj(b)) return b;
  const out: Obj = { ...a };
  for (const [k, v] of Object.entries(b)) out[k] = merge(a[k], v);
  return out;
}

function tooBig(spec: Json, depth = 0): boolean {
  if (depth > 10 || !spec || typeof spec !== "object") return false;
  if (Array.isArray(spec)) return spec.length > MAX_ROWS || spec.some((x) => tooBig(x, depth + 1));
  return Object.values(spec).some((x) => tooBig(x, depth + 1));
}

/** Container-sized dimensions mean nothing without a page; give the chart a fixed size. */
function sized(spec: Obj, aspectRatio = 1.5): Obj {
  const numeric = (v: Json | undefined) => typeof v === "number" && v > 0;
  const width = numeric(spec.width) ? spec.width : WIDTH;
  const height = numeric(spec.height) ? spec.height : Math.round((width as number) / aspectRatio);
  // Faceted/concatenated views size their cells themselves.
  if (spec.facet || spec.concat || spec.hconcat || spec.vconcat || spec.repeat) return spec;
  return { ...spec, width, height };
}

const escapeAttr = (s: string) => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");

/**
 * Tidy Vega's SVG for inline use: scale to the column (viewBox, width 100%), label it, drop the
 * empty background/foreground paths and DOM-only attributes, and make clip ids unique per chart.
 */
function finishSvg(svg: string, label: string, prefix: string): string | null {
  const root = /^<svg\b[^>]*\bwidth="([\d.]+)"[^>]*\bheight="([\d.]+)"[^>]*>/.exec(svg);
  if (!root) return null;
  const [, w, h] = root;
  const aria = label ? ` aria-label="${escapeAttr(label)}"` : "";
  return (
    `<svg viewBox="0 0 ${w} ${h}" width="100%" role="img"${aria}>` +
    svg
      .slice(root[0].length)
      .replace(/<path class="(?:background|foreground)"[^>]*?d="(?:M0,0h0v0h0Z)?"[^>]*\/>/g, "")
      .replace(/ (?:class|pointer-events|display|role|aria-[a-z]+)="[^"]*"/g, "")
      .replace(/\b(id="|url\(#)(clip\d+)/g, `$1${prefix}-$2`)
  );
}

function titleText(spec: Obj): string {
  const t = spec.title;
  if (typeof t === "string") return t;
  if (Array.isArray(t)) return t.filter((x) => typeof x === "string").join(" ");
  if (isObj(t) && typeof t.text === "string") return t.text;
  return typeof spec.description === "string" ? spec.description : "";
}

function timeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error("chart render timed out")), ms);
  });
  return Promise.race([p, late]).finally(() => clearTimeout(timer));
}

/**
 * Render one Vega-Lite spec to SVG. Vega's expressions run in its AST interpreter (no generated
 * code from page content), and external data/image loads are refused: only inline data renders.
 */
export async function renderChart(chart: ChartSpec, index = 0): Promise<string | null> {
  if (tooBig(chart.spec)) return null;
  // Dynamic imports: vega is ESM-only (with top-level await) and only needed for pages with charts.
  const [vega, { compile }, { expressionInterpreter }] = await Promise.all([
    import("vega"),
    import("vega-lite"),
    import("vega-interpreter"),
  ]);
  const { $schema: _schema, ...rest } = chart.spec;
  void _schema;
  const spec = sized({ ...rest, background: null, config: merge(rest.config, THEME) }, chart.aspectRatio);
  // vega-lite's types are stricter than a spec from the wild; compile() validates at runtime.
  const vg = compile(spec as unknown as Parameters<typeof compile>[0]).spec;
  // Vega logs a failed load and draws the chart without that data; an empty chart is no use.
  let wantedExternal = false;
  const loader = vega.loader();
  loader.sanitize = async () => {
    wantedExternal = true;
    throw new Error("external chart data is not loaded");
  };
  const view = new vega.View(vega.parse(vg, undefined, { ast: true }), {
    renderer: "none",
    loader,
    expr: expressionInterpreter,
  } as ConstructorParameters<typeof vega.View>[1]);
  try {
    const svg = await timeout(view.toSVG(), RENDER_TIMEOUT_MS);
    if (wantedExternal) return null;
    return finishSvg(svg, titleText(chart.spec), `chart${index}`);
  } finally {
    view.finalize();
  }
}

/** Rendered SVG per element id, for every chart in the page's RSC payload that renders. */
export async function renderPageCharts(html: string): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const charts = findChartSpecs(html);
  await Promise.all(
    charts.map(async (chart, i) => {
      try {
        const svg = await renderChart(chart, i);
        if (svg) chart.ids.forEach((id) => out.set(id, svg));
      } catch {
        /* unrenderable spec: the figure keeps its link to the original */
      }
    }),
  );
  return out;
}
