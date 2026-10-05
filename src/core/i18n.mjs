/**
 * i18n — the pet's bilingual message catalogue (简体中文 / English).
 *
 * Every user-visible string the DATA side produces (status labels, relative ages,
 * progress text, notification labels) lives here, keyed and parameterised, so the
 * pet can be switched between Chinese and English at runtime. The WPF shell keeps
 * its own copy of the presentation-only strings in `src/shell/PetStrings.ps1` —
 * it cannot import an ES module — but the two tables use the same keys and the
 * same `{0}`-style placeholders, so a language switch changes both halves at once.
 *
 * The choice travels through the existing control channel: the shell writes the
 * selected language into `state/pet-control.json`, the bridge reads it on every
 * poll and regenerates the snapshot in that language. No new file, no new process.
 *
 * @module i18n
 */

/** The language used when nothing else was requested. The pet's origin is Chinese. */
export const DEFAULT_LANGUAGE = 'zh-CN';

/** Languages this module can actually render. */
export const SUPPORTED_LANGUAGES = ['zh-CN', 'en'];

/**
 * Normalise any user/config-supplied language tag onto a supported one.
 *
 * Accepts the forms that actually occur in the wild — `zh`, `zh-CN`, `zh_CN`,
 * `zh-Hans`, `en`, `en-US`, `EN` — and folds everything else onto the default
 * rather than failing, because an unsupported tag must never take the pet down.
 *
 * @param {unknown} value raw language tag
 * @returns {'zh-CN'|'en'} a supported language
 */
export function normalizeLanguage(value) {
  if (typeof value !== 'string') return DEFAULT_LANGUAGE;
  const lower = value.trim().toLowerCase();
  if (lower === '') return DEFAULT_LANGUAGE;
  if (lower === 'zh' || lower.startsWith('zh-') || lower.startsWith('zh_')) return 'zh-CN';
  if (lower.startsWith('en')) return 'en';
  return DEFAULT_LANGUAGE;
}

/**
 * The catalogue. Placeholders are `{0}`, `{1}`, … and are substituted positionally
 * by `t()`. Keys are shared with `src/shell/PetStrings.ps1`; adding a key here
 * means adding it there too when the shell renders it.
 */
export const MESSAGES = {
  'zh-CN': {
    // Status labels — bubble headline and list rows.
    statusApproval: '等待确认',
    statusQuestion: '等待回答',
    statusWorking: '工作中',
    statusWorkingTool: '工作中 · {0}',
    statusThinking: '思考中',
    statusLongThinking: '长任务 · 推理中',
    statusDone: '✅ 任务完成',
    statusError: '出错了',
    statusErrorCode: '出错了 · {0}',
    statusIdle: '待机',
    // Notification row labels.
    labelDone: '任务完成',
    labelError: '出错了',
    // Todo progress.
    progressDone: '已完成 {0}/{1}',
    // Relative ages.
    ageNow: '刚刚',
    ageMinutes: '{0} 分钟前',
    ageHours: '{0} 小时前',
    ageDays: '{0} 天前',
    // Session name fallback when no workspace folder is known.
    sessionFallback: '会话',
  },
  en: {
    statusApproval: 'Waiting for approval',
    statusQuestion: 'Waiting for your reply',
    statusWorking: 'Working',
    statusWorkingTool: 'Working · {0}',
    statusThinking: 'Thinking',
    statusLongThinking: 'Long task · reasoning',
    statusDone: '✅ Task complete',
    statusError: 'Failed',
    statusErrorCode: 'Failed · {0}',
    statusIdle: 'Idle',
    labelDone: 'Task complete',
    labelError: 'Failed',
    progressDone: 'Done {0}/{1}',
    ageNow: 'just now',
    ageMinutes: '{0} min ago',
    ageHours: '{0} h ago',
    ageDays: '{0} d ago',
    sessionFallback: 'Session',
  },
};

/**
 * Translate one key in one language, substituting `{n}` placeholders.
 *
 * A missing key falls back to the default language and then to the key itself, so
 * a typo degrades to visible text instead of an empty label — and never throws:
 * the reducer renders this output inside a StrictMode WPF shell.
 *
 * @param {string} lang requested language (normalised)
 * @param {string} key catalogue key
 * @param {...unknown} args positional placeholder values
 * @returns {string}
 */
export function t(lang, key, ...args) {
  const catalogue = MESSAGES[normalizeLanguage(lang)] ?? MESSAGES[DEFAULT_LANGUAGE];
  let text = catalogue[key];
  if (typeof text !== 'string') text = MESSAGES[DEFAULT_LANGUAGE][key];
  if (typeof text !== 'string') return key;
  return text.replace(/\{(\d+)\}/gu, (match, index) => {
    const value = args[Number(index)];
    return value === undefined ? match : String(value);
  });
}

/**
 * Relative age label such as `刚刚` / `3 分钟前` (zh) or `just now` / `3 min ago` (en).
 *
 * Lives beside `t()` rather than in `clock.mjs` so the age vocabulary is part of
 * the same auditable catalogue as every other string.
 *
 * @param {number} ms age in milliseconds (negative input clamps to zero)
 * @param {string} [lang] requested language
 * @returns {string}
 */
export function formatAge(ms, lang = DEFAULT_LANGUAGE) {
  const seconds = Math.max(0, Math.floor((Number.isFinite(ms) ? ms : 0) / 1000));
  if (seconds < 45) return t(lang, 'ageNow');
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return t(lang, 'ageMinutes', minutes);
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return t(lang, 'ageHours', hours);
  return t(lang, 'ageDays', Math.floor(hours / 24));
}
