// Generate the "钃濋哺灏忔繁" sprite sheet from the official DeepSeek whale mark.
//
// Sheet layout is the one the design brief asks for: 8 columns x 9 rows, one
// row per state, cells of 192x208 CSS px. Rows:
//   0 idle      杞诲井鍛煎惛娴姩锛屽熬宸寸紦缂撴憜鍔?//   1 thinking  鎱㈤€熷贰娓革紝澶撮《涓夐閿欏嘲姘存淮
//   2 working   鎶辩瑪璁版湰锛岃韩浣撳井鏅?//   3 waiting   鐤戦棶濮挎€侊紝姝ご
//   4 celebrate 璺冨嚭姘撮潰锛屾簠璧锋按鑺?//   5 error     涓嬫綔鍛婂埆
//   6 drag      闅忓厜鏍囨柟鍚戞憞鎽嗙殑澧為暱鎷栧熬
//   7 longtask  瓒村湪閿洏涓?//   8 reserve   (spare row, keeps the 8x9 contract)
//
// The whale is the official mark, not a redrawn lookalike: every frame places
// the same 50x50 path under an affine transform, so brand geometry and the
// white interior detail (which never darkens) are preserved exactly.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const sharp = require('sharp');

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const whale = JSON.parse(await readFile(join(root, 'art', 'whale.json'), 'utf8'));

const CELL_W = 192;
const CELL_H = 208;
const COLS = 8;
const ROWS = 9;
const WHALE_D = whale.paths.map((p) => p.d).join(' ');

const BRAND = '#4D6BFE';
const BRAND_LIGHT = '#7C92FF';
const BRAND_DEEP = '#3B54D6';
const WHITE = '#FFFFFF';

const rad = (deg) => (deg * Math.PI) / 180;
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
/** Smooth 0..1 wave with `phase` in turns. */
const wave = (phase, offset = 0) => Math.sin((phase + offset) * Math.PI * 2);

// The mark's own bounding box inside its 0 0 50 50 viewBox. Every frame is placed
// by fitting this box to a target rectangle, so a state's size is expressed
// directly in cell pixels instead of being guessed as a scale factor.
const WHALE = { x: 1.3, y: 7, w: 48, h: 33.5 };
const WHALE_CX = WHALE.x + WHALE.w / 2;
const WHALE_CY = WHALE.y + WHALE.h / 2;
const WHALE_ASPECT = WHALE.h / WHALE.w;

/** The cell's middle, which is the pivot every state rotates and skews around. */
const CX = CELL_W / 2;
const CY = CELL_H / 2;

/**
 * Transform placing the mark inside a `w x h` target box centred at (cx, cy),
 * then applying the state's rotation and tail skew about the cell's middle.
 *
 * The fit happens first so `rotate` pivots the whole placement rather than a
 * half-scaled mark, which is what kept earlier poses drifting out of their cell.
 */
function place({ cx = CX, cy = CY, w, rotate = 0, tail = 0 }) {
  const h = w * WHALE_ASPECT;
  const s = w / WHALE.w;
  return [
    `translate(${cx.toFixed(2)} ${cy.toFixed(2)})`,
    `rotate(${rotate.toFixed(2)})`,
    `skewY(${(tail * 0.35).toFixed(2)})`,
    `scale(${s.toFixed(4)})`,
    `translate(${(-WHALE_CX).toFixed(4)} ${(-WHALE_CY).toFixed(4)})`,
  ].join(' ');
}

/** Widest a frame may be, leaving a little breathing room inside the cell. */
const MAX_W = CELL_W - 16;

/**
 * One animation state: frame count plus the pose each frame lands on.
 * A pose names a target box (`w` in cell pixels, `cx`/`cy` offsets) plus
 * rotation and tail sway; see {@link place}.
 */
