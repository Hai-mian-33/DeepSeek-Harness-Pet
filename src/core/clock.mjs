/**
 * Timing primitives shared by the pet bridge and the reducer.
 *
 * Two clocks are in play. Harness events carry an authoritative wall-clock
 * millisecond stamp (`session/event.time`), while the renderer needs a local
 * "now". They agree in practice, but an injected clock keeps every derivation
 * testable and lets the UI resolve durations without re-reading the log.
 */

/**
 * @typedef {object} ClockReading
 * @property {number} now authoritative harness-comparable epoch ms
 * @property {number} localNow raw `Date.now()` at the same instant
 * @property {number} skew `now - localNow`
 */

/**
 * Track the newest event stamp seen so durations can be resolved against the
 * harness clock even when the host clock drifts.
 * @returns {{ observe: (time: unknown) => void, reading: (localNow?: number) => ClockReading }}
 */
export function createClockTracker() {
  let newest = 0;
  return {
    observe(time) {
      if (typeof time === 'number' && Number.isFinite(time) && time > newest) newest = time;
    },
    reading(localNow = Date.now()) {
      // Before any event is seen there is no evidence of drift, so the local
      // clock is the best available reading.
      const skew = newest > 0 ? newest - localNow : 0;
      return { now: localNow + skew, localNow, skew };
    },
  };
}

import { formatAge as formatAgeLocalized } from './i18n.mjs';

/** Clamp `value` into `[lo, hi]`. */
export function clamp(value, lo, hi) {
  return Math.min(hi, Math.max(lo, value));
}

/**
 * Format a millisecond duration as `mm:ss`, saturating negative input at zero.
 * @param {number} ms duration in milliseconds
 * @returns {string}
 */
export function formatDuration(ms) {
  const total = Math.max(0, Math.floor((Number.isFinite(ms) ? ms : 0) / 1000));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
}

/** Relative age label such as `刚刚` / `3 分钟前`. Bilingual: see `core/i18n.mjs`. */
export function formatAge(ms, lang) {
  return formatAgeLocalized(ms, lang);
}
