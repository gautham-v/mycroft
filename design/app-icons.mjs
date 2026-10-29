// OpenDispatch app icons: a soft disc and hand-drawn ink strokes on a plain tile, in eight designs and
// nine colorways (Settings → Appearance → App Icon). The wobble is seeded, so every run draws the same
// icons. `node design/app-icons.mjs <dir>` writes <design>-<colorway>.svg for each pair; scripts/render-icons.sh
// renders them into the asset catalog. The ids match AppIconDesign and AppIconColorway in App/Model/AppIcon.swift.

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const COLORWAYS = {
  glacier: { tile: "#EEF3F8", disc: "#76A6D6", ink: "#14202C" },
  paper: { tile: "#FBFBFA", disc: "#D97E5E", ink: "#1B1A19" },
  night: { tile: "#1D1D1F", disc: "#D97E5E", ink: "#F2F0EB" },
  newsprint: { tile: "#ECEAE4", disc: "#C8462E", ink: "#1F1E1C" },
  harbor: { tile: "#1B2433", disc: "#E0AE4B", ink: "#F3F1EC" },
  cobalt: { tile: "#2F5BD3", disc: "#F2C14E", ink: "#111214" },
  sage: { tile: "#F3F5F0", disc: "#8FB592", ink: "#1C281E" },
  terracotta: { tile: "#D3704F", disc: "#F5DCCB", ink: "#1B1A19" },
  graphite: { tile: "#FFFFFF", disc: "#D9D9D6", ink: "#151515" },
};
export const DEFAULT = "o-d-glacier";

// Seeded randomness (mulberry32), and a slow tremor: three sines with random frequencies and phases.
function rng(s) { return () => { s = s + 0x6D2B79F5 | 0; let t = Math.imul(s ^ s >>> 15, 1 | s); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296 } }
function tremor(r) {
  const k = [[1.2 + r() * .6, 1], [2.4 + r() * 1.2, .5], [4.2 + r() * 2, .25]].map(([f, a]) => ({ f, a, p: r() * 6.283 }));
  return t => k.reduce((s, o) => s + o.a * Math.sin(6.283 * o.f * t + o.p), 0) / 1.75;
}
const f = p => p[0].toFixed(1) + " " + p[1].toFixed(1);
// The drawn area of the icon being drawn, so svg() can scale the mark to fill the tile.
let box;
const track = pts => { for (const [x, y] of pts) box = [Math.min(box[0], x), Math.min(box[1], y), Math.max(box[2], x), Math.max(box[3], y)] };
// Catmull-Rom through the points as cubic Béziers.
function segs(pts, closed) {
  const n = pts.length, P = i => closed ? pts[(i + n) % n] : pts[Math.max(0, Math.min(n - 1, i))];
  let d = "";
  for (let i = 0; i < (closed ? n : n - 1); i++) {
    const a = P(i - 1), b = P(i), c = P(i + 1), e = P(i + 2);
    d += `C${f([b[0] + (c[0] - a[0]) / 6, b[1] + (c[1] - a[1]) / 6])} ${f([c[0] - (e[0] - b[0]) / 6, c[1] - (e[1] - b[1]) / 6])} ${f(c)}`;
  }
  return d;
}

function rim(R, r) {
  const k = [2, 3, 5].map((n, i) => ({ n, a: [.6, .35, .15][i] * (.6 + r() * .8), p: r() * 6.283 }));
  return th => R * (1 + .05 * k.reduce((s, o) => s + o.a * Math.sin(o.n * th + o.p), 0));
}
function blob(cx, cy, R, r, fill) {
  const rr = rim(R, r), pts = [];
  for (let i = 0; i < 48; i++) { const th = i / 48 * 6.283; pts.push([cx + rr(th) * Math.cos(th), cy + rr(th) * Math.sin(th)]) }
  track(pts);
  return `<path fill="${fill}" d="M${f(pts[0])}${segs(pts, true)}Z"/>`;
}
// Half a disc with a straight cut: side -1 keeps the left half, 1 the right.
function half(cx, cy, R, side, r, fill) {
  const rr = rim(R, r), pts = [];
  for (let i = 0; i <= 24; i++) { const th = (side < 0 ? Math.PI / 2 : -Math.PI / 2) + i / 24 * Math.PI; pts.push([cx + rr(th) * Math.cos(th), cy + rr(th) * Math.sin(th)]) }
  track(pts);
  return `<path fill="${fill}" d="M${f(pts[0])}${segs(pts)}Z"/>`;
}
// A marker stroke along fn(t): the centerline wobbles and the width breathes a little, with round ends.
function stroke(fn, W, r, fill) {
  const N = 44, nz = tremor(r), wz = tremor(r), L = [], R = [];
  for (let i = 0; i <= N; i++) {
    const t = i / N, p = fn(t), a = fn(Math.max(0, t - .002)), b = fn(Math.min(1, t + .002));
    let tx = b[0] - a[0], ty = b[1] - a[1]; const m = Math.hypot(tx, ty) || 1; tx /= m; ty /= m; const nx = -ty, ny = tx;
    const off = 8 * nz(t), end = Math.min(1, Math.min(t, 1 - t) / .1);
    const h = W / 2 * (1 + .14 * wz(t)) * (.84 + .16 * end);
    const q = [p[0] + nx * off, p[1] + ny * off];
    L.push([q[0] + nx * h, q[1] + ny * h]); R.push([q[0] - nx * h, q[1] - ny * h]);
  }
  track(L); track(R);
  const Rv = R.slice().reverse(), r1 = Math.hypot(L[N][0] - R[N][0], L[N][1] - R[N][1]) / 2, r0 = Math.hypot(L[0][0] - R[0][0], L[0][1] - R[0][1]) / 2;
  return `<path fill="${fill}" d="M${f(L[0])}${segs(L)}A${r1.toFixed(1)} ${r1.toFixed(1)} 0 0 0 ${f(Rv[0])}${segs(Rv)}A${r0.toFixed(1)} ${r0.toFixed(1)} 0 0 0 ${f(L[0])}Z"/>`;
}

