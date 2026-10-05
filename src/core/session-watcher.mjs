/**
 * Watch `$DSH_HOME/sessions` and turn every session into reducer facts.
 *
 * One watcher instance owns the incremental bookkeeping (byte offsets, folded
 * log state, completion acknowledgements) so polling cost stays proportional to
 * *new* events rather than to session history.
 *
 * @module session-watcher
 */

import { readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';

import { readLogTail } from './session-log.mjs';
import { applyEvents, initialLogState } from './session-facts.mjs';
import { loadProjection } from './projection-cache.mjs';
import { toSessionFacts } from './session-snapshot.mjs';

/** Per-session incremental record. */
function createTracked(id, logFile, cacheFile) {
  return {
    id,
    logFile,
    cacheFile,
    offset: 0,
    log: initialLogState(),
    projection: null,
    /** newest `turn/end` seq already reported as a completion */
    reportedTurnEndSeq: null,
    /** first poll seeds the turn-end watermark without firing a completion */
    seeded: false,
    /** the session has produced events at least once */
    primed: false,
    /** log mtime from the last poll, for diagnostics */
    mtimeMs: 0,
  };
}

/**
 * Discover sessions on disk.
 * @param {string} sessionsRoot `$DSH_HOME/sessions`
 */
export async function discoverSessions(sessionsRoot) {
  const found = [];
  let workspaces;
  try {
    workspaces = await readdir(sessionsRoot, { withFileTypes: true });
  } catch {
    return found;
  }
  for (const workspace of workspaces) {
    if (!workspace.isDirectory()) continue;
    const workspaceDir = join(sessionsRoot, workspace.name);
    let sessions;
    try {
      sessions = await readdir(workspaceDir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const session of sessions) {
      if (!session.isDirectory()) continue;
      const dir = join(workspaceDir, session.name);
      let files;
      try {
        files = await readdir(dir);
      } catch {
        continue;
      }
      const logName = files.find((name) => name.endsWith('.jsonl.zstd'));
      if (logName === undefined) continue;
      found.push({ id: session.name, logFile: join(dir, logName) });
    }
  }
  return found;
}

/**
 * Poll every session once.
 *
 * @param {object} input
 * @param {string} input.sessionsRoot
 * @param {string} input.cacheRoot `$DSH_HOME/storages/session_projcache/sessions`
 * @param {Map<string, object>} input.tracked mutable map kept across polls
 * @param {number} input.now authoritative epoch ms
 * @param {number} [input.maxNewSessions] cap sessions folded from scratch per poll
 * @param {boolean} [input.exposeTitle]
 * @param {string} [input.language] UI language for fallback labels in the facts
 * @returns {Promise<{facts: Array<object>, completions: Array<{sessionId: string, at: number, kind: string}>, stats: object}>}
 */
export async function pollSessions({
  sessionsRoot,
  cacheRoot,
  tracked,
  now,
  maxNewSessions = 6,
  exposeTitle = false,
  language,
}) {
  const discovered = await discoverSessions(sessionsRoot);
  const completions = [];
  const facts = [];
  let folded = 0;
  let newSessions = 0;
  let bytesRead = 0;

  for (const { id, logFile } of discovered) {
    let record = tracked.get(id);
    if (record === undefined) {
      if (newSessions >= maxNewSessions) continue;
      newSessions += 1;
      record = createTracked(id, logFile, join(cacheRoot, `${id}.json`));
      tracked.set(id, record);
    }

    let info;
    try {
      info = await stat(logFile);
    } catch {
      continue;
    }

    // Captured BEFORE folding, because it decides whether this poll is the initial
    // catch-up or a genuine append. See the completion block below.
    const wasPrimed = record.primed;

    try {
      const tail = await readLogTail(logFile, record.offset);
      bytesRead += tail.bytes;
      if (tail.events.length > 0) {
        applyEvents(record.log, tail.events);
        folded += tail.events.length;
      }
      // Set on a successful read even when it yielded no complete frame. `primed`
      // means "this log's existing content has been read at least once", which is
      // what distinguishes history from news. Tying it to `events.length > 0` was a
      // bug: a log that was locked or mid-frame on the first poll left `primed`
      // false but `seeded` true, so the NEXT poll re-read the whole file from offset
      // 0 and reported a turn that had ended days earlier as a fresh completion.
      record.primed = true;
      record.offset = tail.offset;
    } catch {
      // The log may be locked or mid-rewrite; keep the previous fold state.
    }

    // The projection cache carries questions/todos the log never records.
    record.projection = await loadProjection(record.cacheFile);

    const sessionFacts = toSessionFacts({ log: record.log, projection: record.projection, id, now, exposeTitle, language });
    facts.push(sessionFacts);

    // Completion detection. A completion is only reported for a `turn/end` that
    // arrives *while this watcher is running* and that happened recently.
    //
    // Two guards, because both failure modes were observed:
    //
    //   1. `seeded` — the first time a session's history is read, the newest turn
    //      end is recorded as a watermark instead of firing. Launching the pet must
    //      not replay celebrations for turns that finished before it started.
    //
    //   2. `wasPrimed` — a completion is only news if the log had already been read
    //      once. Without this, a first poll that could not decode any frame (the log
    //      is locked, or its newest frame was still being written) left the session
    //      unprimed, and the next poll re-read the entire file from offset 0 and
    //      reported a days-old turn as if it had just happened.
    const endSeq = record.log.lastTurnEndSeq;
    if (!record.seeded || !wasPrimed) {
      record.seeded = true;
      record.reportedTurnEndSeq = typeof endSeq === 'number' ? endSeq : null;
    } else if (typeof endSeq === 'number' && (record.reportedTurnEndSeq === null || endSeq > record.reportedTurnEndSeq)) {
      record.reportedTurnEndSeq = endSeq;
      completions.push({
        sessionId: id,
        at: record.log.lastTurnEndedAt ?? now,
        kind: record.log.lastTurnCompleted ? 'done' : 'error',
      });
    }

    record.mtimeMs = info.mtimeMs;
  }

  return {
    facts,
    completions,
    stats: { sessions: discovered.length, tracked: tracked.size, folded, bytesRead },
  };
}
