/**
 * `PetReducer` — the pet's mood/priority state machine as one pure function.
 *
 * The brief asks for a testable reducer with mood mapping, so nothing here
 * touches the clock, the filesystem, or the window: `SessionFacts` in, one view
 * model out. The bridge owns I/O, the shell owns pixels.
 *
 * @module pet-reducer
 */

import { clamp, formatAge, formatDuration } from './clock.mjs';
import { DEFAULT_LANGUAGE, t } from './i18n.mjs';

/** Priority tiers, highest first — the brief's `审批 > 等待回答 > 完成提醒 > 等待/错误 > 当前会话`. */
export const PRIORITY = {
  approval: 100,
  question: 90,
  done: 80,
  error: 70,
  working: 50,
  thinking: 40,
  idle: 0,
};

/** Statuses that mean "the agent is busy right now". */
const BUSY = new Set(['approval', 'question', 'working', 'thinking']);

/**
 * @typedef {object} SessionFacts
 * @property {string} id session id
 * @property {string} name project / workspace display name
 * @property {string|null} title optional session title (only when the operator opts in)
 * @property {number} seq last observed event sequence
 * @property {number|null} time stamp of the last observed event (epoch ms)
 * @property {boolean} openTurn a turn is open
 * @property {boolean} openStep a step is open
 * @property {number} pendingApprovals count of `approval/asked` without a decision
 * @property {number} pendingQuestions count of active user questions
 * @property {number} pendingCalls count of tool calls still awaiting results
 * @property {string|null} lastToolName name of the most recent tool call
 * @property {number} toolCalls tool calls observed in the session
 * @property {number} toolErrors tool results flagged `isError`
 * @property {boolean} lastToolFailed the newest tool result is an error
 * @property {string|null} errorCode short error code, never message text
 * @property {number|null} todoDone completed todo count
 * @property {number|null} todoTotal total todo count
 * @property {string|null} startedAt stamp when the current turn opened
 * @property {number|null} lastActivity stamp of the newest meaningful activity
 * @property {boolean} lastTurnCompleted the newest turn ended without a failure
 * @property {boolean} tracked the session is currently live in the host
 */

/** Derive mood, freshness flags and progress from one session's facts. */
export function deriveSession(facts, { now, activeSessionId = null, longTaskMs = 600_000 }) {
  const startedAt = facts.startedAt ?? facts.time ?? now;
  const lastActivity = facts.lastActivity ?? facts.time ?? startedAt;
  const runningMs = Math.max(0, now - startedAt);
  const idleMs = Math.max(0, now - lastActivity);

  let status;
  if (facts.pendingApprovals > 0) status = 'approval';
  else if (facts.pendingQuestions > 0) status = 'question';
  else if (facts.openTurn && facts.pendingCalls > 0) {
    // A call awaiting its result is the evidence that a tool is running; the
    // tool's *name* only enriches the label, so a missing name must not demote a
    // working session to "thinking".
    status = 'working';
  } else if (facts.openTurn) status = 'thinking';
  else if (facts.lastToolFailed) status = 'error';
  else if (facts.lastTurnCompleted === true) status = 'done';
  else status = 'idle';

  const busy = BUSY.has(status);
  const longTask = busy && runningMs >= longTaskMs;

  const progress = facts.todoTotal !== null && facts.todoTotal > 0
    ? { done: clamp(facts.todoDone ?? 0, 0, facts.todoTotal), total: facts.todoTotal }
    : null;

  return {
    id: facts.id,
    name: facts.name,
    title: facts.title ?? null,
    status,
    busy,
    longTask,
    isActive: facts.id === activeSessionId,
    lastToolName: facts.lastToolName,
    errorCode: facts.errorCode,
    toolCalls: facts.toolCalls,
    toolErrors: facts.toolErrors,
    progress,
    startedAt,
    lastActivity,
    runningMs,
    idleMs,
    seq: facts.seq,
  };
}

/** Map a derived status (plus long-task escalation) onto one sprite row. */
export function moodOf(session, { dragging = false } = {}) {
  if (dragging) return 'drag';
  switch (session.status) {
    case 'approval':
    case 'question':
      return 'waiting';
    case 'working':
      return session.longTask ? 'longtask' : 'working';
    case 'thinking':
      return session.longTask ? 'longtask' : 'thinking';
    case 'done':
      return 'celebrate';
    case 'error':
      return 'error';
    default:
      return 'idle';
  }
}

