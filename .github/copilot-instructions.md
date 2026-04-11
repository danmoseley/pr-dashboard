# Copilot Instructions for PR Dashboard

## Prime Directive: Keep the Site Up

The dashboard is a live tool used daily. **Every change must preserve site availability.** Key principles:

- **Graceful degradation over failure.** If an API call fails, degrade accuracy — never crash the script or produce invalid output. For example, `Expand-TeamHandle` returns an empty array on failure so triage falls back to just the area lead.
- **Never overwrite good data with bad data.** The pipeline writes scan results to `scan.json.tmp` first and only copies to `scan.json` after validating it's valid JSON. Preserve this pattern.
- **The workflow pushes directly to `main`.** Branch protection rules that require PRs will silently break report generation (the push step uses `continue-on-error`-like behavior, so the job appears green). Do not add branch protection rules that block pushes to main.
- **Guard against API quota exhaustion.** The scan script makes many GitHub API calls per repo. New features that add API calls (like team expansion) should use caching and stay well within the 1000 req/hr rate limit. Currently ~81 team expansion calls add ~32s.
- **Client-side refresh is best-effort.** `pr-refresh.js` and `pr-view-refresh.js` update open/closed state and CI status live, but cannot recompute triage scores, approvals, or next-action — those require a pipeline re-run.

## Architecture Overview

- **`scripts/Get-PrTriageData.ps1`** — The single source of truth for all triage logic. Produces `scan.json` per repo. All report types (actionable, community, quick-wins, consider-closing) consume its output.
- **`scripts/Build-Reports.ps1`** — Reads `scan.json`, filters into report subsets, renders HTML via `ConvertTo-ReportHtml.ps1`.
- **`docs/all/actionable.html`** — Cross-repo view that loads all `scan.json` files client-side and merges them.
- **`config/maintainers.json`** — Hardcoded per-repo maintainer lists, used as a fallback when no area-owner match exists.
- **`.github/workflows/generate-reports.yml`** — Orchestrates scanning all repos on a tiered schedule (priority repos ~4x daily, others ~daily). Has a "skip if recent run" guard to avoid redundant runs.

### Owner/Maintainer Resolution (in priority order)

1. **Area owners** from the target repo's `docs/area-owners.md`. Team handles (e.g., `@dotnet/ncl`) are expanded to individual members via GitHub API with per-run caching.
2. **`-Label` filter owners** if the workflow passes label-based filters.
3. **`config/maintainers.json`** hardcoded fallback for repos without area-owners.

Within a PR's owners, `$prioritizedOwners` ranks: requested reviewers > area owners > engaged maintainers > remaining owners.

### Key Variables in Get-PrTriageData.ps1

