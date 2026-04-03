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
node test-pr-filters.js
```

The tests cover `all/actionable.html` filter behavior:
- Area label click → filter chip appears + rows filtered
- Ctrl+click area label → multi-select (adds second chip)
- Chip `✕` button removes that filter
- Repo name click → repo filter chip
- URL params (`?area=`, `?repo=`) restore filters on load
- User filter + area filter combo

Tests expect the server to be running on `http://localhost:8080`.
