// Show the structural shape (types only, truncated values) of selected session
// event types so a reducer can be written against the real vocabulary.
import { readFile } from 'node:fs/promises';
import { zstdDecompressSync } from 'node:zlib';

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const file = process.argv[2];
const wanted = new Set(process.argv.slice(3));
const buf = await readFile(file);

function frameAt(offset) {
  let end = offset + 1;
  while (end <= buf.length) {
    try { return { text: zstdDecompressSync(buf.subarray(offset, end)).toString('utf8'), end }; }
    catch { end++; }
  }
  return undefined;
}

const texts = [];
let offset = 0;
while (offset < buf.length) {
  const next = buf.indexOf(MAGIC, offset);
  if (next < 0) break;
  const frame = frameAt(next);
  if (!frame) break;
  texts.push(frame.text);
  offset = frame.end;
}

/** Describe a value structurally: types, lengths, and only non-content scalars. */
function describe(value, depth = 0, key = '') {
  if (value === null) return 'null';
  if (Array.isArray(value)) return `Array(${value.length})${value.length && depth < 3 ? ` [${describe(value[0], depth + 1)}]` : ''}`;
  if (typeof value === 'object') {
    const entries = Object.entries(value).slice(0, 14)
      .map(([k, v]) => `${k}: ${describe(v, depth + 1, k)}`);
    return `{ ${entries.join(', ')} }`;
  }
  if (typeof value === 'string') {
    // Short enumerable-looking scalars are safe and useful; long text is not.
    return value.length <= 24 && !value.includes('\n') ? JSON.stringify(value) : `string(${value.length})`;
  }
  return `${typeof value} ${String(value)}`;
}

const seen = new Set();
for (const text of texts) {
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue;
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }
    const type = obj.type;
    if (!wanted.has(type) || seen.has(type)) continue;
    seen.add(type);
    console.log(`=== ${type} ===`);
    console.log(`  envelope: ${Object.keys(obj).join(', ')}`);
    console.log(`  data: ${describe(obj.data ?? obj)}`);
    console.log('');
  }
}
