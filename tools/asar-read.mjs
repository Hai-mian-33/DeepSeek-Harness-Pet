#!/usr/bin/env node
// Minimal asar reader: list / extract / cat files from an Electron asar archive.
// Usage:
//   node asar-read.mjs ls   <asar> [prefix]
//   node asar-read.mjs cat  <asar> <innerPath>
//   node asar-read.mjs extract <asar> <innerPrefix> <outDir>
import { open, mkdir, writeFile } from 'node:fs/promises';
import { dirname, join, relative, sep } from 'node:path';

const HEADER_SIZE = 16;

async function readHeader(asar) {
  const fh = await open(asar, 'r');
  const head = Buffer.alloc(HEADER_SIZE);
  await fh.read(head, 0, HEADER_SIZE, 0);
  const jsonSize = head.readUInt32LE(12);
  const buf = Buffer.alloc(jsonSize);
  let read = 0;
  while (read < jsonSize) {
    const { bytesRead } = await fh.read(buf, read, jsonSize - read, HEADER_SIZE + read);
    if (bytesRead <= 0) break;
    read += bytesRead;
  }
  await fh.close();
  const header = JSON.parse(buf.subarray(0, read).toString('utf8'));
  // Offsets in file entries are relative to the start of the content section.
  const contentBase = HEADER_SIZE + Number(header.size ?? jsonSize);
  return { header, contentBase, fh: null };
}

function walk(node, prefix, out) {
  for (const [name, val] of Object.entries(node.files ?? {})) {
    const p = prefix ? `${prefix}/${name}` : name;
    if (val.files) walk(val, p, out);
    else out.push({ path: p, ...val });
  }
}

function findEntry(header, innerPath) {
  const parts = innerPath.split('/').filter(Boolean);
  let node = header;
  for (const part of parts) {
    node = node.files?.[part];
    if (!node) return null;
  }
  return node;
}

async function readContent(asar, contentBase, entry) {
  const fh = await open(asar, 'r');
  const size = Number(entry.size);
  const start = contentBase + Number(entry.offset);
  const buf = Buffer.alloc(size);
  let read = 0;
  while (read < size) {
    const { bytesRead } = await fh.read(buf, read, size - read, start + read);
    if (bytesRead <= 0) break;
    read += bytesRead;
  }
  await fh.close();
  return buf.subarray(0, read);
}

const [cmd, asar, ...rest] = process.argv.slice(2);
if (!cmd || !asar) {
  console.error('usage: asar-read.mjs <ls|cat|extract> <asar> [...]');
  process.exit(2);
}
const { header, contentBase } = await readHeader(asar);

if (cmd === 'ls') {
  const prefix = rest[0] ?? '';
  const all = [];
  walk(header, '', all);
  for (const e of all) if (e.path.startsWith(prefix)) console.log(`${e.size}\t${e.path}`);
} else if (cmd === 'cat') {
  const entry = findEntry(header, rest[0]);
  if (!entry || entry.files) {
    console.error(`not a file: ${rest[0]}`);
    process.exit(1);
  }
  process.stdout.write(await readContent(asar, contentBase, entry));
} else if (cmd === 'catto') {
  const entry = findEntry(header, rest[0]);
  if (!entry || entry.files) {
    console.error(`not a file: ${rest[0]}`);
    process.exit(1);
  }
  await writeFile(rest[1], await readContent(asar, contentBase, entry));
  console.log(`wrote ${rest[1]}`);
} else if (cmd === 'extract') {
  const prefix = rest[0];
  const outDir = rest[1];
  const all = [];
  walk(header, '', all);
  const hits = all.filter((e) => e.path.startsWith(prefix));
  for (const e of hits) {
    const rel = relative(prefix, e.path).split(sep).join('/');
    const dest = join(outDir, rel);
    await mkdir(dirname(dest), { recursive: true });
    await writeFile(dest, await readContent(asar, contentBase, e));
  }
  console.log(`extracted ${hits.length} files to ${outDir}`);
} else {
  console.error(`unknown command: ${cmd}`);
  process.exit(2);
}
