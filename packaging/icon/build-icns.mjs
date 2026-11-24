#!/usr/bin/env node
// Assemble AppIcon.icns from the vector sources: AppIcon.svg for 128px and up,
// AppIcon-small.svg for 16/32/64px. Rasterizing goes through resvg so the build
// runs anywhere and keeps the alpha channel — the previous qlmanage step
// flattened the SVG onto white, which shipped an icon with opaque corners.
//
// 16px and 32px are written as ARGB (per-channel PackBits), not PNG: macOS
// renders PNG data in ic04/ic05 garbled at 1x backing scale, which is why
// Apple's iconutil emits ARGB for exactly those two slots.
import { Resvg } from '@resvg/resvg-js';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const MASTER = 'AppIcon.svg';
const SMALL = 'AppIcon-small.svg';
const OUT = 'AppIcon.icns';
const SOURCES_DIGEST = 'AppIcon.icns.sources.sha256';

const SLOTS = [
  { type: 'ic04', px: 16, art: SMALL, format: 'argb' },
  { type: 'ic05', px: 32, art: SMALL, format: 'argb' },
  { type: 'ic11', px: 32, art: SMALL, format: 'png' },
  { type: 'ic12', px: 64, art: SMALL, format: 'png' },
  { type: 'ic07', px: 128, art: MASTER, format: 'png' },
  { type: 'ic13', px: 256, art: MASTER, format: 'png' },
  { type: 'ic08', px: 256, art: MASTER, format: 'png' },
  { type: 'ic14', px: 512, art: MASTER, format: 'png' },
  { type: 'ic09', px: 512, art: MASTER, format: 'png' },
  { type: 'ic10', px: 1024, art: MASTER, format: 'png' },
];

const sources = new Map([MASTER, SMALL].map((name) => [name, readFileSync(join(HERE, name), 'utf8')]));

function render(art, px) {
  const image = new Resvg(sources.get(art), { fitTo: { mode: 'width', value: px } }).render();
  return { png: image.asPng(), pixels: Buffer.from(image.pixels) };
}

// A squircle never reaches the canvas corners, so an opaque corner means the
// rasterizer composited the artwork onto a background instead of keeping alpha.
function assertCornersTransparent(pixels, px, label) {
  for (const [x, y] of [[0, 0], [px - 1, 0], [0, px - 1], [px - 1, px - 1]]) {
    const alpha = pixels[(y * px + x) * 4 + 3];
    if (alpha > 64) {
      throw new Error(`${label}: corner (${x},${y}) alpha ${alpha} — artwork lost its transparency`);
    }
  }
}

function packBits(bytes) {
  const out = [];
  let i = 0;
  while (i < bytes.length) {
    let run = 1;
    while (run < 130 && i + run < bytes.length && bytes[i + run] === bytes[i]) run += 1;
    if (run >= 3) {
      out.push(0x80 | (run - 3), bytes[i]);
      i += run;
      continue;
    }
    const start = i;
    while (i < bytes.length && i - start < 128) {
      const same = i + 2 < bytes.length && bytes[i] === bytes[i + 1] && bytes[i] === bytes[i + 2];
      if (same && i > start) break;
      i += 1;
    }
    out.push(i - start - 1, ...bytes.subarray(start, i));
  }
  return Buffer.from(out);
}

function unpackBits(buf, count) {
  const out = Buffer.alloc(count);
  let i = 0;
  let o = 0;
  while (o < count) {
    const control = buf[i++];
    if (control & 0x80) {
      const run = control - 125;
      out.fill(buf[i++], o, o + run);
      o += run;
    } else {
      const run = control + 1;
      buf.copy(out, o, i, i + run);
      i += run;
      o += run;
    }
  }
  return { out, consumed: i };
}

function argbBody(pixels, px) {
  const count = px * px;
  const channels = [3, 0, 1, 2].map((offset) => {
    const channel = Buffer.alloc(count);
    for (let i = 0; i < count; i += 1) channel[i] = pixels[i * 4 + offset];
    return channel;
  });
  const packed = channels.map(packBits);

  // Decode our own output before trusting it to the icon file.
  let cursor = 0;
  const joined = Buffer.concat(packed);
  for (const [index, channel] of channels.entries()) {
    const { out, consumed } = unpackBits(joined.subarray(cursor), count);
    if (!out.equals(channel)) throw new Error(`ARGB channel ${index} failed to round-trip at ${px}px`);
    cursor += consumed;
  }
  return Buffer.concat([Buffer.from('ARGB', 'latin1'), joined]);
}

const chunks = [];
for (const slot of SLOTS) {
  const { png, pixels } = render(slot.art, slot.px);
  assertCornersTransparent(pixels, slot.px, `${slot.art} at ${slot.px}px`);
  const body = slot.format === 'png' ? png : argbBody(pixels, slot.px);
  const header = Buffer.alloc(8);
  header.write(slot.type, 0, 'latin1');
  header.writeUInt32BE(body.length + 8, 4);
  chunks.push(Buffer.concat([header, body]));
  console.log(`  ${slot.type}  ${String(slot.px).padStart(4)}px  ${slot.format}  ${body.length} bytes  ${slot.art}`);
}

const payload = Buffer.concat(chunks);
const head = Buffer.alloc(8);
head.write('icns', 0, 'latin1');
head.writeUInt32BE(payload.length + 8, 4);
writeFileSync(join(HERE, OUT), Buffer.concat([head, payload]));

const digests = [...sources.entries()]
  .map(([name, svg]) => `${createHash('sha256').update(svg).digest('hex')}  ${name}\n`)
  .join('');
writeFileSync(join(HERE, SOURCES_DIGEST), digests);

console.log(`==> wrote ${OUT} (${payload.length + 8} bytes, ${SLOTS.length} slots) and ${SOURCES_DIGEST}`);