const STATES = [
  {
    key: 'idle',
    frames: 8,
    poses: (i, n) => {
      const t = i / n;
      return {
        w: 150 * (1 + 0.015 * wave(t, 0.25)),
        cy: CY + 4 * wave(t),
        rotate: 1.6 * wave(t, 0.5),
        tail: 10 * wave(t, 0.12),
      };
    },
  },
  {
    key: 'thinking',
    frames: 8,
    poses: (i, n) => {
      const t = i / n;
      // 慢速巡游: a slow lateral patrol, with the droplets rising behind it.
      return {
        w: 132,
        cx: CX + 10 * wave(t, 0.25),
        cy: CY - 6 + 3 * wave(t, 0.1),
        rotate: 2.4 * wave(t, 0.4),
        tail: 16 * wave(t, 0.2),
        droplets: true,
      };
    },
  },
  {
    key: 'working',
    frames: 8,
    poses: (i, n) => {
      const t = i / n;
      // 身体微晃: a small working sway, slightly smaller than idle so the
      // thinking and working rows read differently at a glance.
      return {
        w: 130,
        cy: CY + 3 * wave(t, 0.2),
        rotate: 2.6 * wave(t, 0.3),
        tail: 7 * wave(t, 0.3),
      };
    },
  },
  {
    key: 'waiting',
    frames: 8,
    poses: (i, n) => {
      const t = i / n;
      const nudge = wave(t, 0.05);
      // 歪头: head tilted and held, with the question mark to its right.
      return {
        w: 128,
        cx: CX - 10,
        cy: CY + 3 * wave(t, 0.5),
        rotate: -9 + 1.6 * nudge,
        tail: 5 * wave(t, 0.5),
        question: true,
      };
    },
  },
  {
    key: 'celebrate',
    frames: 8,
    poses: (i, n) => {
      const t = i / n;
      const arc = Math.sin(t * Math.PI);
      // 跃出水面: a small breach — up, a fuller turn, and back down.
      return {
        w: 132 + 8 * arc,
        cx: CX - 14 * (t - 0.5),
        cy: CY + 26 * arc,
        rotate: -22 + 44 * t,
        tail: 22 * wave(t, 0.1),
      };
    },
  },
  {
    key: 'error',
    frames: 8,
    poses: (i, n) => {
      const t = i / n;
      // 下潜告别: sink away, nose down, fading out.
      return {
        w: 132 - 12 * t,
        cx: CX - 8 + 18 * t,
        cy: CY - 14 + 40 * t,
        rotate: 12 + 26 * t,
        tail: 24 * t,
        alpha: 1 - 0.5 * t,
      };
    },
  },
  {
    key: 'drag',
    frames: 8,
    poses: (i, n) => {
      const t = i / n;
      // 被拎起来: held up and swaying with the cursor.
      return {
        w: 138,
        cy: CY - 14 + 4 * wave(t, 0.35),
        rotate: -14 + 5 * wave(t, 0.3),
        tail: 20 * wave(t, 0.15),
      };
    },
  },
  {
    key: 'longtask',
    frames: 8,
    poses: (i, n) => {
      const t = i / n;
      // A settled, heavier sway than `working` — the long haul, without props.
      return {
        w: 126,
        cy: CY + 12 + 2 * wave(t, 0.2),
        rotate: 5 + 1.2 * wave(t, 0.4),
        tail: 4 * wave(t, 0.6),
      };
    },
  },
  {
    key: 'reserve',
    frames: 8,
    poses: (i, n) => {
      const t = i / n;
      return {
        w: 134,
        cy: CY + 4 * wave(t),
        rotate: 1.5 * wave(t, 0.5),
        tail: 12 * wave(t, 0.2),
      };
    },
  },
];

/** Three staggered droplets rising from the blowhole. */
function droplets(i, n) {
  const parts = [];
  for (let d = 0; d < 3; d++) {
    const local = (i / n + d / 3) % 1;
    const cy = 44 - 34 * local;
    const cx = 74 + 7 * Math.sin(local * Math.PI * 2 + d);
    const r = 3.4 - 1.1 * local;
    const alpha = 0.95 - 0.75 * local;
    parts.push(`<path d="M${cx.toFixed(1)} ${(cy - r * 1.7).toFixed(1)} C${(cx + r * 1.5).toFixed(1)} ${cy.toFixed(1)}, ${(cx + r).toFixed(1)} ${(cy + r * 1.6).toFixed(1)}, ${cx.toFixed(1)} ${(cy + r * 1.6).toFixed(1)} C${(cx - r).toFixed(1)} ${(cy + r * 1.6).toFixed(1)}, ${(cx - r * 1.5).toFixed(1)} ${cy.toFixed(1)}, ${cx.toFixed(1)} ${(cy - r * 1.7).toFixed(1)} Z" fill="${BRAND}" opacity="${alpha.toFixed(2)}"/>`);
    parts.push(`<circle cx="${(cx - r * 0.3).toFixed(1)}" cy="${(cy - r * 0.1).toFixed(1)}" r="${(r * 0.32).toFixed(1)}" fill="${WHITE}" opacity="${(alpha * 0.9).toFixed(2)}"/>`);
  }
  return parts.join('\n    ');
}

