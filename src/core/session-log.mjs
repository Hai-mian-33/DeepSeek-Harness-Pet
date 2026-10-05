/**
 * Read a DSH session log (`session.v4.jsonl.zstd`).
 *
 * The persistence layer appends one independent zstd frame per checkpoint, so
 * the file is a concatenation of frames rather than one stream. That is what
 * makes tailing cheap: each complete frame decompresses on its own, and the
 * only state to carry across polls is a byte offset.
 *
 * The reader is deliberately tolerant. A frame that is still being written
 * fails to decompress and is simply left for the next poll, which is the
 * normal case while an agent is streaming output.
 *
 * @module session-log
 */

import { readFile } from 'node:fs/promises';
import { zstdDecompressSync } from 'node:zlib';

/** zstd frame magic number, little-endian. */
export const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

const MAX_FRAME_BYTES = 512 * 1024 * 1024;

/**
 * Load the events appended to a log since `fromOffset`.
 *
 * @param {string} file absolute log path
 * @param {number} fromOffset byte offset of the last consumed frame boundary
 * @returns {Promise<{events: Array<object>, offset: number, bytes: number, frames: number}>}
 *   `offset` is the new frame boundary; bytes before it are fully consumed.
 */
export async function readLogTail(file, fromOffset = 0) {
  const buffer = await readFile(file);
  return decodeFrames(buffer, fromOffset);
}

/**
 * Decode every complete frame in `buffer` starting at `fromOffset`.
 *
 * Two strategies, because frame sizes vary by four orders of magnitude (tiny
 * state-only checkpoints and multi-megabyte assistant messages):
 *
 * 1. Fast path — one whole-buffer decode. This is what makes the first read of
 *    a long session cheap, and it validates the common case in a single call.
 * 2. Two-pointer scan — a forward pointer searches for the next frame magic
 *    while a trailing pointer grows a window. Each byte is examined a bounded
 *    number of times, so a multi-frame file cannot degrade into re-decoding
 *    every prefix of every frame.
 *
 * @param {Buffer} buffer whole-file buffer
 * @param {number} fromOffset byte offset to resume from
 * @returns {{events: Array<object>, offset: number, bytes: number, frames: number}}
 */
export function decodeFrames(buffer, fromOffset = 0) {
  let offset = Math.max(0, Math.min(fromOffset, buffer.length));
  if (offset >= buffer.length) return { events: [], offset, bytes: buffer.length, frames: 0 };

  // Fast path: the remainder is exactly one complete frame. Node's zstd decoder
  // stops at the end of the first frame in its input *without* reporting an
  // error, so a successful call is not proof that the whole slice was consumed.
  // The trailing magic check is what makes this path strict: any leftover frame
  // header means there is more to decode, and the scan below owns it.
  const whole = tryDecompress(buffer.subarray(offset));
  if (whole !== null && buffer.indexOf(ZSTD_MAGIC, offset + 4) < 0) {
    return { events: parseLines(whole), offset: buffer.length, bytes: buffer.length, frames: 1 };
  }

  const events = [];
  let frames = 0;
  let cursor = offset;
  while (cursor < buffer.length) {
    const start = buffer.indexOf(ZSTD_MAGIC, cursor);
    if (start < 0) break;

    // Two pointers: `probe` grows the candidate window, `start` never moves
    // backwards, so each byte participates in a bounded number of attempts.
    let probe = start + 1;
    let boundary = -1;
    let text = null;
    while (probe <= buffer.length) {
      const attempt = tryDecompress(buffer.subarray(start, probe));
      if (attempt !== null) {
        text = attempt;
        boundary = probe;
        break;
      }
      const next = buffer.indexOf(ZSTD_MAGIC, probe);
      probe = next < 0 ? buffer.length + 1 : next;
    }

    // A trailing frame that never completes is left for the next poll.
    if (text === null || boundary < 0) break;

    events.push(...parseLines(text));
    frames += 1;
    cursor = boundary;
  }

  return { events, offset: cursor, bytes: buffer.length, frames };
}

/** Decompress `slice` or return `null` when it is not one complete frame. */
function tryDecompress(slice) {
  if (slice.length < 4) return null;
  if (slice[0] !== 0x28 || slice[1] !== 0xb5 || slice[2] !== 0x2f || slice[3] !== 0xfd) return null;
  try {
    return zstdDecompressSync(slice, { maxOutputLength: MAX_FRAME_BYTES }).toString('utf8');
  } catch {
    return null;
  }
}

/** Split a decoded frame body into JSON events, skipping a torn tail line. */
function parseLines(text) {
  const events = [];
  for (const line of text.split('\n')) {
    if (line === '') continue;
    try {
      events.push(JSON.parse(line));
    } catch {
      // A torn JSON line is not actionable; the next frame repeats a consistent
      // view, so skipping is safe.
    }
  }
  return events;
}
