/**
 * Fold raw DSH session events into the small, privacy-bounded fact set the pet
 * is allowed to know.
 *
 * Privacy boundary (from the design brief): only status, turn/step numbers,
 * tool *names*, timing and a short error code survive this fold. Prompts, model
 * replies, tool arguments, tool result content, workspace paths and file
 * contents are read into a local variable to detect an event and then dropped —
 * they are never copied into the returned state, and therefore never reach the
 * snapshot the UI reads.
 *
 * @module session-facts
 */

/** Event types whose payload is dropped entirely (only their arrival matters). */
const IGNORED = new Set([
  'session-log-deepseek/delivery-accepted',
  'request/header',
  'request/context',
  'session/title-llm-request',
  'web/deepseek-search-llm-request',
  'agent/inbox/spliced',
  'session/end-seed',
]);

/**
 * @typedef {object} SessionLogState
 * @property {string|null} id
 * @property {string|null} cwd
 * @property {string|null} agentPreset
 * @property {number} lastSeq
 * @property {number|null} lastTime
 * @property {number|null} turn
 * @property {number|null} step
 * @property {boolean} openTurn
 * @property {boolean} openStep
 * @property {Set<string>} approvals open `approval/asked` ids
 * @property {Map<string, {name: string, at: number|null}>} activeCalls callId -> tool
 * @property {number} toolCalls
 * @property {number} toolErrors
 * @property {string|null} lastToolName
 * @property {boolean} lastToolFailed
 * @property {string|null} errorCode
 * @property {number|null} turnStartedAt
 * @property {number|null} lastActivityAt
 * @property {boolean} lastTurnCompleted
 * @property {number|null} lastTurnEndedAt
 * @property {number|null} lastTurnEndSeq
 * @property {number|null} todoDone
 * @property {number|null} todoTotal
 */

/** Fresh fold state for one session. */
export function initialLogState() {
  return {
    id: null,
    cwd: null,
    agentPreset: null,
    lastSeq: -1,
    lastTime: null,
    turn: null,
    step: null,
    openTurn: false,
    openStep: false,
    approvals: new Set(),
    activeCalls: new Map(),
    toolCalls: 0,
    toolErrors: 0,
    lastToolName: null,
    lastToolFailed: false,
    errorCode: null,
    turnStartedAt: null,
    lastActivityAt: null,
    lastTurnCompleted: false,
    lastTurnEndedAt: null,
    lastTurnEndSeq: null,
    todoDone: null,
    todoTotal: null,
  };
}

/**
 * Extract a short machine error code from a tool result.
 *
 * Only a bounded token is kept: an error code such as `EACCES` or `ENOENT`
 * is useful on the bubble, while the message body may embed paths or content.
 * @param {unknown} message tool-result message payload
 * @returns {string|null}
 */
export function errorCodeOf(message) {
  const text = message?.content?.[0]?.text;
  if (typeof text !== 'string') return null;
  const match = /(?:^|\s)(E[A-Z]{2,12}|[A-Z_]{3,20}_ERROR|HTTP\s?[45]\d\d)\b/u.exec(text);
  if (match !== null) return match[1].replace(/\s+/gu, '');
  return null;
}

/**
 * Apply one session event, returning the advanced state.
 *
 * Unknown event types are ignored on purpose: the fold must not break when the
 * harness adds a new event, and the pet only cares about the lifecycle spine.
 *
 * @param {SessionLogState} state previous state (mutated in place for speed)
 * @param {any} event raw session event
 * @returns {SessionLogState}
 */
