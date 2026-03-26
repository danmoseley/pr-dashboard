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
