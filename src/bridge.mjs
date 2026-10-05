/**
 * Pet bridge: the only process that touches the Harness filesystem.
 *
 * It polls the DSH session store, folds real session events into privacy-bounded
 * facts, runs them through `PetReducer`, and publishes one JSON snapshot plus
 * the sprite manifest. The shell (WPF) reads that snapshot and never reads the
 * Harness store itself — a deliberate seam that keeps every privacy rule in one
 * auditable file and lets the renderer be replaced without touching the data
 * path.
 *
 * Snapshot publication is atomic (write temp, then rename) so the renderer can
 * never read a half-written document. The brief's SSE/real-time requirement is
 * met by *tail* subscription rather than by a network stream: the bridge keeps a
 * per-session byte offset and only decodes frames appended since the last poll,
 * and the renderer re-reads the snapshot on a fast tick. If a poll throws, the
 * bridge keeps serving the last good snapshot and marks itself degraded, which
 * is the reconnect-and-poll-fallback behaviour the brief asks for without a
 * socket to break.
 *
 * @module bridge
 */

import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { createClockTracker } from './core/clock.mjs';
import { applyCompletions, pruneCompletions, reviveCompletions } from './core/completions.mjs';
import { DEFAULT_LANGUAGE, normalizeLanguage } from './core/i18n.mjs';
import { reducePet } from './core/pet-reducer.mjs';
import { pollSessions } from './core/session-watcher.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(here, '..');

/** Resolve `$DSH_HOME` the way the harness does. */
function resolveDshHome() {
  if (typeof process.env.DSH_HOME === 'string' && process.env.DSH_HOME !== '') return process.env.DSH_HOME;
  return join(process.env.USERPROFILE ?? homedir(), '.dsh');
}

/** Parse `--key value` / `--flag` arguments. */
function parseArgs(argv) {
  const options = {
    home: resolveDshHome(),
    stateDir: join(projectRoot, 'state'),
    pollMs: 1000,
    exposeTitle: false,
    longTaskMs: 600_000,
    completionTtlMs: 30_000,
    quietMs: 45_000,
    language: DEFAULT_LANGUAGE,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => argv[++i];
    if (arg === '--home') options.home = next();
    else if (arg === '--state-dir') options.stateDir = resolve(next());
    else if (arg === '--poll-ms') options.pollMs = Number(next());
    else if (arg === '--expose-title') options.exposeTitle = true;
    else if (arg === '--long-task-ms') options.longTaskMs = Number(next());
    else if (arg === '--completion-ttl-ms') options.completionTtlMs = Number(next());
    else if (arg === '--quiet-ms') options.quietMs = Number(next());
    else if (arg === '--lang') options.language = normalizeLanguage(next());
  }
  return options;
}

/**
 * Read the shell-written control document.
 *
 * The shell owns interaction state (hover, drag, acknowledgement, which
 * conversation the Harness window is on) and hands it back through this file,
 * so the bridge stays a pure function of (harness store, control file).
 *
 * The shell also publishes its UI language here, which is how a right-click
 * language switch reaches the data side without any new channel: the labels in
 * the next snapshot come back in the requested language.
 */
async function readControl(file) {
  try {
    const parsed = JSON.parse(await readFile(file, 'utf8'));
    return {
      hovered: parsed.hovered === true,
      dragging: parsed.dragging === true,
      activeSessionId: typeof parsed.activeSessionId === 'string' ? parsed.activeSessionId : null,
      acknowledged: readAcknowledgements(parsed.acknowledged),
      paused: parsed.paused === true,
      tick: typeof parsed.tick === 'number' ? parsed.tick : 0,
      language: normalizeLanguage(parsed.language),
    };
  } catch {
    return {
      hovered: false,
      dragging: false,
      activeSessionId: null,
      acknowledged: [],
      paused: false,
      tick: 0,
      language: DEFAULT_LANGUAGE,
    };
  }
}

/**
 * Normalise the shell's acknowledgement list.
 *
 * The shell reports each dismissal as `{sessionId, at}`, because a dismissal applies to ONE
 * reply rather than to the conversation for all time. This function previously accepted only
 * bare strings and filtered everything else out, so **every acknowledgement was silently
 * discarded** and the bridge never learned about any click: a conversation the user had
 * opened stayed marked unread and reappeared on every restart, which is exactly the bug that
 * was reported repeatedly.
 *
 * Both shapes are accepted: the object form (current) and a bare session id (written by an
 * older shell, dismissed without a timestamp).
 *
 * @param {unknown} value
 * @returns {Array<string|{sessionId: string, at?: number}>}
 */
function readAcknowledgements(value) {
  if (!Array.isArray(value)) return [];
  const out = [];
  for (const entry of value) {
    if (typeof entry === 'string') {
      if (entry !== '') out.push(entry);
      continue;
    }
    if (entry !== null && typeof entry === 'object'
        && typeof entry.sessionId === 'string' && entry.sessionId !== '') {
      const at = typeof entry.at === 'number' && Number.isFinite(entry.at) ? entry.at : undefined;
      out.push(at === undefined ? entry.sessionId : { sessionId: entry.sessionId, at });
    }
  }
  return out;
}

