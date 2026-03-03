# PR Dashboard

Automated PR triage dashboard for [dotnet/runtime](https://github.com/dotnet/runtime), updated daily via GitHub Actions.

## Reports

- [**Top 15 Most Actionable PRs**](https://danmoseley.github.io/pr-dashboard/top15.html) — highest merge-readiness score
- [**Community PRs Awaiting Review**](https://danmoseley.github.io/pr-dashboard/community.html) — community contributions needing maintainer review
- [**Quick Wins: Ready to Merge**](https://danmoseley.github.io/pr-dashboard/quick-wins.html) — approved, CI green, no unresolved threads

[**Dashboard home**](https://danmoseley.github.io/pr-dashboard/)

## How it works

1. A [scheduled GitHub Actions workflow](.github/workflows/generate-reports.yml) runs daily at 8am UTC
2. It fetches [Get-PrTriageData.ps1](https://github.com/dotnet/runtime/pull/125005) which scores all open PRs using batched GraphQL queries across 12 dimensions (CI status, approvals, conflicts, staleness, etc.)
3. The full scan (~300 PRs in ~80s) is filtered into 3 reports
4. Each report gets AI-generated observations via [GitHub Models](https://docs.github.com/en/github-models) (GPT-4o)
5. Results are published as full-width HTML pages via GitHub Pages

## Scoring

PRs are scored 0–10 on a weighted composite of 12 dimensions including CI status, merge conflicts, maintainer approval, unresolved feedback, staleness, discussion complexity, and more. See the [pr-triage skill PR](https://github.com/dotnet/runtime/pull/125005) for full details.

## Adding reports

Edit `scripts/Build-Reports.ps1` to add new report definitions in the `$reports` array. Each report needs a filter function, title, and AI prompt.
