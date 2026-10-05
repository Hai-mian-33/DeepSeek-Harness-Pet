/**
 * Tests for the bilingual catalogue and every label it feeds.
 *
 * The pet ships in Chinese and English, switchable at runtime from the shell's
 * right-click menu. The language reaches the data side through the control file,
 * and these tests pin the contract on both ends: the catalogue normalises any
 * real-world language tag onto a supported one, the reducer emits the same shape
 * with labels in the requested language, and the default stays Chinese so callers
 * (and shells) written before the language parameter existed behave unchanged.
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import { formatAge } from '../src/core/clock.mjs';
import {
  DEFAULT_LANGUAGE,
  MESSAGES,
  SUPPORTED_LANGUAGES,
  normalizeLanguage,
  t,
} from '../src/core/i18n.mjs';
import { statusLabel, reducePet } from '../src/core/pet-reducer.mjs';
import { projectNameOf } from '../src/core/session-snapshot.mjs';

test('normalizeLanguage folds real-world tags onto the supported pair', () => {
  assert.equal(normalizeLanguage('zh'), 'zh-CN');
  assert.equal(normalizeLanguage('zh-CN'), 'zh-CN');
  assert.equal(normalizeLanguage('zh_CN'), 'zh-CN');
  assert.equal(normalizeLanguage('zh-Hans-CN'), 'zh-CN');
  assert.equal(normalizeLanguage('ZH-tw'), 'zh-CN');
  assert.equal(normalizeLanguage('en'), 'en');
  assert.equal(normalizeLanguage('en-US'), 'en');
  assert.equal(normalizeLanguage('EN-GB'), 'en');
  // Anything unrecognised — junk, numbers, unsupported languages — lands on the
  // default rather than throwing, because a bad tag must never take the pet down.
  assert.equal(normalizeLanguage('fr-FR'), DEFAULT_LANGUAGE);
  assert.equal(normalizeLanguage(''), DEFAULT_LANGUAGE);
  assert.equal(normalizeLanguage(null), DEFAULT_LANGUAGE);
  assert.equal(normalizeLanguage(42), DEFAULT_LANGUAGE);
  assert.equal(normalizeLanguage(undefined), DEFAULT_LANGUAGE);
});

test('the catalogue is symmetric: every key exists in every supported language', () => {
  const [first, ...rest] = SUPPORTED_LANGUAGES;
  const reference = Object.keys(MESSAGES[first]).sort();
  for (const language of rest) {
    assert.deepEqual(
      Object.keys(MESSAGES[language]).sort(),
      reference,
      `${language} must define exactly the same keys as ${first}`,
    );
  }
});

test('t() substitutes positional placeholders and never throws', () => {
  assert.equal(t('zh-CN', 'statusWorkingTool', 'pwsh'), '工作中 · pwsh');
  assert.equal(t('en', 'statusWorkingTool', 'pwsh'), 'Working · pwsh');
  assert.equal(t('en', 'progressDone', 2, 10), 'Done 2/10');
  // A missing placeholder survives as literal text instead of an empty gap.
  assert.equal(t('en', 'progressDone'), 'Done {0}/{1}');
  // A missing key falls back to the default language, then to the key itself.
  assert.equal(t('en', 'definitely-not-a-key'), 'definitely-not-a-key');
  assert.equal(t('zh-CN', 'definitely-not-a-key'), 'definitely-not-a-key');
  // A junk language tag degrades to the default catalogue.
  assert.equal(t('qq-QQ', 'statusWorking'), '工作中');
});

test('formatAge renders both languages; the default stays Chinese', () => {
  assert.equal(formatAge(5_000), '刚刚');
  assert.equal(formatAge(180_000), '3 分钟前');
  assert.equal(formatAge(3 * 3600_000), '3 小时前');
  assert.equal(formatAge(2 * 24 * 3600_000), '2 天前');
  assert.equal(formatAge(5_000, 'en'), 'just now');
  assert.equal(formatAge(180_000, 'en'), '3 min ago');
  assert.equal(formatAge(3 * 3600_000, 'en'), '3 h ago');
  assert.equal(formatAge(2 * 24 * 3600_000, 'en'), '2 d ago');
  // Re-exported through clock.mjs with its default intact.
  assert.equal(formatAge(180_000, 'qq'), '3 分钟前');
});

/** Build one derived session with only the fields statusLabel reads. */
function sessionOf(overrides) {
  return {
    status: 'working',
    lastToolName: null,
    errorCode: null,
    longTask: false,
    ...overrides,
  };
}

