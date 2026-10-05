/**
 * Read a DSH Session Projection cache document.
 *
 * `$DSH_HOME/storages/session_projcache/sessions/<id>.json` is the host's own
 * persisted projection snapshot: a `{ version, record: { rows } }` document of
 * `(key -> { ver, seq, val })` rows, written by the session-projection cache
 * plugin. It is the natural source for facts the event log never carries — open
 * user questions and todo progress — so the pet reads it instead of scraping a
 * window.
 *
 * Privacy note: the projection also stores `titleInput`, which embeds the
 * first prompt verbatim. This module never reads it, and the bridge exposes a
 * session title only when the operator opts in.
 *
 * @module projection-cache
 */

import { readFile } from 'node:fs/promises';

/**
 * @typedef {object} ProjectionFacts
 * @property {number|null} asOfSeq lowest observed sequence across rows
 * @property {string|null} title short session title
 * @property {number} pendingQuestions active user-question count
 * @property {number|null} todoDone
 * @property {number|null} todoTotal
 * @property {number|null} openTurnStartSeq sequence where the open turn began
 * @property {number|null} lastPromptAt stamp of the newest prompt
 * @property {string|null} sandboxMode
 * @property {string|null} approvalPolicy
 * @property {string|null} model provider/model label
 */

/** Parse a projection cache document into pet-relevant facts. */
export function readProjection(document) {
  const rows = document?.record?.rows;
  if (rows === null || typeof rows !== 'object') return null;

  let asOfSeq = null;
  for (const row of Object.values(rows)) {
    if (row === null || typeof row !== 'object') continue;
    if (typeof row.seq !== 'number') continue;
    asOfSeq = asOfSeq === null ? row.seq : Math.min(asOfSeq, row.seq);
  }

  const activeQuestions = rows.userQuestions?.val?.questions?.active;
  const todos = rows.todos?.val;
  const selection = rows.modelSelection?.val?.lastUsed;

  return {
    asOfSeq,
    title: typeof rows.title?.val === 'string' && rows.title.val !== '' ? rows.title.val : null,
    pendingQuestions: Array.isArray(activeQuestions) ? activeQuestions.length : 0,
    todoDone: Array.isArray(todos) ? todos.filter((todo) => todo?.status === 'completed').length : null,
    todoTotal: Array.isArray(todos) ? todos.length : null,
    openTurnStartSeq: typeof rows.turnBoundary?.val?.openTurnStartSeq === 'number'
      ? rows.turnBoundary.val.openTurnStartSeq
      : null,
    lastPromptAt: typeof rows.sessionListMetadata?.val?.lastPromptAt === 'number'
      ? rows.sessionListMetadata.val.lastPromptAt
      : null,
    sandboxMode: typeof rows.sandboxMode?.val === 'string' ? rows.sandboxMode.val : null,
    approvalPolicy: typeof rows.approvalPolicy?.val === 'string' ? rows.approvalPolicy.val : null,
    model: typeof selection?.model === 'string' ? selection.model : null,
  };
}

/** Read and parse one cache file; `null` when unreadable or malformed. */
export async function loadProjection(file) {
  try {
    const text = await readFile(file, 'utf8');
    return readProjection(JSON.parse(text));
  } catch {
    // A cache file mid-rewrite, or one written by a newer schema, is not fatal:
    // the event log remains the authoritative source.
    return null;
  }
}
