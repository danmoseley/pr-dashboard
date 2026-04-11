# PR Dashboard Tests

Interactive browser tests using [Playwright](https://playwright.dev/).

## Setup (first time)

```bash
cd tests
npm install
npx playwright install chromium
```

## Running

Start the local HTTP server first:

```bash
cd docs
python -m http.server 8080
```

Then in another terminal:

```bash
cd tests
# Run both test files in parallel (recommended — roughly half the wall-clock time):
npm run test:all

# Run individual test files:
node test-pr-filters.js    # filter UI tests (tests 1–18)
node test-pr-extended.js   # extended tests (groups A–K)
```

`npm run test:all` uses `run-parallel.js` which spawns both scripts simultaneously,
buffers their output, then prints each file's results sequentially once both finish.
This avoids interleaved output while still saving the time of running them in series.

## Test coverage

`test-pr-filters.js` covers `all/actionable.html` filter behavior:
- Area label click → filter chip appears + rows filtered
- Ctrl+click area label → multi-select (adds second chip)
- Chip `✕` button removes that filter
- Repo name click → repo filter chip
- URL params (`?area=`, `?repo=`) restore filters on load
- User filter + area filter combo

`test-pr-extended.js` covers additional features (groups A–K):
- User filter, involves/next-action/easy-action toggles (A–C)
- URL param round-trips (B)
- Column sorting (D)
- Score `[?]` popup (E)
- Per-repo pages (F)
- Show-more expand (G)
- Multi-chip URL params (H)
- Page smoke tests (I)
- Recent name tiles (J)
- Maintainer filter checkboxes (K)

Tests expect the server to be running on `http://localhost:8080`.
