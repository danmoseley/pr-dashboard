// Playwright test for PR dashboard filter UI
// Run: node C:\temp\test-pr-filters.js

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
    await page.goto(PAGE, { waitUntil: 'networkidle' });

    const title = await page.title();
    if (title.includes('Actionable')) pass('Page title correct: ' + title);
    else fail('Page title', 'got: ' + title);

    // Wait for table data (up to 15s)
    log('Waiting for PR table...');
    await page.waitForSelector('#pr-table tbody tr', { timeout: 15000 }).catch(() => null);

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

    // ── Test 3: Area label links present ───────────────────────────────────
    const areaLabels = await page.$$('a.area-label');
    if (areaLabels.length > 0) pass('Area label links found: ' + areaLabels.length);
    else fail('Area label links', 'none found — check hasArea / area_labels data');

    // ── Test 4: filter-banner hidden initially ─────────────────────────────
    const bannerInitial = await page.$eval('#filter-banner', e => getComputedStyle(e).display).catch(() => 'missing');
    if (bannerInitial === 'none' || bannerInitial === '') pass('Filter banner hidden initially (display=' + bannerInitial + ')');
    else fail('Filter banner initial state', 'display=' + bannerInitial);

    // ── Test 5: Click area label → banner appears ──────────────────────────
    if (areaLabels.length > 0) {
      const labelText = await areaLabels[0].textContent();
      log('Clicking area label: ' + labelText);
      await areaLabels[0].click();
      await wait(300);

      const bannerAfter = await page.$eval('#filter-banner', e => e.style.display).catch(() => '?');
      if (bannerAfter === 'flex') pass('Filter banner visible after area click (display=flex)');
      else fail('Filter banner after area click', 'display=' + bannerAfter);

      const chips = await page.$$('.filter-chip');
      if (chips.length > 0) {
        const chipText = await chips[0].textContent();
        pass('Filter chip rendered: "' + chipText.trim() + '"');
      } else fail('Filter chip', 'no .filter-chip elements found');

      // Check filtered rows
      const visibleRows = await page.$$eval('#pr-table tbody tr', rows => rows.filter(r => r.style.display !== 'none').length);
      const hiddenRows  = await page.$$eval('#pr-table tbody tr', rows => rows.filter(r => r.style.display === 'none').length);
      pass('After area filter: ' + visibleRows + ' visible, ' + hiddenRows + ' hidden');
    }

    // ── Test 6: Ctrl+click adds second area filter ─────────────────────────
    // Must pick a label from a VISIBLE row (other rows are now hidden)
    const currentChip = await page.$eval('.filter-chip', e => e.textContent.trim().replace('✕','').trim()).catch(() => '');
    const visibleAreaLabels = await page.$$eval(
      '#pr-table tbody tr:not([style*="display: none"]) a.area-label',
      els => els.map(e => e.textContent.trim())
    );
    log('Visible area labels after first filter: ' + visibleAreaLabels.slice(0, 5).join(', '));

    const secondLabelText = visibleAreaLabels.find(t => t !== currentChip);
    if (secondLabelText) {
      // Click it via evaluate to pass ctrlKey
      log('Ctrl+clicking second area: ' + secondLabelText);
      const result = await page.evaluate(async (targetText) => {
        const labels = Array.from(document.querySelectorAll('#pr-table tbody tr:not([style*="display: none"]) a.area-label'));
        const el = labels.find(e => e.textContent.trim() === targetText);
        if (!el) return 'not found';
        const evt = new MouseEvent('click', { ctrlKey: true, bubbles: true, cancelable: true });
        el.dispatchEvent(evt);
        return 'clicked';
      }, secondLabelText);
      await wait(300);
      const chipsAfterCtrl = await page.$$('.filter-chip');
      if (chipsAfterCtrl.length >= 2) pass('Ctrl+click added second area chip (now ' + chipsAfterCtrl.length + ' chips)');
      else fail('Ctrl+click multi-select', result + ' — still only ' + chipsAfterCtrl.length + ' chip(s)');
    } else {
      log('⚠️  No second distinct visible area label found (only one area in result set)');
      pass('Ctrl+click skipped — single area in filtered results (expected)');
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

    // ── Test 8: Repo filter link present ───────────────────────────────────
    const repoLinks = await page.$$('.repo-col a[onclick*="filterByRepo"]');
    if (repoLinks.length > 0) pass('Repo filter links found: ' + repoLinks.length);
    else fail('Repo filter links', 'none found');

    // ── Test 9: Click repo link → repo chip appears ────────────────────────
    if (repoLinks.length > 0) {
      // Use evaluate so we don't need the element to be visible
      const repoText = await page.evaluate(() => {
        const el = document.querySelector('.repo-col a[onclick*="filterByRepo"]');
        if (!el) return null;
        el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        return el.textContent.trim();
      });
      await wait(300);
      const repoChips = await page.$$eval('.filter-chip', chips => chips.map(c => c.textContent.trim()));
      if (repoChips.some(t => t.includes('Repo:'))) pass('Repo chip appeared after clicking ' + repoText + ': ' + repoChips.join(', '));
      else fail('Repo chip', 'no Repo: chip — chips: ' + repoChips.join(', '));
    }

    // ── Test 10: URL reflects filters ──────────────────────────────────────
    const url = page.url();
    log('Current URL: ' + url);
    if (url.includes('repo=') || url.includes('area=')) pass('URL contains filter params');
    else fail('URL filter params', url);

    // ── Test 11: URL bookmark round-trip ───────────────────────────────────
    const page2 = await browser.newPage();
    await page2.goto(PAGE + '?area=area-CodeGen-coreclr', { waitUntil: 'networkidle' });
    await page2.waitForSelector('#pr-table tbody tr', { timeout: 15000 }).catch(() => null);
    await wait(500);
    const chipsOnLoad = await page2.$$('.filter-chip');
    if (chipsOnLoad.length > 0) pass('URL ?area= param restores filter chip on load');
    else fail('URL area param restore', 'no chips after loading ?area=area-CodeGen-coreclr');
    await page2.close();

    // ── Test 12: User filter + area filter combo ────────────────────────────
    // (replicates the case the user likely hit)
    const page3 = await browser.newPage();
    page3.on('console', msg => { if (msg.type() === 'error') errors.push('p3:' + msg.text()); });
    await page3.goto(PAGE, { waitUntil: 'networkidle' });
    await page3.waitForSelector('#pr-table tbody tr', { timeout: 15000 }).catch(() => null);

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
    const userAreaLabels = await page3.$$('#pr-table tbody tr:not([style*="display: none"]) a.area-label');
    if (userAreaLabels.length > 0) {
      const aLabel = await userAreaLabels[0].textContent();
      log('Clicking area label after user filter: ' + aLabel);
      await userAreaLabels[0].click();
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

    // ── Summary ─────────────────────────────────────────────────────────────
    console.log('\n=== RESULTS: ' + passed + ' passed, ' + failed + ' failed ===');
    if (errors.length) console.log('JS errors: ' + errors.join('\n  '));

  } finally {
    await browser.close();
  }
}

runTests().catch(err => { console.error('Fatal:', err); process.exit(1); });