/** Atomically publish a JSON document. */
async function publishJson(file, value) {
  const temp = `${file}.tmp`;
  await writeFile(temp, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  await rename(temp, file);
}

/** Load the sprite manifest once; a renamed/moved sheet is a build error, not a runtime one. */
async function loadManifest() {
  try {
    return JSON.parse(await readFile(join(projectRoot, 'assets', 'whale-sheet.json'), 'utf8'));
  } catch {
    return null;
  }
}

/**
 * Restore the persisted completion store.
 *
 * A missing or unreadable file is normal on a first run and simply means "nothing has
 * been dismissed yet". A malformed one must not take the bridge down either: the store is
 * a cache of the user's clicks, not authoritative data, so the safe recovery is to start
 * empty rather than to crash the pet.
 */
async function loadCompletions(file) {
  try {
    return reviveCompletions(JSON.parse(await readFile(file, 'utf8')));
  } catch {
    return {};
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const sessionsRoot = join(options.home, 'sessions');
  const cacheRoot = join(options.home, 'storages', 'session_projcache', 'sessions');
  const snapshotFile = join(options.stateDir, 'pet-state.json');
  const controlFile = join(options.stateDir, 'pet-control.json');
  const statusFile = join(options.stateDir, 'bridge-status.json');

  await mkdir(options.stateDir, { recursive: true });

  const clock = createClockTracker();
  const tracked = new Map();
  // Dismissal memory, restored from disk. In memory only, every restart forgot which
  // conversations had been clicked and resurrected all of them as unread — which is
  // exactly what the user saw after each restart.
  const completionFile = join(options.stateDir, 'pet-completions.json');
  let completions = await loadCompletions(completionFile);
  // Last poll's activeSessionId, so acknowledging on entry into a session happens
  // once rather than on every poll. See the completion bookkeeping below.
  let previousActiveSessionId = null;
  const manifest = await loadManifest();

  let sequence = 0;
  let errors = 0;
  let lastError = null;
  let lastPollAt = 0;
  // Serialized form of the last persisted store, so an unchanged store is not rewritten
  // every second.
  let lastCompletionsJson = null;
  let lastStats = { sessions: 0, tracked: 0, folded: 0, bytesRead: 0 };
  let stopping = false;

  const stop = () => { stopping = true; };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);

  while (!stopping) {
    const started = Date.now();
    const control = await readControl(controlFile);

    try {
      const poll = await pollSessions({
        sessionsRoot,
        cacheRoot,
        tracked,
        now: clock.reading().now,
        exposeTitle: options.exposeTitle,
        language: control.language,
      });
      lastStats = poll.stats;

      for (const session of poll.facts) {
        if (typeof session.time === 'number') clock.observe(session.time);
      }

      const reading = clock.reading();

      // Completion bookkeeping. Retention is by acknowledgement, not by a timer:
      // an unread completion is remembered until the user clicks it, so `prune`
      // only discards records that are acknowledged (or beyond the unread cap).
      //
      // `activeSessionId` is folded in only on the transition into it. The shell
      // keeps that value set for as long as the session is the one on screen, so
      // acknowledging it on every poll would silently suppress every FUTURE
      // completion of the same conversation — the click would be treated as a
      // standing "seen everything here" flag rather than a one-off dismissal.
      for (const completion of poll.completions) clock.observe(completion.at);

      const newlyActive = control.activeSessionId !== null && control.activeSessionId !== previousActiveSessionId
        ? [control.activeSessionId]
        : [];

      let nextCompletions = applyCompletions(completions, {
        observed: poll.completions,
        acknowledged: [...control.acknowledged, ...newlyActive],
      });
      previousActiveSessionId = control.activeSessionId;
      completions = pruneCompletions(nextCompletions, {
        now: reading.now,
        completionTtlMs: options.completionTtlMs,
      });

      // Persist on every change, so a restart (including the one `start-pet.cmd` performs
      // automatically) cannot forget a dismissal. Written only when the content actually
      // changed: the file is small but this runs once a second forever.
      const serialized = JSON.stringify(completions);
      if (serialized !== lastCompletionsJson) {
        lastCompletionsJson = serialized;
        await publishJson(completionFile, completions);
      }

      const view = reducePet({
        sessions: poll.facts,
        now: reading.now,
        activeSessionId: control.activeSessionId,
        completions,
        dragging: control.dragging,
        hovered: control.hovered,
        completionTtlMs: options.completionTtlMs,
        longTaskMs: options.longTaskMs,
        quietMs: options.quietMs,
        lang: control.language,
      });

      sequence += 1;
      await publishJson(snapshotFile, {
        schema: 'dsh-pet-state/1',
        language: control.language,
        sequence,
        generatedAt: reading.localNow,
        clock: { now: reading.now, localNow: reading.localNow, skew: reading.skew },
        degraded: errors > 0,
        sprite: manifest,
        view,
        sessions: poll.facts.map((session) => ({
          id: session.id,
          name: session.name,
          status: view.entries.find((entry) => entry.id === session.id)?.status ?? 'idle',
          lastToolName: session.lastToolName,
          toolCalls: session.toolCalls,
          todoDone: session.todoDone,
          todoTotal: session.todoTotal,
        })),
      });
    } catch (error) {
      errors += 1;
      lastError = error instanceof Error ? error.message : String(error);
    }

    lastPollAt = Date.now();
    await publishJson(statusFile, {
      schema: 'dsh-pet-bridge-status/1',
      pid: process.pid,
      home: options.home,
      sessionsRoot,
      cacheRoot,
      pollMs: options.pollMs,
      pollCount: sequence,
      errors,
      lastError,
      lastPollAt,
      lastPollDurationMs: lastPollAt - started,
      stats: lastStats,
      trackedSessions: [...tracked.keys()],
      exposeTitle: options.exposeTitle,
    });

    const elapsed = Date.now() - started;
    const wait = Math.max(50, options.pollMs - elapsed);
    await new Promise((resolveWait) => setTimeout(resolveWait, wait));
  }
}

export { main, parseArgs, resolveDshHome, readControl, readAcknowledgements };

if (process.argv[1] !== undefined && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  main().catch((error) => {
    console.error('[bridge] fatal:', error);
    process.exitCode = 1;
  });
}
