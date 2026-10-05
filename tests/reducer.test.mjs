/**
 * Reducer tests — the state machine the brief asks to be pure and unit tested.
 *
 * They cover the acceptance criteria that are decided in software rather than
 * on screen: B2 (completion keeps its bubble for 30 s, and the reminder
 * survives until the conversation is opened), B3 (审批 > 等待回答 > 完成提醒 >
 * 等待/错误 > 当前会话), and the long-task escalation at 10 minutes.
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import { formatAge, formatDuration } from '../src/core/clock.mjs';
import { deriveSession, moodOf, PRIORITY, priorityOf, rankSessions, reducePet, statusLabel } from '../src/core/pet-reducer.mjs';
import { applyEvents, errorCodeOf, initialLogState } from '../src/core/session-facts.mjs';
import { projectNameOf, toSessionFacts } from '../src/core/session-snapshot.mjs';
import { readProjection } from '../src/core/projection-cache.mjs';

const T0 = 1_800_000_000_000;

/** Minimal well-formed facts; individual tests override what they exercise. */
function facts(overrides = {}) {
  return {
    id: 's1',
    name: 'demo',
    title: null,
    seq: 10,
    time: T0,
    openTurn: false,
    openStep: false,
    pendingApprovals: 0,
    pendingQuestions: 0,
    pendingCalls: 0,
    lastToolName: null,
    toolCalls: 0,
    toolErrors: 0,
    lastToolFailed: false,
    errorCode: null,
    todoDone: null,
    todoTotal: null,
    startedAt: T0,
    lastActivity: T0,
    lastTurnCompleted: false,
    ...overrides,
  };
}

test('an idle session is idle, and a fresh completion becomes a celebration', () => {
  const idle = deriveSession(facts(), { now: T0 + 1000 });
  assert.equal(idle.status, 'idle');
  assert.equal(moodOf(idle), 'idle');

  const done = deriveSession(facts({ lastTurnCompleted: true }), { now: T0 + 1000 });
  assert.equal(done.status, 'done');
  assert.equal(moodOf(done), 'celebrate');
});

test('a running tool reads as working, plain generation as thinking', () => {
  const generating = deriveSession(facts({ openTurn: true, openStep: true }), { now: T0 + 500 });
  assert.equal(generating.status, 'thinking');

  const running = deriveSession(
    facts({ openTurn: true, openStep: true, pendingCalls: 1, lastToolName: 'pwsh' }),
    { now: T0 + 500 },
  );
  assert.equal(running.status, 'working');
  assert.equal(statusLabel(running), '工作中 · pwsh');
  assert.equal(moodOf(running), 'working');
});

test('a pending tool result that failed puts the session in the error mood', () => {
  const failed = deriveSession(facts({ lastToolFailed: true, errorCode: 'ENOENT' }), { now: T0 + 100 });
  assert.equal(failed.status, 'error');
  assert.equal(moodOf(failed), 'error');
  assert.equal(statusLabel(failed), '出错了 · ENOENT');
});

test('a task longer than ten minutes escalates to the long-task animation', () => {
  const long = facts({ openTurn: true, openStep: true, pendingCalls: 1, lastToolName: 'pwsh', startedAt: T0 });
  const short = deriveSession(long, { now: T0 + 9 * 60_000 });
  assert.equal(short.longTask, false);
  assert.equal(moodOf(short), 'working');

  const escalated = deriveSession(long, { now: T0 + 10 * 60_000 });
  assert.equal(escalated.longTask, true);
  assert.equal(moodOf(escalated), 'longtask');
  assert.equal(statusLabel(escalated), '工作中 · pwsh');
});

