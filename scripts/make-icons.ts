import sharp from "sharp";
import { mkdirSync } from "node:fs";
import { join } from "node:path";

const out = join(process.cwd(), "public", "icons");
mkdirSync(out, { recursive: true });

// Rounded square, accent fill, white RSS arc glyph. `pad` shrinks the glyph for maskable safe zone.
function svg(size: number, { rounded = true, scale = 1 } = {}) {
  const r = rounded ? 112 : 0;
  const t = `translate(256 256) scale(${scale}) translate(-256 -256)`;
  return Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 512 512">
  <rect width="512" height="512" rx="${r}" fill="#0F6E6E"/>
  <g transform="${t}" fill="none" stroke="#FFFFFF" stroke-width="44" stroke-linecap="round">
    <path d="M150 238a124 124 0 0 1 124 124"/>
    <path d="M150 146a216 216 0 0 1 216 216"/>
  </g>
  <g transform="${t}"><circle cx="164" cy="348" r="30" fill="#FFFFFF"/></g>
</svg>`);
}

async function main() {
  await sharp(svg(192)).png().toFile(join(out, "icon-192.png"));
  await sharp(svg(512)).png().toFile(join(out, "icon-512.png"));
  await sharp(svg(512, { rounded: false, scale: 0.72 })).png().toFile(join(out, "maskable-512.png"));
  await sharp(svg(180, { rounded: false })).png().toFile(join(out, "apple-touch-icon-180.png"));
  console.log("icons written to", out);
}
main();
