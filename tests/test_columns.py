"""
Playwright tests for column picker and responsive column width behavior.
Run with: python -m pytest tests/test_columns.py -v
"""
import pytest
from playwright.sync_api import sync_playwright, expect

BASE = "http://localhost:8080/_test_shrink.html"

@pytest.fixture(scope="module")
def browser():
    with sync_playwright() as p:
        b = p.chromium.launch()
        yield b
        b.close()

@pytest.fixture
def wide_page(browser):
    """Full-width page where all columns are visible."""
    page = browser.new_page(viewport={"width": 1400, "height": 600})
    page.goto(BASE)
    page.wait_for_timeout(300)
    yield page
    page.close()


# ── Responsive media query tests ──

class TestMediaQueryShrinking:

    def _visible_width(self, page, col_id):
        """Return the rendered pixel width of a column header."""
        th = page.locator(f'th[data-col="{col_id}"]')
        return th.bounding_box()["width"]

    def _is_effectively_hidden(self, page, col_id):
        """Column is hidden if its width is ≤ 2px (zero-width with rounding)."""
        return self._visible_width(page, col_id) <= 2

    def test_wide_all_visible(self, browser):
        page = browser.new_page(viewport={"width": 1500, "height": 600})
        page.goto(BASE); page.wait_for_timeout(300)
        for col in ["ready", "need", "action", "pr", "repo", "title",
                     "nextaction", "ci", "disc", "age", "upd", "size",
                     "author", "area"]:
            assert not self._is_effectively_hidden(page, col), f"{col} should be visible at 1500px"
        page.close()

    def test_1400_numbers_vanish(self, browser):
        """Tier 1 (≤1400px): ready/need/action vanish."""
        page = browser.new_page(viewport={"width": 1399, "height": 600})
        page.goto(BASE); page.wait_for_timeout(300)
        for col in ["ready", "need", "action"]:
            assert self._is_effectively_hidden(page, col), f"{col} should be hidden at 1399px"
        for col in ["pr", "repo", "title", "nextaction", "ci", "author", "area"]:
            assert not self._is_effectively_hidden(page, col), f"{col} should be visible at 1399px"
        page.close()

    def test_1100_only_core_remain(self, browser):
        """Tier 2 (≤1100px): only PR/repo/title/nextaction remain."""
        page = browser.new_page(viewport={"width": 1099, "height": 600})
        page.goto(BASE); page.wait_for_timeout(300)
        for col in ["ready", "need", "action", "disc", "age", "upd", "size", "author", "ci", "area"]:
            assert self._is_effectively_hidden(page, col), f"{col} should be hidden at 1099px"
        for col in ["pr", "repo", "title", "nextaction"]:
            assert not self._is_effectively_hidden(page, col), f"{col} should be visible at 1099px"
        page.close()

    def test_title_gets_more_space_as_narrower(self, browser):
        """Title column should get a larger share of total width as viewport narrows."""
        widths = {}
        for vw in [1500, 1099]:
            page = browser.new_page(viewport={"width": vw, "height": 600})
            page.goto(BASE); page.wait_for_timeout(300)
            tw = page.locator("#pr-table").bounding_box()["width"]
            title_w = self._visible_width(page, "title")
            widths[vw] = title_w / tw
            page.close()
        assert widths[1099] > widths[1500], \
            f"Title share should grow: {widths[1500]:.2%} at 1500 vs {widths[1099]:.2%} at 1099"


# ── Column picker tests ──

# We need a page that has the column chooser initialized.
# The _test_shrink.html doesn't have shared-ui.js, so we create a richer fixture.

