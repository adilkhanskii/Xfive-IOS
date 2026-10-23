// Generates AppIcon-1024.png.
// Direction: premium dark X5 mark with neon-lime glass depth for App Store Connect.
// Run: node scripts/gen-icon.mjs
import { writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';

const __dirname = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(__dirname, '..', 'X5', 'Assets.xcassets', 'AppIcon.appiconset');
mkdirSync(outDir, { recursive: true });

const SIZE = 1024;

function pngBuffer(width, height, drawPixel) {
  const channels = 3;
  const bytesPerRow = width * channels + 1;
  const raw = Buffer.alloc(bytesPerRow * height);
  for (let y = 0; y < height; y++) {
    raw[y * bytesPerRow] = 0;
    for (let x = 0; x < width; x++) {
      const px = drawPixel(x, y);
      const o = y * bytesPerRow + 1 + x * channels;
      raw[o] = px[0]; raw[o + 1] = px[1]; raw[o + 2] = px[2];
    }
  }
  const idat = zlib.deflateSync(raw, { level: 9 });
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))]);
}

function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([len, typeBuf, data, crc]);
}

const CRC = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function clamp01(v) { return Math.max(0, Math.min(1, v)); }
function mix(a, b, t) { return a + (b - a) * t; }
function smoothstep(edge0, edge1, x) {
  const t = clamp01((x - edge0) / (edge1 - edge0));
  return t * t * (3 - 2 * t);
}
function blend(base, over, a) {
  return [
    Math.round(mix(base[0], over[0], a)),
    Math.round(mix(base[1], over[1], a)),
    Math.round(mix(base[2], over[2], a))
  ];
}
function length2(x, y) { return Math.sqrt(x * x + y * y); }
function distSegment(px, py, ax, ay, bx, by) {
  const vx = bx - ax, vy = by - ay;
  const wx = px - ax, wy = py - ay;
  const c1 = vx * wx + vy * wy;
  const c2 = vx * vx + vy * vy;
  const t = clamp01(c1 / c2);
  return length2(px - (ax + vx * t), py - (ay + vy * t));
}
function sdOrientedBox(px, py, cx, cy, ux, uy, hx, hy) {
  const vx = -uy, vy = ux;
  const dx = px - cx, dy = py - cy;
  const qx = Math.abs(dx * ux + dy * uy) - hx;
  const qy = Math.abs(dx * vx + dy * vy) - hy;
  const ox = Math.max(qx, 0);
  const oy = Math.max(qy, 0);
  return length2(ox, oy) + Math.min(Math.max(qx, qy), 0);
}
function sdBox(px, py, cx, cy, hx, hy) {
  const dx = Math.abs(px - cx) - hx;
  const dy = Math.abs(py - cy) - hy;
  const ox = Math.max(dx, 0);
  const oy = Math.max(dy, 0);
  return length2(ox, oy) + Math.min(Math.max(dx, dy), 0);
}
function minDistance(...values) { return values.reduce((m, v) => Math.min(m, v), Infinity); }

function markDistances(x, y) {
  const s = SIZE;
  const stroke = s * 0.082;
  const xLeft = s * 0.225;
  const xRight = s * 0.505;
  const yTop = s * 0.305;
  const yBottom = s * 0.705;
  const xCx = (xLeft + xRight) / 2;
  const xCy = (yTop + yBottom) / 2;
  const dx = xRight - xLeft;
  const dy = yBottom - yTop;
  const len = length2(dx, dy);
  const ux = dx / len;
  const uy = dy / len;

  const xDist = Math.min(
    sdOrientedBox(x, y, xCx, xCy, ux, uy, len / 2, stroke),
    sdOrientedBox(x, y, xCx, xCy, ux, -uy, len / 2, stroke)
  );

  const fiveLeft = s * 0.515;
  const fiveRight = s * 0.805;
  const top = s * 0.315;
  const mid = s * 0.49;
  const bottom = s * 0.685;
  const bar = s * 0.088;
  const fiveDist = minDistance(
    sdBox(x, y, (fiveLeft + fiveRight) / 2, top, (fiveRight - fiveLeft) / 2, bar / 2),
    sdBox(x, y, fiveLeft + bar / 2, (top + mid) / 2, bar / 2, (mid - top) / 2),
    sdBox(x, y, (fiveLeft + fiveRight - bar * 0.35) / 2, mid, (fiveRight - fiveLeft - bar * 0.35) / 2, bar / 2),
    sdBox(x, y, fiveRight - bar / 2, (mid + bottom) / 2, bar / 2, (bottom - mid) / 2),
    sdBox(x, y, (fiveLeft + fiveRight) / 2, bottom, (fiveRight - fiveLeft) / 2, bar / 2)
  );

  return Math.min(xDist, fiveDist);
}

function background(x, y) {
  const nx = x / SIZE;
  const ny = y / SIZE;
  const d1 = length2(nx - 0.78, ny - 0.10);
  const d2 = length2(nx - 0.16, ny - 0.88);
  const edge = length2(nx - 0.5, ny - 0.5);
  const grain = ((x * 17 + y * 31) % 97) / 97;
  let color = [9, 11, 23];
  color = blend(color, [24, 34, 54], clamp01(1 - d1 * 2.0) * 0.75);
  color = blend(color, [17, 86, 68], clamp01(1 - d2 * 2.15) * 0.42);
  color = blend(color, [0, 0, 0], smoothstep(0.36, 0.72, edge) * 0.40);
  color = blend(color, [255, 255, 255], grain * 0.025);
  return color;
}

const LIME = [206, 255, 20];
const MINT = [48, 238, 171];
const WHITE = [248, 255, 238];

const buf = pngBuffer(SIZE, SIZE, (x, y) => {
  let color = background(x, y);
  const d = markDistances(x, y);

  const wideGlow = 1 - smoothstep(0, 95, Math.max(d, 0));
  const tightGlow = 1 - smoothstep(0, 28, Math.max(d, 0));
  color = blend(color, MINT, wideGlow * 0.18);
  color = blend(color, LIME, tightGlow * 0.38);

  const fill = 1 - smoothstep(-1.5, 1.8, d);
  const topShine = clamp01(1 - y / SIZE * 1.15);
  const glyph = [
    Math.round(mix(LIME[0], WHITE[0], topShine * 0.38)),
    Math.round(mix(LIME[1], WHITE[1], topShine * 0.26)),
    Math.round(mix(LIME[2], WHITE[2], topShine * 0.18))
  ];
  color = blend(color, glyph, fill);

  const innerShadow = smoothstep(-20, -4, d) * smoothstep(80, 220, y);
  color = blend(color, [115, 150, 25], innerShadow * 0.16);

  return color;
});

writeFileSync(resolve(outDir, 'AppIcon-1024.png'), buf);
console.log('wrote AppIcon-1024.png (' + buf.length + ' bytes)');
