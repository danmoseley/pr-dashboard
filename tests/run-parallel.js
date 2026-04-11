// Runs test-pr-filters.js and test-pr-extended.js (in three parallel slices) concurrently,
// printing each script's buffered output sequentially once all finish.
// Groups F and I each load large pages (~30 s each) so they run as dedicated workers;
// the remaining fast groups run together as a fourth worker.
// Usage: node run-parallel.js  (from the tests/ directory)
'use strict';

const { spawn } = require('child_process');
const path = require('path');

/**
 * Spawn `script` as a child Node process, buffer its output, and resolve with
 * { code, output, script }.  `extraEnv` (optional) is merged into process.env
 * for the child, e.g. `{ ONLY_GROUPS: 'F' }` to select a test-group subset.
 */
function runScript(script, extraEnv) {
  const label = extraEnv && extraEnv.ONLY_GROUPS
    ? `${script} [groups ${extraEnv.ONLY_GROUPS}]`
    : script;
  return new Promise((resolve) => {
    const chunks = [];
    const child = spawn(process.execPath, [path.join(__dirname, script)], {
      cwd: __dirname,
      env: extraEnv ? { ...process.env, ...extraEnv } : process.env,
    });
    let settled = false;
    child.stdout.on('data', d => chunks.push(d));
    child.stderr.on('data', d => chunks.push(d));
    child.on('error', err => {
      if (settled) return;
      settled = true;
      chunks.push(Buffer.from(`Failed to start ${script}: ${err.message}\n`));
      resolve({ code: 1, output: Buffer.concat(chunks).toString(), script: label });
    });
    child.on('close', (code, signal) => {
      if (settled) return;
      settled = true;
      if (signal) {
        chunks.push(Buffer.from(`Process terminated by signal: ${signal}\n`));
      }
      resolve({
        code: code === null ? 1 : code,
        output: Buffer.concat(chunks).toString(),
        script: label,
      });
    });
  });
}

(async () => {
  const start = Date.now();
  console.log('Running Playwright tests in parallel…\n');

  // Four parallel workers:
  //   filters         : ~22 s
  //   extended A-E,G-K: ~52 s  (fast groups)
  //   extended F      : ~120 s (per-repo pages, one slow page-load per test)
  //   extended I      : ~90 s  (smoke tests, one slow page-load per test)
  // Wall-clock bottleneck: ~120 s instead of the previous ~264 s sequential run.
  const results = await Promise.all([
    runScript('test-pr-filters.js'),
    runScript('test-pr-extended.js', { ONLY_GROUPS: 'A,B,C,D,E,G,H,J,K' }),
    runScript('test-pr-extended.js', { ONLY_GROUPS: 'F' }),
    runScript('test-pr-extended.js', { ONLY_GROUPS: 'I' }),
  ]);

  for (const r of results) {
    const bar = '─'.repeat(60);
    console.log(bar);
    console.log('▶ ' + r.script);
    console.log(bar);
    process.stdout.write(r.output);
    if (!r.output.endsWith('\n')) console.log();
  }

  const elapsed = ((Date.now() - start) / 1000).toFixed(1);
  const allPassed = results.every(r => r.code === 0);
  console.log('═'.repeat(60));
  console.log('Parallel run complete in ' + elapsed + 's — ' + (allPassed ? 'ALL PASSED ✅' : 'FAILURES DETECTED ❌'));
  if (!allPassed) {
    const failures = results.filter(r => r.code !== 0).map(r => r.script);
    console.error('Failed: ' + failures.join(', '));
  }
  process.exit(allPassed ? 0 : 1);
})();
