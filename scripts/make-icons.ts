import sharp from "sharp";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const out = join(process.cwd(), "public", "icons");
mkdirSync(out, { recursive: true });

// Rounded square, accent fill, white hand-drawn feed glyph (same bezier geometry as ArcIcon, 24-unit space
// scaled onto the 512 canvas; the browser-side roughness filter is skipped because librsvg renders it coarsely). `scale` shrinks the glyph for the maskable safe zone.
const GLYPH = 15.43; // 24-unit glyph -> 512 canvas
// `favicon` drops the square: transparent background, teal glyph filling the canvas so it reads in a browser tab.
function svg(size: number, { rounded = true, scale = 1, favicon = false } = {}) {
  const r = rounded ? 112 : 0;
  const glyph = favicon ? 30 : GLYPH;
  const t = `translate(256 256) scale(${scale}) scale(${glyph}) translate(-12.25 -12)`;
  const ink = favicon ? "#1F8F8F" : "#FFFFFF";
  const rect = favicon ? "" : `<rect width="512" height="512" rx="${r}" fill="#0F6E6E"/>`;
  return Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 512 512">
  ${rect}
  <g transform="${t}" fill="none" stroke="${ink}" stroke-width="2.7" stroke-linecap="round">
    <path d="M4.4 11.6 C7.6 9.9 11.3 11.6 12.6 14.2 C13.5 16 13.7 17.6 12.7 19.7"/>
    <path d="M5.4 4.3 C10.4 5.2 15.1 6.1 17.9 10.6 C19.7 13.4 20.1 16.4 18.6 19.5"/>
  </g>
  <g transform="${t}"><path d="M5 17 c1.2-0.7 2.6 0.1 2.6 1.3 c0 1.2-1.3 2-2.4 1.5 c-1.1-0.4-1.3-2.1-0.2-2.8z" fill="${ink}"/></g>
</svg>`);
}

// Favicon: PNG wrapped in a one-image ICO container.
function ico(png: Buffer, size: number) {
  const h = Buffer.alloc(22);
  h.writeUInt16LE(0, 0); h.writeUInt16LE(1, 2); h.writeUInt16LE(1, 4);
  h.writeUInt8(size, 6); h.writeUInt8(size, 7); h.writeUInt8(0, 8); h.writeUInt8(0, 9);
  h.writeUInt16LE(1, 10); h.writeUInt16LE(32, 12); h.writeUInt32LE(png.length, 14); h.writeUInt32LE(22, 18);
  return Buffer.concat([h, png]);
}

async function main() {
  await sharp(svg(192)).png().toFile(join(out, "icon-192.png"));
  await sharp(svg(512)).png().toFile(join(out, "icon-512.png"));
  await sharp(svg(512, { rounded: false, scale: 0.72 })).png().toFile(join(out, "maskable-512.png"));
  await sharp(svg(180, { rounded: false })).png().toFile(join(out, "apple-touch-icon-180.png"));
  const fav32 = await sharp(svg(32, { favicon: true })).png().toBuffer();
  await sharp(fav32).toFile(join(out, "favicon-32.png"));
  writeFileSync(join(process.cwd(), "src", "app", "favicon.ico"), ico(fav32, 32));
  console.log("icons written to", out);
}
main();