test('priority follows 审批 > 等待回答 > 完成提醒 > 等待/错误 > 当前会话', () => {
  assert.ok(PRIORITY.approval > PRIORITY.question);
  assert.ok(PRIORITY.question > PRIORITY.done);
  assert.ok(PRIORITY.done > PRIORITY.error);
  assert.ok(PRIORITY.error > PRIORITY.working);
  assert.ok(PRIORITY.working > PRIORITY.thinking);
  assert.ok(PRIORITY.thinking > PRIORITY.idle);

  const approval = deriveSession(facts({ id: 'a', pendingApprovals: 1, openTurn: true }), { now: T0 });
  const question = deriveSession(facts({ id: 'q', pendingQuestions: 1, openTurn: true }), { now: T0 });
  const done = deriveSession(facts({ id: 'd', lastTurnCompleted: true }), { now: T0 });
  const working = deriveSession(facts({ id: 'w', openTurn: true, openStep: true, pendingCalls: 1 }), { now: T0 });

  // The completion tier is only reachable through an unacknowledged completion.
  const ranked = rankSessions([working, done, question, approval], { now: T0, unacknowledged: new Set(['d']) });
  assert.deepEqual(ranked.map((entry) => entry.session.id), ['a', 'q', 'd', 'w']);
});

test('an unacknowledged completion outranks a session that is merely working', () => {
  const done = deriveSession(facts({ id: 'done', lastTurnCompleted: true }), { now: T0 });
  const working = deriveSession(facts({ id: 'work', openTurn: true, openStep: true, pendingCalls: 1 }), { now: T0 });
  assert.ok(priorityOf(done, { unacknowledged: true }) > priorityOf(working));
  const ranked = rankSessions([working, done], { now: T0, unacknowledged: new Set(['done']) });
  assert.equal(ranked[0].session.id, 'done');
});

test('a session whose turn ended long ago does not outrank live work', () => {
  // History must not masquerade as a completion reminder: only a completion the
  // bridge actually witnessed (and that nobody has opened yet) takes the
  // completion tier.
  const historicalFacts = facts({ id: 'old', lastTurnCompleted: true, lastActivity: T0 - 90_000 });
  const liveFacts = facts({ id: 'live', openTurn: true, openStep: true, pendingCalls: 1, lastToolName: 'pwsh', lastActivity: T0 });

  const historical = deriveSession(historicalFacts, { now: T0 });
  const live = deriveSession(liveFacts, { now: T0 });
  assert.equal(historical.status, 'done');
  assert.equal(live.status, 'working');
  assert.ok(priorityOf(live) > priorityOf(historical), 'a stale completion sits below live work');

  const ranked = rankSessions([historical, live], { now: T0 });
  assert.equal(ranked[0].session.id, 'live', 'the running conversation leads');

  // reducePet takes raw facts, not derived sessions, so it re-derives them.
  const view = reducePet({ sessions: [historicalFacts, liveFacts], now: T0 });
  assert.equal(view.mood, 'working');
  assert.equal(view.bubble.status, 'working');
  assert.equal(view.bubble.label, '工作中 · pwsh');
});

test('the active session wins a tie inside one priority tier', () => {
  const older = facts({ id: 'older', lastActivity: T0, openTurn: true, openStep: true, pendingCalls: 1 });
  const newer = facts({ id: 'newer', lastActivity: T0 + 5000, openTurn: true, openStep: true, pendingCalls: 1 });
  const now = T0 + 10_000;
  // Same tier, but the conversation the Harness window is on must lead it even
  // though the other session was touched more recently.
  const ranked = rankSessions(
    [
      deriveSession(older, { now, activeSessionId: 'older' }),
      deriveSession(newer, { now, activeSessionId: 'older' }),
    ],
    { now },
  );
  assert.equal(ranked[0].session.id, 'older', 'the current conversation leads its tier');
});

test('only the top two stay stable; the rest rotate with the clock', () => {
  const sessions = ['a', 'b', 'c', 'd', 'e'].map((id) =>
    deriveSession(facts({ id, openTurn: true, openStep: true, pendingCalls: 1, lastActivity: T0 }), { now: T0 }));
  const first = rankSessions(sessions, { now: 0, rotateMs: 1000 });
  const later = rankSessions(sessions, { now: 1000, rotateMs: 1000 });
  assert.deepEqual(first.slice(0, 2).map((e) => e.session.id), later.slice(0, 2).map((e) => e.session.id));
  assert.notDeepEqual(first.slice(2).map((e) => e.session.id), later.slice(2).map((e) => e.session.id));
});

