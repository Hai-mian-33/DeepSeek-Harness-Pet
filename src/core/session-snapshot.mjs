/**
 * Convert one watched session (log fold + projection cache) into the
 * `SessionFacts` shape the reducer consumes.
 *
 * This is the single place where the privacy boundary is enforced, so it is
 * deliberately explicit: the only string taken from the workspace path is its
 * final segment, the only string taken from the cache is the short title (and
 * only when the operator opted in), and no event payload text is copied.
 *
 * @module session-snapshot
 */

import { basename } from 'node:path';

import { DEFAULT_LANGUAGE, t } from './i18n.mjs';

/** Workspace folder name, used as the project label. The full path is discarded. */
export function projectNameOf(cwd, lang = DEFAULT_LANGUAGE) {
  if (typeof cwd !== 'string' || cwd === '') return t(lang, 'sessionFallback');
  const trimmed = cwd.replace(/[\\/]+$/u, '');
  const base = basename(trimmed);
  return base === '' ? t(lang, 'sessionFallback') : base;
}

/**
 * Build reducer-ready facts for one session.
 *
 * @param {object} input
 * @param {import('./session-facts.mjs').SessionLogState} input.log folded log state
 * @param {import('./projection-cache.mjs').ProjectionFacts|null} input.projection cache facts
 * @param {string} input.id session id
 * @param {number} input.now authoritative epoch ms
 * @param {boolean} input.exposeTitle whether the operator opted into titles
 * @param {string} [input.language] UI language for the fallback project label
 */
export function toSessionFacts({ log, projection, id, now, exposeTitle = false, language = DEFAULT_LANGUAGE }) {
  const pendingApprovals = log.approvals.size;
  const pendingCalls = log.activeCalls.size;
  const startedAt = log.turnStartedAt;
  const lastActivity = log.lastActivityAt ?? projection?.lastPromptAt ?? log.lastTime ?? null;
  const lastToolName = pendingCalls > 0 ? (log.activeCalls.values().next().value?.name ?? log.lastToolName) : log.lastToolName;

  return {
    id,
    name: projectNameOf(log.cwd, language),
    title: exposeTitle ? projection?.title ?? null : null,
    seq: log.lastSeq,
    time: log.lastTime,
    openTurn: log.openTurn,
    openStep: log.openStep,
    pendingApprovals,
    pendingQuestions: projection?.pendingQuestions ?? 0,
    pendingCalls,
    lastToolName: lastToolName ?? null,
    toolCalls: log.toolCalls,
    toolErrors: log.toolErrors,
    lastToolFailed: log.lastToolFailed,
    errorCode: log.errorCode,
    todoDone: projection?.todoDone ?? log.todoDone,
    todoTotal: projection?.todoTotal ?? log.todoTotal,
    startedAt,
    lastActivity,
    lastTurnCompleted: log.lastTurnCompleted,
    lastTurnEndedAt: log.lastTurnEndedAt,
    lastTurnEndSeq: log.lastTurnEndSeq,
    sandboxMode: projection?.sandboxMode ?? null,
    model: projection?.model ?? null,
    now,
  };
}