/**
 * Priority tier for one session.
 *
 * The completion tier comes from an *unacknowledged* completion — one the bridge
 * observed finish while the user was not looking — not from the mere fact that a
 * session's last turn ended successfully. Without that distinction every
 * historical session would outrank the conversation that is actually running,
 * and the pet would permanently show a stale "task complete" over live work.
 */
export function priorityOf(session, { unacknowledged = false } = {}) {
  if (unacknowledged) return PRIORITY.done;
  if (session.status === 'done') return PRIORITY.thinking - 1;   // history, below live work
  return PRIORITY[session.status] ?? 0;
}

/**
 * Stage label used by the bubble and list rows, in the requested language.
 *
 * The default remains Chinese for backwards compatibility with callers (and
 * tests) written before the language parameter existed; the bridge passes the
 * shell's chosen language through on every poll.
 *
 * @param {object} session derived session
 * @param {string} [lang] supported language tag, e.g. `'zh-CN'` / `'en'`
 */
export function statusLabel(session, lang = DEFAULT_LANGUAGE) {
  const tool = session.lastToolName;
  switch (session.status) {
    case 'approval':
      return t(lang, 'statusApproval');
    case 'question':
      return t(lang, 'statusQuestion');
    case 'working':
      // `null` comes from the fold; `undefined` from a hand-built session in a test.
      // Either way the tool name only enriches the label, so a missing one must not
      // leak an unfilled `{0}` placeholder into the bubble.
      if (tool === null || tool === undefined) return t(lang, 'statusWorking');
      return t(lang, 'statusWorkingTool', tool);
    case 'thinking':
      return session.longTask ? t(lang, 'statusLongThinking') : t(lang, 'statusThinking');
    case 'done':
      return t(lang, 'statusDone');
    case 'error':
      return session.errorCode === null || session.errorCode === undefined
        ? t(lang, 'statusError')
        : t(lang, 'statusErrorCode', session.errorCode);
    default:
      return t(lang, 'statusIdle');
  }
}

/**
 * Total order over sessions.
 *
 * The brief fixes the head of the order (approval, waiting for an answer,
 * completion reminder, waiting/error, then the current session) and says that
 * within one tier only the first two are stable while the rest rotate by update
 * time. Ties therefore break on freshness: the active session first, then the
 * most recently updated.
 *
 * @param {{session: object, priority: number}} left decorated session
 * @param {{session: object, priority: number}} right decorated session
 */
export function compareRanked(left, right) {
  if (left.priority !== right.priority) return right.priority - left.priority;
  const l = left.session;
  const r = right.session;
  if (l.isActive !== r.isActive) return l.isActive ? -1 : 1;
  if (l.lastActivity !== r.lastActivity) return r.lastActivity - l.lastActivity;
  return String(l.id).localeCompare(String(r.id));
}

/**
 * Rank sessions and rotate everything below the stable top two.
 *
 * @param {Array<object>} sessions derived sessions
 * @param {object} options
 * @param {number} options.now reading on the harness clock
 * @param {Set<string>} options.unacknowledged ids whose completion was never seen
 * @param {number} options.rotateMs rotation period for the tail
 * @param {number} options.stableCount how many rows stay pinned at the top
 */
export function rankSessions(sessions, { now, unacknowledged = new Set(), rotateMs = 8_000, stableCount = 2 } = {}) {
  const decorated = sessions
    .map((session) => ({
      session,
      priority: priorityOf(session, { unacknowledged: unacknowledged.has(session.id) }),
    }))
    .sort(compareRanked);

  if (decorated.length <= stableCount) return decorated;
  const head = decorated.slice(0, stableCount);
  const tail = decorated.slice(stableCount);
  // Rotate only what is left; a stable head keeps the bubble from flickering.
  const offset = tail.length > 0 ? Math.floor(now / rotateMs) % tail.length : 0;
  const rotated = offset === 0 ? tail : [...tail.slice(offset), ...tail.slice(0, offset)];
  return [...head, ...rotated];
}

/**
 * Reduce session facts into the pet's complete view model.
 *
 * @param {object} input
 * @param {Array<SessionFacts>} input.sessions raw facts from the bridge
 * @param {number} input.now authoritative epoch ms
 * @param {string|null} input.activeSessionId session the Harness window is on, when known
 * @param {object} [input.completions] completion bookkeeping by session id
 * @param {boolean} [input.dragging] a drag is in progress
 * @param {boolean} [input.hovered] the pointer is over the pet
 * @param {number} [input.completionTtlMs] how long a completion reminder survives
 * @param {number} [input.longTaskMs] when a task becomes a long task
 * @param {number} [input.quietMs] when an idle bubble may fade out
 * @param {string} [input.lang] UI language for every label in the view model
 */
