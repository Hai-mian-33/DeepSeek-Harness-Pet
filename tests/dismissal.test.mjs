/**
 * Regression tests for the user's requirement:
 *
 *   "A finished conversation I have clicked must never appear again. One I have NOT
 *    clicked must keep its box, even after it finished."
 *
 * The failure mode being pinned: the completion record for a clicked conversation is
 * pruned after `completionTtlMs`, which throws away the only evidence that the user had
 * dismissed it. Anything that re-observes that same turn afterwards then creates a fresh
 * UNREAD record — and the box the user already dealt with comes back.
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import { applyCompletions, pruneCompletions, reviveCompletions } from '../src/core/completions.mjs';
import { reducePet } from '../src/core/pet-reducer.mjs';

const T0 = 1701011262369;
const TTL = 30_000;

/** Minimal session facts, matching the reducer's expected shape. */
function facts(overrides = {}) {
  return {
    id: 's',
    name: 'Session',
    title: null,
    lastToolName: null,
    lastToolFailed: false,
    lastTurnCompleted: false,
    errorCode: null,
    todoDone: 0,
    todoTotal: null,
    pendingApprovals: 0,
    pendingQuestions: 0,
    openTurn: false,
    openStep: false,
    pendingCalls: 0,
    toolCalls: 0,
    toolErrors: 0,
    lastActivity: T0,
    startedAt: T0,
    seq: 1,
    ...overrides,
  };
}

test('a clicked conversation never returns, even after its record is pruned', () => {
  // Step 1: the task finishes.
  let completions = applyCompletions({}, {
    observed: [{ sessionId: 's', at: T0, kind: 'done' }],
    acknowledged: [],
  });
  assert.equal(completions.s.acknowledged, false);

  // Step 2: the user clicks it.
  completions = applyCompletions(completions, { observed: [], acknowledged: [{ sessionId: 's', at: T0 }] });
  assert.equal(completions.s.acknowledged, true);

  // Step 3: time passes well beyond the reminder window, so the record is pruned.
  const afterPrune = pruneCompletions(completions, { now: T0 + TTL * 10, completionTtlMs: TTL });

  // Step 4: something re-observes that SAME turn (a log re-read, a bridge restart that
  // fails to seed, a replayed frame). It must NOT become an unread completion again.
  const reObserved = applyCompletions(afterPrune, {
    observed: [{ sessionId: 's', at: T0, kind: 'done' }],
    acknowledged: [],
  });
  assert.equal(
    reObserved.s.acknowledged,
    true,
    'a turn the user already dismissed must not come back as unread',
  );

  // And the view must show nothing for it.
  const view = reducePet({
    sessions: [facts({ lastTurnCompleted: true, lastActivity: T0 })],
    now: T0 + TTL * 10,
    completions: reObserved,
  });
  assert.equal(view.bubble, null, 'no box for a dismissed conversation');
  assert.equal(view.bubbles.length, 0);
});

test('an UNclicked completion keeps its box indefinitely', () => {
  // The other half of the requirement: retention must not be time-limited for something
  // the user has not dealt with.
  const completions = applyCompletions({}, {
    observed: [{ sessionId: 's', at: T0, kind: 'done' }],
    acknowledged: [],
  });

  for (const age of [TTL, 10 * 60_000, 2 * 3600_000]) {
    const kept = pruneCompletions(completions, { now: T0 + age, completionTtlMs: TTL });
    const view = reducePet({
      sessions: [facts({ lastTurnCompleted: true, lastActivity: T0 })],
      now: T0 + age,
      completions: kept,
    });
    assert.equal(view.bubbles.length, 1, `an unread completion must still show after ${age} ms`);
    assert.equal(view.bubbles[0].status, 'done');
  }
});

test('the acknowledgement survives pruning of the completion record', () => {
  // The root cause: `pruneCompletions` deletes an acknowledged record, discarding the
  // only memory that the user had dismissed it. The acknowledgement therefore has to live
  // somewhere that TTL-based pruning does not touch.
  const dismissed = applyCompletions({}, {
    observed: [{ sessionId: 's', at: T0, kind: 'done' }],
    acknowledged: [{ sessionId: 's', at: T0 }],
  });
  assert.equal(dismissed.s.acknowledged, true);

  const pruned = pruneCompletions(dismissed, { now: T0 + TTL * 5, completionTtlMs: TTL });
  // Re-observing the same turn at any later time stays dismissed.
  const again = applyCompletions(pruned, {
    observed: [{ sessionId: 's', at: T0, kind: 'done' }],
    acknowledged: [],
  });
  assert.equal(again.s.acknowledged, true);
});

