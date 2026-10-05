#!/usr/bin/env node
// Decompress the DSH Desktop boot manifest (zstd) to plain JSON for inspection.
import { readFile, writeFile } from 'node:fs/promises';
import { zstdDecompressSync } from 'node:zlib';

const [, , input, output] = process.argv;
if (!input || !output) {
  console.error('usage: unzstd.mjs <input.json> <output.json>');
  process.exit(2);
}
const compressed = await readFile(input);
const plain = zstdDecompressSync(compressed);
await writeFile(output, plain);
console.log(`wrote ${plain.length} bytes to ${output}`);
