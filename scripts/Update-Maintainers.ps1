<#
.SYNOPSIS
    Discovers maintainers by analyzing who merged PRs recently, and updates config/maintainers.json.

.DESCRIPTION
    For each repo listed in docs/repos.json, queries GitHub's GraphQL API to find PRs merged
    in the last N days. Users who merged at least -MinMerges PRs (excluding bots) are considered
    maintainers. The results are unioned with the existing config/maintainers.json and written back.

    Requires: PowerShell 7+ (pwsh) and gh CLI authenticated with appropriate permissions.

    Note: Uses GitHub's search API which caps at ~1000 results. For very active repos this may
    undercount merges, but since we union with the existing list and use a low threshold, the
    practical impact is minimal.

.PARAMETER Days
    How many days back to look for merged PRs. Default: 90 (roughly 3 months).

.PARAMETER MinMerges
    Minimum number of merges to qualify as a maintainer. Default: 3.

.PARAMETER DryRun
    If set, prints what would change without writing to disk.

.EXAMPLE
    # Standard usage — updates maintainers.json in place
    ./scripts/Update-Maintainers.ps1

    # Look back 60 days, require 5+ merges, preview only
    ./scripts/Update-Maintainers.ps1 -Days 60 -MinMerges 5 -DryRun
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [int]$Days = 90,
    [int]$MinMerges = 3,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path (Join-Path $repoRoot 'docs' 'repos.json'))) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path (Join-Path $repoRoot 'docs' 'repos.json'))) {
    Write-Error "Cannot find docs/repos.json. Run from the pr-dashboard repo root or scripts/ folder."
    exit 1
}

$reposJsonPath = Join-Path $repoRoot 'docs' 'repos.json'
$maintainersJsonPath = Join-Path $repoRoot 'config' 'maintainers.json'

# Bot accounts to exclude
$botLogins = @(
    'dotnet-maestro[bot]'
    'dotnet-maestro'
    'dependabot[bot]'
    'dependabot'
    'github-actions[bot]'
    'github-actions'
    'msftbot[bot]'
    'msftbot'
    'dotnet-policy-service[bot]'
    'dotnet-policy-service'
    'azure-pipelines[bot]'
    'copilot'
)

$repos = Get-Content $reposJsonPath -Raw | ConvertFrom-Json
$existing = @{}
if (Test-Path $maintainersJsonPath) {
    $raw = Get-Content $maintainersJsonPath -Raw | ConvertFrom-Json
    foreach ($prop in $raw.PSObject.Properties) {
        $existing[$prop.Name] = @($prop.Value)
    }
}

$cutoffDate = (Get-Date).AddDays(-$Days).ToString('yyyy-MM-dd')
Write-Host "Looking for PRs merged since $cutoffDate (last $Days days), min $MinMerges merges." -ForegroundColor Cyan
Write-Host ""

$updated = @{}

foreach ($entry in $repos) {
    $repo = $entry.repo
    Write-Host "  $repo ... " -NoNewline

    $mergerCounts = @{}
    $cursor = $null
    $totalFetched = 0

    do {
        $afterClause = if ($cursor) { ", after: `"$cursor`"" } else { "" }
        $q = "{ search(query: `"repo:$repo is:pr is:merged merged:>$cutoffDate`", type: ISSUE, first: 100$afterClause) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { mergedBy { login } } } } }"

        $result = $null
        $stderr = $null
        $result = gh api graphql -f query="$q" 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR querying $repo (skipping)" -ForegroundColor Red
            $mergerCounts = $null
            break
        }

        $data = $result | ConvertFrom-Json
        $searchData = $data.data.search

        foreach ($node in $searchData.nodes) {
            if ($node.mergedBy -and $node.mergedBy.login) {
                $login = $node.mergedBy.login
                if ($login -notin $botLogins) {
                    $mergerCounts[$login] = ($mergerCounts[$login] ?? 0) + 1
                }
            }
            $totalFetched++
        }

        $hasNext = $searchData.pageInfo.hasNextPage
        $cursor = $searchData.pageInfo.endCursor
    } while ($hasNext)

    # Skip repo if fetch failed — keep existing entry unchanged
    if ($null -eq $mergerCounts) {
        $updated[$repo] = @($existing[$repo] ?? @())
        continue
    }

    # Apply threshold
    $discovered = @($mergerCounts.GetEnumerator() |
        Where-Object { $_.Value -ge $MinMerges } |
        Sort-Object Value -Descending |
        ForEach-Object { $_.Key })

    # Union with existing
    $existingForRepo = @($existing[$repo] ?? @())
    $merged = @($existingForRepo + $discovered | Select-Object -Unique | Sort-Object)

    $added = @($merged | Where-Object { $_ -notin $existingForRepo })

    $updated[$repo] = $merged

    Write-Host "$totalFetched merged PRs, $($discovered.Count) qualifying mergers" -NoNewline
    if ($added.Count -gt 0) {
        Write-Host " (+$($added.Count) new: $($added -join ', '))" -ForegroundColor Green
    } else {
        Write-Host " (no changes)" -ForegroundColor DarkGray
    }
}

if (-not $DryRun) {
    # Build ordered output matching docs/repos.json order
    $orderedObj = [ordered]@{}
    foreach ($entry in $repos) {
        $repo = $entry.repo
        $orderedObj[$repo] = @($updated[$repo])
    }

    $json = $orderedObj | ConvertTo-Json -Depth 3
    Set-Content -Path $maintainersJsonPath -Value $json -Encoding utf8NoBOM
    Write-Host ""
    Write-Host "Updated $maintainersJsonPath" -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "[DryRun] No files written." -ForegroundColor Yellow
    foreach ($repo in ($updated.Keys | Sort-Object)) {
        $existingForRepo = @($existing[$repo] ?? @())
        $added = @($updated[$repo] | Where-Object { $_ -notin $existingForRepo })
        if ($added.Count -gt 0) {
            Write-Host "  $repo would add: $($added -join ', ')" -ForegroundColor Yellow
        }
    }
}