export function applyEvent(state, event) {
  if (event === null || typeof event !== 'object') return state;
  const type = event.type;
  const seq = typeof event.seq === 'number' ? event.seq : null;
  const time = typeof event.time === 'number' ? event.time : null;

  if (seq !== null) {
    if (seq <= state.lastSeq) return state;
    state.lastSeq = seq;
  }
  if (time !== null) state.lastTime = time;

  if (type === 'session') {
    state.id = typeof event.id === 'string' ? event.id : state.id;
    state.cwd = typeof event.cwd === 'string' ? event.cwd : state.cwd;
    state.agentPreset = typeof event.agentPreset === 'string' ? event.agentPreset : state.agentPreset;
    return state;
  }

  if (IGNORED.has(type)) return state;

  switch (type) {
    case 'turn/start': {
      state.turn = event.data?.turn ?? state.turn;
      state.openTurn = true;
      state.openStep = false;
      state.turnStartedAt = time;
      state.lastActivityAt = time;
      state.lastTurnCompleted = false;
      state.errorCode = null;
      state.lastToolFailed = false;
      break;
    }
    case 'turn/end': {
      const reason = event.data?.reason?.kind ?? 'unknown';
      state.openTurn = false;
      state.openStep = false;
      state.activeCalls.clear();
      state.lastTurnCompleted = reason === 'completed';
      state.lastTurnEndedAt = time;
      state.lastTurnEndSeq = seq;
      if (reason !== 'completed') state.errorCode = String(reason).slice(0, 32);
      break;
    }
    case 'step/start': {
      state.turn = event.data?.turn ?? state.turn;
      state.step = event.data?.step ?? state.step;
      state.openStep = true;
      state.lastActivityAt = time;
      break;
    }
    case 'step/end': {
      state.openStep = false;
      state.lastActivityAt = time;
      break;
    }
    case 'tool/call': {
      const name = event.data?.name;
      const callId = event.data?.callId;
      if (typeof name === 'string') state.lastToolName = name;
      state.toolCalls += 1;
      state.toolErrors += 0;
      if (typeof callId === 'string') state.activeCalls.set(callId, { name: name ?? 'tool', at: time });
      state.lastToolFailed = false;
      state.lastActivityAt = time;
      break;
    }
    case 'tool/result': {
      const callId = event.data?.message?.toolCallId;
      if (typeof callId === 'string') state.activeCalls.delete(callId);
      const failed = event.data?.message?.isError === true;
      state.lastToolFailed = failed;
      if (failed) {
        state.toolErrors += 1;
        const code = errorCodeOf(event.data?.message);
        // Keep the newest short code; the registry prefix is a stable label.
        state.errorCode = code;
        if (code === null) {
          const registry = event.data?.meta?.error?.code;
          if (typeof registry === 'string') state.errorCode = registry.slice(0, 24);
        }
      }
      state.lastActivityAt = time;
      break;
    }
    case 'approval/asked': {
      const id = event.data?.id;
      if (typeof id === 'string') state.approvals.add(id);
      if (typeof event.data?.toolName === 'string') state.lastToolName = event.data.toolName;
      state.lastActivityAt = time;
      break;
    }
    case 'approval/decided': {
      const id = event.data?.id;
      if (typeof id === 'string') state.approvals.delete(id);
      state.lastActivityAt = time;
      break;
    }
    case 'todo/write': {
      const todos = event.data?.todos;
      if (Array.isArray(todos)) {
        state.todoTotal = todos.length;
        state.todoDone = todos.filter((todo) => todo?.status === 'completed').length;
      }
      state.lastActivityAt = time;
      break;
    }
    case 'user/message': {
      state.lastActivityAt = time;
      break;
    }
    case 'assistant/message':
    case 'system/message':
    case 'session/title':
    case 'command/run':
    case 'command/done':
    case 'subagent/descriptor':
    case 'subagent/catalog':
    case 'model/selection':
    case 'agent-preset/selected':
    case 'permission/preset':
    case 'sandbox/mode':
    case 'approval/policy': {
      state.lastActivityAt = time;
      break;
    }
    default:
      break;
  }

  return state;
}

/** Fold many events in log order. */
export function applyEvents(state, events) {
  for (const event of events) applyEvent(state, event);
  return state;
}