test('a completion is retained until it is clicked, not dropped on a timer', () => {
  // The requirement: while a conversation runs the bubble shows live; once it
  // finishes the bubble STAYS until the user clicks it. A timer-based expiry would
  // let a completion slip past unseen, so retention is driven by acknowledgement.
  const session = facts({ id: 's', lastTurnCompleted: true, lastActivity: T0 });
  const completions = { s: { at: T0, kind: 'done', acknowledged: false } };

  const fresh = reducePet({ sessions: [session], now: T0 + 5_000, completions });
  assert.equal(fresh.bubble.label, '✅ 任务完成');

  // Long past the 30 s reminder window: still shown, because it is unacknowledged.
  const muchLater = reducePet({ sessions: [session], now: T0 + 30 * 60_000, completions });
  assert.equal(muchLater.bubble.label, '✅ 任务完成');
  assert.equal(muchLater.entries.length, 1);
  assert.equal(muchLater.counts.unacknowledged, 1);

  // Clicking it (which acknowledges the session) removes it immediately.
  const clicked = reducePet({
    sessions: [session],
    now: T0 + 30 * 60_000,
    completions: { s: { at: T0, kind: 'done', acknowledged: true } },
  });
  assert.equal(clicked.bubble, null);
  assert.equal(clicked.entries.length, 0);
  assert.equal(clicked.counts.unacknowledged, 0);
});

test('a new reply in a dismissed conversation shows the bubble again', () => {
  // The requirement: dismissing a completion hides THAT completion, not the
  // conversation. When the same conversation replies again, the bubble must return.
  const session = facts({ id: 's', lastTurnCompleted: true, lastActivity: T0 });

  // The user dismissed the first reply.
  const dismissed = reducePet({
    sessions: [session],
    now: T0 + 1_000,
    completions: { s: { at: T0, kind: 'done', acknowledged: true } },
  });
  assert.equal(dismissed.bubble, null, 'the dismissed completion is hidden');

  // A later turn ends in the same conversation: a new, unread completion.
  const secondReply = T0 + 120_000;
  const again = reducePet({
    sessions: [facts({ id: 's', lastTurnCompleted: true, lastActivity: secondReply })],
    now: secondReply + 1_000,
    completions: { s: { at: secondReply, kind: 'done', acknowledged: false } },
  });
  assert.equal(again.bubble !== null, true, 'the bubble comes back for the new reply');
  assert.equal(again.bubble.sessionId, 's');
  assert.equal(again.bubble.label, '✅ 任务完成');
  assert.equal(again.bubble.completionAt, secondReply, 'the bubble identifies the new reply');
});

test('a running conversation is never hidden by an earlier dismissal', () => {
  // Live work must stay visible: an old dismissal refers to a previous reply.
  const view = reducePet({
    sessions: [facts({ id: 's', openTurn: true, openStep: true, pendingCalls: 1, lastToolName: 'pwsh' })],
    now: T0 + 5_000,
    completions: { s: { at: T0 - 60_000, kind: 'done', acknowledged: true } },
  });
  assert.equal(view.bubble !== null, true);
  assert.equal(view.bubble.status, 'working');
  assert.equal(view.bubble.completionAt, 0, 'running work has no completion to dismiss');
});

test('a running session shows live and keeps showing until it finishes', () => {
  const running = facts({ id: 'r', openTurn: true, openStep: true, pendingCalls: 1, lastToolName: 'pwsh' });
  const early = reducePet({ sessions: [running], now: T0 + 1_000 });
  assert.equal(early.bubble.status, 'working');
  assert.equal(early.bubble.elapsedText, '00:01');

  // The bubble tracks the task rather than expiring while it works.
  const late = reducePet({ sessions: [running], now: T0 + 45 * 60_000 });
  assert.equal(late.bubble.status, 'working');
  assert.equal(late.bubble.longTask, true);
  assert.equal(late.bubble.elapsedText, '45:00');
});

