# PR Dashboard

Automated PR triage dashboard for dotnet repositories, updated via GitHub Actions.

**[View Dashboard](https://danmoseley.github.io/pr-dashboard/)**

## Reports

### dotnet/runtime (every 4 hours)
- [Top 15 Most Actionable PRs](https://danmoseley.github.io/pr-dashboard/runtime/top15.html)
- [Community PRs Awaiting Review](https://danmoseley.github.io/pr-dashboard/runtime/community.html)
- [Quick Wins: Ready to Merge](https://danmoseley.github.io/pr-dashboard/runtime/quick-wins.html)

### Other repos (every 12 hours)

Each of these repos gets Top 15 and Quick Wins reports:

[aspnetcore](https://danmoseley.github.io/pr-dashboard/aspnetcore/top15.html) ·
[sdk](https://danmoseley.github.io/pr-dashboard/sdk/top15.html) ·
[msbuild](https://danmoseley.github.io/pr-dashboard/msbuild/top15.html) ·
[winforms](https://danmoseley.github.io/pr-dashboard/winforms/top15.html) ·
[wpf](https://danmoseley.github.io/pr-dashboard/wpf/top15.html) ·
[roslyn](https://danmoseley.github.io/pr-dashboard/roslyn/top15.html) ·
[aspire](https://danmoseley.github.io/pr-dashboard/aspire/top15.html)

## How it works

1. Scheduled GitHub Actions workflows run on cron (runtime every 4h, others every 12h)
2. Each run fetches [Get-PrTriageData.ps1](https://github.com/dotnet/runtime/pull/125005) which scores all open PRs using batched GraphQL queries across 12 dimensions
3. Results are filtered into reports and formatted as full-width HTML tables
4. AI-generated observations are added via [GitHub Models](https://docs.github.com/en/github-models) (GPT-4o)
5. Reports are published via GitHub Pages

## Adding reports

Edit `scripts/Build-Reports.ps1` to add new report definitions. Edit the workflow files to add new repositories.
