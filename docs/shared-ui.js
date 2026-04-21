(function() {
  'use strict';

  // HTML escaping
  window.escHtml = function(s) {
    if (s == null) return '';
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  };

  window.escAttr = function(s) {
    return escHtml(s).replace(/'/g, '&#39;').replace(/\n/g, '&#10;');
  };

  // Known bot usernames that should render as a bot icon instead of an avatar.
  // Keep in sync with ConvertTo-UserHtml in scripts/ConvertTo-ReportHtml.ps1.
  var BOT_USERS = Object.create(null);
  BOT_USERS['copilot-pull-request-reviewer'] = 'Copilot reviewer';

  function isBotUser(name) { return name in BOT_USERS; }

  function botHtml(name) {
    var label = BOT_USERS[name] || name;
    return '<span class="user-ref"><span class="bot-icon" role="img" aria-label="' + escAttr(label) + '" title="' + escAttr(label) + '">&#x1F916;</span>' +
      '<a class="filter-btn" href="#" onclick="filterByUser(\'' + escAttr(name) + '\');return false" title="Show only @' + escAttr(name) + '" aria-label="Show only @' + escAttr(name) + '">&#x1F50D;</a></span>';
  }

  // Render a single @username as HTML (avatar + link + filter, or bot icon)
  window.userHtml = function(username) {
    if (!username) return '';
    var u = username.replace(/^@/, '');
    if (/^app\//.test(u)) {
      var name = u.replace(/^app\//, '');
      return '<a href="https://github.com/apps/' + encodeURIComponent(name) + '">@' + escHtml(name) + '</a>';
    }
    if (isBotUser(u)) return botHtml(u);
    return '<span class="user-ref"><img class="avatar" src="https://github.com/' + encodeURIComponent(u) + '.png?size=32" alt="' + escAttr(u) + '">' +
      '<a href="https://github.com/' + encodeURIComponent(u) + '">@' + escHtml(u) + '</a>' +
      '<a class="filter-btn" href="#" onclick="filterByUser(\'' + escAttr(u) + '\');return false" title="Show only @' + escAttr(u) + '" aria-label="Show only @' + escAttr(u) + '">&#x1F50D;</a></span>';
  };

  // Replace all @username references in text with rendered HTML
  window.convertUserRefs = function(text) {
    return text.replace(/@((?:app\/)?[\w-]+)/g, function(match, name) {
      if (/^app\//.test(name)) {
        var botName = name.replace(/^app\//, '');
        return '<a href="https://github.com/apps/' + encodeURIComponent(botName) + '">@' + escHtml(botName) + '</a>';
      }
      if (isBotUser(name)) return botHtml(name);
      return '<span class="user-ref"><img class="avatar" src="https://github.com/' + encodeURIComponent(name) + '.png?size=32" alt="' + escAttr(name) + '">' +
        '<a href="https://github.com/' + encodeURIComponent(name) + '">@' + escHtml(name) + '</a>' +
        '<a class="filter-btn" href="#" onclick="filterByUser(\'' + escAttr(name) + '\');return false" title="Show only @' + escAttr(name) + '" aria-label="Show only @' + escAttr(name) + '">&#x1F50D;</a></span>';
    });
  };

  // [?] popup logic
  var activePopup = null;
  var activePopupBtn = null;
  window.showWhy = function(el) {
    if (activePopup) {
      activePopup.remove();
      var wasSame = (activePopupBtn === el);
      activePopup = null; activePopupBtn = null;
      if (wasSame) return;
    }
    var why = (el.getAttribute('data-why') || '').replace(/&#10;/g, '\n');
    if (!why) return;
    var popup = document.createElement('div');
    popup.className = 'why-popup';
    popup.textContent = why;
    document.body.appendChild(popup);
    var rect = el.getBoundingClientRect();
    popup.style.left = Math.max(0, Math.min(rect.right + 5, window.innerWidth - 360)) + 'px';
    popup.style.top = Math.max(0, rect.top) + 'px';
    activePopup = popup;
    activePopupBtn = el;
    var dismissClick = function(e) {
      if (!popup.parentNode) { document.removeEventListener('click', dismissClick); document.removeEventListener('mousemove', dismissMouse); return; }
      if (!popup.contains(e.target) && e.target !== el) { popup.remove(); activePopup = null; activePopupBtn = null; document.removeEventListener('click', dismissClick); document.removeEventListener('mousemove', dismissMouse); }
    };
    var dismissMouse = function(e) {
      if (!popup.parentNode) { document.removeEventListener('mousemove', dismissMouse); document.removeEventListener('click', dismissClick); return; }
      var r = popup.getBoundingClientRect();
      var pad = 50;
      if (e.clientX < r.left - pad || e.clientX > r.right + pad || e.clientY < r.top - pad || e.clientY > r.bottom + pad) {
        popup.remove(); activePopup = null; activePopupBtn = null; document.removeEventListener('mousemove', dismissMouse); document.removeEventListener('click', dismissClick);
      }
    };
    setTimeout(function() { document.addEventListener('click', dismissClick); }, 0);
    document.addEventListener('mousemove', dismissMouse);
  };

  // Sortable table columns
  window.initTableSort = function(tableId, defaultSortCol) {
    var table = document.getElementById(tableId);
    if (!table) return;
    var tbody = table.querySelector('tbody');
    var headers = table.querySelectorAll('thead th');
    headers.forEach(function(th, colIdx) {
      if (!th.classList.contains('sortable')) return;
      th.addEventListener('click', function(e) {
        if (e.target.style && e.target.style.cursor === 'col-resize') return;
        var isDesc = th.classList.contains('desc');
        var newDir = isDesc ? 'asc' : 'desc';
        headers.forEach(function(h) {
          h.classList.remove('sorted', 'asc', 'desc');
          var old = h.querySelector('.sort-arrow');
          if (old) old.remove();
        });
        th.classList.add('sorted', newDir);
        var arrow = document.createElement('span');
        arrow.className = 'sort-arrow';
        arrow.textContent = newDir === 'desc' ? ' \u25BC' : ' \u25B2';
        th.insertBefore(arrow, th.querySelector('div'));
        var rows = Array.from(tbody.querySelectorAll('tr'));
        var sortType = th.getAttribute('data-sort') || 'num';
        rows.sort(function(a, b) {
          var aCell = a.cells[colIdx], bCell = b.cells[colIdx];
          if (!aCell || !bCell) return 0;
          if (sortType === 'alpha') {
            var aText = aCell.textContent.trim().toLowerCase();
            var bText = bCell.textContent.trim().toLowerCase();
            var cmp = aText < bText ? -1 : aText > bText ? 1 : 0;
            return newDir === 'desc' ? -cmp : cmp;
          }
          var aText = aCell.textContent.replace(/[#?]/g, '');
          var bText = bCell.textContent.replace(/[#?]/g, '');
          var aNums = aText.match(/[\d.]+/g) || [0];
          var bNums = bText.match(/[\d.]+/g) || [0];
          var aVal = aNums.reduce(function(s, n) { return s + parseFloat(n); }, 0);
          var bVal = bNums.reduce(function(s, n) { return s + parseFloat(n); }, 0);
          return newDir === 'desc' ? bVal - aVal : aVal - bVal;
        });
        rows.forEach(function(r) { tbody.appendChild(r); });
      });
    });
    // Apply default sort marker
    if (typeof defaultSortCol === 'number' && defaultSortCol >= 0 && defaultSortCol < headers.length) {
      var defTh = headers[defaultSortCol];
      defTh.classList.add('sorted', 'desc');
      var arrow = document.createElement('span');
      arrow.className = 'sort-arrow';
      arrow.textContent = ' \u25BC';
      defTh.insertBefore(arrow, defTh.querySelector('div'));
    }
  };

  // Resizable columns: drag right edge of any <th> to resize
  window.initResizableColumns = function(tableId) {
    var table = document.getElementById(tableId);
    if (!table) return;
    var ths = table.querySelectorAll('thead th');
    var locked = false;
    function lockLayout() {
      if (locked) return; locked = true;
      // Freeze current column widths so drag-resize works in absolute px
      var widths = Array.prototype.map.call(ths, function(h) { return h.offsetWidth + 'px'; });
      // Override CSS-driven <col> widths with snapshotted px widths
      var cols = table.querySelectorAll('colgroup col');
      cols.forEach(function(c, i) { c.style.width = widths[i]; });
      ths.forEach(function(h, i) {
        h.style.width = widths[i]; h.style.minWidth = widths[i]; h.style.maxWidth = widths[i];
      });
      table.style.tableLayout = 'fixed';
    }
    // Expose unlock so column chooser reset can undo drag-resize
    table._unlockLayout = function() { locked = false; };
    ths.forEach(function(th) {
      var grip = document.createElement('div');
      grip.style.cssText = 'position:absolute;top:0;right:0;bottom:0;width:5px;cursor:col-resize;user-select:none;border-right:1px solid #484f58';
      th.style.position = 'relative';
      grip.addEventListener('mousedown', function(e) {
        lockLayout();
        var startX = e.pageX, startW = th.offsetWidth;
        var colKey = th.getAttribute('data-col');
        var col = colKey ? table.querySelector('colgroup col[data-col="' + colKey + '"]') : null;
        function onMove(e2) {
          var w = Math.max(30, startW + e2.pageX - startX) + 'px';
          th.style.width = w; th.style.minWidth = w; th.style.maxWidth = w;
          if (col) col.style.width = w;
        }
        function onUp() { document.removeEventListener('mousemove', onMove); document.removeEventListener('mouseup', onUp); }
        document.addEventListener('mousemove', onMove);
        document.addEventListener('mouseup', onUp);
        e.preventDefault();
      });
      th.appendChild(grip);
    });
  };

  // Column chooser: hide/show columns, persisted in localStorage
  window.initColumnChooser = function(tableId, storageKey, containerId) {
    var table = document.getElementById(tableId);
    if (!table) return;
    storageKey = storageKey || 'pr-dashboard-hidden-cols';


    // Column definitions: data-col value -> display label (strip sort arrows)
    function readCols() {
      var cols = [];
      table.querySelectorAll('thead th[data-col]').forEach(function(th) {
        var label = th.textContent.replace(/[\u25B2\u25BC\u2191\u2193]/g, '').trim();
        cols.push({ id: th.getAttribute('data-col'), label: label });
      });
      return cols;
    }
    if (readCols().length === 0) return;

    // Read hidden set from localStorage
    var hidden;
    try {
      var raw = localStorage.getItem(storageKey);
      hidden = raw ? JSON.parse(raw) : [];
      if (!Array.isArray(hidden)) hidden = [];
    } catch(e) { hidden = []; }

    function applyHidden() {
      var set = {};
      hidden.forEach(function(c) { set[c] = true; });
      // For table-layout:fixed, we must zero out the <col> width AND hide cell content
      table.querySelectorAll('colgroup col[data-col]').forEach(function(col) {
        if (set[col.getAttribute('data-col')]) {
          col.style.width = '0';
        } else if (!col.style.width || col.style.width === '0' || col.style.width === '0px') {
          col.style.width = ''; // restore CSS-driven width
        }
      });
      table.querySelectorAll('td[data-col], th[data-col]').forEach(function(el) {
        if (set[el.getAttribute('data-col')]) {
          el.style.fontSize = '0'; el.style.padding = '0';
          el.style.border = '0'; el.style.overflow = 'hidden';
        } else {
          el.style.fontSize = ''; el.style.padding = '';
          el.style.border = ''; el.style.overflow = '';
        }
      });
    }

    function saveHidden() {
      try { localStorage.setItem(storageKey, JSON.stringify(hidden)); } catch(e) {}
    }

    // Apply on load
    applyHidden();

    // Reuse existing button if already created (re-render safe)
    var btnId = tableId + '-col-chooser-btn';
    var btn = document.getElementById(btnId);
    if (btn) return; // already wired up
    btn = document.createElement('button');
    btn.type = 'button';
    btn.id = btnId;
    btn.className = 'col-chooser-btn';
    btn.textContent = '\u2699 Columns';
    btn.title = 'Show/hide table columns';

    // Place in specified container or before the table
    var container = containerId && document.getElementById(containerId);
    if (container) {
      container.appendChild(btn);
    } else {
      table.parentNode.insertBefore(btn, table);
    }

    var popup = null;
    var dismissFn = null;

    function closePopup() {
      if (popup) { popup.remove(); popup = null; }
      if (dismissFn) { document.removeEventListener('click', dismissFn); dismissFn = null; }
    }

    btn.addEventListener('click', function(e) {
      e.stopPropagation();
      if (popup) { closePopup(); return; }
      popup = document.createElement('div');
      popup.className = 'col-chooser-popup';
      var hiddenSet = {};
      hidden.forEach(function(c) { hiddenSet[c] = true; });
      var checkboxes = [];
      readCols().forEach(function(col) {
        var lbl = document.createElement('label');
        var cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = !hiddenSet[col.id];
        cb.setAttribute('data-col-id', col.id);
        cb.addEventListener('change', function() {
          if (cb.checked) {
            hidden = hidden.filter(function(c) { return c !== col.id; });
          } else {
            if (hidden.indexOf(col.id) === -1) hidden.push(col.id);
          }
          saveHidden();
          applyHidden();
        });
        lbl.appendChild(cb);
        lbl.appendChild(document.createTextNode(col.label));
        popup.appendChild(lbl);
        checkboxes.push(cb);
      });
      // Reset button
      var resetBtn = document.createElement('button');
      resetBtn.type = 'button';
      resetBtn.className = 'col-chooser-reset';
      resetBtn.textContent = 'Reset all';
      resetBtn.addEventListener('click', function() {
        hidden = [];
        saveHidden();
        applyHidden();
        checkboxes.forEach(function(cb) { cb.checked = true; });
        // Clear any column width customizations from drag-resize
        if (table._unlockLayout) table._unlockLayout();
        table.querySelectorAll('thead th').forEach(function(th) {
          th.style.width = ''; th.style.minWidth = ''; th.style.maxWidth = '';
        });
        // Clear inline <col> widths so CSS media-query rules take effect again
        table.querySelectorAll('colgroup col').forEach(function(c) {
          c.style.width = '';
        });
      });
      popup.appendChild(resetBtn);

      document.body.appendChild(popup);
      var r = btn.getBoundingClientRect();
      popup.style.left = Math.max(0, Math.min(r.left, window.innerWidth - 180)) + 'px';
      popup.style.top = (r.bottom + 4) + 'px';
      // Dismiss on outside click (single tracked listener)
      setTimeout(function() {
        dismissFn = function(ev) {
          if (popup && !popup.contains(ev.target) && ev.target !== btn) {
            closePopup();
          }
        };
        document.addEventListener('click', dismissFn);
      }, 0);
    });

    // Dismiss on Escape
    document.addEventListener('keydown', function(ev) {
      if (ev.key === 'Escape' && popup) closePopup();
    });
  };
})();
