// pr-view-refresh.js — "Refresh View" for PR Dashboard
// Batch-checks all visible PRs (hides merged/closed), discovers new PRs
// by the current user (+ Copilot PRs they triggered), and adds them to the table.
// Uses unauthenticated GitHub REST + Search APIs — no PAT needed.

(function() {
  'use strict';

  var VIEW_REFRESH_CACHE_KEY = 'pr-view-refresh-cache';
  var CONCURRENCY = 6; // max parallel REST fetches
  var API_HEADERS = { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' };
  var FETCH_OPTS = { headers: API_HEADERS, cache: 'no-store' };

  // --- Rate limit tracking (shared with pr-refresh.js footer) ---
  var rateLimitRemaining = null;

  function updateRateLimitFromResponse(response, isCore) {
    var rem = response.headers.get('X-RateLimit-Remaining');
    var limit = response.headers.get('X-RateLimit-Limit');
    if (rem == null || limit == null) return;
    if (isCore) rateLimitRemaining = parseInt(rem, 10);
    rateLimitDisplay = rem + '/' + limit;
    var reset = response.headers.get('X-RateLimit-Reset');
    if (reset) {
      var resetMin = Math.ceil((parseInt(reset, 10) * 1000 - Date.now()) / 60000);
      rateLimitDisplay += resetMin > 0 ? ' \u00B7 resets ' + resetMin + 'min' : '';
    }
  }

  var rateLimitDisplay = '';

  // --- localStorage cache helpers ---
  function loadViewCache() {
    try { return JSON.parse(localStorage.getItem(VIEW_REFRESH_CACHE_KEY)) || {}; }
    catch(e) { return {}; }
  }

  function saveViewCache(cache) {
    try { localStorage.setItem(VIEW_REFRESH_CACHE_KEY, JSON.stringify(cache)); }
    catch(e) { /* quota exceeded */ }
  }

  function getServerTimestamp() {
    var el = document.querySelector('[data-server-updated]');
    if (el) return el.getAttribute('data-server-updated');
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

  // --- Parse PR info from a table row (reuses pattern from pr-refresh.js) ---
  function parsePrFromRow(tr) {
    var link = tr.querySelector('.pr-num a');
    if (!link) return null;
    var href = link.getAttribute('href') || '';
    var m = href.match(/github\.com\/([^\/]+)\/([^\/]+)\/pull\/(\d+)/);
    if (!m) return null;
    return { owner: m[1], repo: m[2], number: parseInt(m[3]) };
  }

  // --- Fetch a single PR's current state ---
  function RateLimitError(message) {
    this.message = message;
    this.name = 'RateLimitError';
  }
  RateLimitError.prototype = Object.create(Error.prototype);

  function fetchPrState(owner, repo, number) {
    var url = 'https://api.github.com/repos/' + owner + '/' + repo + '/pulls/' + number;
    return fetch(url, FETCH_OPTS)
      .then(function(r) {
        updateRateLimitFromResponse(r, true);
        if (r.status === 403 || r.status === 429) throw new RateLimitError('Rate limited');
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function(pr) {
        return {
          number: pr.number,
          state: pr.state,
          merged: pr.merged || false,
          title: pr.title,
          mergeable_state: pr.mergeable_state,
          labels: (pr.labels || []).map(function(l) { return l.name; }),
          draft: pr.draft || false,
          created_at: pr.created_at,
          updated_at: pr.updated_at,
          additions: pr.additions || 0,
          deletions: pr.deletions || 0,
          changed_files: pr.changed_files || 0,
          author: pr.user ? pr.user.login : '',
          assignees: (pr.assignees || []).map(function(a) { return a.login; }),
          requested_reviewers: (pr.requested_reviewers || []).map(function(r) { return r.login; })
        };
      });
  }

  // --- Run promises with concurrency limit ---
  // Aborts remaining tasks on RateLimitError.
  function parallelLimit(tasks, limit) {
    var results = new Array(tasks.length);
    var idx = 0;
    var running = 0;
    var aborted = false;

    return new Promise(function(resolve) {
      function next() {
        if (aborted && running === 0) { resolve(results); return; }
        while (!aborted && running < limit && idx < tasks.length) {
          (function(i) {
            running++;
            tasks[i]().then(function(val) {
              results[i] = { ok: true, value: val };
            }).catch(function(err) {
              results[i] = { ok: false, error: err };
              if (err.name === 'RateLimitError') aborted = true;
            }).then(function() {
              running--;
              next();
            });
          })(idx++);
        }
        if (running === 0 && (idx >= tasks.length || aborted)) resolve(results);
      }
      next();
    });
  }

  // --- Search for new PRs by user ---
  function searchNewPrs(username, existingKeys, repoList) {
    // Build repo filter for tracked repos (use spaces — encodeURIComponent handles encoding)
    var repoFilter = repoList.map(function(r) { return 'repo:' + r.repo; }).join(' ');

    // Search for PRs authored by the user
    var queries = [
      'author:' + username + ' is:open is:pr ' + repoFilter
    ];
    // Also search for Copilot PRs triggered by the user (assigned to them)
    queries.push('author:copilot-swe-agent assignee:' + username + ' is:open is:pr ' + repoFilter);

    var newPrs = [];
    var searchTruncated = false;
    var searchFailed = false;

    return queries.reduce(function(chain, q) {
      return chain.then(function() {
        var url = 'https://api.github.com/search/issues?q=' + encodeURIComponent(q) + '&per_page=100';
        return fetch(url, FETCH_OPTS)
          .then(function(r) {
            updateRateLimitFromResponse(r, false);
            if (r.status === 403 || r.status === 429) throw new RateLimitError('Search rate limited');
            if (!r.ok) throw new Error('Search failed: HTTP ' + r.status);
            return r.json();
          })
          .then(function(data) {
            if (data.total_count > (data.items || []).length || data.incomplete_results) {
              searchTruncated = true;
            }
            (data.items || []).forEach(function(item) {
              // Extract owner/repo from the html_url
              var m = item.html_url.match(/github\.com\/([^\/]+)\/([^\/]+)\/(?:pull|issues)\/(\d+)/);
              if (!m) return;
              var key = m[1] + '/' + m[2] + '#' + m[3];
              if (existingKeys[key]) return; // already in table
              existingKeys[key] = true; // prevent duplicates across queries
              newPrs.push({
                owner: m[1],
                repo: m[2],
                number: parseInt(m[3]),
                title: item.title,
                author: item.user ? item.user.login : '',
                created_at: item.created_at,
                updated_at: item.updated_at,
                labels: (item.labels || []).map(function(l) { return l.name; }),
                assignees: (item.assignees || []).map(function(a) { return a.login; }),
                draft: item.draft || (item.pull_request && item.pull_request.draft) || false,
                state: item.state
              });
            });
          })
          .catch(function(err) {
            if (err.name === 'RateLimitError') throw err;
            searchFailed = true;
            console.warn('PR search failed:', err.message);
          });
      });
    }, Promise.resolve()).then(function() {
      return { prs: newPrs, truncated: searchTruncated, failed: searchFailed };
    });
  }

  // --- Convert REST PR data to a scan.json-like PR object ---
  function restPrToScanPr(restPr, slug, repoFullName) {
    var now = new Date();
    var created = new Date(restPr.created_at);
    var updated = new Date(restPr.updated_at);
    var ageDays = Math.floor((now - created) / 86400000);
    var daysSinceUpdate = Math.floor((now - updated) / 86400000);
    var linesChanged = (restPr.additions || 0) + (restPr.deletions || 0);
    var labels = restPr.labels || [];
    var areaLabels = labels.filter(function(l) { return /^area-/.test(l); });
    var isCommunity = labels.some(function(l) { return /^community/.test(l); });
    var isCopilot = /copilot-swe-agent/.test(restPr.author);
    var copilotTrigger = null;
    if (isCopilot && restPr.assignees) {
      var human = restPr.assignees.filter(function(a) {
        return !/copilot/i.test(a);
      });
      if (human.length > 0) copilotTrigger = human[0];
    }

    return {
      number: restPr.number,
      title: restPr.title,
      author: restPr.author,
      copilot_trigger: copilotTrigger,
      ci: 'UNKNOWN',
      ci_detail: '',
      mergeable: 'UNKNOWN',
      approval_count: 0,
      unresolved_threads: 0,
      total_threads: 0,
      total_comments: 0,
      distinct_commenters: 0,
      is_community: isCommunity,
      area_labels: areaLabels,
      age_days: ageDays,
      days_since_update: daysSinceUpdate,
      days_since_review: daysSinceUpdate,
      days_since_author_review_comment: daysSinceUpdate,
      changed_files: restPr.changed_files || 0,
      lines_changed: linesChanged,
      next_action: '',
      who: '',
      blockers: '',
      why: 'newly discovered — scores pending next pipeline run',
      value_why: 'newly discovered — scores pending next pipeline run',
      action_why: 'newly discovered — scores pending next pipeline run',
      merge_readiness: null,
      value_score: null,
      action_score: null,
      score: null,
      _slug: slug,
      _repo: repoFullName,
      _isNew: true
    };
  }

  // --- Find slug for a given owner/repo ---
  function findSlug(owner, repo, repoList) {
    var full = owner + '/' + repo;
    for (var i = 0; i < repoList.length; i++) {
      if (repoList[i].repo === full) return repoList[i].slug;
    }
    return repo; // fallback
  }

  // --- Main refresh logic ---
  function doViewRefresh(currentUser, repoList, renderRowFn, allPrs) {
    if (!currentUser) return;

    var btn = document.getElementById('view-refresh-btn');
    var statusEl = document.getElementById('view-refresh-status');
    if (btn) btn.disabled = true;
    if (statusEl) statusEl.textContent = 'Checking PRs\u2026';
    if (statusEl) statusEl.style.display = 'inline';

    // Collect visible PR rows
    var rows = document.querySelectorAll('#pr-table tbody tr');
    var visibleRows = [];
    var existingKeys = {};

    rows.forEach(function(tr) {
      if (tr.style.display === 'none') return; // skip hidden rows (including unexpanded .more-row)
      var info = parsePrFromRow(tr);
      if (!info) return;
      var key = info.owner + '/' + info.repo + '#' + info.number;
      existingKeys[key] = true;
      visibleRows.push({ tr: tr, info: info });
    });

    var total = visibleRows.length;
    var checked = 0;
    var succeeded = 0;
    var failed = 0;
    var hidden = 0;
    var ciUpdated = 0;
    var coreExhausted = false;
    var searchExhausted = false;
    var searchTruncated = false;
    var searchFailed = false;

    // If we already know core is exhausted, skip phase 1 entirely
    var skipPhase1 = rateLimitRemaining !== null && rateLimitRemaining <= 0;

    // Phase 1: Batch-check existing PRs (uses core rate limit)
    var phase1;
    if (skipPhase1) {
      coreExhausted = true;
      if (statusEl) statusEl.textContent = 'Core API exhausted, searching for new PRs\u2026';
      phase1 = Promise.resolve();
    } else {
      var tasks = visibleRows.map(function(item) {
        return function() {
          return fetchPrState(item.info.owner, item.info.repo, item.info.number)
            .then(function(pr) {
              checked++;
              succeeded++;
              var rl = rateLimitDisplay ? ' (API: ' + rateLimitDisplay + ')' : '';
              if (statusEl) statusEl.textContent = 'Checking ' + checked + '/' + total + '\u2026' + rl;

              if (pr.merged || pr.state === 'closed') {
                // Remove from DOM so filter/clear logic can't re-show it
                if (item.tr.parentNode) item.tr.parentNode.removeChild(item.tr);
                // Remove from allPrs (the parameter) so re-renders don't bring it back
                if (allPrs) {
                  var itemRepoId = item.info.owner + '/' + item.info.repo;
                  for (var i = allPrs.length - 1; i >= 0; i--) {
                    var repoId = allPrs[i].repo || allPrs[i]._repo;
                    if (allPrs[i].number === item.info.number && repoId === itemRepoId) {
                      allPrs.splice(i, 1);
                      break;
                    }
                  }
                }
                hidden++;
                return;
              }

              // Update CI from mergeable_state
              if (pr.mergeable_state && pr.mergeable_state !== 'unknown') {
                var ciCell = item.tr.querySelector('.ci');
                if (ciCell) {
                  var ci = ciFromMergeableState(pr.mergeable_state);
                  if (ci) {
                    var emoji = ci.status === 'SUCCESS' ? '\u2705' :
                                ci.status === 'FAILURE' ? '\u274C' :
                                ci.status === 'IN_PROGRESS' ? '\u23F3' :
                                ci.status === 'CONFLICT' ? '\uD83D\uDED1' : '\u26A0\uFE0F';
                    var newText = emoji + ' ' + ci.detail;
                    if (ciCell.textContent !== newText) {
                      ciCell.textContent = newText;
                      ciCell.title = 'Approximate status from mergeable_state (refreshed)';
                      ciUpdated++;
                    }
                  }
                }
              }

              // Update conflict indicator in action cell
              var actionCell = item.tr.querySelector('.action');
              if (pr.mergeable_state === 'dirty') {
                if (actionCell && !/conflict/i.test(actionCell.textContent)) {
                  var span = document.createElement('span');
                  span.className = 'pr-conflict-indicator';
                  span.textContent = '\uD83D\uDED1 conflict';
                  actionCell.insertBefore(span, actionCell.firstChild);
                }
              } else if (actionCell) {
                var existing = actionCell.querySelector('.pr-conflict-indicator');
                if (existing) existing.remove();
              }
            })
            .catch(function(err) {
              checked++;
              if (err.name === 'RateLimitError') {
                coreExhausted = true;
                if (statusEl) statusEl.textContent = '\u26A0\uFE0F Core API exhausted, searching for new PRs\u2026';
                throw err;
              }
              failed++;
              if (statusEl) statusEl.textContent = 'Checking ' + checked + '/' + total + '\u2026';
              console.warn('Failed to check PR #' + item.info.number + ':', err.message);
            });
        };
      });
      phase1 = parallelLimit(tasks, CONCURRENCY).then(function(results) {
        coreExhausted = coreExhausted || results.some(function(r) {
          return r && !r.ok && r.error && r.error.name === 'RateLimitError';
        });
      });
    }

    phase1
      .then(function() {
        // Phase 2: Discover new PRs (uses search rate limit — separate from core)
        if (statusEl) statusEl.textContent = 'Searching for new PRs\u2026';
        return searchNewPrs(currentUser, existingKeys, repoList)
          .catch(function(err) {
            if (err.name === 'RateLimitError') { searchExhausted = true; return { prs: [], truncated: false, failed: false }; }
            throw err;
          });
      })
      .then(function(searchResult) {
        var newPrs = searchResult.prs;
        searchTruncated = searchResult.truncated;
        searchFailed = searchResult.failed;
        var added = 0;

        if (newPrs.length > 0) {
          // Phase 3: Fetch full details (uses core API — skip if exhausted)
          var detailPromise;
          if (coreExhausted) {
            detailPromise = Promise.resolve();
          } else {
            var detailTasks = newPrs.map(function(pr) {
              return function() {
                return fetchPrState(pr.owner, pr.repo, pr.number)
                  .then(function(full) {
                    pr.additions = full.additions;
                    pr.deletions = full.deletions;
                    pr.changed_files = full.changed_files;
                    pr.author = full.author || pr.author;
                    pr.assignees = full.assignees || pr.assignees;
                    pr.labels = full.labels || pr.labels;
                    pr.draft = full.draft;
                    pr.created_at = full.created_at || pr.created_at;
                    pr.updated_at = full.updated_at || pr.updated_at;
                    pr.merged = full.merged;
                    pr.state = full.state;
                    pr.mergeable_state = full.mergeable_state;
                    return pr;
                  })
                  .catch(function(err) {
                    if (err.name === 'RateLimitError') { coreExhausted = true; throw err; }
                    return pr;
                  });
              };
            });
            detailPromise = parallelLimit(detailTasks, CONCURRENCY);
          }

          return detailPromise.then(function() {
            // Filter out closed/merged, drafts, and PRs created before the report
            var serverTs = getServerTimestamp();
            newPrs = newPrs.filter(function(pr) {
              if (pr.state !== 'open' || pr.merged || pr.draft) return false;
              // Only show PRs created after the report was generated
              if (serverTs && pr.created_at && pr.created_at < serverTs) return false;
              return true;
            });

            if (newPrs.length > 0) {
              var tbody = document.querySelector('#pr-table tbody');
              if (!tbody) return;

              // Check if table has Area column
              var headerCells = document.querySelectorAll('#pr-table thead th');
              var hasArea = Array.prototype.some.call(headerCells, function(th) {
                return (th.textContent || '').trim().toLowerCase() === 'area';
              });

              newPrs.forEach(function(pr) {
                var slug = findSlug(pr.owner, pr.repo, repoList);
                var scanPr = restPrToScanPr(pr, slug, pr.owner + '/' + pr.repo);

                // Derive CI from mergeable_state if available
                if (pr.mergeable_state && pr.mergeable_state !== 'unknown') {
                  var ci = ciFromMergeableState(pr.mergeable_state);
                  if (ci) {
                    scanPr.ci = ci.status;
                    scanPr.ci_detail = ci.detail;
                  }
                }

                // restPrToScanPr() already initializes score-related fields to null; for
                // newly discovered PRs we leave those null values so renderRow shows
                // "unknown" in the score, next action, and discussion columns. CI may
                // still be derived from mergeable_state above when available.

                // Add to allPrs so it participates in filtering
                allPrs.push(scanPr);

                // Render row
                var rowHtml = renderRowFn(scanPr, hasArea, 0, 0, false, currentUser);
                var temp = document.createElement('tbody');
                temp.innerHTML = rowHtml;
                var newRow = temp.firstElementChild;
                if (newRow) {
                  // Add "NEW" badge to the title cell
                  var titleCell = newRow.querySelector('.title');
                  if (titleCell) {
                    titleCell.innerHTML = '<span class="badge new-pr-badge" title="Discovered during refresh — scores pending next pipeline run">NEW</span> ' + titleCell.innerHTML;
                  }
                  newRow.classList.add('view-refresh-new');
                  // Insert at the end of tbody (new PRs have no scores, so bottom is fine)
                  tbody.appendChild(newRow);
                  added++;
                }
              });
            }
            return added;
          });
        }
        return 0;
      })
      .then(function(added) {
        // Update status
        var parts = [];
        if (hidden > 0) parts.push(hidden + ' closed/merged hidden');
        if (ciUpdated > 0) parts.push(ciUpdated + ' CI updated');
        if (added > 0) parts.push(added + ' new PR' + (added > 1 ? 's' : '') + ' found');
        if (failed > 0) parts.push(failed + ' PR' + (failed !== 1 ? 's' : '') + ' failed to check');
        var unchecked = total - checked;
        if (coreExhausted && unchecked > 0) {
          parts.push('core API exhausted \u2014 ' + unchecked + ' PR' + (unchecked !== 1 ? 's' : '') + ' not checked (closed/merged detection and CI unavailable)');
        }
        if (searchExhausted) parts.push('search API exhausted \u2014 new PR discovery unavailable');
        if (searchTruncated) parts.push('search results truncated \u2014 some new PRs may not appear');
        if (searchFailed) parts.push('search query failed \u2014 new PR discovery may be incomplete');
        if (parts.length === 0) parts.push('all PRs up to date');

        var ts = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
        var icon = (coreExhausted || searchExhausted || failed > 0 || searchFailed) ? '\u26A0\uFE0F' : '\u2705';
        if (statusEl) statusEl.textContent = icon + ' ' + parts.join(', ') + ' (at ' + ts + ')';

        // Cache result
        var cache = loadViewCache();
        cache.lastRefresh = {
          ts: new Date().toISOString(),
          serverTs: getServerTimestamp(),
          user: currentUser,
          hidden: hidden,
          added: added
        };
        saveViewCache(cache);
      })
      .catch(function(err) {
        if (statusEl) statusEl.textContent = '\u274C Refresh failed: ' + err.message;
        console.error('View refresh error:', err);
      })
      .then(function() {
        if (btn) btn.disabled = false;
        // Re-fetch accurate rate limit for footer (free call)
        fetchAndShowRateLimit();
      });
  }

  // Reuse ciFromMergeableState from pr-refresh.js if available, else define locally
  function ciFromMergeableState(state) {
    var status, detail;
    switch (state) {
      case 'clean':    status = 'SUCCESS';     detail = 'checks passing'; break;
      case 'unstable': return null;
      case 'blocked':  status = 'IN_PROGRESS'; detail = 'waiting'; break;
      case 'dirty':    status = 'CONFLICT';    detail = 'conflicts'; break;
      case 'behind':   status = 'UNKNOWN';     detail = 'base behind'; break;
      default:         status = 'UNKNOWN';     detail = 'computing'; break;
    }
    return { status: status, detail: detail };
  }

  // --- Expire stale cache on page load ---
  function expireStaleCache() {
    var serverTs = getServerTimestamp();
    var cache = loadViewCache();
    if (!cache.lastRefresh) return;

    // Expire if server data is newer than our cache
    if (serverTs && cache.lastRefresh.serverTs && serverTs > cache.lastRefresh.serverTs) {
      localStorage.removeItem(VIEW_REFRESH_CACHE_KEY);
    }
  }

  // --- Inject the Refresh View button ---
  function injectRefreshButton() {
    function tryInject() {
      var bar = document.getElementById('summary-bar');
      if (!bar) return;
      // Bar must be visible (inline style overrides CSS display:none)
      if (bar.style.display !== 'block' && bar.style.display !== '') return;
      if (bar.offsetParent === null) return; // truly hidden
      if (document.getElementById('view-refresh-btn')) return;

      var btn = document.createElement('button');
      btn.id = 'view-refresh-btn';
      btn.className = 'view-refresh-btn';
      btn.textContent = '\u21BB Best-effort Refresh View';
      btn.title = 'Check for closed/merged PRs and discover new ones (uses unauthenticated API calls, one per visible PR)';
      btn.addEventListener('click', function() {
        var user = window._prDashboard && window._prDashboard.currentUser;
        var repos = window._prDashboard && window._prDashboard.repoList;
        var renderRow = window._prDashboard && window._prDashboard.renderRow;
        var allPrs = window._prDashboard && window._prDashboard.allPrs;
        if (!user || !repos) return;
        doViewRefresh(user, repos, renderRow, allPrs);
      });

      var status = document.createElement('span');
      status.id = 'view-refresh-status';
      status.className = 'view-refresh-status';
      status.setAttribute('role', 'status');
      status.setAttribute('aria-live', 'polite');
      status.style.display = 'none';

      bar.appendChild(document.createTextNode(' '));
      bar.appendChild(btn);
      bar.appendChild(document.createTextNode(' '));
      bar.appendChild(status);
    }

    // Use a MutationObserver on the summary bar to catch
    // both style changes (bar becoming visible) and innerHTML replacements
    // (which destroy the button).
    var bar = document.getElementById('summary-bar');
    if (bar) {
      var observer = new MutationObserver(function() {
        // Debounce: the innerHTML set + style set fire multiple mutations
        clearTimeout(observer._timer);
        observer._timer = setTimeout(tryInject, 50);
      });
      observer.observe(bar, { attributes: true, childList: true, subtree: true });

      // Try injecting immediately in case the bar is already visible on page load
      tryInject();
    }
  }

  // --- Rate limit footer ---
  // Creates a dedicated #view-refresh-rate-limit element and hides any
  // other .rate-limit-footer nodes (e.g. from pr-refresh.js) to avoid duplicates.
  function ensureRateLimitFooter() {
    // Use a dedicated element to avoid conflicting with pr-refresh.js's .rate-limit-footer
    var el = document.getElementById('view-refresh-rate-limit');
    if (!el) {
      el = document.createElement('div');
      el.id = 'view-refresh-rate-limit';
      el.className = 'rate-limit-footer';
      el.setAttribute('role', 'status');
      el.setAttribute('aria-live', 'polite');
      document.body.appendChild(el);
    }
    // Hide pr-refresh.js's separate footer if it exists, on every call
    // (pr-refresh.js may create its footer after ours)
    var others = document.querySelectorAll('.rate-limit-footer:not(#view-refresh-rate-limit)');
    others.forEach(function(f) { f.style.display = 'none'; });
    // Add refresh-limitations note if not already present
    if (!document.querySelector('.refresh-limitations')) {
      var note = document.createElement('div');
      note.className = 'refresh-limitations';
      note.style.cssText = 'color: #8b949e; font-size: 0.75em; text-align: right; padding: 0.25em 0;';
      note.textContent = 'Refresh can update: open/closed state, CI status, new PRs. Cannot update: threads, approvals, scores, next action (requires pipeline re-run).';
      el.parentNode.insertBefore(note, el.nextSibling);
    }
    return el;
  }

  // Fetch rate limit status on page load (GET /rate_limit is free — doesn't consume quota)
  function fetchAndShowRateLimit() {
    fetch('https://api.github.com/rate_limit', FETCH_OPTS)
      .then(function(r) {
        if (!r.ok) return;
        return r.json();
      })
      .then(function(data) {
        if (!data || !data.resources) return;
        var core = data.resources.core;
        var search = data.resources.search;
        if (!core) return;
        var el = ensureRateLimitFooter();
        var parts = [];

        var coreReset = '';
        if (core.reset) {
          var coreMin = Math.ceil((core.reset * 1000 - Date.now()) / 60000);
          coreReset = coreMin > 0 ? ' resets in ' + coreMin + 'min' : ' resets soon';
        }
        parts.push('Core: ' + core.remaining + '/' + core.limit + ' remaining' + coreReset);

        if (search) {
          var searchReset = '';
          if (search.reset) {
            var searchMin = Math.ceil((search.reset * 1000 - Date.now()) / 60000);
            searchReset = searchMin > 0 ? ' resets in ' + searchMin + 'min' : ' resets soon';
          }
          parts.push('Search: ' + search.remaining + '/' + search.limit + ' remaining' + searchReset);
        }

        el.textContent = 'API: ' + parts.join(' \u00B7 ');

        // Update module-level tracking so phase 1 skip works
        rateLimitRemaining = core.remaining;
      })
      .catch(function() { /* silently ignore */ });
  }

  // --- Initialize ---
  function init() {
    expireStaleCache();
    injectRefreshButton();
    fetchAndShowRateLimit();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
