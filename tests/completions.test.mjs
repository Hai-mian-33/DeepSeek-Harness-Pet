/**
 * Completion-store tests.
 *
 * These cover the pruning and acknowledgement policy that the bridge applies BEFORE
 * calling the reducer. The distinction matters: a reducer test can assert that an
 * unread completion is retained indefinitely while the running bridge still deletes
 * it after two minutes, because the deletion happened in the bridge and the test
 * never called it. That was a real bug, so the policy now lives in a pure module and
 * is exercised here.
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import { applyCompletions, pruneCompletions } from '../src/core/completions.mjs';

const T0 = 1701011262369;
const TTL = 30_000;

test('an unread completion survives long past the reminder window', () => {
  // The regression: pruning on `completionTtlMs` alone withdrew a completion the
  // user had not seen. The bridge used to drop it after 120 s.
  const completions = { s: { at: T0, kind: 'done', acknowledged: false } };

  for (const age of [1_000, 60_000, 120_000, 10 * 60_000, 60 * 60_000]) {
    const kept = pruneCompletions(completions, { now: T0 + age, completionTtlMs: TTL });
    assert.deepEqual(
      Object.keys(kept),
      ['s'],
      `an unread completion must survive ${age} ms (the bridge used to drop it at 120 s)`,
    );
  }
});

test('an unread completion older than the history bound is dropped', () => {
  // Retention is by acknowledgement, but the pet is not a history view: a record
  // from many hours ago is no longer "a task that just finished". This also means no
  // bug elsewhere can pin a stale bubble forever.
  const completions = { s: { at: T0, kind: 'done', acknowledged: false } };

  const withinBound = pruneCompletions(completions, { now: T0 + 6 * 60 * 60_000, completionTtlMs: TTL });
  assert.deepEqual(Object.keys(withinBound), ['s']);

  const beyondBound = pruneCompletions(completions, { now: T0 + 24 * 60 * 60_000, completionTtlMs: TTL });
  assert.deepEqual(Object.keys(beyondBound), [], 'a day-old unread completion is history');
});

test('an acknowledged completion is remembered, not age-pruned', () => {
  // This asserted the opposite until the bug it caused was found: dropping an
  // acknowledged record by age throws away the only memory that the user dismissed that
  // completion, so anything re-observing the same turn presents it as unread again and the
  // box the user clicked reappears. The record is therefore bounded by COUNT, not by age.
  const completions = { s: { at: T0, kind: 'done', acknowledged: true } };

  const fresh = pruneCompletions(completions, { now: T0 + 5_000, completionTtlMs: TTL });
  assert.deepEqual(Object.keys(fresh), ['s'], 'kept briefly so the dismissal can render');

  const stale = pruneCompletions(completions, { now: T0 + TTL + 1, completionTtlMs: TTL });
  assert.deepEqual(Object.keys(stale), ['s'], 'still remembered: it is the dismissal record');

  const ancient = pruneCompletions(completions, { now: T0 + 24 * 60 * 60_000, completionTtlMs: TTL });
  assert.deepEqual(Object.keys(ancient), ['s'], 'age does not forget a dismissal');
});

test('the acknowledged-record cap keeps the newest, and drops the oldest', () => {
  // The count cap is the only thing that bounds this store, so it must prefer the records
  // most likely to still matter.
  const completions = {};
  for (let i = 0; i < 30; i++) {
    completions[`s${i}`] = { at: T0 + i, kind: 'done', acknowledged: true };
  }
  const kept = pruneCompletions(completions, { now: T0 + 1000, maxAcknowledged: 5 });
  assert.deepEqual(Object.keys(kept).sort(), ['s25', 's26', 's27', 's28', 's29']);
});

test('re-observing an old completion does not resurrect an acknowledged one', () => {
  // The session log replays its last turn/end on a fresh bridge, and a poll can see
  // the same completion more than once. Neither may undo the user's click.
  const acknowledged = { s: { at: T0, kind: 'done', acknowledged: true } };
  const afterReplay = applyCompletions(acknowledged, {
    observed: [{ sessionId: 's', at: T0, kind: 'done' }],
    acknowledged: [],
  });
  assert.equal(afterReplay.s.acknowledged, true, 'the earlier click still stands');
});

test('a later turn in the same conversation notifies again', () => {
  // Acknowledgements are per completion, not per session. A new turn ending after
  // the acknowledged one starts a fresh unread reminder.
  const acknowledged = { s: { at: T0, kind: 'done', acknowledged: true } };
  const later = applyCompletions(acknowledged, {
    observed: [{ sessionId: 's', at: T0 + 60_000, kind: 'error' }],
    acknowledged: [],
  });
  assert.equal(later.s.acknowledged, false, 'a genuinely new completion is unread');
  assert.equal(later.s.at, T0 + 60_000);
  assert.equal(later.s.kind, 'error');
});

test('a standing acknowledgement does not silence the next reply', () => {
  // The regression this whole timestamp scheme exists for.
  //
  // The shell keeps reporting a dismissal on every control write — it must, or the
  // reminder flashes back before the bridge's next poll. When the acknowledgement was
  // keyed on the session id alone, that standing report re-acknowledged every future
  // completion, so a conversation the user had EVER clicked could never show a bubble
  // again. The timestamp limits it to the completion that was actually dismissed.
  const stale = [{ sessionId: 's', at: T0 }];

  // The user's old dismissal is still being reported, and a new turn has ended.
  const next = applyCompletions(
    { s: { at: T0, kind: 'done', acknowledged: true } },
    { observed: [{ sessionId: 's', at: T0 + 90_000, kind: 'done' }], acknowledged: stale },
  );
  assert.equal(
    next.s.acknowledged,
    false,
    'the new completion must be unread despite the standing acknowledgement',
  );
  assert.equal(next.s.at, T0 + 90_000);
});

test('re-reporting the same acknowledgement stays idempotent', () => {
  const completions = { s: { at: T0, kind: 'done', acknowledged: false } };
  const first = applyCompletions(completions, { observed: [], acknowledged: [{ sessionId: 's', at: T0 }] });
  assert.equal(first.s.acknowledged, true);
  const second = applyCompletions(first, { observed: [], acknowledged: [{ sessionId: 's', at: T0 }] });
  assert.equal(second.s.acknowledged, true, 'no change on the second identical report');
});

test('an acknowledgement older than the stored completion is ignored', () => {
  const completions = { s: { at: T0 + 50_000, kind: 'done', acknowledged: false } };
  const next = applyCompletions(completions, {
    observed: [],
    acknowledged: [{ sessionId: 's', at: T0 }],   // refers to an earlier reply
  });
  assert.equal(next.s.acknowledged, false, 'an old dismissal cannot silence a newer reply');
});

test('a bare session id still acknowledges the current completion', () => {
  // Backwards compatibility with a shell that sends plain ids.
  const completions = { s: { at: T0, kind: 'done', acknowledged: false } };
  const next = applyCompletions(completions, { observed: [], acknowledged: ['s'] });
  assert.equal(next.s.acknowledged, true);
});

test('acknowledgement marks the record without touching the others', () => {
  const completions = {
    a: { at: T0, kind: 'done', acknowledged: false },
    b: { at: T0 + 1, kind: 'done', acknowledged: false },
  };
  const next = applyCompletions(completions, { observed: [], acknowledged: ['a'] });
  assert.equal(next.a.acknowledged, true);
  assert.equal(next.b.acknowledged, false);
  assert.equal(completions.a.acknowledged, false, 'input is not mutated');
});

test('the unread cap keeps the newest records, not the oldest', () => {
  const completions = {};
  for (let i = 0; i < 30; i++) {
    completions[`s${i}`] = { at: T0 + i, kind: 'done', acknowledged: false };
  }
  const kept = pruneCompletions(completions, { now: T0 + 1000, completionTtlMs: TTL, maxUnacknowledged: 5 });
  assert.deepEqual(Object.keys(kept).sort(), ['s25', 's26', 's27', 's28', 's29']);
});

test('pruning never mutates its input', () => {
  const completions = {
    keep: { at: T0, kind: 'done', acknowledged: false },
    drop: { at: T0 - 10 * TTL, kind: 'done', acknowledged: true },
  };
  const snapshot = JSON.parse(JSON.stringify(completions));
  pruneCompletions(completions, { now: T0, completionTtlMs: TTL });
  assert.deepEqual(completions, snapshot);
});
