// Runs test-pr-filters.js and test-pr-extended.js in parallel,
// printing each script's buffered output sequentially once both finish.
// Usage: node run-parallel.js  (from the tests/ directory)
'use strict';

const { spawn } = require('child_process');
const path = require('path');

function runScript(script) {
  return new Promise((resolve) => {
    const chunks = [];
    const child = spawn(process.execPath, [path.join(__dirname, script)], {
      cwd: __dirname,
    });
    let settled = false;
    child.stdout.on('data', d => chunks.push(d));
    child.stderr.on('data', d => chunks.push(d));
    child.on('error', err => {
      if (settled) return;
      settled = true;
      chunks.push(Buffer.from(`Failed to start ${script}: ${err.message}\n`));
      resolve({ code: 1, output: Buffer.concat(chunks).toString(), script });
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
        script,
      });
    });
  });
}

(async () => {
  const start = Date.now();
  console.log('Running Playwright tests in parallel…\n');

  const [r1, r2] = await Promise.all([
    runScript('test-pr-filters.js'),
    runScript('test-pr-extended.js'),
  ]);

  for (const r of [r1, r2]) {
    const bar = '─'.repeat(60);
    console.log(bar);
    console.log('▶ ' + r.script);
    console.log(bar);
    process.stdout.write(r.output);
    if (!r.output.endsWith('\n')) console.log();
  }

  const elapsed = ((Date.now() - start) / 1000).toFixed(1);
  const allPassed = r1.code === 0 && r2.code === 0;
  console.log('═'.repeat(60));
  console.log('Parallel run complete in ' + elapsed + 's — ' + (allPassed ? 'ALL PASSED ✅' : 'FAILURES DETECTED ❌'));
  if (!allPassed) {
    const failures = [r1, r2].filter(r => r.code !== 0).map(r => r.script);
    console.error('Failed: ' + failures.join(', '));
  }
  process.exit(allPassed ? 0 : 1);
})();