test('a completion retains the bubble while another conversation runs', () => {
  // An unacknowledged completion takes the completion tier, which outranks a
  // merely-running session — that is the brief's stated priority. Both are still
  // surfaced: the finished one owns the top bubble, the running one is listed.
  const view = reducePet({
    sessions: [
      facts({ id: 'run', openTurn: true, openStep: true, pendingCalls: 1, lastToolName: 'edit', lastActivity: T0 }),
      facts({ id: 'fin', lastTurnCompleted: true, lastActivity: T0 - 60_000 }),
    ],
    now: T0,
    completions: { fin: { at: T0 - 60_000, kind: 'done', acknowledged: false } },
  });
  assert.equal(view.bubble.sessionId, 'fin');
  assert.equal(view.bubble.status, 'done');
  assert.deepEqual(view.entries.map((e) => e.id).sort(), ['fin', 'run']);
  assert.equal(view.entries.find((e) => e.id === 'fin').unacknowledged, true);
  assert.equal(view.notifications.length, 1);

  // Once clicked, the running conversation takes the bubble.
  const afterClick = reducePet({
    sessions: [
      facts({ id: 'run', openTurn: true, openStep: true, pendingCalls: 1, lastToolName: 'edit', lastActivity: T0 }),
      facts({ id: 'fin', lastTurnCompleted: true, lastActivity: T0 - 60_000 }),
    ],
    now: T0,
    completions: { fin: { at: T0 - 60_000, kind: 'done', acknowledged: true } },
  });
  assert.equal(afterClick.bubble.sessionId, 'run');
  assert.equal(afterClick.notifications.length, 0);
});

test('acknowledging a completion clears its green dot immediately', () => {
  const session = facts({ id: 's', lastTurnCompleted: true });
  const before = reducePet({
    sessions: [session], now: T0 + 1000,
    completions: { s: { at: T0, kind: 'done', acknowledged: false } },
  });
  assert.equal(before.counts.unacknowledged, 1);

  const after = reducePet({
    sessions: [session], now: T0 + 1000,
    completions: { s: { at: T0, kind: 'done', acknowledged: true } },
  });
  assert.equal(after.counts.unacknowledged, 0);
  assert.equal(after.notifications.length, 0);
});

test('several parallel completions each keep their own bubble', () => {
  // The requirement: parallel tasks each get their own dialog box, rather than being
  // folded into one summary line. The shell shows the first by default and the rest
  // once its panel is expanded, so nothing is hidden and nothing competes for the
  // single line the old design had.
  const sessions = [
    facts({ id: 'a', lastTurnCompleted: true, lastActivity: T0 }),
    facts({ id: 'b', lastTurnCompleted: true, lastActivity: T0 }),
  ];
  const view = reducePet({
    sessions,
    now: T0 + 1000,
    completions: { a: { at: T0, kind: 'done' }, b: { at: T0, kind: 'done' } },
  });
  assert.equal(view.bubbles.length, 2, 'one bubble per finished conversation');
  assert.deepEqual(view.bubbles.map((b) => b.sessionId).sort(), ['a', 'b']);
  for (const bubble of view.bubbles) {
    assert.equal(bubble.label, '✅ 任务完成');
    assert.equal(bubble.others, 1, 'each bubble counts the others');
    assert.equal(bubble.badge, '+1');
    assert.equal(bubble.summary, false, 'there is no summary bubble any more');
  }
  // The front bubble is the first of the list, which is what the collapsed view draws.
  assert.equal(view.bubble.sessionId, view.bubbles[0].sessionId);
  assert.equal(view.notifications.length, 2);
  assert.equal(view.entries.length, 2);
  assert.equal(view.entries[0].unacknowledged, true);
});

test('a running task and a finished one each keep their own bubble', () => {
  // A mixed set is the case the user described: keep showing the running task live, and
  // keep the finished one until it is clicked.
  const view = reducePet({
    sessions: [
      facts({ id: 'run', openTurn: true, openStep: true, pendingCalls: 1, lastToolName: 'pwsh', lastActivity: T0 }),
      facts({ id: 'fin', lastTurnCompleted: true, lastActivity: T0 - 30_000 }),
    ],
    now: T0,
    completions: { fin: { at: T0 - 30_000, kind: 'done' } },
  });
  assert.equal(view.bubbles.length, 2);
  const run = view.bubbles.find((b) => b.sessionId === 'run');
  const fin = view.bubbles.find((b) => b.sessionId === 'fin');
  assert.equal(run.status, 'working');
  assert.equal(run.completionAt, 0, 'running work has no completion to dismiss');
  assert.equal(fin.status, 'done');
  assert.equal(fin.completionAt, T0 - 30_000, 'the finished box names its own completion');
});

