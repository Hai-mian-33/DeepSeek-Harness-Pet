// Extract the geometry of the official DeepSeek whale mark into a plain JSON
// asset. The mark is one long `d` path whose coordinates legitimately contain
// the byte sequence `/>` (e.g. "1.242/>, "), so naive tag-boundary scanning
// truncates it: parse the attribute list directly instead.
import { readFile, writeFile } from 'node:fs/promises';

const src = process.argv[2];
const out = process.argv[3];
const svg = await readFile(src, 'utf8');

const viewBox = /viewBox="([^"]+)"/u.exec(svg)?.[1] ?? '0 0 50 50';
const head = svg.slice(0, svg.indexOf('<path'));
const tailFrom = svg.lastIndexOf('</svg>');
const body = svg.slice(svg.indexOf('<path'), tailFrom < 0 ? undefined : tailFrom);

// Split the body into <path ...> elements by their opening tag only, then read
// each attribute with a global attribute regex. No `>`-based boundary is used
// for the attribute values themselves.
const elements = body.split(/<path\b/u).slice(1);
const paths = elements.map((raw) => {
  const attrs = {};
  const attrRe = /([\w:-]+)\s*=\s*"([^"]*)"/gu;
  let m;
  while ((m = attrRe.exec(raw)) !== null) attrs[m[1]] = m[2];
  return {
    id: attrs.id,
    d: attrs.d,
    fill: attrs.fill,
    stroke: attrs.stroke,
    fillRule: attrs['fill-rule'],
    strokeWidth: attrs['stroke-width'],
  };
}).filter((p) => typeof p.d === 'string' && p.d.length > 0);

const asset = {
  source: 'DeepSeek Harness official web-frontend whale mark (dist/favicon.svg)',
  note: 'Single official whale path on a 50x50 grid; the pet animates this mark rather than redrawing it.',
  viewBox,
  brandBlue: '#4D6BFE',
  detailWhite: '#FFFFFF',
  head,
  paths,
};
await writeFile(out, `${JSON.stringify(asset, null, 2)}\n`);
console.log(`viewBox=${viewBox} paths=${paths.length} dLengths=${paths.map((p) => p.d.length).join(',')} -> ${out}`);
