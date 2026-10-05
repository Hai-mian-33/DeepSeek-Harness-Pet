/**
 * Tests for the shell -> bridge control channel.
 *
 * This path had NO coverage, and that is exactly why a severe bug survived several rounds
 * of fixing: the shell reports a dismissal as `{sessionId, at}`, but `readControl` accepted
 * only bare strings and filtered the objects out. Every acknowledgement was therefore
 * silently discarded, the bridge never learned about any click, and a conversation the user
 * had opened reappeared forever — including the "✅ 任务完成" row they kept seeing.
 *
 * The tests below deliberately go through the REAL file-reading entry point rather than
 * only the normalisation helper, because the bug was in the wiring (the filter) rather than
 * in the shape of the data.
 */

import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { readAcknowledgements, readControl } from '../src/bridge.mjs';

/** Write a control document and read it back through the real reader. */
async function roundTrip(payload) {
  const dir = await mkdtemp(join(tmpdir(), 'pet-control-'));
  const file = join(dir, 'pet-control.json');
  try {
    await writeFile(file, JSON.stringify(payload), 'utf8');
    return await readControl(file);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('an acknowledgement written as an object survives the control read', async () => {
  // THE regression test. The shell writes this exact shape; an earlier version dropped it.
  const control = await roundTrip({
    acknowledged: [{ sessionId: 'session-a', at: 1791028133567 }],
  });
  assert.equal(control.acknowledged.length, 1, 'the dismissal must not be filtered away');
  assert.deepEqual(control.acknowledged[0], { sessionId: 'session-a', at: 1791028133567 });
});

test('several acknowledgements all survive', async () => {
  const control = await roundTrip({
    acknowledged: [
      { sessionId: 'a', at: 1000 },
      { sessionId: 'b', at: 2000 },
      { sessionId: 'c', at: 3000 },
    ],
  });
  assert.equal(control.acknowledged.length, 3);
  assert.deepEqual(control.acknowledged.map((a) => a.sessionId), ['a', 'b', 'c']);
});

test('a bare session id from an older shell still works', async () => {
  // Backwards compatibility: the previous shell contract sent plain strings, and a mixed
  // file must not lose the entries it can understand.
  const control = await roundTrip({ acknowledged: ['plain-id', { sessionId: 'obj-id', at: 42 }] });
  assert.deepEqual(control.acknowledged, ['plain-id', { sessionId: 'obj-id', at: 42 }]);
});

test('an object without a usable timestamp degrades to a bare id', async () => {
  // No timestamp means "dismiss whatever is currently recorded", which the store handles.
  const control = await roundTrip({
    acknowledged: [
      { sessionId: 'no-at' },
      { sessionId: 'nan-at', at: Number.NaN },
      { sessionId: 'string-at', at: '123' },
    ],
  });
  assert.deepEqual(control.acknowledged, ['no-at', 'nan-at', 'string-at']);
});

test('malformed acknowledgement entries are dropped, not passed through', async () => {
  // A junk entry must not reach the store: `undefined` ids or NaN timestamps would pollute
  // the persisted file and could acknowledge the wrong conversation.
  const control = await roundTrip({
    acknowledged: [
      null,
      42,
      { at: 100 },
      { sessionId: '' },
      { sessionId: 7 },
      'good',
    ],
  });
  assert.deepEqual(control.acknowledged, ['good']);
});

test('a missing or non-array acknowledged field yields an empty list', async () => {
  for (const value of [undefined, null, 'nope', 5, {}]) {
    const control = await roundTrip({ acknowledged: value });
    assert.deepEqual(control.acknowledged, [], `acknowledged=${JSON.stringify(value)}`);
  }
  // And a control file that does not exist at all must not throw.
  const missing = await readControl(join(tmpdir(), 'definitely-not-here-9f8a7b.json'));
  assert.deepEqual(missing.acknowledged, []);
  assert.equal(missing.activeSessionId, null);
});

test('the other control fields are read correctly', async () => {
  // Guards the rest of the channel, since it is now covered by tests at all.
  const control = await roundTrip({
    hovered: true,
    dragging: true,
    activeSessionId: 'session-x',
    paused: true,
    tick: 12345,
    acknowledged: [],
  });
  assert.equal(control.hovered, true);
  assert.equal(control.dragging, true);
  assert.equal(control.activeSessionId, 'session-x');
  assert.equal(control.paused, true);
  assert.equal(control.tick, 12345);
});

test('the shell\'s language choice survives the control read, normalised', async () => {
  // The shell writes its UI language here on every control tick; the bridge emits
  // the next snapshot's labels in this language. Real-world tags must fold onto a
  // supported one, and a junk or missing value must fall back to the default
  // rather than poisoning the snapshot.
  assert.equal((await roundTrip({ language: 'en' })).language, 'en');
  assert.equal((await roundTrip({ language: 'en-US' })).language, 'en');
  assert.equal((await roundTrip({ language: 'zh' })).language, 'zh-CN');
  assert.equal((await roundTrip({ language: 'zh_CN' })).language, 'zh-CN');
  for (const junk of [undefined, null, '', 'fr-FR', 42, {}]) {
    assert.equal(
      (await roundTrip({ language: junk })).language,
      'zh-CN',
      `language=${JSON.stringify(junk)}`,
    );
  }
  // A control file that does not exist at all defaults to Chinese.
  const missing = await readControl(join(tmpdir(), 'definitely-not-here-9f8a7b.json'));
  assert.equal(missing.language, 'zh-CN');
});

test('readAcknowledgements is defensive about its own input', () => {
  assert.deepEqual(readAcknowledgements(undefined), []);
  assert.deepEqual(readAcknowledgements('a string'), []);
  assert.deepEqual(readAcknowledgements([{ sessionId: 'ok', at: 1 }]), [{ sessionId: 'ok', at: 1 }]);
});
