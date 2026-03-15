// pr-refresh.js — Per-PR refresh button for PR Dashboard
// Adds a hover-only 🔄 button next to each PR number. On click, fetches
// current PR state from the GitHub REST API and updates the row in-place.
// Persists refreshes to localStorage so they survive page reloads.
// Auto-expires cached entries when the server-side pipeline has run.
//
// Security notes (this site is public on GitHub Pages):
// - All API calls are unauthenticated — no tokens are embedded in client code.
//   Each visitor's requests count against their own IP's rate limit (60/hour).
// - Responses update only the visitor's local DOM and localStorage, never the
//   repo or any server-side state. A page reload restores the static HTML.
// - The 2-second cooldown limits casual rapid-fire clicks.

(function() {
  'use strict';

  var CACHE_KEY = 'pr-refresh-cache';
  var COOLDOWN_MS = 2000; // min ms between refreshes
  var lastRefreshTime = 0;

  // --- Inject CSS ---
  var style = document.createElement('style');
  style.textContent =
    '.pr-refresh-btn { display:none; position:absolute; right:0; top:50%; transform:translateY(-50%);' +
    '  background:var(--bg,#0d1117); border:none; cursor:pointer; font-size:1.4em; padding:0 3px;' +
    '  line-height:1; z-index:10; color:#2f81f7; font-weight:bold; }' +
    '.pr-refresh-btn:hover { color:#58a6ff; }' +
    'tr:hover .pr-refresh-btn { display:inline-block; }' +
    '.pr-num { position:relative; }' +
    '@keyframes pr-spin { to { transform:translateY(-50%) rotate(360deg); } }' +
    '.pr-refresh-btn.loading { display:inline-block; animation: pr-spin 0.8s linear infinite; opacity:0.7; }';
  document.head.appendChild(style);

  // --- Get server timestamp for cache expiry ---
  function getServerTimestamp() {
    // Static pages: look for data-updated on body or a meta element
    var el = document.querySelector('[data-server-updated]');
    if (el) return el.getAttribute('data-server-updated');
    // Cross-repo page: look for data-updated cells (pick the oldest)
    var cells = document.querySelectorAll('[data-updated]');
    if (cells.length > 0) {
      var oldest = null;
      cells.forEach(function(c) {
        var ts = c.getAttribute('data-updated');
        if (ts && (!oldest || ts < oldest)) oldest = ts;
      });
      return oldest;
    }
    return null;
  }

  // --- localStorage helpers ---
  function loadCache() {
    try { return JSON.parse(localStorage.getItem(CACHE_KEY)) || {}; }
    catch(e) { return {}; }
  }

  function saveCache(cache) {
    try { localStorage.setItem(CACHE_KEY, JSON.stringify(cache)); }
    catch(e) { /* quota exceeded — silently fail */ }
  }

  function cacheKey(owner, repo, number) {
    return owner + '/' + repo + '#' + number;
  }

  // --- Parse PR info from a table row ---
  function parsePrFromRow(tr) {
    var link = tr.querySelector('.pr-num a');
    if (!link) return null;
    var href = link.getAttribute('href') || '';
    var m = href.match(/github\.com\/([^\/]+)\/([^\/]+)\/pull\/(\d+)/);
    if (!m) return null;
    return { owner: m[1], repo: m[2], number: parseInt(m[3]), link: link };
  }

  // --- Inject buttons into all PR rows ---
  function injectButtons() {
    var rows = document.querySelectorAll('#pr-table tbody tr, table tbody tr');
    rows.forEach(function(tr) {
      var info = parsePrFromRow(tr);
      if (!info) return;
      var cell = tr.querySelector('.pr-num');
      if (!cell || cell.querySelector('.pr-refresh-btn')) return;
      var btn = document.createElement('button');
      btn.className = 'pr-refresh-btn';
      btn.innerHTML = '&#x21bb;';
      btn.title = 'Check merge status and CI for this PR';
      btn.setAttribute('aria-label', 'Check status of PR #' + info.number);
      btn.addEventListener('click', function(e) {
        e.preventDefault();
        e.stopPropagation();
        doRefresh(tr, btn, info);
      });
      cell.appendChild(btn);
    });
  }

  // --- Refresh a single PR ---
  function doRefresh(tr, btn, info) {
    var now = Date.now();
    if (now - lastRefreshTime < COOLDOWN_MS) return;
    lastRefreshTime = now;

    btn.classList.add('loading');

    // Public (unauthenticated) GitHub REST API — no token needed or sent.
    var apiBase = 'https://api.github.com/repos/' + info.owner + '/' + info.repo;
    fetch(apiBase + '/pulls/' + info.number, { headers: { Accept: 'application/vnd.github.v3+json' } })
      .then(function(r) {
        if (!r.ok) throw new Error('PR fetch failed: ' + r.status);
        return r.json();
      })
      .then(function(pr) {
        var result = {
          state: pr.state,
          merged: pr.merged || false,
          mergeable_state: pr.mergeable_state,
          title: pr.title,
          head_sha: pr.head && pr.head.sha,
          ts: new Date().toISOString(),
          serverTs: getServerTimestamp()
        };

        if (pr.state === 'open' && result.head_sha) {
          // Fetch check runs for CI status
          return fetch(apiBase + '/commits/' + result.head_sha + '/check-runs?per_page=100',
            { headers: { Accept: 'application/vnd.github.v3+json' } })
            .then(function(r2) { return r2.ok ? r2.json() : { check_runs: [] }; })
            .then(function(checks) {
              result.ci = parseCiStatus(checks.check_runs || []);
              return result;
            });
        }
        return result;
      })
      .then(function(result) {
        applyResultToRow(tr, result);
        // Cache
        var cache = loadCache();
        var key = cacheKey(info.owner, info.repo, info.number);
        cache[key] = result;
        saveCache(cache);
        btn.classList.remove('loading');
      })
      .catch(function(err) {
        btn.classList.remove('loading');
        btn.title = 'Refresh failed: ' + err.message;
        console.error('PR refresh error:', err);
      });
  }

  // --- Parse CI check runs (mirrors server-side logic) ---
  function parseCiStatus(runs) {
    // Find the "Build Analysis" check (primary CI signal)
    var buildAnalysis = null;
    for (var i = 0; i < runs.length; i++) {
      if (/build.analysis/i.test(runs[i].name)) {
        buildAnalysis = runs[i];
        break;
      }
    }

    var pass = 0, fail = 0, pending = 0;
    runs.forEach(function(r) {
      if (r.status !== 'completed') { pending++; }
      else if (r.conclusion === 'success' || r.conclusion === 'skipped' || r.conclusion === 'neutral') { pass++; }
      else { fail++; }
    });
    var detail = pass + '/' + fail + '/' + pending;

    var status;
    if (buildAnalysis) {
      if (buildAnalysis.status !== 'completed') status = 'IN_PROGRESS';
      else if (buildAnalysis.conclusion === 'success') status = 'SUCCESS';
      else status = 'FAILURE';
    } else if (pending > 0) {
      status = 'IN_PROGRESS';
    } else if (fail === 0 && pass > 0) {
      status = 'SUCCESS';
    } else if (fail > 0) {
      status = 'FAILURE';
    } else {
      status = 'UNKNOWN';
    }

    return { status: status, detail: detail, failCount: fail };
  }

  // --- Apply refresh result to a DOM row ---
  function applyResultToRow(tr, result) {
    // Merged or closed — remove from the list
    if (result.merged || result.state === 'closed') {
      tr.style.display = 'none';
      return;
    }

    // Open — update CI cell
    if (result.ci) {
      var ciCell = tr.querySelector('.ci');
      if (ciCell) {
        var emoji = result.ci.status === 'SUCCESS' ? '\u2705' :
                    result.ci.status === 'FAILURE' ? '\u274C' :
                    result.ci.status === 'IN_PROGRESS' ? '\u23F3' : '\u26A0\uFE0F';
        var failHint = '';
        if (result.ci.status === 'SUCCESS' && result.ci.failCount > 0) {
          failHint = '<sup class="ci-warn">' + result.ci.failCount + '</sup>';
          ciCell.title = 'Build Analysis passed; ' + result.ci.failCount + ' non-blocking check(s) failed';
        } else {
          ciCell.title = '';
        }
        ciCell.innerHTML = emoji + failHint + ' ' + result.ci.detail;
      }
    }

    // Update mergeable indicator in the action cell
    if (result.mergeable_state === 'dirty') {
      var actionCell = tr.querySelector('.action');
      if (actionCell && !/conflict/i.test(actionCell.textContent)) {
        var span = document.createElement('span');
        span.style.cssText = 'color:#da3633; font-weight:600; margin-right:4px;';
        span.textContent = '\uD83D\uDED1 conflict';
        actionCell.insertBefore(span, actionCell.firstChild);
      }
    }
  }

  // --- Apply cached refreshes on page load ---
  function applyCachedRefreshes() {
    var serverTs = getServerTimestamp();
    var cache = loadCache();
    var changed = false;

    Object.keys(cache).forEach(function(key) {
      var entry = cache[key];
      // Expire if server data is newer than our cache
      if (serverTs && entry.serverTs && serverTs > entry.serverTs) {
        delete cache[key];
        changed = true;
        return;
      }
    });

    if (changed) saveCache(cache);

    // Apply remaining cached entries to matching rows
    var rows = document.querySelectorAll('#pr-table tbody tr, table tbody tr');
    rows.forEach(function(tr) {
      var info = parsePrFromRow(tr);
      if (!info) return;
      var key = cacheKey(info.owner, info.repo, info.number);
      if (cache[key]) {
        applyResultToRow(tr, cache[key]);
      }
    });
  }

  // --- Initialize ---
  function init() {
    applyCachedRefreshes();
    injectButtons();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  // Re-inject buttons when the cross-repo page dynamically renders tables
  var content = document.getElementById('content');
  if (content) {
    var debounceTimer = null;
    var observer = new MutationObserver(function(mutations) {
      // Only react to new table rows or tables, not our own button/style additions
      var hasNewRows = false;
      for (var i = 0; i < mutations.length; i++) {
        var nodes = mutations[i].addedNodes;
        for (var j = 0; j < nodes.length; j++) {
          var tag = nodes[j].nodeName;
          if (tag === 'TR' || tag === 'TBODY' || tag === 'TABLE') { hasNewRows = true; break; }
        }
        if (hasNewRows) break;
      }
      if (!hasNewRows) return;
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(function() {
        injectButtons();
        applyCachedRefreshes();
      }, 100);
    });
    observer.observe(content, { childList: true, subtree: true });
  }
})();
