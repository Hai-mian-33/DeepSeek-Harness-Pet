// Inspect a DSH session log: walk concatenated zstd frames, summarize the event
// vocabulary by TYPE ONLY (no prompts, replies, or tool arguments are printed).
import { readFile } from 'node:fs/promises';
import { zstdDecompressSync } from 'node:zlib';

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const file = process.argv[2];
const buf = await readFile(file);

/** Try to decode one complete zstd frame starting at `offset`. */
function frameAt(offset) {
  let end = offset + 1;
  while (end <= buf.length) {
    try {
      return { text: zstdDecompressSync(buf.subarray(offset, end)).toString('utf8'), end };
    } catch (error) {
      if (error.code === 'ZSTD_error_frameParameter_unsupported') console.error(`  ! unsupported frame at ${offset}`);
      end++;
    }
  }
  return undefined;
}

const texts = [];
let offset = 0;
let frames = 0;
let pendingFrom = 0;
while (offset < buf.length) {
  const next = buf.indexOf(MAGIC, offset);
  if (next < 0) { pendingFrom = offset; break; }
  const frame = frameAt(next);
  if (!frame) { pendingFrom = next; break; }
  texts.push(frame.text);
  frames++;
  offset = frame.end;
}
const text = texts.join('');
console.log(`frames=${frames} pendingBytes=${buf.length - pendingFrom} text=${text.length} bytes`);

const lines = text.split('\n').filter((line) => line.trim() !== '');
console.log(`jsonl lines: ${lines.length}`);

const counts = new Map();
const shape = new Map();
for (const line of lines) {
  let obj;
  try { obj = JSON.parse(line); } catch { counts.set('(unparsable)', (counts.get('(unparsable)') ?? 0) + 1); continue; }
  const type = obj.type ?? '(untyped)';
  counts.set(type, (counts.get(type) ?? 0) + 1);
  if (!shape.has(type)) {
    const data = obj.data ?? {};
    shape.set(type, Object.keys(data).slice(0, 12).join(','));
  }
}
console.log('--- event types (count, data keys) ---');
[...counts.entries()].sort((a, b) => b[1] - a[1]).forEach(([type, n]) => {
  console.log(`${String(n).padStart(6)}  ${type}${shape.has(type) ? `  {${shape.get(type)}}` : ''}`);
});