const rad = d => d * Math.PI / 180;
const arc = (cx, cy, rr, a0, a1, grow = 0) => t => { const a = rad(a0 + (a1 - a0) * t), q = rr * (1 + grow * (t - .5)); return [cx + q * Math.cos(a), cy + q * Math.sin(a)] };
const quad = (p0, c, p2) => t => [(1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * c[0] + t * t * p2[0], (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * c[1] + t * t * p2[1]];
const lines = (list, W, r, C) => list.map(([a, c, b]) => stroke(quad(a, c, b), W, r, C.ink)).join("");
const loop = (cx, cy, R, r, C, a0 = -212) => stroke(arc(cx, cy, R, a0, a0 + 380, .07), 46, r, C.ink);

// Each design keeps the seed it had in the review page, so the strokes look as they did there.
export const DESIGNS = {
  "o-d": { seed: 697, draw: (r, C) => half(492, 512, 290, -1, r, C.disc) + stroke(quad([532, 212], [524, 512], [534, 812]), 46, r, C.ink) + stroke(arc(532, 512, 300, -90, 90), 46, r, C.ink) },
  "swept": { seed: 680, draw: (r, C) => blob(512, 540, 300, r, C.disc) + lines([[[196, 430], [470, 290], [772, 384]], [[248, 545], [490, 418], [742, 500]], [[310, 655], [500, 548], [684, 612]]], 46, r, C) },
  "two-lines": { seed: 681, draw: (r, C) => blob(512, 540, 300, r, C.disc) + lines([[[190, 470], [480, 330], [790, 430]], [[260, 620], [500, 490], [730, 575]]], 60, r, C) },
  "split": { seed: 694, draw: (r, C) => blob(470, 570, 272, r, C.disc) + stroke(quad([474, 268], [462, 570], [478, 872]), 40, r, C.tile) + [340, 422].map(rr => stroke(arc(470, 570, rr, -78, -14), 46, r, C.ink)).join("") },
  "ink-cut": { seed: 698, draw: (r, C) => blob(512, 530, 290, r, C.disc) + stroke(quad([492, 160], [520, 520], [500, 880]), 50, r, C.ink) },
  "trace": { seed: 701, draw: (r, C) => blob(430, 600, 240, r, C.disc) + loop(592, 436, 232, r, C) },
  "misprint": { seed: 702, draw: (r, C) => blob(490, 540, 280, r, C.disc) + loop(552, 480, 270, r, C) },
  "trace-wave": { seed: 704, draw: (r, C) => blob(410, 620, 225, r, C.disc) + loop(540, 490, 215, r, C) + stroke(arc(540, 490, 315, -84, -8), 46, r, C.ink) },
};

// The mark's longer side as a share of the tile, about what the other icons in the Dock fill.
const FILL = 0.8;

export function svg(design, colorway) {
  const C = COLORWAYS[colorway], d = DESIGNS[design];
  box = [Infinity, Infinity, -Infinity, -Infinity];
  const mark = d.draw(rng(d.seed), C);
  // Scale the mark about its own center and put that center in the middle of the tile.
  const k = FILL * 1024 / Math.max(box[2] - box[0], box[3] - box[1]), cx = (box[0] + box[2]) / 2, cy = (box[1] + box[3]) / 2;
  const fit = `translate(512 512) scale(${k.toFixed(4)}) translate(${(-cx).toFixed(1)} ${(-cy).toFixed(1)})`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024"><rect width="1024" height="1024" fill="${C.tile}"/><g transform="${fit}">${mark}</g></svg>\n`;
}

if (process.argv[2]) {
  const dir = process.argv[2];
  mkdirSync(dir, { recursive: true });
  for (const d of Object.keys(DESIGNS)) for (const c of Object.keys(COLORWAYS)) writeFileSync(join(dir, `${d}-${c}.svg`), svg(d, c));
}