test('the bubble only exists while there is something to say', () => {
  const quiet = reducePet({ sessions: [facts()], now: T0 + 120_000 });
  assert.equal(quiet.bubble, null, 'an idle pet shows no bubble');
  assert.equal(quiet.mood, 'idle');

  const busy = reducePet({
    sessions: [facts({ openTurn: true, openStep: true, pendingCalls: 1, lastToolName: 'read' })],
    now: T0 + 30_000,
  });
  assert.equal(busy.bubble.label, '工作中 · read');
  assert.equal(busy.bubble.elapsedText, '00:30');
});

test('progress and hover detail are reported for the bubble', () => {
  const view = reducePet({
    // A pending call with a known tool name is what makes the session "working"
    // (and counts toward the hover tool total) rather than merely "thinking".
    sessions: [facts({ openTurn: true, openStep: true, pendingCalls: 1, lastToolName: 'read', todoDone: 3, todoTotal: 5 })],
    now: T0 + 65_000,
    hovered: true,
  });
  assert.equal(view.bubble.progressText, '已完成 3/5');
  assert.equal(view.hover.runningTools, 1);
  assert.equal(view.hover.elapsedText, '01:05');
});

test('the +N backer counts the other conversations that are shown', () => {
  const sessions = [
    facts({ id: 'a', openTurn: true, openStep: true, pendingCalls: 1 }),
    facts({ id: 'b', openTurn: true, openStep: true }),
    facts({ id: 'c', openTurn: true, openStep: true, pendingCalls: 1 }),
  ];
  const view = reducePet({ sessions, now: T0 + 1000 });
  assert.equal(view.bubble.others, 2);
  assert.equal(view.bubble.badge, '+2');
  assert.equal(view.entries.length, 3);
});

test('the list shows running work and just-finished work, and drops history', () => {
  const view = reducePet({
    sessions: [
      // Running now.
      facts({ id: 'live', openTurn: true, openStep: true, pendingCalls: 1, lastActivity: T0 }),
      // Finished a moment ago: still worth showing.
      facts({ id: 'recent', lastTurnCompleted: true, lastActivity: T0 - 5_000 }),
      // Finished long ago: history, so it is not listed and cannot lead the pet.
      facts({ id: 'ancient', lastTurnCompleted: true, lastActivity: T0 - 3 * 3600_000 }),
      // Idle and never ran: not listed either.
      facts({ id: 'cold', lastActivity: T0 - 26 * 24 * 3600_000 }),
    ],
    now: T0,
    completionTtlMs: 30_000,
  });

  const ids = view.entries.map((entry) => entry.id);
  assert.deepEqual(ids.sort(), ['live', 'recent'], 'only running and just-finished sessions are listed');
  assert.equal(view.bubble.sessionId, 'live', 'the running conversation leads');
  assert.equal(view.mood, 'working');
  // The totals still describe the whole store, only the list is narrowed.
  assert.equal(view.counts.sessions, 4);
  assert.equal(view.counts.busy, 1);
});

test('a finished task still celebrates when nothing else is running', () => {
  // This is the case the list filter must not break: with no live session left,
  // the just-finished one is what the pet displays, so the celebration plays and
  // its bubble survives the 30 s window.
  const view = reducePet({
    sessions: [facts({ id: 'just', lastTurnCompleted: true, lastActivity: T0 })],
    now: T0 + 2_000,
    completions: { just: { at: T0, kind: 'done', acknowledged: false } },
    completionTtlMs: 30_000,
  });
  assert.equal(view.mood, 'celebrate');
  assert.equal(view.bubble.label, '✅ 任务完成');
  assert.equal(view.entries.length, 1);
  assert.equal(view.entries[0].unacknowledged, true);

  const after = reducePet({
    sessions: [facts({ id: 'just', lastTurnCompleted: true, lastActivity: T0 })],
    now: T0 + 31_000,
    completionTtlMs: 30_000,
  });
  assert.equal(after.bubble, null, 'and it is gone once the window closes');
  assert.equal(after.mood, 'idle');
  assert.equal(after.entries.length, 0);
});