PICKER_HTML = """<!DOCTYPE html>
<html><head>
<link rel="stylesheet" href="shared-styles.css">
<style>table#pr-table { table-layout: fixed; }</style>
</head><body>
<div id="controls"></div>
<table id="pr-table">
<colgroup>
  <col data-col="ready"><col data-col="need"><col data-col="action">
  <col data-col="pr"><col data-col="repo">
  <col data-col="title"><col data-col="nextaction">
  <col data-col="ci"><col data-col="disc">
  <col data-col="age"><col data-col="upd"><col data-col="size">
  <col data-col="author"><col data-col="area">
</colgroup>
<thead><tr>
  <th data-col="ready">Rdy</th><th data-col="need">Need</th><th data-col="action">Act</th>
  <th data-col="pr">PR</th><th data-col="repo">Repo</th>
  <th data-col="title">Title</th><th data-col="nextaction">Next Action</th>
  <th data-col="ci">CI</th><th data-col="disc">Disc</th>
  <th data-col="age">Age</th><th data-col="upd">Upd</th><th data-col="size">Size</th>
  <th data-col="author">Author</th><th data-col="area">Area</th>
</tr></thead>
<tbody>
<tr>
  <td data-col="ready">3</td><td data-col="need">1</td><td data-col="action">2</td>
  <td data-col="pr">#4821</td><td data-col="repo">runtime</td>
  <td data-col="title">Fix regex perf</td>
  <td data-col="nextaction">Waiting on CI</td>
  <td data-col="ci">ok</td><td data-col="disc">5</td>
  <td data-col="age">3d</td><td data-col="upd">1h</td><td data-col="size">M</td>
  <td data-col="author">dan</td><td data-col="area">regex</td>
</tr>
</tbody>
</table>
<script src="shared-ui.js"></script>
<script>
  initResizableColumns('pr-table');
  initColumnChooser('pr-table', 'test-hidden-cols', 'controls');
</script>
</body></html>"""


@pytest.fixture
def picker_page(browser):
    """Page with column chooser initialized, at wide viewport."""
    import pathlib, tempfile
    # Write the picker test page
    path = pathlib.Path(r"C:\git\pr-dashboard\docs\_test_picker.html")
    path.write_text(PICKER_HTML, encoding="utf-8")
    page = browser.new_page(viewport={"width": 1400, "height": 600})
    # Clear localStorage for clean state
    page.goto("http://localhost:8080/_test_picker.html")
    page.evaluate("localStorage.removeItem('test-hidden-cols')")
    page.reload()
    page.wait_for_timeout(300)
    yield page
    page.close()
    path.unlink(missing_ok=True)


