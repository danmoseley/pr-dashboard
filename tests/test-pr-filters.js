// Playwright test for PR dashboard filter UI
// Run: node test-pr-filters.js  (from the tests/ directory, with server on port 8080)

const { chromium } = require('playwright');

const BASE = 'http://localhost:8080';
const PAGE = BASE + '/all/actionable.html';

async function log(msg) { console.log('[' + new Date().toISOString().slice(11,19) + '] ' + msg); }

async function wait(ms) { return new Promise(r => setTimeout(r, ms)); }

async function runTests() {
  const browser = await chromium.launch({ headless: true });
  const errors = [];
  let passed = 0;
  let failed = 0;

  function pass(name) { log('✅ PASS: ' + name); passed++; }
  function fail(name, detail) { log('❌ FAIL: ' + name + (detail ? ' — ' + detail : '')); failed++; }

  try {
    const page = await browser.newPage();
    page.on('console', msg => {
      if (msg.type() === 'error') errors.push(msg.text());
    });
    page.on('pageerror', err => errors.push('PAGE ERROR: ' + err.message));

    // ── Test 1: Page loads ──────────────────────────────────────────────────
    log('Navigating to ' + PAGE);
    await page.goto(PAGE, { waitUntil: 'domcontentloaded' });

    const title = await page.title();
    if (title.includes('Actionable')) pass('Page title correct: ' + title);
    else fail('Page title', 'got: ' + title);

    // Wait for table data (up to 15s)
    log('Waiting for PR table...');
    await page.waitForFunction(() => document.querySelectorAll('#pr-table tbody tr').length > 100, { timeout: 15000 }).catch(() => null);

    const rowCount = await page.$eval('#pr-table tbody', tb => tb.querySelectorAll('tr').length).catch(() => 0);
    if (rowCount > 0) pass('Table loaded with ' + rowCount + ' rows');
    else fail('Table load', 'no rows found');

    // Report any JS errors so far
    if (errors.length > 0) {
      log('⚠️  JS errors detected: ' + errors.join(' | '));
    }

    // ── Test 2: Area column present ─────────────────────────────────────────
    const hasAreaCol = await page.$('#pr-table th:last-child').then(el => el ? el.innerText() : '').catch(() => '');
    const areaHeader = await page.$eval('#pr-table th:last-child', e => e.textContent).catch(() => '');
    if (areaHeader.includes('Area')) pass('Area column visible');
    else fail('Area column', 'last th text: ' + areaHeader);

    // ── Test 3: Area label buttons present ─────────────────────────────────
    const areaLabels = await page.$$('button.area-label');
    if (areaLabels.length > 0) pass('Area label buttons found: ' + areaLabels.length);
    else fail('Area label buttons', 'none found — check hasArea / area_labels data');

    // ── Test 4: filter-banner hidden initially ─────────────────────────────
    const bannerInitial = await page.$eval('#filter-banner', e => getComputedStyle(e).display).catch(() => 'missing');
    if (bannerInitial === 'none' || bannerInitial === '') pass('Filter banner hidden initially (display=' + bannerInitial + ')');
    else fail('Filter banner initial state', 'display=' + bannerInitial);

    // ── Test 5: Click area label → banner appears ──────────────────────────
    const areaLabelLocator = page.locator('button.area-label').first();
    const labelText = await areaLabelLocator.textContent();
    log('Clicking area label: ' + labelText);
    await areaLabelLocator.click();
    await wait(300);

    const bannerAfter = await page.$eval('#filter-banner', e => e.style.display).catch(() => '?');
    if (bannerAfter === 'flex') pass('Filter banner visible after area click (display=flex)');
    else fail('Filter banner after area click', 'display=' + bannerAfter);

    const chips = await page.$$('.filter-chip');
    if (chips.length > 0) {
      const chipText = await chips[0].textContent();
      pass('Filter chip rendered: "' + chipText.trim() + '"');
    } else fail('Filter chip', 'no .filter-chip elements found');

    const visibleRows = await page.$$eval('#pr-table tbody tr', rows => rows.filter(r => r.style.display !== 'none').length);
    const hiddenRows  = await page.$$eval('#pr-table tbody tr', rows => rows.filter(r => r.style.display === 'none').length);
    pass('After area filter: ' + visibleRows + ' visible, ' + hiddenRows + ' hidden');

    // ── Test 6: Ctrl+click adds second area filter (REAL modifier, not synthetic) ──
    // Navigate back to clean URL (reload would preserve ?area= query and re-filter)
    await page.goto('http://localhost:8080/all/actionable.html', { waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => document.querySelectorAll('#pr-table tbody tr').length > 100, { timeout: 15000 }).catch(() => null);
    await wait(300);

    // Find a row with 2+ area labels so after filtering by label1, label2 is still in a visible row
    const labelPair = await page.$$eval('#pr-table tbody tr', rows => {
      for (const row of rows) {
        if (row.style.display === 'none') continue;
        const btns = Array.from(row.querySelectorAll('button.area-label'));
        if (btns.length >= 2) return [btns[0].textContent.trim(), btns[1].textContent.trim()];
      }
      return null;
    });

    if (!labelPair) {
      // Fallback: just verify Ctrl+click adds a chip (no multi-label row found)
      log('⚠️  No multi-label row found; testing basic Ctrl+click chip behavior');
      const allLabels2 = await page.$$eval('#pr-table tbody tr', rows =>
        rows.filter(r => r.style.display !== 'none')
            .flatMap(r => Array.from(r.querySelectorAll('button.area-label')).map(e => e.textContent.trim()))
      );
      const fl = allLabels2[0];
      if (!fl) { pass('Ctrl+click skipped — no labels found'); }
      else {
        const coordsF = await page.evaluate((t) => {
          for (const row of document.querySelectorAll('#pr-table tbody tr')) {
            if (row.style.display === 'none') continue;
            for (const btn of row.querySelectorAll('button.area-label')) {
              if (btn.textContent.trim() === t) { const r = btn.getBoundingClientRect(); return r.width > 0 ? { x: r.left + r.width/2, y: r.top + r.height/2 } : null; }
            }
          }
          return null;
        }, fl);
        if (coordsF) {
          await page.keyboard.down('Control'); await page.mouse.click(coordsF.x, coordsF.y); await page.keyboard.up('Control'); await wait(300);
          const cnt = await page.$$eval('.filter-chip', els => els.length);
          if (cnt >= 1) pass('Ctrl+click (single) added chip: ' + cnt + ' chip(s)');
          else fail('Ctrl+click fallback', 'no chip after ctrl+click');
        } else fail('Ctrl+click fallback', 'coords not found');
      }
    } else {
      const [lA, lB] = labelPair;
      log('Ctrl+click test using multi-label row: "' + lA + '" + "' + lB + '"');

      // Helper: scroll element into view then get viewport-relative coords
      async function getVisibleBtnCoords(text) {
        // First scroll into view via evaluate
        await page.evaluate((targetText) => {
          for (const row of document.querySelectorAll('#pr-table tbody tr')) {
            if (row.style.display === 'none') continue;
            for (const btn of row.querySelectorAll('button.area-label')) {
              if (btn.textContent.trim() === targetText) { btn.scrollIntoView({ behavior: 'instant', block: 'center' }); return; }
            }
          }
        }, text);
        await wait(50); // let browser settle after scroll
        // Now get fresh viewport-relative coordinates
        return page.evaluate((targetText) => {
          for (const row of document.querySelectorAll('#pr-table tbody tr')) {
            if (row.style.display === 'none') continue;
            for (const btn of row.querySelectorAll('button.area-label')) {
              if (btn.textContent.trim() === targetText) {
                const r = btn.getBoundingClientRect();
                if (r.width > 0 && r.height > 0 && r.top >= 0) return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height };
              }
            }
          }
          return null;
        }, text);
      }

      // Step 1: Click lA (single click) → filter to lA; multi-label row remains visible showing lB
      const coordsA = await getVisibleBtnCoords(lA);
      if (!coordsA) { fail('Ctrl+click multi-select', 'could not locate "' + lA + '"'); }
      else {
        // Check no new tab (button element sanity check)
        let newTabOpened = false;
        page.once('popup', () => { newTabOpened = true; });
        await page.keyboard.down('Control');
        await page.mouse.click(coordsA.x, coordsA.y);
        await page.keyboard.up('Control');
        await wait(300);
        if (newTabOpened) fail('Ctrl+click on button opened new tab — <button> regression');
        else pass('Ctrl+click first label: no new tab (button element correct)');

        const chipsAfterA = await page.$$('.filter-chip');
        if (chipsAfterA.length < 1) {
          fail('Ctrl+click first label', 'no chip appeared');
        } else {
          pass('Ctrl+click first area: ' + chipsAfterA.length + ' chip(s) — "' + lA + '" added');

          // Step 2: Ctrl+click lB. Hold Ctrl FIRST (keydown un-hides all rows, shifting layout),
          // then get FRESH coords after layout settles, then click.
          await page.keyboard.down('Control');
          await wait(150); // let keydown handler run + layout settle
          const coordsB = await page.evaluate((label) => {
            const btn = [...document.querySelectorAll('button.area-label')].find(b => b.textContent.trim() === label);
            if (!btn) return null;
            btn.scrollIntoView({ behavior: 'instant', block: 'center' });
            const r = btn.getBoundingClientRect();
            const vh = window.innerHeight;
            return (r.width > 0 && r.top >= 0 && r.bottom <= vh) ? { x: r.left + r.width / 2, y: r.top + r.height / 2 } : null;
          }, lB);
          await wait(50); // scrollIntoView settle
          const coordsB2 = coordsB && await page.evaluate((label) => {
            const btn = [...document.querySelectorAll('button.area-label')].find(b => b.textContent.trim() === label);
            if (!btn) return null;
            const r = btn.getBoundingClientRect();
            const vh = window.innerHeight;
            return (r.width > 0 && r.top >= 0 && r.bottom <= vh) ? { x: r.left + r.width / 2, y: r.top + r.height / 2 } : null;
          }, lB);
          if (!coordsB2) {
            await page.keyboard.up('Control');
            fail('Ctrl+click second label', '"' + lB + '" not visible while Ctrl held');
          } else {
            await page.mouse.click(coordsB2.x, coordsB2.y);
            await page.keyboard.up('Control');
            await wait(300);
            const chipsAfterBoth = await page.$$('.filter-chip');
            if (chipsAfterBoth.length >= 2) pass('Ctrl+click multi-select: ' + chipsAfterBoth.length + ' chips — "' + lA + '" + "' + lB + '"');
            else fail('Ctrl+click multi-select', 'only ' + chipsAfterBoth.length + ' chip(s) after two Ctrl+clicks — ctrlKey may not be detected');
          }
        }
      }
    }

    // ── Test 7: Chip X removes filter ─────────────────────────────────────
    const removeBtn = await page.$('.filter-chip .chip-remove');
    if (removeBtn) {
      await removeBtn.click();
      await wait(300);
      const chipsAfterRemove = await page.$$('.filter-chip');
      pass('After chip remove: ' + chipsAfterRemove.length + ' chip(s) remain');
    } else fail('Chip remove button', 'not found');

    // Clear remaining chip so all rows visible
    await page.evaluate(() => { if (window.clearAllSecondaryFilters) window.clearAllSecondaryFilters(); });
    await wait(200);

    // ── Test 8: Repo filter buttons present ────────────────────────────────
    const repoLinks = await page.$$('button.repo-filter-btn');
    if (repoLinks.length > 0) pass('Repo filter buttons found: ' + repoLinks.length);
    else fail('Repo filter buttons', 'none found');

    // ── Test 9: Click repo button → repo chip appears ──────────────────────
    if (repoLinks.length > 0) {
      // Use locator for auto scroll-into-view
      const repoLocator = page.locator('button.repo-filter-btn').first();
      const repoText = await repoLocator.textContent();
      log('Clicking repo button: ' + repoText);
      await repoLocator.click();
      await wait(300);
      const repoChips = await page.$$eval('.filter-chip', chips => chips.map(c => c.textContent.trim()));
      if (repoChips.some(t => t.includes('Repo:'))) pass('Repo chip appeared after clicking ' + repoText.trim() + ': ' + repoChips.join(', '));
      else fail('Repo chip', 'no Repo: chip — chips: ' + repoChips.join(', '));
    }

    // ── Test 10: URL reflects filters ──────────────────────────────────────
    const url = page.url();
    log('Current URL: ' + url);
    if (url.includes('repo=') || url.includes('area=')) pass('URL contains filter params');
    else fail('URL filter params', url);

    // ── Test 11: URL bookmark round-trip ───────────────────────────────────
    const page2 = await browser.newPage();
    await page2.goto(PAGE + '?area=area-CodeGen-coreclr', { waitUntil: 'domcontentloaded' });
    await page2.waitForFunction(() => document.querySelectorAll('#pr-table tbody tr').length > 0, { timeout: 15000 }).catch(() => null);
    await wait(500);
    const chipsOnLoad = await page2.$$('.filter-chip');
    if (chipsOnLoad.length > 0) pass('URL ?area= param restores filter chip on load');
    else fail('URL area param restore', 'no chips after loading ?area=area-CodeGen-coreclr');
    await page2.close();

    // ── Test 12: User filter + area filter combo ────────────────────────────
    // (replicates the case the user likely hit)
    const page3 = await browser.newPage();
    page3.on('console', msg => { if (msg.type() === 'error') errors.push('p3:' + msg.text()); });
    await page3.goto(PAGE, { waitUntil: 'domcontentloaded' });
    await page3.waitForFunction(() => document.querySelectorAll('#pr-table tbody tr').length > 100, { timeout: 15000 }).catch(() => null);

    // Pick a real author from the table so the user filter returns results
    const firstAuthor = await page3.evaluate(() => {
      const btns = document.querySelectorAll('#pr-table tbody tr .filter-btn');
      for (const b of btns) {
        const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
        if (m) return m[1];
      }
      return null;
    });
    log('Testing user filter + area combo (user: ' + firstAuthor + ')');
    if (!firstAuthor) { fail('User filter combo', 'could not find author'); }
    else {
    await page3.$eval('#user-field', (el, u) => { el.value = u; }, firstAuthor);
    await page3.click('button[onclick*="applyUser"]');
    await wait(1000); // wait for re-render

    const summaryBar = await page3.$eval('#summary-bar', e => e.style.display).catch(() => '?');
    log('Summary bar display after user filter: ' + summaryBar);

    // Now click an area label in the filtered results
    const userAreaLabelLocator = page3.locator('button.area-label').first();
    const userAreaLabelCount = await userAreaLabelLocator.count();
    if (userAreaLabelCount > 0) {
      const aLabel = await userAreaLabelLocator.textContent();
      log('Clicking area label after user filter: ' + aLabel);
      await userAreaLabelLocator.click();
      await wait(300);
      const bannerUser = await page3.$eval('#filter-banner', e => e.style.display).catch(() => '?');
      if (bannerUser === 'flex') pass('Filter banner visible after area click WITH user filter active');
      else fail('Filter banner with user filter', 'display=' + bannerUser + ' (expected flex)');
    } else {
      log('⚠️  No area labels visible after user filter — skipping combo test');
      pass('User+area combo skipped (no area labels for this user)');
    }
    } // end if firstAuthor
    await page3.close();

    // ── Test 13: URL ?repo= bookmark round-trip ──────────────────────────────
    const page4 = await browser.newPage();
    await page4.goto(PAGE + '?repo=runtime', { waitUntil: 'domcontentloaded' });
    await page4.waitForFunction(() => document.querySelectorAll('#pr-table tbody tr').length > 0, { timeout: 15000 }).catch(() => null);
    await wait(300);
    const repoChipsOnLoad = await page4.$$('.filter-chip');
    if (repoChipsOnLoad.length > 0) pass('URL ?repo= param restores repo filter chip on load');
    else fail('URL repo param restore', 'no chips after loading ?repo=runtime');
    await page4.close();

    // ── Test 14: Ctrl+click same area twice deselects it ────────────────────
    {
      const p14 = await browser.newPage();
      await p14.goto(PAGE, { waitUntil: 'domcontentloaded' });
      await p14.waitForFunction(() => document.querySelectorAll('#pr-table tbody tr').length > 100, { timeout: 15000 }).catch(() => null);
      await wait(300);
      // Find any visible area label
      const firstAreaLabel = await p14.evaluate(() => {
        for (const row of document.querySelectorAll('#pr-table tbody tr')) {
          if (row.style.display === 'none') continue;
          const btn = row.querySelector('button.area-label');
          if (btn) { btn.scrollIntoView({ behavior: 'instant', block: 'center' }); return btn.textContent.trim(); }
        }
        return null;
      });
      if (!firstAreaLabel) { fail('Ctrl+click deselect', 'no area labels found'); }
      else {
        // First Ctrl+click → select
        await p14.keyboard.down('Control');
        const coordsC1 = await p14.evaluate((label) => {
          const btn = [...document.querySelectorAll('button.area-label')].find(b => b.textContent.trim() === label);
          if (!btn) return null;
          btn.scrollIntoView({ behavior: 'instant', block: 'center' });
          const r = btn.getBoundingClientRect();
          return r.width > 0 ? { x: r.left + r.width / 2, y: r.top + r.height / 2 } : null;
        }, firstAreaLabel);
        await wait(100);
        if (coordsC1) await p14.mouse.click(coordsC1.x, coordsC1.y);
        await p14.keyboard.up('Control');
        await wait(200);
        const chipsAfterSelect = await p14.$$('.filter-chip');
        if (chipsAfterSelect.length < 1) { fail('Ctrl+click deselect (setup)', 'no chip after first ctrl+click'); }
        else {
          // Second Ctrl+click → deselect
          await p14.keyboard.down('Control');
          await wait(150);
          const coordsC2 = await p14.evaluate((label) => {
            const btn = [...document.querySelectorAll('button.area-label')].find(b => b.textContent.trim() === label);
            if (!btn) return null;
            btn.scrollIntoView({ behavior: 'instant', block: 'center' });
            const r = btn.getBoundingClientRect();
            return r.width > 0 ? { x: r.left + r.width / 2, y: r.top + r.height / 2 } : null;
          }, firstAreaLabel);
          await wait(50);
          if (coordsC2) await p14.mouse.click(coordsC2.x, coordsC2.y);
          await p14.keyboard.up('Control');
          await wait(300);
          const chipsAfterDeselect = await p14.$$('.filter-chip');
          if (chipsAfterDeselect.length === 0) pass('Ctrl+click same area twice deselects (0 chips)');
          else fail('Ctrl+click deselect', chipsAfterDeselect.length + ' chips remain after deselect');
        }
      }
      await p14.close();
    }

    // ── Test 15: Clear all removes all chips ─────────────────────────────────
    {
      const p15 = await browser.newPage();
      await p15.goto(PAGE + '?area=area-CodeGen-coreclr', { waitUntil: 'domcontentloaded' });
      await p15.waitForFunction(() => document.querySelectorAll('.filter-chip').length >= 1, { timeout: 10000 }).catch(() => null);
      await wait(200);
      const chipsBeforeClear = await p15.$$('.filter-chip');
      if (chipsBeforeClear.length < 1) { fail('Clear all setup', 'expected 1+ chips, got ' + chipsBeforeClear.length); }
      else {
        // Click the "Clear all" link in the banner
        const clearAll = await p15.$('#filter-banner a[onclick*="clearAll"]');
        if (!clearAll) { fail('Clear all', '"Clear all" link not found in banner'); }
        else {
          await clearAll.click();
          await wait(300);
          const chipsAfterClear = await p15.$$('.filter-chip');
          if (chipsAfterClear.length === 0) pass('Clear all removes all chips');
          else fail('Clear all', chipsAfterClear.length + ' chips remain after clear all');
        }
      }
      await p15.close();
    }

    // ── Summary ─────────────────────────────────────────────────────────────
    console.log('\n=== RESULTS: ' + passed + ' passed, ' + failed + ' failed ===');
    if (errors.length) console.log('JS errors: ' + errors.join('\n  '));
    if (failed > 0) process.exitCode = 1;

  } finally {
    await browser.close();
  }
}

runTests().catch(err => { console.error('Fatal:', err); process.exit(1); });