test('status colours match the brief: green done, blue running, yellow waiting, red error', () => {
  const view = reducePet({
    sessions: [
      facts({ id: 'a', lastTurnCompleted: true }),
      facts({ id: 'b', openTurn: true, openStep: true, pendingCalls: 1 }),
      facts({ id: 'c', pendingApprovals: 1, openTurn: true }),
      facts({ id: 'd', lastToolFailed: true }),
    ],
    now: T0 + 1000,
  });
  const byId = Object.fromEntries(view.entries.map((entry) => [entry.id, entry.dot]));
  assert.equal(byId.a, '#22C55E');
  assert.equal(byId.b, '#4D6BFE');
  assert.equal(byId.c, '#F59E0B');
  assert.equal(byId.d, '#EF4444');
});

test('dragging overrides the mood without disturbing the bubble', () => {
  const view = reducePet({
    sessions: [facts({ openTurn: true, openStep: true, pendingCalls: 1, lastToolName: 'edit' })],
    now: T0 + 1000,
    dragging: true,
  });
  assert.equal(view.mood, 'drag');
  assert.equal(view.dragging, true);
  assert.equal(view.bubble.status, 'working');
});

test('the fold reads lifecycle, tool names and a short error code only', () => {
  const state = applyEvents(initialLogState(), [
    { type: 'session', id: 's1', cwd: 'C:\\work\\demo', agentPreset: 'standard' },
    { type: 'turn/start', seq: 1, time: T0, data: { turn: 1 } },
    { type: 'step/start', seq: 2, time: T0 + 10, data: { turn: 1, step: 1 } },
    { type: 'tool/call', seq: 3, time: T0 + 20, data: { turn: 1, step: 1, callId: 'c1', name: 'pwsh', arguments: '{"command":"secret"}' } },
  ]);
  assert.equal(state.id, 's1');
  assert.equal(state.cwd, 'C:\\work\\demo');
  assert.equal(state.openTurn, true);
  assert.equal(state.openStep, true);
  assert.equal(state.lastToolName, 'pwsh');
  assert.equal(state.activeCalls.size, 1);
  // The tool arguments were never copied into the fact set.
  assert.equal(JSON.stringify(state).includes('secret'), false);
});

test('a failed tool result is recorded as a flag plus an error code', () => {
  const state = applyEvents(initialLogState(), [
    { type: 'turn/start', seq: 1, time: T0, data: { turn: 1 } },
    { type: 'tool/call', seq: 2, time: T0 + 1, data: { callId: 'c1', name: 'read' } },
    {
      type: 'tool/result', seq: 3, time: T0 + 2,
      data: { message: { toolCallId: 'c1', isError: true, content: [{ type: 'text', text: 'spawn EPERM: C:\\Users\\someone\\secret.txt' }] } },
    },
  ]);
  assert.equal(state.lastToolFailed, true);
  assert.equal(state.errorCode, 'EPERM');
  assert.equal(state.activeCalls.size, 0);
  assert.equal(JSON.stringify(state).includes('secret.txt'), false, 'the message body is dropped');
});

test('approval events add and remove pending ids', () => {
  const asked = applyEvents(initialLogState(), [
    { type: 'approval/asked', seq: 1, time: T0, data: { id: 'a1', toolName: 'pwsh' } },
  ]);
  assert.equal(asked.approvals.size, 1);
  assert.equal(asked.lastToolName, 'pwsh');

  const decided = applyEvents(asked, [
    { type: 'approval/decided', seq: 2, time: T0 + 5, data: { id: 'a1', outcome: 'allow' } },
  ]);
  assert.equal(decided.approvals.size, 0);
});

test('turn end records completion or failure by reason', () => {
  const completed = applyEvents(initialLogState(), [
    { type: 'turn/start', seq: 1, time: T0, data: { turn: 1 } },
    { type: 'turn/end', seq: 2, time: T0 + 100, data: { turn: 1, reason: { kind: 'completed' } } },
  ]);
  assert.equal(completed.openTurn, false);
  assert.equal(completed.lastTurnCompleted, true);
  assert.equal(completed.lastTurnEndedAt, T0 + 100);

  const aborted = applyEvents(initialLogState(), [
    { type: 'turn/start', seq: 1, time: T0, data: { turn: 1 } },
    { type: 'turn/end', seq: 2, time: T0 + 100, data: { turn: 1, reason: { kind: 'aborted' } } },
  ]);
  assert.equal(aborted.lastTurnCompleted, false);
  assert.equal(aborted.errorCode, 'aborted');
});