test('a NEW reply after a dismissal is shown again', () => {
  // Dismissal is per reply, not per conversation — otherwise a conversation the user once
  // clicked could never notify again.
  const dismissed = applyCompletions(
    { s: { at: T0, kind: 'done', acknowledged: true } },
    { observed: [{ sessionId: 's', at: T0 + 600_000, kind: 'done' }], acknowledged: [] },
  );
  assert.equal(dismissed.s.acknowledged, false, 'a genuinely newer reply is unread');
  assert.equal(dismissed.s.at, T0 + 600_000);
});

test('dismissals survive a restart via the persisted store', () => {
  // This is the bug the user actually saw: the store lived in memory only, so every
  // restart forgot which conversations had been clicked and resurrected all of them. The
  // pet is restarted often (start-pet.cmd stops any previous instance first), so this made
  // the dismissal look like it did not work at all.
  const dismissed = applyCompletions({}, {
    observed: [{ sessionId: 's', at: T0, kind: 'done' }],
    acknowledged: [{ sessionId: 's', at: T0 }],
  });

  // Simulate the round trip through JSON on disk.
  const restored = reviveCompletions(JSON.parse(JSON.stringify(dismissed)));
  assert.equal(restored.s.acknowledged, true, 'the dismissal comes back after a restart');

  // A fresh bridge, seeded from the file, must not present the old turn as news — even
  // though its own watcher has never seen this session before.
  const afterRestart = applyCompletions(restored, {
    observed: [{ sessionId: 's', at: T0, kind: 'done' }],
    acknowledged: [],
  });
  assert.equal(afterRestart.s.acknowledged, true);

  const view = reducePet({
    sessions: [facts({ lastTurnCompleted: true, lastActivity: T0 })],
    now: T0 + 60_000,
    completions: afterRestart,
  });
  assert.equal(view.bubbles.length, 0, 'nothing is shown for an already-dismissed conversation');
});

test('an unread completion also survives a restart', () => {
  // The other direction, and the one the user explicitly asked for: a conversation they
  // have NOT clicked must still be shown after a restart.
  const unread = applyCompletions({}, {
    observed: [{ sessionId: 's', at: T0, kind: 'done' }],
    acknowledged: [],
  });
  const restored = reviveCompletions(JSON.parse(JSON.stringify(unread)));
  assert.equal(restored.s.acknowledged, false);

  const view = reducePet({
    sessions: [facts({ lastTurnCompleted: true, lastActivity: T0 })],
    now: T0 + 60_000,
    completions: restored,
  });
  assert.equal(view.bubbles.length, 1, 'the unread box is still there');
});

test('a malformed persisted store is discarded rather than trusted', () => {
  // The file is written by a previous build, so it may predate a shape change. A record
  // with a non-numeric timestamp would otherwise reach the reducer as NaN and render as
  // nonsense — or worse, crash the shell under StrictMode.
  const restored = reviveCompletions({
    good: { at: T0, kind: 'done', acknowledged: true },
    badAt: { at: 'yesterday', kind: 'done', acknowledged: true },
    missingAt: { kind: 'done' },
    nullRecord: null,
    notAnObject: 42,
    wrongKind: { at: T0 + 1, kind: 'exploded', acknowledged: false },
  });
  assert.deepEqual(Object.keys(restored).sort(), ['good', 'wrongKind']);
  assert.equal(restored.good.at, T0);
  assert.equal(restored.wrongKind.kind, 'done', 'an unknown kind falls back to done');
});

test('a corrupt or absent store does not stop the pet', () => {
  // "Cannot read the file" is the normal first-run case, and unparseable JSON is a
  // recoverable one: both must yield an empty store rather than throwing.
  for (const input of [null, undefined, 'not json', [], 7]) {
    assert.deepEqual(reviveCompletions(input), {});
  }
});