test('statusLabel localises every branch', () => {
  const cases = [
    [{ status: 'approval' }, '等待确认', 'Waiting for approval'],
    [{ status: 'question' }, '等待回答', 'Waiting for your reply'],
    [{ status: 'working' }, '工作中', 'Working'],
    [{ status: 'working', lastToolName: 'pwsh' }, '工作中 · pwsh', 'Working · pwsh'],
    [{ status: 'thinking' }, '思考中', 'Thinking'],
    [{ status: 'thinking', longTask: true }, '长任务 · 推理中', 'Long task · reasoning'],
    [{ status: 'done' }, '✅ 任务完成', '✅ Task complete'],
    [{ status: 'error' }, '出错了', 'Failed'],
    [{ status: 'error', errorCode: 'ENOENT' }, '出错了 · ENOENT', 'Failed · ENOENT'],
    [{ status: 'idle' }, '待机', 'Idle'],
  ];
  for (const [session, zh, en] of cases) {
    assert.equal(statusLabel(session, 'zh-CN'), zh, JSON.stringify(session));
    assert.equal(statusLabel(session, 'en'), en, JSON.stringify(session));
  }
});

test('reducePet emits the same shape in English: bubbles, progress, ages, notifications', () => {
  const T0 = 1_800_000_000_000;
  const view = reducePet({
    sessions: [{
      id: 's1', name: 'proj', title: null, seq: 1, time: T0,
      openTurn: true, openStep: true, pendingApprovals: 0, pendingQuestions: 0,
      pendingCalls: 1, lastToolName: 'pwsh', toolCalls: 3, toolErrors: 0,
      lastToolFailed: false, errorCode: null, todoDone: 2, todoTotal: 10,
      startedAt: T0 - 65_000, lastActivity: T0 - 120_000, lastTurnCompleted: null, tracked: true,
    }],
    now: T0,
    completions: { s1: { at: T0 - 120_000, kind: 'done', acknowledged: false } },
    lang: 'en',
  });

  assert.equal(view.bubble.label, 'Working · pwsh');
  assert.equal(view.bubble.progressText, 'Done 2/10');
  assert.equal(view.bubble.ageText, '2 min ago');
  assert.equal(view.entries[0].label, 'Working · pwsh');
  assert.equal(view.entries[0].ageText, '2 min ago');
  // The unread completion keeps its notification row, in English.
  assert.equal(view.notifications[0].label, 'Task complete');
  assert.equal(view.notifications[0].ageText, '2 min ago');
  // Structural fields are untouched by language.
  assert.equal(view.bubble.sessionId, 's1');
  assert.equal(view.counts.unacknowledged, 1);
});

test('reducePet localises error labels too', () => {
  const T0 = 1_800_000_000_000;
  const facts = {
    id: 's-err', name: 'proj', title: null, seq: 2, time: T0,
    openTurn: false, openStep: false, pendingApprovals: 0, pendingQuestions: 0,
    pendingCalls: 0, lastToolName: 'bash', toolCalls: 1, toolErrors: 1,
    lastToolFailed: true, errorCode: 'EPERM', todoDone: null, todoTotal: null,
    startedAt: T0 - 5_000, lastActivity: T0, lastTurnCompleted: false, tracked: true,
  };
  const view = reducePet({ sessions: [facts], now: T0, lang: 'en' });
  assert.equal(view.bubble.label, 'Failed · EPERM');
});

test('the default language stays Chinese, so pre-i18n callers behave unchanged', () => {
  const T0 = 1_800_000_000_000;
  const view = reducePet({
    sessions: [{
      id: 's1', name: 'proj', title: null, seq: 1, time: T0,
      openTurn: true, openStep: true, pendingApprovals: 0, pendingQuestions: 0,
      pendingCalls: 1, lastToolName: 'pwsh', toolCalls: 1, toolErrors: 0,
      lastToolFailed: false, errorCode: null, todoDone: 3, todoTotal: 5,
      startedAt: T0, lastActivity: T0, lastTurnCompleted: null, tracked: true,
    }],
    now: T0,
  });
  assert.equal(view.bubble.label, '工作中 · pwsh');
  assert.equal(view.bubble.progressText, '已完成 3/5');
});

test('projectNameOf localises the fallback label for workspace-less sessions', () => {
  assert.equal(projectNameOf('', 'zh-CN'), '会话');
  assert.equal(projectNameOf('', 'en'), 'Session');
  assert.equal(projectNameOf('C:/work/demo', 'en'), 'demo');
  assert.equal(projectNameOf(undefined), '会话');
});