test('events are folded in sequence order and duplicates are ignored', () => {
  const state = applyEvents(initialLogState(), [
    { type: 'step/start', seq: 5, time: T0, data: { turn: 1, step: 2 } },
    { type: 'step/start', seq: 5, time: T0, data: { turn: 9, step: 9 } },
    { type: 'step/start', seq: 4, time: T0, data: { turn: 9, step: 9 } },
  ]);
  assert.equal(state.step, 2);
  assert.equal(state.lastSeq, 5);
});

test('errorCodeOf only returns a bounded machine code', () => {
  assert.equal(errorCodeOf({ content: [{ type: 'text', text: 'spawn EPERM' }] }), 'EPERM');
  assert.equal(errorCodeOf({ content: [{ type: 'text', text: 'HTTP 500 from upstream' }] }), 'HTTP500');
  assert.equal(errorCodeOf({ content: [{ type: 'text', text: 'a long narrative without any code' }] }), null);
  assert.equal(errorCodeOf(undefined), null);
});

test('the privacy boundary drops the workspace path and keeps only a folder label', () => {
  assert.equal(projectNameOf('C:\\Users\\someone\\Desktop\\沐问同行'), '沐问同行');
  assert.equal(projectNameOf('C:\\work\\demo\\'), 'demo');
  assert.equal(projectNameOf('/home/someone/project'), 'project');
  assert.equal(projectNameOf(''), '会话');

  const cache = {
    record: {
      rows: {
        title: { ver: 1, seq: 9, val: 'Refactor the payment module' },
        titleInput: { ver: 3, seq: 9, val: { first: { seq: 8, text: 'a very long pasted prompt with secrets' } } },
        userQuestions: { ver: 2, seq: 9, val: { questions: { active: [{ id: 'q1' }], settled: [] } } },
        todos: { ver: 2, seq: 9, val: [{ status: 'completed' }, { status: 'pending' }] },
        turnBoundary: { ver: 2, seq: 9, val: { openTurnStartSeq: 4 } },
      },
    },
  };
  const projection = readProjection(cache);
  assert.equal(projection.title, 'Refactor the payment module');
  assert.equal(projection.pendingQuestions, 1);
  assert.deepEqual([projection.todoDone, projection.todoTotal], [1, 2]);

  const log = applyEvents(initialLogState(), [
    { type: 'session', id: 's1', cwd: 'C:\\Users\\someone\\Secret Project' },
    { type: 'turn/start', seq: 4, time: T0, data: { turn: 1 } },
  ]);

  const exposed = toSessionFacts({ log, projection, id: 's1', now: T0, exposeTitle: true });
  assert.equal(exposed.title, 'Refactor the payment module');
  assert.equal(exposed.name, 'Secret Project');

  const private_ = toSessionFacts({ log, projection, id: 's1', now: T0, exposeTitle: false });
  assert.equal(private_.title, null, 'titles are opt-in');
});

test('duration and age formatting', () => {
  assert.equal(formatDuration(0), '00:00');
  assert.equal(formatDuration(65_000), '01:05');
  assert.equal(formatDuration(600_000), '10:00');
  assert.equal(formatDuration(-5), '00:00');
  assert.equal(formatAge(5_000), '刚刚');
  assert.equal(formatAge(180_000), '3 分钟前');
  assert.equal(formatAge(3 * 3600_000), '3 小时前');
});

test('a missing todo list reports no progress rather than 0/0', () => {
  const view = reducePet({ sessions: [facts({ openTurn: true, openStep: true, pendingCalls: 1 })], now: T0 });
  assert.equal(view.bubble.progress, null);
  assert.equal(view.bubble.progressText, null);
});

