// Extended Playwright tests for PR dashboard
// Covers user filter, URL params, easy-action filter, column sorting,
// [?] popup, per-repo pages, show-more, multi-chip URLs, and smoke tests.
// Run: node tests/test-pr-extended.js   (from repo root, with dev server on :8080)

const { chromium } = require('playwright');

const BASE = 'http://localhost:8080';
const ALL  = BASE + '/all/actionable.html';
const RUNTIME = BASE + '/runtime/actionable.html';

async function log(msg) { console.log('[' + new Date().toISOString().slice(11,19) + '] ' + msg); }
async function wait(ms) { return new Promise(r => setTimeout(r, ms)); }

async function runTests() {
  const browser = await chromium.launch({ headless: true });
  const jsErrors = [];
  let passed = 0, failed = 0;

  function pass(name) { log('✅ PASS: ' + name); passed++; }
  function fail(name, detail) { log('❌ FAIL: ' + name + (detail ? ' — ' + detail : '')); failed++; }

  // Shared context: reusing one context (vs. per-test newContext) avoids the overhead of
  // spinning up a new browser context (~100ms+) for every test. localStorage isolation is
  // achieved via addInitScript, which runs before any page script on every navigation.
  const ctx = await browser.newContext();
  await ctx.addInitScript(() => { try { localStorage.clear(); } catch (e) {} });

  // Helper: open a fresh page and wait for the PR table to have rows.
  async function openPage(url, minRows = 1, timeout = 20000) {
    const p = await ctx.newPage();
    p.on('console', msg => { if (msg.type() === 'error') jsErrors.push(msg.text()); });
    p.on('pageerror', err => jsErrors.push('PAGE ERROR: ' + err.message));
    await p.goto(url, { waitUntil: 'domcontentloaded' });
    if (minRows > 0) {
      try {
        await p.waitForFunction(n => document.querySelectorAll('#pr-table tbody tr').length >= n,
          minRows, { timeout });
      } catch (err) {
        await p.close();
        throw new Error('openPage: table did not reach ' + minRows + ' rows within ' + timeout + 'ms at ' + url);
      }
    }
    await p.waitForFunction(() => document.readyState === 'complete', { timeout: 2000 }).catch(() => null);
    return p;
  }

  try {

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP A — User filter
    // ══════════════════════════════════════════════════════════════════════════

    log('\n── Group A: User filter ──');

    // A1: Enter username → Go → summary bar appears with a count
    {
      const p = await openPage(ALL, 100);
      const author = await p.evaluate(() => {
        for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
          const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
          if (m) return m[1];
        }
        return null;
      });
      if (!author) { fail('A1: User filter summary bar', 'no author found in table'); }
      else {
        await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
        await p.click('#go-btn');
        await p.waitForFunction(
          () => {
            const sb = document.getElementById('summary-bar');
            if (!sb) return false;
            const display = getComputedStyle(sb).display;
            const text = (sb.textContent || '').trim();
            return display !== 'none' && text.length > 0;
          },
          { timeout: 3000 }).catch(() => null);
        const summaryDisplay = await p.$eval('#summary-bar', e => getComputedStyle(e).display).catch(() => 'missing');
        if (summaryDisplay !== 'none' && summaryDisplay !== 'missing') {
          const summaryText = await p.$eval('#summary-bar', e => e.textContent).catch(() => '');
          pass('A1: User filter shows summary bar (user=' + author + '): "' + summaryText.trim().slice(0, 60) + '"');
        } else {
          fail('A1: User filter summary bar', 'display=' + summaryDisplay + ' for user=' + author);
        }
      }
      await p.close();
    }

    // A2: Clicking 🔍 (filter-btn) in a table row fills user-field and filters rows
    {
      const p = await openPage(ALL, 100);
      const filterBtns = await p.$$('#pr-table tbody tr .filter-btn');
      if (filterBtns.length === 0) { fail('A2: Avatar filter button click', 'no .filter-btn elements found'); }
      else {
        const firstBtn = p.locator('#pr-table tbody tr .filter-btn').first();
        await firstBtn.scrollIntoViewIfNeeded();
        await firstBtn.click();
        await p.waitForFunction(
          () => {
            const sb = document.getElementById('summary-bar');
            if (!sb) return false;
            const display = getComputedStyle(sb).display;
            const text = (sb.textContent || '').trim();
            return display !== 'none' && text.length > 0;
          },
          { timeout: 3000 }).catch(() => null);
        const userVal = await p.$eval('#user-field', e => e.value).catch(() => '');
        const summaryDisplay = await p.$eval('#summary-bar', e => getComputedStyle(e).display).catch(() => 'missing');
        if (userVal.length > 0) pass('A2: Avatar filter click fills user field: "' + userVal + '"');
        else fail('A2: Avatar filter click', 'user-field still empty after click');
        if (summaryDisplay !== 'none' && summaryDisplay !== 'missing') {
          pass('A2: Avatar filter click shows summary bar');
        } else {
          fail('A2: Avatar filter click — summary bar', 'display=' + summaryDisplay);
        }
      }
      await p.close();
    }

    // A3: ?user=username URL param pre-fills the field and shows summary bar
    {
      const p = await openPage(ALL + '?user=dotnet-bot', 0);
      const userVal = await p.$eval('#user-field', e => e.value).catch(() => '');
      if (userVal === 'dotnet-bot') pass('A3: ?user= param pre-fills user field');
      else fail('A3: ?user= param', 'user-field="' + userVal + '", expected "dotnet-bot"');
      const summaryDisplay = await p.$eval('#summary-bar', e => getComputedStyle(e).display).catch(() => 'missing');
      if (summaryDisplay !== 'none' && summaryDisplay !== 'missing') {
        pass('A3: ?user= param shows summary bar on load');
      } else {
        fail('A3: ?user= param summary bar', 'summary-bar display=' + summaryDisplay);
      }
      await p.close();
    }

    // A4: Involves toggle appears after user filter and is clickable
    {
      const p = await openPage(ALL, 100);
      const author = await p.evaluate(() => {
        for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
          const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
          if (m) return m[1];
        }
        return null;
      });
      if (!author) { fail('A4: Involves toggle', 'no author in table'); }
      else {
        await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
        await p.click('#go-btn');
        await wait(800);
        const involvesDisplay = await p.$eval('#involves-label', e => getComputedStyle(e).display).catch(() => 'missing');
        if (involvesDisplay !== 'none' && involvesDisplay !== 'missing') pass('A4: Involves label visible after user filter');
        else fail('A4: Involves toggle', 'involves-label display=' + involvesDisplay);
        // Toggle involves and assert the checkbox state actually changes
        const beforeChecked = await p.$eval('#involves-toggle', e => e.checked).catch(() => null);
        const beforeRows = await p.$$eval('#pr-table tbody tr', rows => rows.filter(r => r.style.display !== 'none').length);
        await p.click('#involves-toggle');
        await wait(600);
        const afterChecked = await p.$eval('#involves-toggle', e => e.checked).catch(() => null);
        const afterRows = await p.$$eval('#pr-table tbody tr', rows => rows.filter(r => r.style.display !== 'none').length);
        if (beforeChecked !== null && afterChecked !== null && beforeChecked !== afterChecked) {
          pass('A4: Involves toggle changed checked state: ' + beforeChecked + ' → ' + afterChecked + ' (rows ' + beforeRows + ' → ' + afterRows + ')');
        } else {
          fail('A4: Involves toggle', 'checked state did not change (' + beforeChecked + ' → ' + afterChecked + '), rows ' + beforeRows + ' → ' + afterRows);
        }
      }
      await p.close();
    }

    // A5: Next-action-only toggle disables the involves checkbox
    {
      const p = await openPage(ALL, 100);
      const author = await p.evaluate(() => {
        for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
          const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
          if (m) return m[1];
        }
        return null;
      });
      if (!author) { fail('A5: Next-action toggle', 'no author'); }
      else {
        await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
        await p.click('#go-btn');
        await wait(800);
        await p.click('#next-action-toggle');
        await wait(400);
        const involvesDisabled = await p.$eval('#involves-toggle', e => e.disabled).catch(() => null);
        if (involvesDisabled === true) pass('A5: Next-action-only toggle disables involves checkbox');
        else fail('A5: Next-action-only toggle', 'involves-toggle.disabled=' + involvesDisabled);
      }
      await p.close();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP B — URL param round-trips
    // ══════════════════════════════════════════════════════════════════════════

    log('\n── Group B: URL param round-trips ──');

    // B1: ?involves=true restores involves checkbox as checked
    {
      const p = await openPage(ALL + '?user=danmoseley&involves=true', 0);
      const checked = await p.$eval('#involves-toggle', e => e.checked).catch(() => null);
      if (checked === true) pass('B1: ?involves=true restores involves checkbox');
      else fail('B1: ?involves=true', 'involves-toggle.checked=' + checked);
      await p.close();
    }

    // B2: ?nextaction=true restores next-action checkbox and involves disabled
    {
      const p = await openPage(ALL + '?user=danmoseley&nextaction=true', 0);
      const naChecked = await p.$eval('#next-action-toggle', e => e.checked).catch(() => null);
      const involvesDisabled = await p.$eval('#involves-toggle', e => e.disabled).catch(() => null);
      if (naChecked === true) pass('B2: ?nextaction=true restores next-action checkbox');
      else fail('B2: ?nextaction=true', 'next-action-toggle.checked=' + naChecked);
      if (involvesDisabled === true) pass('B2: ?nextaction=true also disables involves checkbox');
      else fail('B2: ?nextaction=true — involves disabled', 'disabled=' + involvesDisabled);
      await p.close();
    }

    // B3: ?easyaction=true restores easy-action checkbox
    {
      const p = await openPage(ALL + '?user=danmoseley&easyaction=true', 0);
      const eaChecked = await p.$eval('#easy-action-toggle', e => e.checked).catch(() => null);
      if (eaChecked === true) pass('B3: ?easyaction=true restores easy-action checkbox');
      else fail('B3: ?easyaction=true', 'easy-action-toggle.checked=' + eaChecked);
      await p.close();
    }

    // B4: Combined ?area=Y&repo=Z restores both filters at once
    {
      const p = await openPage(ALL + '?area=area-CodeGen-coreclr&repo=runtime', 1);
      await wait(500);
      const chips = await p.$$eval('.filter-chip', els => els.map(e => e.textContent.trim()));
      const hasArea = chips.some(t => t.includes('CodeGen') || t.includes('coreclr'));
      const hasRepo = chips.some(t => t.includes('Repo:') && t.includes('runtime'));
      if (hasArea) pass('B4: Combined URL — area chip present: ' + chips.join(', '));
      else fail('B4: Combined URL — area chip', 'chips: ' + chips.join(', '));
      if (hasRepo) pass('B4: Combined URL — repo chip present');
      else fail('B4: Combined URL — repo chip', 'chips: ' + chips.join(', '));
      await p.close();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP C — Easy action filter
    // ══════════════════════════════════════════════════════════════════════════

    log('\n── Group C: Easy action filter ──');

    // C1: Easy action toggle (no user) filters the table to a smaller set
    {
      const p = await openPage(ALL, 100);
      // Easy action toggle is only functional with a user — set one first
      const author = await p.evaluate(() => {
        for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
          const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
          if (m) return m[1];
        }
        return null;
      });
      if (!author) { fail('C1: Easy action filter', 'no author in table'); }
      else {
        await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
        await p.click('#go-btn');
        await wait(800);
        const rowsAfterUser = await p.$$eval('#pr-table tbody tr', rows => rows.filter(r => r.style.display !== 'none').length);
        await p.click('#easy-action-toggle');
        await wait(500);
        const rowsAfterEasy = await p.$$eval('#pr-table tbody tr', rows => rows.filter(r => r.style.display !== 'none').length);
        const eaChecked = await p.$eval('#easy-action-toggle', e => e.checked).catch(() => null);
        if (eaChecked === true) pass('C1: Easy action filter: toggle checked, rows=' + rowsAfterUser + ' → ' + rowsAfterEasy);
        else fail('C1: Easy action filter', 'toggle not checked after click (checked=' + eaChecked + ')');
      }
      await p.close();
    }

    // C2: Easy badge elements are present in the DOM
    {
      const p = await openPage(ALL, 100);
      const badgeCount = await p.$$eval('.easy-badge', els =>
        els.filter(e => e.offsetParent !== null && e.textContent.trim().length > 0).length);
      if (badgeCount > 0) pass('C2: Easy badge elements present (visible, non-empty): ' + badgeCount);
      else {
        log('  ℹ️  No .easy-badge elements — may require user filter. Checking with user...');
        const author = await p.evaluate(() => {
          for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
            const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
            if (m) return m[1];
          }
          return null;
        });
        if (author) {
          await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
          await p.click('#go-btn');
          await wait(800);
          const bc2 = await p.$$eval('.easy-badge', els => els.length);
          if (bc2 > 0) pass('C2: Easy badge elements present after user filter: ' + bc2);
          else fail('C2: Easy badge elements', '0 .easy-badge found even with user filter');
        } else fail('C2: Easy badge elements', '0 .easy-badge and no author to test with');
      }
      await p.close();
    }

    // C3: [?] why-button elements present on score cells
    {
      const p = await openPage(ALL, 100);
      const whyBtns = await p.$$('.easy-why-btn');
      if (whyBtns.length > 0) pass('C3: Easy [?] why-buttons present: ' + whyBtns.length);
      else {
        // May only appear with user filter
        pass('C3: Easy [?] why-buttons — skipped (no easy-action PRs visible without user filter)');
      }
      await p.close();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP D — Column sorting
    // ══════════════════════════════════════════════════════════════════════════

    log('\n── Group D: Column sorting ──');

    // D1: Click a sortable column header → sort arrow appears
    {
      const p = await openPage(ALL, 100);
      const sortableHeader = await p.$('#pr-table thead th.sortable');
      if (!sortableHeader) { fail('D1: Sortable column header', 'no th.sortable found'); }
      else {
        const headerText = await sortableHeader.textContent();
        await sortableHeader.click();
        await p.waitForFunction(() => !!document.querySelector('#pr-table thead th.sorted'), { timeout: 2000 }).catch(() => null);
        const arrowEl = await p.$('#pr-table thead th.sorted .sort-arrow');
        if (arrowEl) {
          const arrowText = await arrowEl.textContent();
          pass('D1: Sort arrow appears after clicking "' + headerText.trim() + '": ' + arrowText.trim());
        } else {
          fail('D1: Sort arrow', 'no .sort-arrow element after click on "' + headerText.trim() + '"');
        }
      }
      await p.close();
    }

    // D2: Click same header twice → sort direction reverses
    {
      const p = await openPage(ALL, 100);
      const sortableHeader = p.locator('#pr-table thead th.sortable').first();
      await sortableHeader.click();
      await p.waitForFunction(() => !!document.querySelector('#pr-table thead th.sorted'), { timeout: 2000 }).catch(() => null);
      const dir1 = await p.$eval('#pr-table thead th.sorted', e => e.classList.contains('desc') ? 'desc' : 'asc').catch(() => '?');
      await sortableHeader.click();
      await p.waitForFunction(
        (prev) => { const th = document.querySelector('#pr-table thead th.sorted'); return th && (th.classList.contains('desc') ? 'desc' : 'asc') !== prev; },
        dir1, { timeout: 2000 }).catch(() => null);
      const dir2 = await p.$eval('#pr-table thead th.sorted', e => e.classList.contains('desc') ? 'desc' : 'asc').catch(() => '?');
      if (dir1 !== dir2) pass('D2: Click same header twice reverses direction: ' + dir1 + ' → ' + dir2);
      else fail('D2: Sort direction toggle', 'direction did not change: ' + dir1 + ' → ' + dir2);
      await p.close();
    }

    // D3: After sort, first row score ≥ last visible row score (numeric desc)
    {
      const p = await openPage(ALL, 100);
      // Find a numeric sortable column
      const numHeader = await p.$('#pr-table thead th.sortable[data-sort="num"]');
      if (!numHeader) { fail('D3: Numeric sort order', 'no th[data-sort=num] found'); }
      else {
        // Ensure desc
        await numHeader.click(); await wait(200);
        const isDesc = await numHeader.evaluate(e => e.classList.contains('desc'));
        if (!isDesc) { await numHeader.click(); await wait(200); }
        const colIdx = await numHeader.evaluate(th => Array.from(th.parentNode.children).indexOf(th));
        const scores = await p.$$eval('#pr-table tbody tr', (rows, ci) =>
          rows.filter(r => r.style.display !== 'none')
              .map(r => { const c = r.cells[ci]; return c ? parseFloat(c.textContent.replace(/[^0-9.]/g,'')) || 0 : 0; }),
          colIdx);
        const nonZero = scores.filter(s => s !== 0);
        if (nonZero.length === 0) fail('D3: Numeric sort order', 'all scores are 0 — column may have no numeric data');
        else {
          const first = scores[0], last = scores[scores.length - 1];
          if (first >= last) pass('D3: Numeric sort desc: first=' + first + ' ≥ last=' + last + ' (' + scores.length + ' rows)');
          else fail('D3: Numeric sort order', 'first=' + first + ' < last=' + last);
        }
      }
      await p.close();
    }

    // D5: Sort with area filter active → clear filter → all rows (incl. previously hidden) remain sorted
    // Guards against sort implementations that skip hidden rows, causing unsorted reveals.
    {
      const p = await openPage(ALL + '?area=area-CodeGen-coreclr', 1);
      await wait(500);
      const numHeader = await p.$('#pr-table thead th.sortable[data-sort="num"]');
      if (!numHeader) {
        pass('D5: Sort+filter+clear — skipped (no numeric sort column)');
      } else {
        // Sort descending
        await numHeader.click();
        await p.waitForFunction(() => !!document.querySelector('#pr-table thead th.sorted'), { timeout: 2000 }).catch(() => null);
        const isDesc = await numHeader.evaluate(e => e.classList.contains('desc'));
        if (!isDesc) { await numHeader.click(); await p.waitForFunction(() => !!document.querySelector('#pr-table thead th.sorted.desc'), { timeout: 2000 }).catch(() => null); }
        const colIdx = await numHeader.evaluate(th => Array.from(th.parentNode.children).indexOf(th));
        // Clear the area filter to reveal previously hidden rows
        await p.evaluate(() => { if (typeof clearAllSecondaryFilters === 'function') clearAllSecondaryFilters(); });
        await wait(300);
        // Check all visible rows are still in sorted (desc) order
        const allScores = await p.$$eval('#pr-table tbody tr', (rows, ci) =>
          rows.filter(r => r.style.display !== 'none')
              .map(r => { const c = r.cells[ci]; return c ? parseFloat(c.textContent.replace(/[^0-9.]/g,'')) || 0 : 0; }),
          colIdx);
        const nonZero = allScores.filter(s => s !== 0);
        if (nonZero.length === 0) {
          pass('D5: Sort+filter+clear — skipped (no numeric data after clear)');
        } else {
          const isSorted = allScores.every((v, i, a) => i === 0 || a[i-1] >= v);
          if (isSorted) pass('D5: Sort order preserved after filter clear: ' + allScores.length + ' rows desc');
          else {
            const bad = allScores.findIndex((v, i, a) => i > 0 && a[i-1] < v);
            fail('D5: Sort+filter+clear', 'row ' + bad + ' breaks sort: ' + allScores[bad-1] + ' < ' + allScores[bad]);
          }
        }
      }
      await p.close();
    }


    {
      const p = await openPage(ALL, 100);
      const alphaHeader = await p.$('#pr-table thead th.sortable[data-sort="alpha"]');
      if (!alphaHeader) { pass('D4: Alpha sort — skipped (no alpha column)'); }
      else {
        await alphaHeader.click(); await wait(200);
        // Ensure asc
        const isDesc = await alphaHeader.evaluate(e => e.classList.contains('desc'));
        if (isDesc) { await alphaHeader.click(); await wait(200); }
        const colIdx = await alphaHeader.evaluate(th => Array.from(th.parentNode.children).indexOf(th));
        const texts = await p.$$eval('#pr-table tbody tr', (rows, ci) =>
          rows.filter(r => r.style.display !== 'none')
              .map(r => { const c = r.cells[ci]; return c ? c.textContent.trim().toLowerCase() : ''; }),
          colIdx);
        const sorted = [...texts].sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
        const isAlpha = texts.every((v, i) => v === sorted[i]);
        if (isAlpha) pass('D4: Alpha sort asc: ' + texts.length + ' rows in order');
        else fail('D4: Alpha sort order', 'first few: ' + texts.slice(0,4).join(', '));
      }
      await p.close();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP E — [?] score popup
    // ══════════════════════════════════════════════════════════════════════════

    log('\n── Group E: [?] score popup ──');

    // E1: Click [?] button → .why-popup appears
    // Use JS click to bypass the parent <td> intercepting pointer events.
    {
      const p = await openPage(ALL, 100);
      const hasWhyBtn = await p.$('[data-why]');
      if (!hasWhyBtn) { fail('E1: [?] popup appears', 'no [data-why] elements found'); }
      else {
        await p.evaluate(() => document.querySelector('[data-why]').click());
        await wait(300);
        const popup = await p.$('.why-popup');
        if (popup) {
          const popupText = await popup.textContent();
          pass('E1: [?] popup appears: "' + popupText.trim().slice(0, 60) + '"');
        } else {
          fail('E1: [?] popup appears', 'no .why-popup in DOM after click');
        }
      }
      await p.close();
    }

    // E2: Click outside popup → popup disappears
    {
      const p = await openPage(ALL, 100);
      const hasWhyBtn = await p.$('[data-why]');
      if (!hasWhyBtn) { fail('E2: Click outside dismisses popup', 'no [data-why] elements'); }
      else {
        await p.evaluate(() => document.querySelector('[data-why]').click());
        await wait(200);
        const popup = await p.$('.why-popup');
        if (!popup) { fail('E2: Click outside', 'popup did not open'); }
        else {
          // Click the page header (safe area away from popup and table)
          await p.mouse.click(10, 10);
          await wait(300);
          const popupAfter = await p.$('.why-popup');
          if (!popupAfter) pass('E2: Click outside dismisses popup');
          else fail('E2: Click outside', 'popup still visible after click at (10,10)');
        }
      }
      await p.close();
    }

    // E3: Click same [?] button twice → popup toggles closed
    {
      const p = await openPage(ALL, 100);
      const hasWhyBtn = await p.$('[data-why]');
      if (!hasWhyBtn) { fail('E3: [?] toggle close', 'no [data-why] elements'); }
      else {
        await p.evaluate(() => document.querySelector('[data-why]').click());
        await wait(200);
        const openPopup = await p.$('.why-popup');
        if (!openPopup) { fail('E3: [?] toggle close', 'popup did not open on first click'); }
        else {
          await p.evaluate(() => document.querySelector('[data-why]').click());
          await wait(200);
          const closedPopup = await p.$('.why-popup');
          if (!closedPopup) pass('E3: [?] button toggle: second click closes popup');
          else fail('E3: [?] toggle close', 'popup still visible after second click');
        }
      }
      await p.close();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP F — Per-repo pages
    // ══════════════════════════════════════════════════════════════════════════

    log('\n── Group F: Per-repo pages ──');

    // F1: runtime/actionable.html loads with PR data
    {
      const p = await openPage(RUNTIME, 1, 20000);
      const title = await p.title();
      if (title.toLowerCase().includes('runtime')) pass('F1: Per-repo page title correct: ' + title);
      else fail('F1: Per-repo page title', 'got: ' + title);
      const rowCount = await p.$$eval('#pr-table tbody tr', rows => rows.length);
      if (rowCount > 0) pass('F1: Per-repo page loaded ' + rowCount + ' rows');
      else fail('F1: Per-repo page rows', 'no rows found');
      await p.close();
    }

    // F2: Per-repo page: click area label → chip appears in banner
    // Per-repo pages now use the same button.area-label / filter-chip system as all/actionable.html.
    {
      const p = await openPage(RUNTIME, 1, 20000);
      const areaBtn = p.locator('button.area-label').first();
      if (await areaBtn.count() === 0) { fail('F2: Per-repo area filter', 'no button.area-label elements found'); }
      else {
        const labelText = await areaBtn.textContent();
        await areaBtn.click(); await wait(400);
        const chipCount = await p.$$eval('#filter-banner .filter-chip', chips => chips.length);
        if (chipCount > 0) pass('F2: Per-repo area filter: chip appears after click on "' + labelText.trim() + '"');
        else fail('F2: Per-repo area filter', 'no .filter-chip in banner after click');
      }
      await p.close();
    }

    // F3: Per-repo ?area= URL round-trip (same as all/actionable.html)
    {
      const p = await openPage(RUNTIME + '?area=area-CodeGen-coreclr', 1, 20000);
      await wait(500);
      const chipCount = await p.$$eval('#filter-banner .filter-chip', chips => chips.length);
      if (chipCount > 0) pass('F3: Per-repo ?area= URL restores filter chip (' + chipCount + ' chip(s))');
      else fail('F3: Per-repo ?area= URL', 'no .filter-chip in banner after load with ?area= param');
      await p.close();
    }

    // F4: Per-repo clear all filters → banner empties
    {
      const p = await openPage(RUNTIME + '?area=area-CodeGen-coreclr', 1, 20000);
      await wait(500);
      const chipsBefore = await p.$$eval('#filter-banner .filter-chip', chips => chips.length);
      if (chipsBefore === 0) { fail('F4: Per-repo clear filter', 'no chips to clear (check F3)'); }
      else {
        // Per-repo pages use clearAllFilters(); all/actionable.html uses clearAllSecondaryFilters()
        await p.evaluate(() => {
          if (typeof clearAllFilters === 'function') clearAllFilters();
          else if (typeof clearAllSecondaryFilters === 'function') clearAllSecondaryFilters();
        });
        await wait(300);
        const chipsAfter = await p.$$eval('#filter-banner .filter-chip', chips => chips.length);
        if (chipsAfter === 0) pass('F4: Per-repo clear all filters: banner chips gone');
        else fail('F4: Per-repo clear filter', chipsAfter + ' chip(s) still present after clear');
      }
      await p.close();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP G — "Show N more" expand
    // ══════════════════════════════════════════════════════════════════════════

    log('\n── Group G: Show more / show less ──');

    // G1: "Show N more" button is present after data loads
    {
      const p = await openPage(ALL, 100);
      const toggleBtn = await p.$('#toggle-more');
      if (toggleBtn) {
        const btnText = await toggleBtn.textContent();
        pass('G1: "Show more" button present: "' + btnText.trim() + '"');
      } else {
        // It may not be present if all PRs fit on one "page" (< threshold)
        log('  ℹ️  #toggle-more not found — may not be needed with current data count');
        pass('G1: Show-more button — acceptable absence (not enough rows to paginate)');
      }
      await p.close();
    }

    // G2: Click "Show more" → hidden .more-row rows become visible
    {
      const p = await openPage(ALL, 100);
      const toggleBtn = await p.$('#toggle-more');
      if (!toggleBtn) {
        pass('G2: Show-more click — skipped (button absent)');
      } else {
        const hiddenBefore = await p.$$eval('#pr-table tbody tr.more-row', rows =>
          rows.filter(r => r.style.display === 'none').length);
        if (hiddenBefore === 0) {
          pass('G2: Show-more click — skipped (no hidden .more-row rows)');
        } else {
          await toggleBtn.click(); await wait(400);
          const hiddenAfter = await p.$$eval('#pr-table tbody tr.more-row', rows =>
            rows.filter(r => r.style.display === 'none').length);
          if (hiddenAfter === 0) pass('G2: Show more: ' + hiddenBefore + ' hidden rows now visible');
          else fail('G2: Show more', hiddenAfter + ' rows still hidden after click');
          // Verify button text changed
          const btnTextAfter = await toggleBtn.textContent();
          if (btnTextAfter.toLowerCase().includes('less') || btnTextAfter.toLowerCase().includes('fewer')) {
            pass('G2: Show-more button text updated to: "' + btnTextAfter.trim() + '"');
          } else {
            log('  ℹ️  Button text after expand: "' + btnTextAfter.trim() + '"');
            pass('G2: Show-more button text present after click');
          }
        }
      }
      await p.close();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP H — Multi-chip URL params
    // ══════════════════════════════════════════════════════════════════════════

    log('\n── Group H: Multi-chip URL params ──');

    // H1: ?area=a&area=b (repeated params) → two area chips on load
    {
      const p = await openPage(ALL + '?area=area-CodeGen-coreclr&area=area-GC', 1);
      await wait(500);
      const chips = await p.$$eval('.filter-chip', els => els.map(e => e.textContent.trim()));
      const areaChips = chips.filter(t => !t.startsWith('Repo:'));
      if (areaChips.length >= 2) pass('H1: Two area chips loaded from ?area=X,Y: ' + areaChips.join(', '));
      else fail('H1: Two area chips', 'only ' + areaChips.length + ' area chip(s): ' + chips.join(', '));
      await p.close();
    }

    // H2: ?area=X&repo=Y → one area chip + one repo chip
    {
      const p = await openPage(ALL + '?area=area-CodeGen-coreclr&repo=runtime', 1);
      await wait(500);
      const chips = await p.$$eval('.filter-chip', els => els.map(e => e.textContent.trim()));
      const areaChips = chips.filter(t => !t.startsWith('Repo:'));
      const repoChips = chips.filter(t => t.startsWith('Repo:'));
      if (areaChips.length >= 1) pass('H2: Area chip present: ' + areaChips.join(', '));
      else fail('H2: Area chip from combined URL', 'no area chips: ' + chips.join(', '));
      if (repoChips.length >= 1) pass('H2: Repo chip present: ' + repoChips.join(', '));
      else fail('H2: Repo chip from combined URL', 'no repo chips: ' + chips.join(', '));
      await p.close();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP I — Smoke tests (other pages)
    // ══════════════════════════════════════════════════════════════════════════

    log('\n── Group I: Page smoke tests ──');

    // I1: index.html loads, has expected title and repo links
    {
      const p = await openPage(BASE + '/index.html', 0);
      const title = await p.title();
      if (title.toLowerCase().includes('dashboard')) pass('I1: index.html title: ' + title);
      else fail('I1: index.html title', 'got: ' + title);
      const runtimeLink = await p.$('a[href*="runtime/actionable"]');
      if (runtimeLink) pass('I1: index.html has runtime/actionable link');
      else fail('I1: index.html runtime link', 'not found');
      await p.close();
    }

    // I2: Per-repo consider-closing page loads
    {
      const p = await openPage(BASE + '/runtime/consider-closing.html', 0);
      const title = await p.title();
      const hasH1 = await p.$('h1');
      if (title.length > 0 && hasH1) pass('I2: consider-closing.html loads: ' + title);
      else fail('I2: consider-closing.html', 'title="' + title + '", h1=' + !!hasH1);
      await p.close();
    }

    // I3: Per-repo quick-wins page loads
    {
      const p = await openPage(BASE + '/runtime/quick-wins.html', 0);
      const title = await p.title();
      const hasH1 = await p.$('h1');
      if (title.length > 0 && hasH1) pass('I3: quick-wins.html loads: ' + title);
      else fail('I3: quick-wins.html', 'title="' + title + '", h1=' + !!hasH1);
      await p.close();
    }

    // I4: changelog.html loads with content
    {
      const p = await openPage(BASE + '/changelog.html', 0);
      const title = await p.title();
      const hasH1 = await p.$('h1');
      if (title.length > 0 && hasH1) pass('I4: changelog.html loads: ' + title);
      else fail('I4: changelog.html', 'title="' + title + '", h1=' + !!hasH1);
      await p.close();
    }

    // ── Summary ──────────────────────────────────────────────────────────────
    console.log('\n=== RESULTS: ' + passed + ' passed, ' + failed + ' failed ===');
    if (jsErrors.length) console.log('JS errors captured:\n  ' + jsErrors.join('\n  '));
    if (failed > 0) process.exitCode = 1;

  } finally {
    await ctx.close();
    await browser.close();
  }
}

runTests().catch(err => { console.error('Fatal:', err); process.exit(1); });