class TestColumnPicker:

    def _col_width(self, page, col_id):
        th = page.locator(f'th[data-col="{col_id}"]')
        return th.bounding_box()["width"]

    def _open_picker(self, page):
        page.locator(".col-chooser-btn").click()
        page.wait_for_timeout(200)

    def _checkbox_for(self, page, col_id):
        return page.locator(f'.col-chooser-popup input[data-col-id="{col_id}"]')

    def test_picker_button_exists(self, picker_page):
        assert picker_page.locator(".col-chooser-btn").is_visible()

    def test_picker_opens_and_closes(self, picker_page):
        self._open_picker(picker_page)
        assert picker_page.locator(".col-chooser-popup").is_visible()
        # Click button again to close
        picker_page.locator(".col-chooser-btn").click()
        picker_page.wait_for_timeout(200)
        assert picker_page.locator(".col-chooser-popup").count() == 0

    def test_uncheck_hides_column(self, picker_page):
        """Unchecking a column in the picker should make it effectively zero-width."""
        # Verify repo is visible first
        assert self._col_width(picker_page, "repo") > 10
        # Open picker and uncheck repo
        self._open_picker(picker_page)
        cb = self._checkbox_for(picker_page, "repo")
        cb.uncheck()
        picker_page.wait_for_timeout(200)
        # Repo column should now be effectively hidden
        assert self._col_width(picker_page, "repo") <= 2, "repo should be hidden after unchecking"

    def test_recheck_restores_column(self, picker_page):
        """Checking a previously unchecked column restores it."""
        orig_w = self._col_width(picker_page, "author")
        # Hide author
        self._open_picker(picker_page)
        self._checkbox_for(picker_page, "author").uncheck()
        picker_page.wait_for_timeout(200)
        assert self._col_width(picker_page, "author") <= 2
        # Show author again
        self._checkbox_for(picker_page, "author").check()
        picker_page.wait_for_timeout(200)
        restored_w = self._col_width(picker_page, "author")
        assert restored_w > 10, f"author should be restored, got {restored_w}px"

    def test_hidden_persists_across_reload(self, picker_page):
        """Hidden columns should persist in localStorage across page reload."""
        self._open_picker(picker_page)
        self._checkbox_for(picker_page, "disc").uncheck()
        picker_page.wait_for_timeout(200)
        assert self._col_width(picker_page, "disc") <= 2
        # Reload
        picker_page.reload()
        picker_page.wait_for_timeout(500)
        assert self._col_width(picker_page, "disc") <= 2, "disc should stay hidden after reload"

    def test_reset_shows_all_columns(self, picker_page):
        """Reset button should show all columns."""
        # Hide a couple columns
        self._open_picker(picker_page)
        self._checkbox_for(picker_page, "age").uncheck()
        self._checkbox_for(picker_page, "size").uncheck()
        picker_page.wait_for_timeout(200)
        assert self._col_width(picker_page, "age") <= 2
        assert self._col_width(picker_page, "size") <= 2
        # Click Reset
        picker_page.locator(".col-chooser-reset").click()
        picker_page.wait_for_timeout(200)
        assert self._col_width(picker_page, "age") > 5, "age should be visible after reset"
        assert self._col_width(picker_page, "size") > 5, "size should be visible after reset"

    def test_escape_closes_picker(self, picker_page):
        self._open_picker(picker_page)
        assert picker_page.locator(".col-chooser-popup").is_visible()
        picker_page.keyboard.press("Escape")
        picker_page.wait_for_timeout(200)
        assert picker_page.locator(".col-chooser-popup").count() == 0

    def test_multiple_columns_hidden(self, picker_page):
        """Can hide multiple columns simultaneously."""
        self._open_picker(picker_page)
        for col in ["ready", "need", "action", "disc"]:
            self._checkbox_for(picker_page, col).uncheck()
        picker_page.wait_for_timeout(200)
        for col in ["ready", "need", "action", "disc"]:
            assert self._col_width(picker_page, col) <= 2, f"{col} should be hidden"
        # Important columns still have width
        for col in ["title", "nextaction", "pr"]:
            assert self._col_width(picker_page, col) > 20, f"{col} should still be visible"


# ── Drag-to-resize tests ──

class TestDragResize:

    def _col_width(self, page, col_id):
        th = page.locator(f'th[data-col="{col_id}"]')
        return th.bounding_box()["width"]

    def test_drag_resize_changes_column_width(self, picker_page):
        """Dragging the right edge of a header should change its width."""
        col = "repo"
        before = self._col_width(picker_page, col)
        th = picker_page.locator(f'th[data-col="{col}"]')
        box = th.bounding_box()
        # Drag from right edge of header 80px to the right
        start_x = box["x"] + box["width"] - 2
        start_y = box["y"] + box["height"] / 2
        picker_page.mouse.move(start_x, start_y)
        picker_page.mouse.down()
        picker_page.mouse.move(start_x + 80, start_y, steps=5)
        picker_page.mouse.up()
        picker_page.wait_for_timeout(200)
        after = self._col_width(picker_page, col)
        assert after > before + 40, f"repo should have grown: {before:.0f} -> {after:.0f}"

    def test_drag_resize_shrinks_column(self, picker_page):
        """Dragging left should shrink a column."""
        col = "nextaction"
        before = self._col_width(picker_page, col)
        th = picker_page.locator(f'th[data-col="{col}"]')
        box = th.bounding_box()
        start_x = box["x"] + box["width"] - 2
        start_y = box["y"] + box["height"] / 2
        picker_page.mouse.move(start_x, start_y)
        picker_page.mouse.down()
        picker_page.mouse.move(start_x - 80, start_y, steps=5)
        picker_page.mouse.up()
        picker_page.wait_for_timeout(200)
        after = self._col_width(picker_page, col)
        assert after < before - 40, f"nextaction should have shrunk: {before:.0f} -> {after:.0f}"
