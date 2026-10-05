/**
 * Completion records: what the pet remembers about conversations that finished.
 *
 * A record exists so a completion can be surfaced — dialog box, green dot, list row —
 * until the user dismisses it by clicking. Retention is therefore driven by
 * ACKNOWLEDGEMENT, not by a timer.
 *
 * The store is PERSISTED by the bridge (see `state/pet-completions.json`). Keeping it in
 * memory only was a real bug: every restart forgot which conversations the user had
 * already clicked, so all of them reappeared as unread.
 *
 * @typedef {object} CompletionRecord
 * @property {number} at - Epoch ms when the turn ended.
 * @property {'done'|'error'} kind - How it ended.
 * @property {boolean} acknowledged - True once the user clicked it.
 */

/**
 * Validate a record loaded from disk.
 *
 * A restore path must not trust its input: the file is written by a previous build and
 * could predate a shape change, and a malformed record would otherwise flow into the
 * reducer as `NaN` timestamps and render as nonsense.
 *
 * @param {unknown} value
 * @returns {CompletionRecord|null} The record, or null when it is unusable.
 */
export function reviveCompletion(value) {
  if (value === null || typeof value !== 'object') return null;
  const record = /** @type {Record<string, unknown>} */ (value);
  const at = typeof record.at === 'number' && Number.isFinite(record.at) ? record.at : null;
  if (at === null) return null;
  const kind = record.kind === 'error' ? 'error' : 'done';
  return { at, kind, acknowledged: record.acknowledged === true };
}

/**
 * Restore a persisted store, dropping anything malformed.
 *
 * @param {unknown} value - Parsed file contents.
 * @returns {Record<string, CompletionRecord>} A fresh map.
 */
export function reviveCompletions(value) {
  const out = {};
  if (value === null || typeof value !== 'object') return out;
  for (const [id, record] of Object.entries(/** @type {Record<string, unknown>} */ (value))) {
    if (typeof id !== 'string' || id === '') continue;
    const revived = reviveCompletion(record);
    if (revived !== null) out[id] = revived;
  }
  return out;
}

/**
 * Drop completion records that no longer need to be remembered.
 *
 * Two kinds of record, with deliberately different lifetimes:
 *
 *   * **Unacknowledged** — the user has not seen this yet, so it is kept so they still
 *     can. Bounded by `maxAgeMs`, past which it is history rather than news: the pet is
 *     not a history view, and a task from many hours ago is no longer "just finished".
 *
 *   * **Acknowledged** — the user clicked it, and the record is the ONLY memory of that
 *     decision. It is therefore kept for as long as it is useful, bounded by count rather
 *     than by age.
 *
 * Deleting an acknowledged record by age was a real bug: it discarded the evidence that
 * the user had already dealt with that completion, so anything that later re-observed the
 * same turn (a log frame re-read, a bridge restart that failed to seed its watermark)
 * created a fresh UNREAD record and the box the user had dismissed reappeared. Keeping the
 * record means the same turn can never be presented as unread again, while a genuinely
 * NEWER reply still produces a new, unread record.
 *
 * @param {Record<string, CompletionRecord>} completions - Current records, keyed by session id.
 * @param {object} options - Pruning policy.
 * @param {number} options.now - Current epoch ms.
 * @param {number} [options.completionTtlMs] - Unused for retention; retained in the
 *   signature because callers pass the configured reminder window through.
 * @param {number} [options.maxAgeMs] - Age beyond which an UNREAD record is history.
 * @param {number} [options.maxUnacknowledged] - Cap on retained unread records.
 * @param {number} [options.maxAcknowledged] - Cap on retained dismissed records.
 * @returns {Record<string, CompletionRecord>} A new map; the input is not mutated.
 */
export function pruneCompletions(completions, options) {
  const {
    now,
    maxAgeMs = 12 * 60 * 60 * 1000,
    maxUnacknowledged = 20,
    maxAcknowledged = 200,
  } = options;

  const kept = {};
  const unread = [];
  const read = [];

  for (const [id, record] of Object.entries(completions)) {
    if (record.acknowledged === true) {
      read.push([id, record]);
      continue;
    }
    if (now - record.at > maxAgeMs) continue;
    unread.push([id, record]);
  }

  // Both caps are safety valves rather than retention policy: they only matter if
  // something generates sessions far faster than a person can click them. Newest first,
  // so the entries most likely to still be relevant survive.
  unread.sort((left, right) => right[1].at - left[1].at);
  for (const [id, record] of unread.slice(0, maxUnacknowledged)) kept[id] = record;

  read.sort((left, right) => right[1].at - left[1].at);
  for (const [id, record] of read.slice(0, maxAcknowledged)) kept[id] = record;

  return kept;
}

/**
 * Fold newly observed completions and explicit acknowledgements into the store.
 *
 * A re-observed completion must not resurrect an acknowledged one: the record is only
 * replaced when it is genuinely new (a later turn ending), which is what lets the same
 * conversation notify again after the user has dealt with the previous reply.
 *
 * @param {Record<string, CompletionRecord>} completions - Current records.
 * @param {object} input - What happened this poll.
 * @param {Array<{sessionId: string, at: number, kind: 'done'|'error'}>} input.observed - Completions seen this poll.
 * @param {Iterable<string|{sessionId: string, at?: number}>} input.acknowledged - Completions the user clicked.
 * @returns {Record<string, CompletionRecord>} A new map; the input is not mutated.
 */
export function applyCompletions(completions, input) {
  const { observed, acknowledged } = input;
  const next = { ...completions };

  for (const completion of observed) {
    const existing = next[completion.sessionId];
    // Same turn or older: the user's earlier decision still stands, so nothing changes.
    // This is what stops a re-read frame from re-presenting a dismissed completion.
    if (existing !== undefined && completion.at <= existing.at) continue;
    // A genuinely newer turn: a fresh, unread record, so the conversation notifies again.
    next[completion.sessionId] = { at: completion.at, kind: completion.kind, acknowledged: false };
  }

  // An acknowledgement refers to ONE completion, identified by the moment the turn ended —
  // not to the session for all time. The shell keeps reporting the dismissal it made so the
  // box does not flash back before the next poll, and comparing timestamps means a standing
  // report cannot silence a newer completion.
  for (const ack of acknowledged) {
    const id = typeof ack === 'string' ? ack : ack?.sessionId;
    if (id === undefined) continue;
    // A bare session id (the older shell shape) carries no timestamp, so it dismisses
    // whatever is currently recorded.
    const at = typeof ack === 'string' ? undefined : ack?.at;

    const record = next[id];
    if (record === undefined || record.acknowledged === true) continue;
    if (at !== undefined && record.at > at) continue;
    next[id] = { ...record, acknowledged: true };
  }

  return next;
}