export function reducePet(input) {
  const {
    sessions = [],
    now,
    activeSessionId = null,
    completions = {},
    dragging = false,
    hovered = false,
    completionTtlMs = 30_000,
    longTaskMs = 600_000,
    quietMs = 45_000,
    lang = DEFAULT_LANGUAGE,
  } = input;

  const derived = sessions.map((facts) => deriveSession(facts, { now, activeSessionId, longTaskMs }));

  // Completion reminders: a session that finished while nobody watched keeps its
  // bubble and green dot until the conversation is opened by clicking it.
  //
  // This is deliberately NOT time-limited. The brief originally asked for a 30 s
  // window, but a timer can drop a completion before the user ever sees it, which
  // defeats the point of the reminder. Retention is driven by acknowledgement
  // instead: it stays until the click happens. `completionTtlMs` survives only as
  // the freshness bound for a completion that was never registered as
  // unacknowledged (see `isRetained` below), so a session that finished long before
  // the pet started is not resurrected as stale history.
  const unacknowledged = new Set();
  const notifications = [];
  for (const session of derived) {
    const record = completions[session.id];
    if (record === undefined || record.acknowledged === true) continue;
    const age = now - record.at;
    unacknowledged.add(session.id);
    notifications.push({
      kind: record.kind ?? 'done',
      sessionId: session.id,
      name: session.name,
      at: record.at,
      ageMs: age,
      // Rendered directly by the notification row, so every field the row reads
      // must be present on every notification. A missing one is a crash in the
      // shell (StrictMode), not a blank line.
      ageText: formatAge(age, lang),
      label: record.kind === 'error' ? t(lang, 'labelError') : t(lang, 'labelDone'),
    });
  }
  notifications.sort((left, right) => right.at - left.at);

  // What the pet surfaces is deliberately narrow: work that is running now, plus
  // work that finished and has not been clicked yet.
  //
  // A running session is shown live. A finished one is RETAINED until the user
  // opens it by clicking its bubble — not dropped on a timer — so a completion can
  // never slip past unnoticed.
  //
  // `unacknowledged` means "the bridge watched this finish and nobody has clicked
  // it yet", which is what keeps sessions that finished before the pet started from
  // being resurrected as stale history.
  //
  // The `completionTtlMs` clause is a narrow fallback for a session that finished
  // moments ago but whose completion the bridge never registered (a turn that ended
  // while the bridge was restarting). It applies ONLY when there is no completion
  // record at all: a session with a record that the user has acknowledged must not be
  // retained, or the dismissal would be undone by this fallback and the bubble the
  // user just clicked would reappear.
  const isLive = (session) => session.busy;
  const isRetained = (session) => {
    if (unacknowledged.has(session.id)) return true;
    if (session.status !== 'done' && session.status !== 'error') return false;
    if (completions[session.id] !== undefined) return false;
    return session.idleMs <= completionTtlMs;
  };
  const active = derived.filter((session) => isLive(session) || isRetained(session));

  const ranked = rankSessions(active, { now, unacknowledged });
  const primary = ranked[0]?.session ?? null;

  const busyCount = derived.filter((s) => s.busy).length;
  const errorCount = derived.filter((s) => s.status === 'error').length;
  const runningTools = derived.reduce((sum, s) => sum + (s.status === 'working' ? 1 : 0), 0);

  // The mood follows the same session the bubble describes, so a finished task
  // still plays its celebration after everything else has gone idle.
  const mood = moodOf(primary ?? { status: 'idle', longTask: false }, { dragging });

  // One bubble per surfaced conversation, in rank order.
  //
  // Every surfaced conversation gets its OWN bubble, because a bubble is a dialog box
  // about one task: running work shows live progress, and a finished task keeps its box
  // with a status that goes on updating ("刚刚" -> "5 分钟前") until the user clicks it.
  // Parallel tasks therefore produce parallel bubbles rather than being folded into a
  // single summary line — the shell shows the first by default and the rest once the
  // list is expanded, so the pet stays glanceable without hiding anything.
  //
  // `others` on each bubble counts the OTHER surfaced conversations, so the "+N" backer
  // reads the same wherever it is drawn.
  const bubbles = ranked.map(({ session }) => {
    // `completionAt` identifies WHICH finished turn a bubble is about: the moment its
    // turn ended, or 0 while it is still running. The shell needs it to dismiss one
    // specific completion — acknowledging "this conversation" would silence its every
    // future reply too, so the acknowledgement travels with a timestamp and is honoured
    // only while it is at least as new as the completion on screen.
    const completion = completions[session.id];
    return {
      sessionId: session.id,
      name: session.name,
      label: statusLabel(session, lang),
      status: session.status,
      progress: session.progress,
      progressText: session.progress === null
        ? null
        : t(lang, 'progressDone', session.progress.done, session.progress.total),
      // Live timing. `elapsedText` counts up while the task runs; `ageText` counts up
      // once it has finished, which is what keeps a retained box informative rather
      // than a frozen "任务完成" that looks abandoned.
      elapsedText: session.busy ? formatDuration(session.runningMs) : null,
      ageText: formatAge(session.idleMs, lang),
      completionAt: session.busy ? 0 : (completion?.at ?? 0),
      others: 0,
      badge: null,
      longTask: session.longTask,
      lastToolName: session.lastToolName,
      // Retained for shape stability: several bubbles are now drawn instead of one
      // summary line, so this is always false. Consumers may read it without a
      // property-existence check.
      summary: false,
    };
  });

  const otherCount = Math.max(0, bubbles.length - 1);
  // A bare "+5" is ambiguous: it does not say five of WHAT, so it reads as though five
  // tasks were running when most may be finished. Counting the rest by state lets the
  // shell label the badge honestly, e.g. "另有 5 个对话（1 个进行中）".
  const BUSY_STATUSES = new Set(['working', 'thinking', 'approval', 'question']);
  const rest = bubbles.slice(1);
  const othersRunning = rest.filter((b) => BUSY_STATUSES.has(b.status)).length;
  const othersFinished = rest.length - othersRunning;

  for (const item of bubbles) {
    item.others = otherCount;
    item.othersRunning = othersRunning;
    item.othersFinished = othersFinished;
    item.badge = otherCount > 0 ? `+${otherCount}` : null;
  }

  // The bubble in front is the highest-ranked one. Kept as its own field because the
  // collapsed view and the pet's own click both act on exactly this conversation.
  const bubble = bubbles[0] ?? null;

  // Several completions at once are no longer folded into one summary line: each
  // conversation keeps its own bubble (see `bubbles` above), which is what lets a
  // parallel run show every task's own state instead of a single "2 个任务已完成".
  // The `summary` field remains on each bubble, always false, so a consumer written
  // against the older shape still finds the property.

  const entries = ranked.map(({ session }) => ({
    id: session.id,
    name: session.name,
    title: session.title,
    status: session.status,
    label: statusLabel(session, lang),
    dot: dotColor(session.status),
    isActive: session.isActive,
    progressText: session.progress === null ? null : `${session.progress.done}/${session.progress.total}`,
    elapsedText: session.busy ? formatDuration(session.runningMs) : null,
    ageText: formatAge(session.idleMs, lang),
    // Same role as the bubble's: identifies this completion so a dismissal can target
    // it without silencing the conversation's future replies.
    completionAt: session.busy ? 0 : (completions[session.id]?.at ?? 0),
    unacknowledged: unacknowledged.has(session.id),
    longTask: session.longTask,
    lastToolName: session.lastToolName,
  }));

  // Hover expands the bubble into stage, running time and live tool count.
  const hover = hovered && primary !== null
    ? {
        sessionId: primary.id,
        label: statusLabel(primary, lang),
        elapsedText: formatDuration(primary.runningMs),
        runningTools,
        ageText: formatAge(primary.idleMs, lang),
      }
    : null;

  return {
    now,
    mood,
    dragging,
    primaryId: primary?.id ?? null,
    bubble,
    // Every surfaced conversation, ranked. The shell draws the whole list when its
    // panel is expanded and only `bubble` when collapsed.
    bubbles,
    hover,
    notifications,
    entries,
    counts: {
      sessions: derived.length,
      busy: busyCount,
      errors: errorCount,
      done: notifications.filter((n) => n.kind === 'done').length,
      runningTools,
      unacknowledged: unacknowledged.size,
    },
  };
}

/** Badge colour per status: green done, blue running, yellow waiting, red error. */
export function dotColor(status) {
  switch (status) {
    case 'done':
      return '#22C55E';
    case 'working':
    case 'thinking':
      return '#4D6BFE';
    case 'approval':
    case 'question':
      return '#F59E0B';
    case 'error':
      return '#EF4444';
    default:
      return '#9CA3AF';
  }
}
