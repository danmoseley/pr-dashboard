# PR Dashboard

Automated PR triage dashboard for dotnet repositories, updated via GitHub Actions.

**[View Dashboard](https://danmoseley.github.io/pr-dashboard/)**

## Reports

All repos are updated every 12 hours with Most Actionable, Community, Quick Wins, and Consider Closing reports. AI observations are generated for runtime, aspnetcore, aspire, and extensions.

[runtime](https://danmoseley.github.io/pr-dashboard/runtime/actionable.html) ·
[aspnetcore](https://danmoseley.github.io/pr-dashboard/aspnetcore/actionable.html) ·
[sdk](https://danmoseley.github.io/pr-dashboard/sdk/actionable.html) ·
[msbuild](https://danmoseley.github.io/pr-dashboard/msbuild/actionable.html) ·
[winforms](https://danmoseley.github.io/pr-dashboard/winforms/actionable.html) ·
[wpf](https://danmoseley.github.io/pr-dashboard/wpf/actionable.html) ·
[roslyn](https://danmoseley.github.io/pr-dashboard/roslyn/actionable.html) ·
[aspire](https://danmoseley.github.io/pr-dashboard/aspire/actionable.html) ·
[extensions](https://danmoseley.github.io/pr-dashboard/extensions/actionable.html)

### Per-person view

Append `?user=USERNAME` to any report URL to filter to a specific person's PRs, e.g.:
- [danmoseley's runtime PRs](https://danmoseley.github.io/pr-dashboard/runtime/actionable.html?user=danmoseley)

You can also hover any @username in a report and click "only" to filter interactively.

## How it works

1. A single scheduled GitHub Actions workflow runs every 12 hours
2. Each run executes `scripts/Get-PrTriageData.ps1` which scores all open PRs using batched GraphQL queries across 12 dimensions
3. Results are filtered into reports and formatted as full-width HTML tables
4. AI-generated observations are added via [GitHub Models](https://docs.github.com/en/github-models) (GPT-4o)
5. Reports are published via GitHub Pages

## Local regeneration

After the workflows have run at least once, you can regenerate HTML reports locally from
cached `scan.json` data (no API calls needed). Useful after changing templates or styles:

```powershell
# Regenerate all reports from cached scan data (skip AI observations)
pwsh ./scripts/Regen-Html.ps1

# Include AI observations (requires gh-models extension)
pwsh ./scripts/Regen-Html.ps1 -SkipAI:$false
```

## Adding reports

Edit `scripts/Build-Reports.ps1` to add new report definitions. Edit the workflow files to add new repositories.
