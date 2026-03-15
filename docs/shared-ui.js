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
      // Freeze current column widths then switch to fixed layout
      var totalW = table.offsetWidth;
      ths.forEach(function(h) {
        var w = h.offsetWidth + 'px';
        h.style.width = w; h.style.minWidth = w; h.style.maxWidth = w;
      });
      table.style.width = totalW + 'px';
      table.style.tableLayout = 'fixed';
    }
    ths.forEach(function(th) {
      var grip = document.createElement('div');
      grip.style.cssText = 'position:absolute;top:0;right:0;bottom:0;width:5px;cursor:col-resize;user-select:none';
      th.style.position = 'relative';
      grip.addEventListener('mousedown', function(e) {
        lockLayout();
        var startX = e.pageX, startW = th.offsetWidth;
        function onMove(e2) { th.style.width = Math.max(30, startW + e2.pageX - startX) + 'px'; th.style.minWidth = th.style.width; th.style.maxWidth = th.style.width; }
        function onUp() { document.removeEventListener('mousemove', onMove); document.removeEventListener('mouseup', onUp); }
        document.addEventListener('mousemove', onMove);
        document.addEventListener('mouseup', onUp);
        e.preventDefault();
      });
      th.appendChild(grip);
    });
  };
})();