/** Tilted question mark above and clear of the whale's tail. */
function question(i, n) {
  const bob = 4 * wave(i / n, 0.2);
  return `
    <text x="150" y="${(42 + bob).toFixed(1)}" font-family="Segoe UI, Arial, sans-serif" font-size="30" font-weight="700" fill="${BRAND}" opacity="0.92">?</text>`;
}

/** Compose one frame as a full SVG document. */
function frame(state, i) {
  const n = state.frames;
  const pose = state.poses(i, n);
  // The pose declares the box the mark should occupy; `place` fits the mark to it
  // and applies the rotation and tail sway about the cell's middle.
  const transform = place({
    cx: pose.cx ?? CX,
    cy: pose.cy ?? CY,
    w: Math.min(pose.w ?? MAX_W / 2, MAX_W),
    rotate: pose.rotate ?? 0,
    tail: pose.tail ?? 0,
  });

  // Only the whale. The pet is a brand mark on the desktop, so the artwork is the
  // official whale on transparency — no props (laptop, keyboard, clock, badges),
  // no water, no shadow. Every state is therefore a pose of the same mark.
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${CELL_W}" height="${CELL_H}" viewBox="0 0 ${CELL_W} ${CELL_H}" fill="none">
  <defs>
    <linearGradient id="body" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="${BRAND_LIGHT}"/>
      <stop offset="55%" stop-color="${BRAND}"/>
      <stop offset="100%" stop-color="${BRAND_DEEP}"/>
    </linearGradient>
  </defs>

  <g id="detail-back">
    ${state.key === 'thinking' ? droplets(i, n) : ''}
  </g>

  <g id="body" transform="${transform}" opacity="${(pose.alpha ?? 1).toFixed(2)}">
    <!-- White base first, then the brand fill over it: the mark's interior
         detail is cut out through the even-odd rule, so the cutouts reveal the
         white underneath and the interior detail never darkens. -->
    <path d="${WHALE_D}" fill="${WHITE}" fill-rule="evenodd"/>
    <path d="${WHALE_D}" fill="url(#body)" fill-rule="evenodd"/>
  </g>

  <g id="detail-front">
    ${state.key === 'waiting' ? question(i, n) : ''}
  </g>
</svg>`;
}

// --- build -----------------------------------------------------------------

const outDir = join(root, 'assets');
await mkdir(outDir, { recursive: true });

const sheet = sharp({
  create: { width: CELL_W * COLS, height: CELL_H * ROWS, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
});
const composites = [];
const manifest = { cellWidth: CELL_W, cellHeight: CELL_H, columns: COLS, rows: ROWS, states: {} };

for (let row = 0; row < STATES.length; row++) {
  const state = STATES[row];
  for (let col = 0; col < COLS; col++) {
    const index = col < state.frames ? col : col % state.frames;
    const svg = frame(state, index);
    const cell = await sharp(Buffer.from(svg), { density: 384 })
      .resize(CELL_W, CELL_H, { fit: 'fill', kernel: 'lanczos3' })
      .png()
      .toBuffer();
    composites.push({ input: cell, left: col * CELL_W, top: row * CELL_H });
  }
  manifest.states[state.key] = { row, frames: state.frames };
  // Expose one representative frame per state for README/preview use.
  const previewSvg = frame(state, Math.floor(state.frames / 3));
  await writeFile(join(outDir, `preview-${state.key}.png`), await sharp(Buffer.from(previewSvg), { density: 384 })
    .resize(CELL_W, CELL_H, { fit: 'fill', kernel: 'lanczos3' })
    .png()
    .toBuffer());
}

const png = await sheet.composite(composites).png({ compressionLevel: 9 }).toBuffer();
await writeFile(join(outDir, 'whale-sheet.png'), png);
await writeFile(join(outDir, 'whale-sheet.json'), `${JSON.stringify(manifest, null, 2)}\n`);

console.log(`sheet ${CELL_W * COLS}x${CELL_H * ROWS} (${COLS}x${ROWS} cells of ${CELL_W}x${CELL_H}) -> assets/whale-sheet.png (${(png.length / 1024).toFixed(1)} KiB)`);
for (const [key, info] of Object.entries(manifest.states)) console.log(`  row ${info.row}  ${key.padEnd(10)} ${info.frames} frames`);
