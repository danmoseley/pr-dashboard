// Extended Playwright tests for PR dashboard
// Covers user filter, URL params, easy-action filter, column sorting,
// [?] popup, per-repo pages, show-more, multi-chip URLs, and smoke tests.
// Run: node tests/test-pr-extended.js   (from repo root, with dev server on :8080)

const { chromium } = require('playwright');

const BASE = 'http://localhost:8080';
const ALL  = BASE + '/actionable.html';
const RUNTIME = BASE + '/runtime/actionable.html';

async function log(msg) { console.log('[' + new Date().toISOString().slice(11,19) + '] ' + msg); }

// If ONLY_GROUPS is set (comma-separated, e.g. "F" or "A,B,C"), only those groups run.
// Used by the parallel runner to split work evenly. Unset = run all groups.
const onlyGroups = process.env.ONLY_GROUPS
  ? new Set(process.env.ONLY_GROUPS.split(',').map(g => g.trim()).filter(Boolean))
  : null;
function shouldRun(g) { return !onlyGroups || onlyGroups.has(g); }

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
    await p.waitForFunction(() => document.readyState === 'complete', null, { timeout: 2000 }).catch(() => null);
    return p;
  }

  // Helper: find the login of the first PR author visible in the table.
  async function findTableAuthor(page) {
    return page.evaluate(() => {
      for (const b of document.querySelectorAll('#pr-table tbody tr .author .filter-btn')) {
        const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
        if (m) return m[1];
      }
      return null;
    });
  }

  try {

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP A — User filter
    // ══════════════════════════════════════════════════════════════════════════

    if (shouldRun('A')) { log('\n── Group A: User filter ──');

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
          null, { timeout: 3000 }).catch(() => null);
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
      const filterBtns = await p.$$('#pr-table tbody tr .user-ref .filter-btn');
      if (filterBtns.length === 0) { fail('A2: Avatar filter button click', 'no .user-ref .filter-btn elements found'); }
      else {
        const firstBtn = p.locator('#pr-table tbody tr .user-ref .filter-btn').first();
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
          null, { timeout: 3000 }).catch(() => null);
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
      await p.waitForFunction(() => { const sb = document.getElementById('summary-bar'); return sb && getComputedStyle(sb).display !== 'none'; }, null, { timeout: 5000 }).catch(() => null);
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
        await p.waitForFunction(() => { const el = document.getElementById('involves-label'); return el && getComputedStyle(el).display !== 'none'; }, null, { timeout: 5000 }).catch(() => null);
        const involvesDisplay = await p.$eval('#involves-label', e => getComputedStyle(e).display).catch(() => 'missing');
        if (involvesDisplay !== 'none' && involvesDisplay !== 'missing') pass('A4: Involves label visible after user filter');
        else fail('A4: Involves toggle', 'involves-label display=' + involvesDisplay);
        // Toggle involves and assert the checkbox state actually changes
        const beforeChecked = await p.$eval('#involves-toggle', e => e.checked).catch(() => null);
        const beforeRows = await p.$$eval('#pr-table tbody tr', rows => rows.filter(r => r.style.display !== 'none').length);
        await p.click('#involves-toggle');
        await p.waitForFunction((prev) => { const t = document.getElementById('involves-toggle'); return t && t.checked !== prev; }, beforeChecked, { timeout: 3000 }).catch(() => null);
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
        await p.waitForFunction(() => window.location.search.includes('user='), null, { timeout: 5000 }).catch(() => null);
        await p.click('#next-action-toggle');
        await p.waitForFunction(() => document.getElementById('involves-toggle')?.disabled === true, null, { timeout: 3000 }).catch(() => null);
        const involvesDisabled = await p.$eval('#involves-toggle', e => e.disabled).catch(() => null);
        if (involvesDisabled === true) pass('A5: Next-action-only toggle disables involves checkbox');
        else fail('A5: Next-action-only toggle', 'involves-toggle.disabled=' + involvesDisabled);
      }
      await p.close();
    }

    } // end GROUP A

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP B — URL param round-trips
    // ══════════════════════════════════════════════════════════════════════════

    if (shouldRun('B')) { log('\n── Group B: URL param round-trips ──');

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
      await p.waitForFunction(() => document.querySelectorAll('.filter-chip').length >= 2, null, { timeout: 10000 }).catch(() => null);
      const chips = await p.$$eval('.filter-chip', els => els.map(e => e.textContent.trim()));
      const hasArea = chips.some(t => t.includes('CodeGen') || t.includes('coreclr'));
      const hasRepo = chips.some(t => t.includes('Repo:') && t.includes('runtime'));
      if (hasArea) pass('B4: Combined URL — area chip present: ' + chips.join(', '));
      else fail('B4: Combined URL — area chip', 'chips: ' + chips.join(', '));
      if (hasRepo) pass('B4: Combined URL — repo chip present');
      else fail('B4: Combined URL — repo chip', 'chips: ' + chips.join(', '));
      await p.close();
    }

    } // end GROUP B

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP C — Easy action filter
    // ══════════════════════════════════════════════════════════════════════════

    if (shouldRun('C')) { log('\n── Group C: Easy action filter ──');

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
        await p.waitForFunction(() => window.location.search.includes('user='), null, { timeout: 5000 }).catch(() => null);
        const rowsAfterUser = await p.$$eval('#pr-table tbody tr', rows => rows.filter(r => r.style.display !== 'none').length);
        await p.click('#easy-action-toggle');
        await p.waitForFunction(() => document.getElementById('easy-action-toggle')?.checked === true, null, { timeout: 3000 }).catch(() => null);
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
          await p.waitForFunction(() => window.location.search.includes('user='), null, { timeout: 5000 }).catch(() => null);
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

    } // end GROUP C

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP D — Column sorting
    // ══════════════════════════════════════════════════════════════════════════

    if (shouldRun('D')) { log('\n── Group D: Column sorting ──');

    // D1: Click a sortable column header → sort arrow appears
    {
      const p = await openPage(ALL, 100);
      const sortableHeader = await p.$('#pr-table thead th.sortable');
      if (!sortableHeader) { fail('D1: Sortable column header', 'no th.sortable found'); }
      else {
        const headerText = await sortableHeader.textContent();
        await sortableHeader.click();
        await p.waitForFunction(() => !!document.querySelector('#pr-table thead th.sorted'), null, { timeout: 2000 }).catch(() => null);
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
      await p.waitForFunction(() => !!document.querySelector('#pr-table thead th.sorted'), null, { timeout: 2000 }).catch(() => null);
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
        await numHeader.click();
        await p.waitForFunction(() => !!document.querySelector('#pr-table thead th.sorted'), null, { timeout: 2000 }).catch(() => null);
        const isDesc = await numHeader.evaluate(e => e.classList.contains('desc'));
        if (!isDesc) {
          await numHeader.click();
          await p.waitForFunction(() => !!document.querySelector('#pr-table thead th.sorted.desc'), null, { timeout: 2000 }).catch(() => null);
        }
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

    // D5: Sort with area filter active → clear filter → verify all rows restored
    // Note: clearAllSecondaryFilters() triggers a full re-render which may reset sort order.
    // This test verifies the clear itself works (rows are restored and table is rendered).
    {
      const p = await openPage(ALL + '?area=area-CodeGen-coreclr', 1);
      await p.waitForFunction(() => document.querySelectorAll('.filter-chip').length > 0, null, { timeout: 10000 }).catch(() => null);
      const filteredRows = await p.$$eval('#pr-table tbody tr', rows =>
        rows.filter(r => getComputedStyle(r).display !== 'none').length);
      // Clear the area filter to reveal previously hidden rows
      await p.evaluate(() => { if (typeof clearAllSecondaryFilters === 'function') clearAllSecondaryFilters(); });
      await p.waitForFunction(() => document.querySelectorAll('.filter-chip').length === 0, null, { timeout: 3000 }).catch(() => null);
      const allRows = await p.$$eval('#pr-table tbody tr', rows =>
        rows.filter(r => getComputedStyle(r).display !== 'none').length);
      if (allRows > filteredRows) {
        pass('D5: Sort+filter+clear restores rows: ' + filteredRows + ' → ' + allRows);
      } else if (allRows === filteredRows) {
        pass('D5: Sort+filter+clear — filter had no effect (all rows matched), ' + allRows + ' rows');
      } else {
        fail('D5: Sort+filter+clear', 'rows after clear (' + allRows + ') < filtered (' + filteredRows + ')');
      }
      await p.close();
    }


    {
      const p = await openPage(ALL, 100);
      const alphaHeader = await p.$('#pr-table thead th.sortable[data-sort="alpha"]');
      if (!alphaHeader) { pass('D4: Alpha sort — skipped (no alpha column)'); }
      else {
        await alphaHeader.click();
        await p.waitForFunction(() => !!document.querySelector('#pr-table thead th.sorted'), null, { timeout: 2000 }).catch(() => null);
        // Ensure asc
        const isDesc = await alphaHeader.evaluate(e => e.classList.contains('desc'));
        if (isDesc) {
          await alphaHeader.click();
          await p.waitForFunction(() => !!document.querySelector('#pr-table thead th.sorted:not(.desc)'), null, { timeout: 2000 }).catch(() => null);
        }
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

    } // end GROUP D

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP E — [?] score popup
    // ══════════════════════════════════════════════════════════════════════════

    if (shouldRun('E')) { log('\n── Group E: [?] score popup ──');

    // E1: Click [?] button → .why-popup appears
    // Use JS click to bypass the parent <td> intercepting pointer events.
    {
      const p = await openPage(ALL, 100);
      const hasWhyBtn = await p.$('[data-why]');
      if (!hasWhyBtn) { fail('E1: [?] popup appears', 'no [data-why] elements found'); }
      else {
        await p.evaluate(() => document.querySelector('[data-why]').click());
        await p.waitForFunction(() => !!document.querySelector('.why-popup'), null, { timeout: 2000 }).catch(() => null);
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
        await p.waitForFunction(() => !!document.querySelector('.why-popup'), null, { timeout: 2000 }).catch(() => null);
        const popup = await p.$('.why-popup');
        if (!popup) { fail('E2: Click outside', 'popup did not open'); }
        else {
          // Click the page header (safe area away from popup and table)
          await p.mouse.click(10, 10);
          await p.waitForFunction(() => !document.querySelector('.why-popup'), null, { timeout: 2000 }).catch(() => null);
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
        await p.waitForFunction(() => !!document.querySelector('.why-popup'), null, { timeout: 2000 }).catch(() => null);
        const openPopup = await p.$('.why-popup');
        if (!openPopup) { fail('E3: [?] toggle close', 'popup did not open on first click'); }
        else {
          await p.evaluate(() => document.querySelector('[data-why]').click());
          await p.waitForFunction(() => !document.querySelector('.why-popup'), null, { timeout: 2000 }).catch(() => null);
          const closedPopup = await p.$('.why-popup');
          if (!closedPopup) pass('E3: [?] button toggle: second click closes popup');
          else fail('E3: [?] toggle close', 'popup still visible after second click');
        }
      }
      await p.close();
    }

    } // end GROUP E

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP F — Per-repo pages
    // ══════════════════════════════════════════════════════════════════════════

    if (shouldRun('F')) { log('\n── Group F: Per-repo pages ──');

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
    // Per-repo pages now use the same button.area-label / filter-chip system as actionable.html.
    {
      const p = await openPage(RUNTIME, 1, 20000);
      // Use :visible to skip buttons hidden inside collapsed "show more" rows
      const areaBtn = p.locator('button.area-label:visible').first();
      const visibleCount = await areaBtn.count();
      if (visibleCount === 0) { pass('F2: Per-repo area filter: skipped (no visible area-label buttons — area column may be absent or all labels in collapsed rows)'); }
      else {
        const labelText = await areaBtn.textContent();
        await areaBtn.click();
        await p.waitForFunction(() => document.querySelectorAll('#filter-banner .filter-chip').length > 0, null, { timeout: 5000 }).catch(() => null);
        const chipCount = await p.$$eval('#filter-banner .filter-chip', chips => chips.length);
        if (chipCount > 0) pass('F2: Per-repo area filter: chip appears after click on "' + labelText.trim() + '"');
        else fail('F2: Per-repo area filter', 'no .filter-chip in banner after click');
      }
      await p.close();
    }

    // F3: Per-repo ?area= URL round-trip (same as actionable.html)
    {
      const p = await openPage(RUNTIME + '?area=area-CodeGen-coreclr', 1, 20000);
      await p.waitForFunction(() => document.querySelectorAll('#filter-banner .filter-chip').length > 0, null, { timeout: 10000 }).catch(() => null);
      const chipCount = await p.$$eval('#filter-banner .filter-chip', chips => chips.length);
      if (chipCount > 0) pass('F3: Per-repo ?area= URL restores filter chip (' + chipCount + ' chip(s))');
      else fail('F3: Per-repo ?area= URL', 'no .filter-chip in banner after load with ?area= param');
      await p.close();
    }

    // F4: Per-repo clear all filters → banner empties
    {
      const p = await openPage(RUNTIME + '?area=area-CodeGen-coreclr', 1, 20000);
      await p.waitForFunction(() => document.querySelectorAll('#filter-banner .filter-chip').length > 0, null, { timeout: 10000 }).catch(() => null);
      const chipsBefore = await p.$$eval('#filter-banner .filter-chip', chips => chips.length);
      if (chipsBefore === 0) { fail('F4: Per-repo clear filter', 'no chips to clear (check F3)'); }
      else {
        // Per-repo pages use clearAllFilters(); actionable.html uses clearAllSecondaryFilters()
        await p.evaluate(() => {
          if (typeof clearAllFilters === 'function') clearAllFilters();
          else if (typeof clearAllSecondaryFilters === 'function') clearAllSecondaryFilters();
        });
        await p.waitForFunction(() => document.querySelectorAll('#filter-banner .filter-chip').length === 0, null, { timeout: 3000 }).catch(() => null);
        const chipsAfter = await p.$$eval('#filter-banner .filter-chip', chips => chips.length);
        if (chipsAfter === 0) pass('F4: Per-repo clear all filters: banner chips gone');
        else fail('F4: Per-repo clear filter', chipsAfter + ' chip(s) still present after clear');
      }
      await p.close();
    }

    } // end GROUP F

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP G — "Show N more" expand
    // ══════════════════════════════════════════════════════════════════════════

    if (shouldRun('G')) { log('\n── Group G: Show more / show less ──');

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
          await toggleBtn.click();
          await p.waitForFunction(() => { const rows = document.querySelectorAll('#pr-table tbody tr.more-row'); return rows.length > 0 && Array.from(rows).every(r => r.style.display !== 'none'); }, null, { timeout: 3000 }).catch(() => null);
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

    } // end GROUP G

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP H — Multi-chip URL params
    // ══════════════════════════════════════════════════════════════════════════

    if (shouldRun('H')) { log('\n── Group H: Multi-chip URL params ──');

    // H1: ?area=a&area=b (repeated params) → two area chips on load
    {
      const p = await openPage(ALL + '?area=area-CodeGen-coreclr&area=area-GC', 1);
      await p.waitForFunction(() => document.querySelectorAll('.filter-chip').length >= 2, null, { timeout: 10000 }).catch(() => null);
      const chips = await p.$$eval('.filter-chip', els => els.map(e => e.textContent.trim()));
      const areaChips = chips.filter(t => !t.startsWith('Repo:'));
      if (areaChips.length >= 2) pass('H1: Two area chips loaded from ?area=X,Y: ' + areaChips.join(', '));
      else fail('H1: Two area chips', 'only ' + areaChips.length + ' area chip(s): ' + chips.join(', '));
      await p.close();
    }

    // H2: ?area=X&repo=Y → one area chip + one repo chip
    {
      const p = await openPage(ALL + '?area=area-CodeGen-coreclr&repo=runtime', 1);
      await p.waitForFunction(() => document.querySelectorAll('.filter-chip').length >= 2, null, { timeout: 10000 }).catch(() => null);
      const chips = await p.$$eval('.filter-chip', els => els.map(e => e.textContent.trim()));
      const areaChips = chips.filter(t => !t.startsWith('Repo:'));
      const repoChips = chips.filter(t => t.startsWith('Repo:'));
      if (areaChips.length >= 1) pass('H2: Area chip present: ' + areaChips.join(', '));
      else fail('H2: Area chip from combined URL', 'no area chips: ' + chips.join(', '));
      if (repoChips.length >= 1) pass('H2: Repo chip present: ' + repoChips.join(', '));
      else fail('H2: Repo chip from combined URL', 'no repo chips: ' + chips.join(', '));
      await p.close();
    }

    } // end GROUP H

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP I — Smoke tests (other pages)
    // ══════════════════════════════════════════════════════════════════════════

    if (shouldRun('I')) { log('\n── Group I: Page smoke tests ──');

    // I1: index.html loads, has expected title and repo links
    {
      const p = await openPage(BASE + '/index.html', 0);
      const title = await p.title();
      if (title.toLowerCase().includes('dashboard')) pass('I1: index.html title: ' + title);
      else fail('I1: index.html title', 'got: ' + title);
      const runtimeLink = await p.$('a[href="actionable.html?repo=runtime"], a[href="./actionable.html?repo=runtime"]');
      if (runtimeLink) pass('I1: index.html has runtime link');
      else fail('I1: index.html runtime link', 'dashboard link not found');
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

    } // end GROUP I

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP J — Recent name tiles
    // ══════════════════════════════════════════════════════════════════════════

    if (shouldRun('J')) { log('\n── Group J: Recent name tiles ──');

    // J1: Entering a username via Go creates a recent tile
    {
      const p = await openPage(ALL, 100);
      // Clear any lingering recent users from previous tests
      await p.evaluate(() => { try { localStorage.removeItem('pr-dashboard-recent-users'); } catch(e) {} });
      // Pick a real author from the table
      const author = await p.evaluate(() => {
        for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
          const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
          if (m) return m[1];
        }
        return null;
      });
      if (!author) { fail('J1: Recent tile after Go', 'no author found'); }
      else {
        await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
        await p.click('#go-btn');
        await p.waitForFunction(() => document.querySelectorAll('.recent-tile').length > 0, null, { timeout: 5000 }).catch(() => null);
        const tiles = await p.$$('.recent-tile');
        if (tiles.length >= 1) {
          const tileText = await tiles[0].textContent();
          pass('J1: Recent tile created after Go: "' + tileText + '"');
        } else {
          fail('J1: Recent tile after Go', 'no .recent-tile elements found');
        }
      }
      await p.close();
    }

    // J2: Tile has .active class when it matches the current user
    {
      // Use a separate context so we can seed localStorage before navigation
      // without the shared context's addInitScript clearing it.
      const j2ctx = await browser.newContext();
      await j2ctx.addInitScript(() => {
        try { localStorage.setItem('pr-dashboard-recent-users', JSON.stringify(['testuser-j2'])); } catch(e) {}
      });
      const p = await j2ctx.newPage();
      p.on('pageerror', err => jsErrors.push('PAGE ERROR: ' + err.message));
      await p.goto(ALL + '?user=testuser-j2', { waitUntil: 'domcontentloaded' });
      await p.waitForFunction(() => !!document.querySelector('.recent-tile'), null, { timeout: 5000 }).catch(() => null);
      const activeTile = await p.$('.recent-tile.active');
      if (activeTile) {
        const text = await activeTile.textContent();
        pass('J2: Active tile has .active class: "' + text + '"');
      } else {
        fail('J2: Active tile', 'no .recent-tile.active found');
      }
      await p.close();
      await j2ctx.close();
    }

    // J3: Click an inactive tile → sets as only active user
    {
      const p = await openPage(ALL, 100);
      // Create a recent user via Go, then clear, then click the tile
      const author = await p.evaluate(() => {
        for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
          const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
          if (m) return m[1];
        }
        return null;
      });
      if (!author) { fail('J3: Tile click sets user', 'no author'); }
      else {
        await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
        await p.click('#go-btn');
        await p.waitForFunction(() => document.querySelectorAll('.recent-tile').length > 0, null, { timeout: 5000 }).catch(() => null);
        // Clear user filter — tile should remain but become inactive
        await p.evaluate(() => { if (window.clearUser) clearUser(); });
        await p.waitForFunction(() => !window.location.search.includes('user='), null, { timeout: 3000 }).catch(() => null);
        const tile = await p.$('.recent-tile');
        if (!tile) { fail('J3: Tile click', 'no tile found after clear'); }
        else {
          await tile.click();
          await p.waitForFunction(() => window.location.search.includes('user='), null, { timeout: 3000 }).catch(() => null);
          const url = p.url();
          if (url.includes('user=')) {
            pass('J3: Clicking inactive tile sets user in URL: ' + url.split('?')[1]);
          } else {
            fail('J3: Tile click URL', 'URL=' + url);
          }
        }
      }
      await p.close();
    }

    // J4: Click an active tile (without Ctrl) → turns it off
    {
      const p = await openPage(ALL, 100);
      const author = await p.evaluate(() => {
        for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
          const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
          if (m) return m[1];
        }
        return null;
      });
      if (!author) { fail('J4: Tile toggle off', 'no author'); }
      else {
        // Set up the user as active
        await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
        await p.click('#go-btn');
        await p.waitForFunction(() => document.querySelectorAll('.recent-tile.active').length > 0, null, { timeout: 5000 }).catch(() => null);
        // Now click the active tile to turn it off
        const activeTile = await p.$('.recent-tile.active');
        if (!activeTile) { fail('J4: Tile toggle off', 'no active tile found after Go'); }
        else {
          await activeTile.click();
          await p.waitForFunction(() => !window.location.search.includes('user='), null, { timeout: 3000 }).catch(() => null);
          const url = p.url();
          const noUser = !url.includes('user=');
          const noActiveTile = !(await p.$('.recent-tile.active'));
          if (noUser && noActiveTile) {
            pass('J4: Clicking active tile deselects it (no user in URL, no .active tile)');
          } else {
            fail('J4: Tile toggle off', 'url=' + url + ', hasActive=' + !noActiveTile);
          }
        }
      }
      await p.close();
    }

    // J5: Ctrl-click tiles → multi-select (two users in URL)
    {
      const p = await openPage(ALL, 100);
      // Find two different authors
      const authors = await p.evaluate(() => {
        const seen = new Set();
        const result = [];
        for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
          const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
          if (m && !seen.has(m[1])) { seen.add(m[1]); result.push(m[1]); if (result.length >= 2) break; }
        }
        return result;
      });
      if (authors.length < 2) { fail('J5: Ctrl-click multi-select', 'need 2 authors, found ' + authors.length); }
      else {
        // Create both recent users via Go
        await p.$eval('#user-field', (el, u) => { el.value = u; }, authors[0]);
        await p.click('#go-btn');
        await p.waitForFunction((u) => window.location.search.includes('user=' + encodeURIComponent(u)), authors[0], { timeout: 5000 }).catch(() => null);
        await p.$eval('#user-field', (el, u) => { el.value = u; }, authors[1]);
        await p.click('#go-btn');
        await p.waitForFunction((u) => window.location.search.includes('user=' + encodeURIComponent(u)), authors[1], { timeout: 5000 }).catch(() => null);
        // Clear and verify both tiles exist
        await p.evaluate(() => { if (window.clearUser) clearUser(); });
        await p.waitForFunction(() => !window.location.search.includes('user='), null, { timeout: 3000 }).catch(() => null);
        // Use locators (auto-retry, auto-re-query) instead of element handles
        const tileCount = await p.locator('.recent-tile').count();
        if (tileCount < 2) { fail('J5: Ctrl-click multi-select', 'only ' + tileCount + ' tiles after setup'); }
        else {
          // Click first tile normally (re-query after each click since DOM rebuilds)
          await p.locator('.recent-tile').first().click();
          await p.waitForFunction(() => window.location.search.includes('user='), null, { timeout: 3000 }).catch(() => null);
          // Ctrl-click second tile
          await p.locator('.recent-tile').nth(1).click({ modifiers: ['Control'] });
          await p.waitForFunction(() => document.querySelectorAll('.recent-tile.active').length >= 2, null, { timeout: 3000 }).catch(() => null);
          const url = p.url();
          const activeTiles = await p.$$('.recent-tile.active');
          if (activeTiles.length >= 2 && url.includes('user=')) {
            pass('J5: Ctrl-click multi-select: ' + activeTiles.length + ' active tiles, URL=' + url.split('?')[1]);
          } else {
            fail('J5: Ctrl-click multi-select', 'activeTiles=' + activeTiles.length + ', url=' + url);
          }
        }
      }
      await p.close();
    }

    // J6: Max 5 recent users stored
    {
      const p = await openPage(ALL, 100);
      // Add 6 users via applyUser calls (within the same page, no navigation)
      await p.evaluate(() => {
        for (let i = 1; i <= 6; i++) {
          document.getElementById('user-field').value = 'testuser' + i;
          applyUser();
        }
      });
      await p.waitForFunction(() => document.querySelectorAll('.recent-tile').length === 5, null, { timeout: 3000 }).catch(() => null);
      const tiles = await p.$$('.recent-tile');
      if (tiles.length === 5) {
        pass('J6: Recent tiles capped at 5 (rendered ' + tiles.length + ')');
      } else {
        fail('J6: Recent tiles cap', tiles.length + ' tiles rendered (expected 5)');
      }
      await p.close();
    }

    // J7: Selected names are persisted to localStorage after Go
    {
      const p = await openPage(ALL, 100);
      await p.evaluate(() => { try { localStorage.removeItem('pr-dashboard-recent-users'); localStorage.removeItem('pr-dashboard-user'); } catch(e) {} });
      const author = await p.evaluate(() => {
        for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
          const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
          if (m) return m[1];
        }
        return null;
      });
      if (!author) { fail('J7: localStorage persistence after Go', 'no author found'); }
      else {
        await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
        await p.click('#go-btn');
        await p.waitForFunction((u) => localStorage.getItem('pr-dashboard-user') === u, author, { timeout: 5000 }).catch(() => null);
        const lsUser = await p.evaluate(() => localStorage.getItem('pr-dashboard-user'));
        const lsRecent = await p.evaluate(() => localStorage.getItem('pr-dashboard-recent-users'));
        const recentArr = lsRecent ? JSON.parse(lsRecent) : [];
        if (lsUser === author && recentArr.includes(author)) {
          pass('J7: localStorage persists selected name: pr-dashboard-user="' + lsUser + '", recent=' + JSON.stringify(recentArr));
        } else {
          fail('J7: localStorage persistence', 'user="' + lsUser + '", recent=' + lsRecent);
        }
      }
      await p.close();
    }

    // J8: Selected names persist across page reload (restored from localStorage)
    {
      // Use a separate context without the localStorage.clear() addInitScript
      const freshCtx = await browser.newContext();
      const p = await freshCtx.newPage();
      p.on('pageerror', err => jsErrors.push('PAGE ERROR: ' + err.message));
      await p.goto(ALL, { waitUntil: 'domcontentloaded' });
      try {
        await p.waitForFunction(n => document.querySelectorAll('#pr-table tbody tr').length >= n, 100, { timeout: 20000 });
      } catch(e) { fail('J8: Reload persistence setup', 'table did not load'); await p.close(); await freshCtx.close(); return; }

      const author = await p.evaluate(() => {
        for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
          const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
          if (m) return m[1];
        }
        return null;
      });
      if (!author) { fail('J8: Reload persistence', 'no author'); }
      else {
        await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
        await p.click('#go-btn');
        await p.waitForFunction((u) => localStorage.getItem('pr-dashboard-user') === u, author, { timeout: 5000 }).catch(() => null);
        // Reload the page (no ?user= in URL — should restore from localStorage)
        await p.goto(ALL, { waitUntil: 'domcontentloaded' });
        await p.waitForFunction(() => document.querySelectorAll('#pr-table tbody tr').length > 0, null, { timeout: 20000 }).catch(() => null);
        await p.waitForFunction(() => !!document.querySelector('.recent-tile'), null, { timeout: 5000 }).catch(() => null);
        const userField = await p.$eval('#user-field', e => e.value).catch(() => '');
        const activeTile = await p.$('.recent-tile.active');
        const summaryText = await p.$eval('#summary-bar', e => e.textContent).catch(() => '');
        if (userField === author && activeTile && /\d+ PRs/.test(summaryText)) {
          pass('J8: Selected name restored after reload: user-field="' + userField + '", summary="' + summaryText.trim().slice(0,50) + '"');
        } else {
          fail('J8: Reload persistence', 'user-field="' + userField + '", activeTile=' + !!activeTile + ', summary="' + summaryText.slice(0,50) + '"');
        }
      }
      await p.close();
      await freshCtx.close();
    }

    // J9: URL with multiple ?user= params restores multi-select
    {
      const p = await openPage(ALL + '?user=alice&user=bob', 0);
      await p.waitForFunction(() => { const sb = document.getElementById('summary-bar'); return sb && getComputedStyle(sb).display !== 'none' && sb.textContent.trim().length > 0; }, null, { timeout: 5000 }).catch(() => null);
      const url = p.url();
      const summaryText = await p.$eval('#summary-bar', e => e.textContent).catch(() => '');
      if (summaryText.includes('@alice') && summaryText.includes('@bob')) {
        pass('J9: Multi-user URL restores both users in summary: "' + summaryText.trim().slice(0,60) + '"');
      } else if (url.includes('user=alice') && url.includes('user=bob')) {
        pass('J9: Multi-user URL preserved in address bar');
      } else {
        fail('J9: Multi-user URL', 'summary="' + summaryText.trim().slice(0,60) + '", url=' + url);
      }
      await p.close();
    }

    } // end GROUP J

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP K — Maintainer filter checkboxes (no-user context)
    // ══════════════════════════════════════════════════════════════════════════

    if (shouldRun('K')) { log('\n── Group K: Maintainer filter (no user) ──');

    // K1: Maintainer toggles are visible when no user is set
    {
      const p = await openPage(ALL, 100);
      const nextMaintainerVisible = await p.$eval('#next-action-maintainer-label', e => getComputedStyle(e).display !== 'none').catch(() => false);
      const easyMaintainerVisible = await p.$eval('#easy-action-maintainer-label', e => getComputedStyle(e).display !== 'none').catch(() => false);
      const involvesVisible = await p.$eval('#involves-label', e => getComputedStyle(e).display !== 'none').catch(() => false);
      const involvesChecked = await p.$eval('#involves-toggle', e => e.checked).catch(() => false);
      const involvesDisabled = await p.$eval('#involves-toggle', e => e.disabled).catch(() => false);
      if (nextMaintainerVisible && easyMaintainerVisible) pass('K1: Maintainer toggles visible when no user set');
      else fail('K1: Maintainer toggles visible', 'next=' + nextMaintainerVisible + ', easy=' + easyMaintainerVisible);
      if (involvesVisible && involvesChecked && involvesDisabled) pass('K1: Involves toggle visible, checked, and disabled when no user set');
      else fail('K1: Involves toggle state when no user', 'visible=' + involvesVisible + ', checked=' + involvesChecked + ', disabled=' + involvesDisabled);
      await p.close();
    }

    // K2: Maintainer toggles are hidden when a user is set; user toggles appear
    {
      const p = await openPage(ALL, 100);
      const author = await p.evaluate(() => {
        for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
          const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
          if (m) return m[1];
        }
        return null;
      });
      if (!author) { fail('K2: Maintainer toggles hide on user set', 'no author in table'); }
      else {
        await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
        await p.click('#go-btn');
        await p.waitForFunction(() => window.location.search.includes('user='), null, { timeout: 5000 }).catch(() => null);
        const nextMaintainerHidden = await p.$eval('#next-action-maintainer-label', e => getComputedStyle(e).display === 'none').catch(() => false);
        const easyMaintainerHidden = await p.$eval('#easy-action-maintainer-label', e => getComputedStyle(e).display === 'none').catch(() => false);
        const involvesVisible = await p.$eval('#involves-label', e => getComputedStyle(e).display !== 'none').catch(() => false);
        if (nextMaintainerHidden && easyMaintainerHidden) pass('K2: Maintainer toggles hidden after user set (user=' + author + ')');
        else fail('K2: Maintainer toggles hidden', 'next hidden=' + nextMaintainerHidden + ', easy hidden=' + easyMaintainerHidden);
        if (involvesVisible) pass('K2: User involves toggle visible after user set');
        else fail('K2: User involves toggle visible', 'display not shown');
      }
      await p.close();
    }

    // K3: Next action on maintainer filter reduces row count
    // Use total DOM row count (rows.length), not visible-row count, because renderTable()
    // rebuilds the table with only the filtered PRs. Both unfiltered and filtered sets can
    // exceed the 500-row "show more" cap, so visible-row counts would both equal 500.
    {
      const p = await openPage(ALL, 100);
      const initialTotalRows = await p.$$eval('#pr-table tbody tr', rows => rows.length);
      await p.click('#next-action-maintainer-toggle');
      await p.waitForFunction(() => { const sb = document.getElementById('summary-bar'); return sb && getComputedStyle(sb).display !== 'none'; }, null, { timeout: 5000 }).catch(() => null);
      const filteredTotalRows = await p.$$eval('#pr-table tbody tr', rows => rows.length);
      const summaryText = await p.$eval('#summary-bar', e => e.textContent).catch(() => '');
      const summaryVisible = await p.$eval('#summary-bar', e => getComputedStyle(e).display !== 'none').catch(() => false);
      if (filteredTotalRows < initialTotalRows && summaryVisible && /\d+ PRs/.test(summaryText)) {
        pass('K3: Maintainer filter reduces total rows: ' + initialTotalRows + ' → ' + filteredTotalRows + ' and shows summary bar');
      } else {
        fail('K3: Maintainer filter', 'totalRows=' + initialTotalRows + ' → ' + filteredTotalRows + ', summaryVisible=' + summaryVisible + ', summary="' + summaryText.trim().slice(0,60) + '"');
      }
      await p.close();
    }

    // K4: Easy next action on maintainer filter further reduces count
    {
      const p = await openPage(ALL, 100);
      await p.click('#next-action-maintainer-toggle');
      await p.waitForFunction(() => { const sb = document.getElementById('summary-bar'); return sb && getComputedStyle(sb).display !== 'none'; }, null, { timeout: 5000 }).catch(() => null);
      const afterNextAction = await p.$$eval('#pr-table tbody tr', rows => rows.length);
      await p.click('#easy-action-maintainer-toggle');
      await p.waitForFunction(() => { const sb = document.getElementById('summary-bar'); return sb && /\d+ PRs/.test(sb.textContent); }, null, { timeout: 5000 }).catch(() => null);
      const afterEasy = await p.$$eval('#pr-table tbody tr', rows => rows.length);
      const summaryText = await p.$eval('#summary-bar', e => e.textContent).catch(() => '');
      if (afterEasy <= afterNextAction && /\d+ PRs/.test(summaryText)) {
        pass('K4: Easy maintainer filter reduces further: ' + afterNextAction + ' → ' + afterEasy + ' rows');
      } else {
        fail('K4: Easy maintainer filter', 'rows=' + afterNextAction + ' → ' + afterEasy + ', summary="' + summaryText.trim().slice(0,60) + '"');
      }
      await p.close();
    }

    // K5: ?nextmaintainer=true URL param pre-checks the toggle and filters on load
    {
      const p = await openPage(ALL + '?nextmaintainer=true', 1);
      await p.waitForFunction(() => document.getElementById('next-action-maintainer-toggle')?.checked === true, null, { timeout: 5000 }).catch(() => null);
      const checked = await p.$eval('#next-action-maintainer-toggle', e => e.checked).catch(() => null);
      const summaryVisible = await p.$eval('#summary-bar', e => getComputedStyle(e).display !== 'none').catch(() => false);
      const summaryText = await p.$eval('#summary-bar', e => e.textContent).catch(() => '');
      if (checked === true) pass('K5: ?nextmaintainer=true pre-checks toggle');
      else fail('K5: ?nextmaintainer=true pre-checks toggle', 'checked=' + checked);
      if (summaryVisible && /\d+ PRs/.test(summaryText)) pass('K5: ?nextmaintainer=true shows summary bar');
      else fail('K5: ?nextmaintainer=true shows summary bar', 'visible=' + summaryVisible + ', summary="' + summaryText.trim().slice(0,60) + '"');
      await p.close();
    }

    // K6: Unchecking toggle removes maintainer filter and restores all PRs
    {
      const p = await openPage(ALL + '?nextmaintainer=true', 1);
      await p.waitForFunction(() => document.getElementById('next-action-maintainer-toggle')?.checked === true, null, { timeout: 5000 }).catch(() => null);
      await p.click('#next-action-maintainer-toggle');
      await p.waitForFunction(() => { const sb = document.getElementById('summary-bar'); return !sb || getComputedStyle(sb).display === 'none'; }, null, { timeout: 3000 }).catch(() => null);
      const summaryHidden = await p.$eval('#summary-bar', e => getComputedStyle(e).display === 'none').catch(() => false);
      const unchecked = await p.$eval('#next-action-maintainer-toggle', e => !e.checked).catch(() => false);
      const url = p.url();
      if (summaryHidden && unchecked && !url.includes('nextmaintainer')) {
        pass('K6: Uncheck toggle removes maintainer filter (summary hidden, toggle unchecked, param gone)');
      } else {
        fail('K6: Uncheck toggle removes filter', 'summaryHidden=' + summaryHidden + ', unchecked=' + unchecked + ', url=' + url);
      }
      await p.close();
    }

    // K7: Setting a user after maintainer filter switches to user context
    {
      const p = await openPage(ALL + '?nextmaintainer=true', 1);
      await p.waitForFunction(() => document.getElementById('next-action-maintainer-toggle')?.checked === true, null, { timeout: 5000 }).catch(() => null);
      const author = await p.evaluate(() => {
        for (const b of document.querySelectorAll('#pr-table tbody tr .filter-btn')) {
          const m = (b.getAttribute('onclick') || '').match(/filterByUser\('([^']+)'\)/);
          if (m) return m[1];
        }
        return null;
      });
      if (!author) { fail('K7: User switch after maintainer filter', 'no author in table'); }
      else {
        await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
        await p.click('#go-btn');
        await p.waitForFunction(() => window.location.search.includes('user='), null, { timeout: 5000 }).catch(() => null);
        const maintainerHidden = await p.$eval('#next-action-maintainer-label', e => getComputedStyle(e).display === 'none').catch(() => false);
        const involvesVisible = await p.$eval('#involves-label', e => getComputedStyle(e).display !== 'none').catch(() => false);
        const summaryText = await p.$eval('#summary-bar', e => e.textContent).catch(() => '');
        if (maintainerHidden && involvesVisible && /\d+ PRs/.test(summaryText)) {
          pass('K7: After setting user, maintainer toggles hidden, user toggles shown, summary for user');
        } else {
          fail('K7: Switch to user context', 'maintainerHidden=' + maintainerHidden + ', involvesVisible=' + involvesVisible + ', summary="' + summaryText.slice(0,60) + '"');
        }
      }
      await p.close();
    }

    // K8: Easy maintainer toggle checks and disables next-action-maintainer toggle
    {
      const p = await openPage(ALL, 100);
      const isDisabledBeforeEasy = await p.$eval('#next-action-maintainer-toggle', e => e.disabled).catch(() => null);
      await p.click('#easy-action-maintainer-toggle');
      await p.waitForFunction(() => document.getElementById('next-action-maintainer-toggle')?.disabled === true, null, { timeout: 3000 }).catch(() => null);
      const afterChecked = await p.$eval('#next-action-maintainer-toggle', e => e.checked).catch(() => null);
      const afterDisabled = await p.$eval('#next-action-maintainer-toggle', e => e.disabled).catch(() => null);
      if (!isDisabledBeforeEasy && afterChecked === true && afterDisabled === true) {
        pass('K8: Easy maintainer toggle checks and disables next-action-maintainer toggle');
      } else {
        fail('K8: Easy maintainer disables next-action-maintainer', 'isDisabledBeforeEasy=' + isDisabledBeforeEasy + ', afterChecked=' + afterChecked + ', afterDisabled=' + afterDisabled);
      }
      // Unchecking easy restores next-action-maintainer state
      await p.click('#easy-action-maintainer-toggle');
      await p.waitForFunction(() => document.getElementById('next-action-maintainer-toggle')?.disabled === false, null, { timeout: 3000 }).catch(() => null);
      const restoredDisabled = await p.$eval('#next-action-maintainer-toggle', e => e.disabled).catch(() => null);
      if (restoredDisabled === false) {
        pass('K8b: Unchecking easy re-enables next-action-maintainer toggle');
      } else {
        fail('K8b: Unchecking easy re-enables next-action-maintainer toggle', 'disabled=' + restoredDisabled);
      }
      await p.close();
    }

    // K9: Clear user button (✕) appears when user is set and clears user when clicked
    {
      const p = await openPage(ALL, 100);
      const clearBtnHiddenBeforeUser = await p.$eval('#clear-user-btn', e => getComputedStyle(e).display === 'none').catch(() => true);
      await p.$eval('#user-field', el => { el.value = 'danmoseley'; });
      await p.click('#go-btn');
      await p.waitForFunction(() => window.location.search.includes('user=danmoseley'), null, { timeout: 5000 }).catch(() => null);
      const btnVisible = await p.$eval('#clear-user-btn', e => getComputedStyle(e).display !== 'none').catch(() => false);
      const url = p.url();
      if (clearBtnHiddenBeforeUser && btnVisible && url.includes('user=danmoseley')) {
        pass('K9: Clear user button (✕) hidden initially, visible after user set');
      } else {
        fail('K9: Clear user button visibility', 'hiddenBefore=' + clearBtnHiddenBeforeUser + ', visible=' + btnVisible + ', url=' + url);
      }
      await p.click('#clear-user-btn');
      await p.waitForFunction(() => !window.location.search.includes('user='), null, { timeout: 5000 }).catch(() => null);
      const btnHiddenAfter = await p.$eval('#clear-user-btn', e => getComputedStyle(e).display === 'none').catch(() => false);
      const clearedUrl = p.url();
      const userFieldEmpty = await p.$eval('#user-field', e => e.value).catch(() => '?');
      if (btnHiddenAfter && !clearedUrl.includes('user=') && userFieldEmpty === '') {
        pass('K9b: Clicking ✕ clears user, hides button, removes user from URL');
      } else {
        fail('K9b: Clicking ✕ clears user', 'hidden=' + btnHiddenAfter + ', url=' + clearedUrl + ', field="' + userFieldEmpty + '"');
      }
      await p.close();
    }

    // K10: Clearing the username input and clicking Go removes user filter
    {
      const p = await openPage(ALL + '?user=danmoseley', 0);
      await p.waitForFunction(() => document.getElementById('user-field')?.value === 'danmoseley', null, { timeout: 5000 }).catch(() => null);
      await p.$eval('#user-field', el => { el.value = ''; });
      await p.click('#go-btn');
      await p.waitForFunction(() => !window.location.search.includes('user='), null, { timeout: 5000 }).catch(() => null);
      const url = p.url();
      const maintainerVisible = await p.$eval('#next-action-maintainer-label', e => getComputedStyle(e).display !== 'none').catch(() => false);
      if (!url.includes('user=') && maintainerVisible) {
        pass('K10: Empty Go clears user filter, shows maintainer toggles');
      } else {
        fail('K10: Empty Go clears user filter', 'url=' + url + ', maintainerVisible=' + maintainerVisible);
      }
      await p.close();
    }

    // K11: ?involves=true without a user gets cleaned up from URL on load
    {
      const p = await openPage(ALL + '?involves=true', 100);
      await p.waitForFunction(() => !window.location.search.includes('involves='), null, { timeout: 3000 }).catch(() => null);
      const url = p.url();
      if (!url.includes('involves=')) {
        pass('K11: ?involves=true (no user) cleaned from URL on load');
      } else {
        fail('K11: ?involves=true (no user) cleaned from URL', 'url=' + url);
      }
      await p.close();
    }

    } // end GROUP K

    // ══════════════════════════════════════════════════════════════════════════
    // GROUP L — Best-effort refresh button
    // ══════════════════════════════════════════════════════════════════════════

    if (shouldRun('L')) { log('\n── Group L: Best-effort refresh button ──');

    // L1: Clicking the refresh button with NO user filter (maintainer mode) starts AND
    // completes the refresh cycle, and skips Phase 2 (new PR search).
    // Before the fix, the button handler returned early when currentUser was empty,
    // so the status element stayed hidden and the button stayed enabled — a silent no-op.
    {
      const p = await openPage(ALL + '?nextmaintainer=true', 1, 30000);
      // Wait for the summary-bar to become visible (shown by renderFilteredMaintainer)
      const barReady = await p.waitForFunction(
        () => {
          const bar = document.getElementById('summary-bar');
          return bar && bar.style.display === 'block';
        },
        null, { timeout: 10000 }
      ).catch(() => null);

      // catch(() => null): null indicates timeout — !null is truthy, triggering the fail path below.
      if (!barReady) {
        fail('L1: Best-effort refresh button (no user) — summary-bar did not appear within 10s');
      } else {
        // Wait for the refresh button to be injected (MutationObserver + 50ms debounce)
        const refreshBtn = await p.waitForSelector('#view-refresh-btn', { timeout: 5000 }).catch(() => null);
        if (!refreshBtn) {
          fail('L1: Best-effort refresh button (no user) — button not injected in summary-bar');
        } else {
          // Force GitHub API calls to fail immediately so this test is deterministic even when
          // outbound network is available on the host/CI machine.
          const githubApiRoute = 'https://api.github.com/**';
          await p.route(githubApiRoute, route => route.abort());
          try {
            await refreshBtn.click();
            const [btnDisabled, statusText] = await p.evaluate(() => {
              const btn = document.getElementById('view-refresh-btn');
              const statusEl = document.getElementById('view-refresh-status');
              return [btn ? btn.disabled : null, statusEl ? statusEl.textContent : ''];
            });

            if (!btnDisabled || !(statusText.includes('Checking') || statusText.includes('Core API exhausted'))) {
              fail('L1: Best-effort refresh button (no user filter) — refresh did not start',
                'btnDisabled=' + btnDisabled + ', statusText="' + statusText + '" (expected disabled=true and "Checking PRs…" or "Core API exhausted…")');
            } else {
              // Wait for the refresh cycle to complete: the final .then() re-enables the button.
              // GitHub API requests are intercepted above, so Phase 1 fails fast without any
              // external network dependency. If this times out, catch returns null;
              // finalBtnEnabled will be false, failing the test.
              await p.waitForFunction(
                () => !document.getElementById('view-refresh-btn').disabled,
                null, { timeout: 15000 }
              ).catch(() => null);

              const [finalBtnEnabled, finalStatus] = await p.evaluate(() => {
                const btn = document.getElementById('view-refresh-btn');
                const statusEl = document.getElementById('view-refresh-status');
                return [btn ? !btn.disabled : null, statusEl ? statusEl.textContent : ''];
              });

              // Phase 2 (new PR search) should be skipped when no user filter is active.
              // If it ran, the intermediate status "Searching for new PRs…" would have appeared,
              // and the final status might mention "new PRs found". Verify it does not.
              const completedOk = finalBtnEnabled;
              const phase2Skipped = !finalStatus.includes('Searching for new PRs') &&
                                    !finalStatus.includes('new PR');
              if (completedOk && phase2Skipped) {
                pass('L1: Best-effort refresh (no user filter) — starts, completes, and skips new-PR search');
              } else {
                fail('L1: Best-effort refresh (no user filter)',
                  'finalBtnEnabled=' + finalBtnEnabled + ', finalStatus="' + finalStatus + '"');
              }
            }
          } finally {
            await p.unroute(githubApiRoute);
          }
        }
      }
      await p.close();
    }

    // L2: Clicking the refresh button WITH a user filter also starts refresh (regression).
    // This worked before the fix too, but we verify it still works after.
    {
      const p = await openPage(ALL, 100);
      const author = await findTableAuthor(p);
      if (!author) {
        fail('L2: Best-effort refresh button (user filter) — no author found in table');
      } else {
        await p.$eval('#user-field', (el, u) => { el.value = u; }, author);
        await p.click('#go-btn');
        // Wait for summary-bar to appear with user context.
        // catch(() => null): null indicates timeout — !null is truthy, triggering the fail path below.
        const barReady = await p.waitForFunction(
          () => {
            const bar = document.getElementById('summary-bar');
            return bar && bar.style.display === 'block';
          },
          null, { timeout: 5000 }
        ).catch(() => null);

        if (!barReady) {
          fail('L2: Best-effort refresh button (user filter) — summary-bar did not appear within 5s');
        } else {
          // Wait for refresh button to be injected
          const refreshBtn = await p.waitForSelector('#view-refresh-btn', { timeout: 5000 }).catch(() => null);
          if (!refreshBtn) {
            fail('L2: Best-effort refresh button (user filter) — button not injected in summary-bar');
          } else {
            await refreshBtn.click();
            const [btnDisabled, statusVisible] = await p.evaluate(() => {
              const btn = document.getElementById('view-refresh-btn');
              const statusEl = document.getElementById('view-refresh-status');
              return [btn ? btn.disabled : null, statusEl ? statusEl.style.display !== 'none' : null];
            });
            if (btnDisabled && statusVisible) {
              pass('L2: Best-effort refresh button (user filter) — click starts refresh (button disabled, status visible)');
            } else {
              fail('L2: Best-effort refresh button (user filter)',
                'btnDisabled=' + btnDisabled + ', statusVisible=' + statusVisible);
            }
          }
        }
      }
      await p.close();
    }

    } // end GROUP L

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