test('every field the shell renders is always present on the view model', () => {
  // The shell runs under PowerShell StrictMode, so reading a missing property is a
  // fatal error rather than a blank line — and it crashes the whole pet, not just
  // one row. This pins the shape for each branch that produces a bubble, a
  // notification, a hover block or a list entry.
  const bubbleFields = [
    'sessionId', 'name', 'label', 'status', 'progress', 'progressText',
    'elapsedText', 'ageText', 'completionAt', 'others', 'othersRunning',
    'othersFinished', 'badge', 'longTask', 'lastToolName', 'summary',
  ];
  const noticeFields = ['kind', 'sessionId', 'name', 'at', 'ageMs', 'ageText', 'label'];
  const entryFields = [
    'id', 'name', 'title', 'status', 'label', 'dot', 'isActive',
    'progressText', 'elapsedText', 'ageText', 'completionAt', 'unacknowledged', 'longTask', 'lastToolName',
  ];
  const hoverFields = ['sessionId', 'label', 'elapsedText', 'runningTools', 'ageText'];

  const hasAll = (object, fields, what) => {
    for (const field of fields) {
      assert.ok(
        Object.hasOwn(object, field),
        `${what} is missing ${field} (the shell reads it under StrictMode)`,
      );
    }
    // The reverse direction matters too, and was the gap that let `othersRunning` and
    // `othersFinished` ship undocumented: checking only that expected fields EXIST means
    // a newly added field is never noticed, so this list drifts behind the reducer. Any
    // field the view model emits must be named here, which forces the decision to be
    // deliberate — either the shell renders it (and it belongs in a field list) or it is
    // redundant and should be removed.
    const extra = Object.keys(object).filter((key) => !fields.includes(key));
    assert.deepEqual(
      extra,
      [],
      `${what} has field(s) the shell's contract does not list: ${extra.join(', ')}`,
    );
  };

  const cases = {
    'working session': {
      sessions: [facts({ id: 'w', openTurn: true, openStep: true, pendingCalls: 1, lastToolName: 'pwsh', todoDone: 1, todoTotal: 4 })],
      now: T0 + 30_000,
      hovered: true,
    },
    'approval pending': {
      sessions: [facts({ id: 'a', pendingApprovals: 1, openTurn: true })],
      now: T0 + 1_000,
    },
    'single completion reminder': {
      sessions: [facts({ id: 'c', lastTurnCompleted: true })],
      now: T0 + 2_000,
      completions: { c: { at: T0, kind: 'done', acknowledged: false } },
    },
    'multiple completions (parallel bubbles)': {
      // c1 completed, c2 failed: two different labels, so the test proves each bubble
      // carries its OWN status rather than a shared one. A failed session is reported by
      // `lastToolFailed` — `lastTurnCompleted: false` alone derives to "idle", not
      // "error".
      sessions: [
        facts({ id: 'c1', lastTurnCompleted: true }),
        facts({ id: 'c2', lastToolFailed: true, errorCode: 'EPERM' }),
      ],
      now: T0 + 2_000,
      completions: {
        c1: { at: T0, kind: 'done', acknowledged: false },
        c2: { at: T0, kind: 'error', acknowledged: false },
      },
    },
    'failure': {
      sessions: [facts({ id: 'e', lastToolFailed: true, errorCode: 'EPERM' })],
      now: T0 + 1_000,
    },
    'all idle': { sessions: [facts({ id: 'i' })], now: T0 + 600_000 },
  };

  for (const [name, input] of Object.entries(cases)) {
    const view = reducePet(input);
    if (view.bubble !== null) hasAll(view.bubble, bubbleFields, `${name}: bubble`);
    // Every box in the list is held to the same shape, because the shell's renderer
    // draws them all with the same function.
    for (const bubble of view.bubbles) hasAll(bubble, bubbleFields, `${name}: bubbles[]`);
    if (view.hover !== null) hasAll(view.hover, hoverFields, `${name}: hover`);
    for (const notice of view.notifications) hasAll(notice, noticeFields, `${name}: notification`);
    for (const entry of view.entries) hasAll(entry, entryFields, `${name}: entry`);
  }

  // The parallel case: every conversation has its own box, and each reports its own
  // status (`1 个任务已完成` / `1 个任务出错` is no longer a single line).
  const parallel = reducePet(cases['multiple completions (parallel bubbles)']);
  assert.equal(parallel.bubbles.length, 2, 'one box per parallel conversation');
  assert.equal(parallel.bubble.sessionId, parallel.bubbles[0].sessionId);
  assert.equal(parallel.bubbles[0].others, 1);
  const labels = parallel.bubbles.map((b) => b.label).sort();
  // statusLabel prefixes completion with ✅ and appends the error code when it has one.
  assert.deepEqual(labels, ['✅ 任务完成', '出错了 · EPERM']);
});
