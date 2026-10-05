// Probe: derive a pet-readable session state from the two privacy-safe DSH
// sources — the session event log (tail) and the persisted projection cache —
// and print only state/turn/tool/timing facts.
import { readFile, readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { zstdDecompressSync } from 'node:zlib';

const DSH_HOME = process.env.DSH_HOME ?? join(process.env.USERPROFILE ?? '', '.dsh');
const SESSIONS = join(DSH_HOME, 'sessions');
const CACHE = join(DSH_HOME, 'storages', 'session_projcache', 'sessions');
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

/** Decode every complete zstd frame in a log buffer; report the trailing partial frame. */
function decodeFrames(buf) {
  const events = [];
  let offset = 0;
  let pending = 0;
  while (offset < buf.length) {
    const next = buf.indexOf(MAGIC, offset);
    if (next < 0) { pending = buf.length - offset; break; }
    let end = next + 1;
    let text;
    for (;;) {
      if (end > buf.length) break;
      try { text = zstdDecompressSync(buf.subarray(next, end)).toString('utf8'); break; }
      catch { end++; }
    }
    if (text === undefined) { pending = buf.length - next; break; }
    for (const line of text.split('\n')) {
      if (line.trim() === '') continue;
      try { events.push(JSON.parse(line)); } catch { /* skip */ }
    }
    offset = end;
  }
  return { events, pending };
}

const dirs = await readdir(SESSIONS, { withFileTypes: true });
const report = [];
for (const dir of dirs) {
  if (!dir.isDirectory()) continue;
  for (const sub of await readdir(join(SESSIONS, dir.name), { withFileTypes: true })) {
    if (!sub.isDirectory()) continue;
    const id = sub.name;
    const logDir = join(SESSIONS, dir.name, id);
    let logFile;
    for (const name of await readdir(logDir)) if (name.endsWith('.jsonl.zstd')) logFile = join(logDir, name);
    if (!logFile) continue;
    const logStat = await stat(logFile);
    const { events, pending } = decodeFrames(await readFile(logFile));

    const header = events.find((e) => e.type === 'session');
    const last = events.at(-1);
    const openTurnStart = events.filter((e) => e.type === 'turn/start').at(-1);
    const openTurnEnd = events.filter((e) => e.type === 'turn/end').at(-1);
    const lastStepStart = events.filter((e) => e.type === 'step/start').at(-1);
    const lastStepEnd = events.filter((e) => e.type === 'step/end').at(-1);
    const asked = new Map();
    for (const e of events) {
      if (e.type === 'approval/asked') asked.set(e.data.id, e);
      if (e.type === 'approval/decided') asked.delete(e.data.id);
    }
    const lastTool = events.filter((e) => e.type === 'tool/call').at(-1);
    const toolResults = events.filter((e) => e.type === 'tool/result');
    const errors = toolResults.filter((e) => e.data?.message?.isError === true);
    const title = events.filter((e) => e.type === 'session/title').at(-1);

    // Projection cache for this session (question state is not in the log).
    let cache = null;
    const cacheCandidates = await readdir(CACHE).catch(() => []);
    const cacheFile = cacheCandidates.find((name) => name === `${id}.json`);
    if (cacheFile) {
      try {
        const parsed = JSON.parse(await readFile(join(CACHE, cacheFile), 'utf8'));
        cache = parsed.record?.rows ?? null;
      } catch { /* skip */ }
    }

    report.push({
      id,
      cwd: header?.cwd,
      mtime: logStat.mtime.toISOString(),
      events: events.length,
      pendingBytes: pending,
      openTurn: openTurnStart !== undefined && (openTurnEnd === undefined || openTurnEnd.seq < openTurnStart.seq),
      lastSeq: last?.seq,
      lastType: last?.type,
      lastTime: last?.time,
      stepOpen: lastStepStart !== undefined && (lastStepEnd === undefined || lastStepEnd.seq < lastStepStart.seq),
      toolCalls: events.filter((e) => e.type === 'tool/call').length,
      toolErrors: errors.length,
      lastErrorCode: errors.at(-1)?.data?.message?.content?.[0]?.text?.slice(0, 40),
      lastToolName: lastTool?.data?.name,
      pendingApprovals: [...asked.keys()].length,
      titleLen: title?.data?.title?.length ?? 0,
      cacheKeys: cache ? Object.keys(cache).join('|') : null,
      cacheQuestions: cache?.userQuestions?.val?.questions?.active?.length ?? null,
      cacheOpenStep: cache?.sessionStats?.val?.openStep ?? null,
      cacheTodos: cache?.todos?.val ? `${cache.todos.val.filter((t) => t.status === 'completed').length}/${cache.todos.val.length}` : null,
      cacheSessions: cache ? Object.keys(cache).length : 0,
      cacheInbox: cache?.inbox?.val ? JSON.stringify({ n: cache.inbox.val['next-turn']?.length, s: cache.inbox.val['next-step']?.length }) : null,
    });
  }
}

console.log(JSON.stringify(report, null, 2));
