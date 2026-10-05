/**
 * Session-watcher tests: the seeding rules that decide what counts as news.
 *
 * These cover a real bug. A completion must only be reported for a `turn/end` that
 * happens while the pet is watching. The original guard used a single `seeded` flag
 * set on the first poll, with `primed` (the log was read successfully) tied to
 * "decoded at least one frame". When a session's first poll decoded nothing — the
 * log was locked, or its newest frame was still being written — the session was
 * seeded but not primed, so the next poll re-read the whole file from offset 0 and
 * reported a turn that had ended DAYS earlier as a fresh completion. With
 * retention-until-clicked that stale bubble then pinned itself on screen until the
 * user clicked it.
 *
 * The tests drive the real watcher against a synthetic session store.
 */

import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { zstdCompressSync } from 'node:zlib';

import { pollSessions } from '../src/core/session-watcher.mjs';
import { initialLogState } from '../src/core/session-facts.mjs';

const NOW = 1701011262369;          // "now" for the pet
const OLD = NOW - 3 * 24 * 60 * 60 * 1000;   // a turn that ended three days ago

/** Build a session log: one independent zstd frame per event, as the app writes it. */
function frame(events) {
  const lines = events.map((event) => JSON.stringify(event)).join('\n') + '\n';
  return zstdCompressSync(Buffer.from(lines, 'utf8'));
}

function turnEnd(seq, at) {
  return { seq, time: at, type: 'turn/end', data: { reason: { kind: 'completed' } } };
}

/**
 * Create a session store with one session, and return its paths plus a rewrite hook
 * so a test can simulate a lock clearing between polls.
 */
async function makeStore(events) {
  const root = await mkdtemp(join(tmpdir(), 'pet-watch-'));
  const sessionsRoot = join(root, 'sessions');
  const cacheRoot = join(root, 'cache');
  const workspace = join(sessionsRoot, 'proj');
  const sessionDir = join(workspace, 'session-abc');
  await mkdir(sessionDir, { recursive: true });
  await mkdir(cacheRoot, { recursive: true });
  const logFile = join(sessionDir, 'session.v4.jsonl.zstd');
  await writeFile(logFile, frame(events));
  return { root, sessionsRoot, cacheRoot, logFile };
}

test('a first poll never reports a completion, even for a brand-new session', async () => {
  const store = await makeStore([turnEnd(1, OLD)]);
  const tracked = new Map();

  const first = await pollSessions({ ...store, tracked, now: NOW });
  assert.deepEqual(first.completions, [], 'launching the pet must not replay old completions');
});

test('a completion that arrives while watching IS reported', async () => {
  const store = await makeStore([turnEnd(1, OLD)]);
  const tracked = new Map();

  await pollSessions({ ...store, tracked, now: NOW });

  // A new turn ends while the pet is running.
  const { appendFile } = await import('node:fs/promises');
  await appendFile(store.logFile, frame([turnEnd(2, NOW + 1_000)]));

  const second = await pollSessions({ ...store, tracked, now: NOW + 1_000 });
  assert.equal(second.completions.length, 1);
  assert.equal(second.completions[0].sessionId, 'session-abc');
  assert.equal(second.completions[0].kind, 'done');
  assert.equal(second.completions[0].at, NOW + 1_000);
});

test('a first poll that decodes nothing does not turn history into news', async () => {
  // The regression. The first poll cannot decode a frame (the log is locked, or its
  // newest frame is still being written), so it keeps an empty fold state and learns
  // nothing. The next poll then reads the whole file from offset 0. Without the
  // `primed` guard that re-read reported a turn which had ended THREE DAYS earlier as
  // a fresh completion — and because retention is until-clicked, that stale bubble
  // then pinned itself on screen.
  const store = await makeStore([turnEnd(1, OLD)]);
  const tracked = new Map();

  await pollSessions({ ...store, tracked, now: NOW });
  const record = tracked.get('session-abc');
  assert.ok(record, 'the session is tracked');

  // Rewind the record to exactly the state a failed read leaves behind: nothing
  // decoded, the fold state untouched, and the offset still at the start.
  record.primed = false;
  record.offset = 0;
  record.log = initialLogState();
  record.seeded = true;
  record.reportedTurnEndSeq = null;

  const afterReread = await pollSessions({ ...store, tracked, now: NOW + 5_000 });
  assert.deepEqual(
    afterReread.completions,
    [],
    'a 3-day-old turn must never surface as a fresh completion',
  );
  assert.equal(record.primed, true, 'a successful read primes even with no events');
});

test('the same completion is reported once, not on every poll', async () => {
  const store = await makeStore([turnEnd(1, OLD)]);
  const tracked = new Map();
  const { appendFile } = await import('node:fs/promises');

  await pollSessions({ ...store, tracked, now: NOW });
  await appendFile(store.logFile, frame([turnEnd(2, NOW + 1_000)]));

  const first = await pollSessions({ ...store, tracked, now: NOW + 1_000 });
  assert.equal(first.completions.length, 1, 'reported when it happens');

  const second = await pollSessions({ ...store, tracked, now: NOW + 2_000 });
  assert.deepEqual(second.completions, [], 'not reported again afterwards');
});