- `$authorLogin` — For bot-authored PRs (e.g., Copilot), resolves to the human trigger, not the bot account. Used to exclude the author from reviewer lists and owner prioritization.
- `$hasOwnerApproval` — True only when an APPROVED review comes from someone in `$prOwners`. Self-reviews are excluded.
- `$requestedReviewerLogins` — Filtered to exclude the PR author (they can't review their own PR).

## Local Testing

Before serving pages locally for testing, ensure scan.json files reflect the most recent pipeline run. Pull just the data files from origin/main without switching branches:

```powershell
git fetch origin main
git checkout origin/main -- docs/*/scan.json
```

This updates scan.json data while preserving your local changes to HTML, JS, and CSS files. Then serve from `docs/`:

```powershell
cd docs; python -m http.server 8080
```

To regenerate scan.json locally for a single repo (uses live API calls):

```powershell
$m = (Get-Content config/maintainers.json | ConvertFrom-Json).'dotnet/runtime' -join ','
pwsh ./scripts/Get-PrTriageData.ps1 -Repo "dotnet/runtime" -Limit 500 -Maintainers $m > docs/runtime/scan.json
```

## Coding Standards

These rules address the most common issues found during code review. Follow them to avoid unnecessary review round-trips.

### HTML / XSS Safety (most frequent review finding)

- **Never insert untrusted data via `innerHTML`.** Use `textContent` for plain text. When HTML structure is needed, build DOM nodes with `document.createElement` or use the `escHtml()` / `escAttr()` helpers — and use the *correct* one for the context:
  - `escHtml()` for element content (`<span>${escHtml(text)}</span>`)
  - `escAttr()` for attribute values (`<div title="${escAttr(text)}">`)
- **Never mix escaping helpers.** `escHtml` output must not appear inside an HTML attribute, and `escAttr` output must not appear in element content.
- **Audit every template literal that produces HTML.** Any variable interpolated into an HTML string — including `data-*` attributes, tooltips, `title=`, and `aria-label=` — must be escaped for its context. Repo slugs, usernames, and PR titles all contain characters that break HTML (`/`, `<`, `"`, `&`).
- **Prefer `textContent` over `innerHTML`** unless the content genuinely requires HTML structure (e.g., links, formatting). Setting `textContent` is always XSS-safe.

### Accessibility

- Every interactive element (button, link, icon) must have an accessible name — either visible text or `aria-label`.
- Icon-only elements (e.g., `.bot-icon`, filter buttons, emoji badges) need `role` and `aria-label` attributes.
- Maintain sufficient color contrast (WCAG AA: 4.5:1 for text, 3:1 for large text/icons), especially in dark mode.
- Footnote/superscript links must be keyboard-navigable and have descriptive `aria-label` text.
- When changing visible labels (eg button name) also change any `aria-label` text to match.

### GitHub API Usage

- **Always paginate.** GitHub API endpoints return at most 100 items per page. Any call that could return more (team members, search results, PR comments) must loop with `?page=N` or GraphQL cursors until the response is empty. Fetching only page 1 silently drops data.
- **`GET /rate_limit` is not free** — it counts against the rate limit. Don't call it in tight loops; cache the result per run.
- **Handle pagination in `gh api` calls** by using `--paginate` or manual `?page=` loops.

### JavaScript Patterns

- **URL encoding:** `URLSearchParams.get()` already decodes values — do not wrap the result in `decodeURIComponent()` (double-decoding turns `%2520` into `%20` then a space).
- **`parseInt()` / `Number()`:** Always check for `NaN` after parsing. Use a fallback: `parseInt(value, 10) || 0`.
- **Avoid inline `onclick` string concatenation.** Use `addEventListener` or delegate events — string-built handlers are XSS-prone and hard to debug.
- **Cache compiled regexes.** If a regex is used inside a loop or called on every row/render, create it once outside the loop and reuse it. Do not recompile with `new RegExp()` on every call.
- **`Object.hasOwn(obj, key)`** (or `Object.prototype.hasOwnProperty.call(obj, key)`) instead of `obj.hasOwnProperty(key)` which fails on `Object.create(null)`.

### PowerShell Patterns

- **`Select-Object -Unique` only removes *adjacent* duplicates.** To deduplicate an array, use `| Sort-Object -Unique` or `[System.Collections.Generic.HashSet[string]]`.
- **Never use `$array += $item` in a loop** — this is O(n²) because PowerShell copies the entire array each iteration. Use `[System.Collections.Generic.List[object]]` with `.Add()`.
- **`[int]$value` throws on `$null` or empty string.** Guard with: `if ($value) { [int]$value } else { 0 }`.
- `-not @()` is `$true` — use `$null -eq` or `.Count -eq 0` for array emptiness checks.
- `-and`/`-or` have same precedence (left-to-right) — parenthesize compound conditions.
- `ConvertFrom-Json` produces DateTime for date strings — string interpolation is locale-dependent. Canonicalize with `.ToUniversalTime().ToString('o')` before hashing or comparing.
- `ConvertFrom-Json` produces Int64 for numbers — hashtable lookup is type-sensitive (cast with `[string]`).
- **`-match` is case-insensitive by default** in PowerShell. Use `-cmatch` when case-sensitive matching is required (e.g., CODEOWNERS patterns).

### Test Quality

- **No fixed `sleep`/`waitForTimeout` in Playwright tests.** Use `waitForSelector`, `waitForFunction`, or `expect(...).toBeVisible()` — fixed sleeps are flaky and slow.
- **Isolate test state.** Each test must get a fresh page/context. Don't share `localStorage`, URL params, or page state across tests — leaked state causes intermittent failures.
- **Don't assert hard-coded row counts.** Use semantic assertions (e.g., "at least one row matches filter X") rather than "exactly 100 rows visible" which breaks when data changes.
- **Ensure test runner exits non-zero on failure.** If writing a custom runner, explicitly set `process.exitCode = 1` on any test failure.

### Avoiding Duplicated Logic

- When the same calculation appears in two or more files (e.g., time formatting, escaping, score categorization), extract it into a shared helper in the appropriate shared module (`docs/shared.js`, `scripts/` module, etc.).
- If a heuristic or classification (like "easy action" or "merge ready") is used in both the PowerShell scan and the HTML/JS rendering, define it in one place and reference it from the other (or document that both must stay in sync).

### Documentation / Comments Accuracy

- **Every comment, tooltip, and PR description must match the actual code behavior.** If you change logic, update the corresponding comments, help text, and parameter documentation in the same commit.
- **Parameter help:** Every new PowerShell parameter must be documented in the function's comment-based help block.
- **Scoring table:** If scoring weights or thresholds change, update the scoring explainer footnotes in the HTML template to match.

## Pre-Push Quality Checklist

**Always run rubber-duck review before pushing.** Online code review is slow and iterative — catch issues locally first. Run rubber-duck review twice: once after planning (design critique) and once after implementing (implementation critique).

Before pushing any PR, verify:

### Config & Schedule Alignment
- Do hardcoded values (timeouts, intervals, thresholds) work across **all** schedule variants (weekday, weekend, manual dispatch)?
- If a value must exceed a schedule interval, does it exceed the **longest** interval across all tiers?

### Cross-Repo / Cross-Run Data Mixing
- When aggregating data from multiple `scan.json` files, can stale data from a previous pipeline run mix with fresh data? Filter by recency if so.
- When injecting metadata (e.g., `_rate_limit`), does it only touch repos that were actually processed this run?

### Test Coverage
- Is there a test for both the "true" and "false" return paths of any new decision logic?
- Are test helpers computing values the same way production code does? (e.g., JSON round-trip for dates, same hash algorithm)

### Edge Cases & Defaults
- What happens when a value is 0, null, empty string, or missing? (e.g., epoch 0 → 1970 date display)
- What happens when an API call fails? Does the code degrade gracefully?
