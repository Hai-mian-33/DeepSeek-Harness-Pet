// Report the non-transparent bounding box of a sprite cell, so pose geometry
// can be checked against the sheet instead of guessed.
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const sharp = require('sharp');
const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

const sheetPath = join(root, 'assets', 'whale-sheet.png');
const meta = await sharp(sheetPath).metadata();
const CELL_W = 192;
const CELL_H = 208;

/** Bounding box of pixels with alpha above `threshold`. */
async function bbox(left, top, w, h, threshold = 16) {
  const { data, info } = await sharp(sheetPath)
    .extract({ left, top, width: w, height: h })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  let minX = w;
  let minY = h;
  let maxX = -1;
  let maxY = -1;
  let opaque = 0;
  for (let y = 0; y < info.height; y++) {
    for (let x = 0; x < info.width; x++) {
      const a = data[(y * info.width + x) * 4 + 3];
      if (a > threshold) {
        opaque++;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }
  return { minX, minY, maxX, maxY, w: maxX - minX + 1, h: maxY - minY + 1, cover: +(opaque / (w * h)).toFixed(3) };
}

console.log(`sheet ${meta.width}x${meta.height}`);
const names = ['idle', 'thinking', 'working', 'waiting', 'celebrate', 'error', 'drag', 'longtask', 'reserve'];
for (let row = 0; row < names.length; row++) {
  const boxes = [];
  for (let col = 0; col < 8; col++) {
    boxes.push(await bbox(col * CELL_W, row * CELL_H, CELL_W, CELL_H));
  }
  const minX = Math.min(...boxes.map((b) => b.minX));
  const maxX = Math.max(...boxes.map((b) => b.maxX));
  const minY = Math.min(...boxes.map((b) => b.minY));
  const maxY = Math.max(...boxes.map((b) => b.maxY));
  const overflow = minX < 0 || minY < 0 || maxX > CELL_W - 1 || maxY > CELL_H - 1 ? ' <-- CLIPPED' : '';
  console.log(`${names[row].padEnd(10)} row=${row} x:[${minX},${maxX}] y:[${minY},${maxY}] cover=${boxes.map((b) => b.cover).join(',')}${overflow}`);
}
