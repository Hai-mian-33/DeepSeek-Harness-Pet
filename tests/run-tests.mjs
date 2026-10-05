/**
 * In-process test runner.
 *
 * `node --test` cannot be used here: it spawns one child process per test file to
 * isolate them, and the DSH sandbox denies that spawn with `EPERM` — piped stdio
 * between processes is a documented boundary of the sandbox — so not a single
 * test gets executed. This runner imports the test files into one process
 * instead. They stay ordinary `node:test` modules, so `node --test tests/` works
 * unchanged outside a sandbox.
 *
 * Output: `node:test`'s own reporter streams every result, and this runner adds
 * the final `pet test summary:` line plus a process exit code (0 only when
 * nothing failed). The summary counts real failures only: each file's synthetic
 * wrapper test also fails with the sandbox's spawn `EPERM`, which is the reason
 * this runner exists rather than a test result.
 *
 * Usage: node tests/run-tests.mjs
 */

import { readdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from 'node:test';

const here = dirname(fileURLToPath(import.meta.url));
const files = (await readdir(here))
  .filter((name) => name.endsWith('.test.mjs'))
  .sort();

if (files.length === 0) {
  console.error('no test files found');
  process.exit(1);
}

for (const file of files) await import(new URL(`./${file}`, import.meta.url).href);

/** Tests that failed, with their assertion detail. */
const failures = [];
/** Wrapper failures: the sandbox's spawn denial, not a test result. */
let sandboxWrappers = 0;
let passed = 0;

for await (const event of run({ concurrency: 1, timeout: 30_000 })) {
  if (event.type !== 'test:pass' && event.type !== 'test:fail') continue;
  const data = event.data ?? {};
  const error = data.details?.error;
  const message = String(error?.message ?? '');

  // Each imported file is wrapped in a synthetic root test whose name is the file
  // path, and that wrapper fails with the sandbox's spawn denial. It is not a test
  // result, so it is counted separately and never as a failure.
  const isWrapper = String(data.name ?? '').endsWith('.test.mjs') && message.includes('spawn EPERM');
  if (isWrapper) {
    if (event.type === 'test:fail') sandboxWrappers += 1;
    continue;
  }
  if (event.type === 'test:pass') {
    passed += 1;
    continue;
  }
  failures.push({
    name: String(data.name ?? 'unknown'),
    detail: error === undefined ? 'failed' : message.split('\n').slice(0, 8).join('\n        '),
  });
}

if (failures.length > 0) {
  process.stdout.write(`\nfailing tests (${failures.length}):\n`);
  for (const failure of failures) process.stdout.write(`  FAIL ${failure.name}\n        ${failure.detail}\n`);
}

process.stdout.write(
  `\npet test summary: ${passed} passed, ${failures.length} failed `
  + `(${passed + failures.length} tests in ${files.length} files`
  + `; ${sandboxWrappers} sandbox wrapper result(s) ignored)\n`,
);
process.exitCode = failures.length === 0 ? 0 : 1;
