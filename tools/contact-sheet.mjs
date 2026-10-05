// Build a contact sheet of the per-state preview frames for visual review.
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const sharp = require('sharp');
const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

const files = (await readdir(join(root, 'assets')))
  .filter((name) => name.startsWith('preview-') && name.endsWith('.png'))
  .sort((a, b) => {
    const order = ['idle', 'thinking', 'working', 'waiting', 'celebrate', 'error', 'drag', 'longtask', 'reserve'];
    return order.indexOf(a.slice(8, -4)) - order.indexOf(b.slice(8, -4));
  });

const W = 192;
const H = 208;
const sheet = sharp({
  create: { width: W * files.length, height: H, channels: 4, background: { r: 244, g: 246, b: 255, alpha: 1 } },
});
const composites = [];
for (let i = 0; i < files.length; i++) {
  const buf = await readFile(join(root, 'assets', files[i]));
  composites.push({ input: buf, left: i * W, top: 0 });
  console.log(`${i}: ${files[i]}`);
}
const out = join(root, 'build', 'contact-sheet.png');
await writeFile(out, await sheet.composite(composites).png().toBuffer());
console.log(`contact sheet -> ${out}`);
