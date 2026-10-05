// Print the distinct scalar values of `turn/end.reason` and the shape of
// approval audit events. Scalars only — no content is printed.
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { zstdDecompressSync } from 'node:zlib';

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const root = process.argv[2];

function frames(buf) {
  const events = [];
  let offset = 0;
  while (offset < buf.length) {
    const next = buf.indexOf(MAGIC, offset);
    if (next < 0) break;
    let end = next + 1;
    let text;
    for (;;) {
      if (end > buf.length) break;
      try { text = zstdDecompressSync(buf.subarray(next, end)).toString('utf8'); break; } catch { end++; }
    }
    if (text === undefined) break;
    for (const line of text.split('\n')) {
      if (line.trim() === '') continue;
      try { events.push(JSON.parse(line)); } catch { /* skip */ }
    }
    offset = end;
  }
  return events;
}

const reasons = new Map();
const approvals = [];
for (const dir of await readdir(root, { withFileTypes: true })) {
  if (!dir.isDirectory()) continue;
  for (const sub of await readdir(join(root, dir.name), { withFileTypes: true })) {
    if (!sub.isDirectory()) continue;
    for (const name of await readdir(join(root, dir.name, sub.name))) {
      if (!name.endsWith('.jsonl.zstd')) continue;
      for (const e of frames(await readFile(join(root, dir.name, sub.name, name)))) {
        if (e.type === 'turn/end') {
          const key = JSON.stringify(e.data);
          reasons.set(key, (reasons.get(key) ?? 0) + 1);
        }
        if (e.type === 'approval/asked' || e.type === 'approval/decided') approvals.push(e);
      }
    }
  }
}
console.log('--- turn/end data values ---');
[...reasons.entries()].forEach(([k, n]) => console.log(`${String(n).padStart(4)}  ${k}`));
console.log('--- approval events ---');
if (approvals.length === 0) console.log('(none in any log)');
approvals.slice(0, 10).forEach((e) => console.log(`${e.type} seq=${e.seq} ${JSON.stringify(Object.keys(e.data))} ${JSON.stringify(e.data).slice(0, 240)}`));
