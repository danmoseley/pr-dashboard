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

.PARAMETER SkipActivity
    If set, skips collecting per-maintainer activity signals and does not write
    config/maintainer-activity.json. Useful for lightweight maintainer-only refreshes.

.EXAMPLE
    # Standard usage — updates maintainers.json and maintainer-activity.json in place
    ./scripts/Update-Maintainers.ps1

    # Look back 60 days, require 5+ merges, preview only
    ./scripts/Update-Maintainers.ps1 -Days 60 -MinMerges 5 -DryRun

    # Refresh maintainers list only, skip activity data collection
    ./scripts/Update-Maintainers.ps1 -SkipActivity
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [int]$Days = 90,
    [int]$MinMerges = 3,
    [switch]$DryRun,
    [switch]$SkipActivity
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/MaintainersGuard.psm1" -Force

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
$activityJsonPath = Join-Path $repoRoot 'config' 'maintainer-activity.json'

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
if (-not $SkipActivity) {
    Write-Host "  (including per-maintainer file/label activity signals)" -ForegroundColor DarkGray
}
Write-Host ""

$updated = @{}
# Per-repo, per-maintainer activity: filePaths buckets and area labels
$activityAccum = @{}   # $activityAccum[$repo][$login] = @{ paths = [List]; labels = [List]; count = int }

foreach ($entry in $repos) {
    $repo = $entry.repo
    Write-Host "  $repo ... " -NoNewline

    $mergerCounts = @{}
    # Per-login accumulation for activity signals (only when not skipped)
    $repoActivity = @{}
    $cursor = $null
    $totalFetched = 0

    do {
        $afterClause = if ($cursor) { ", after: `"$cursor`"" } else { "" }
        if ($SkipActivity) {
            $q = "{ search(query: `"repo:$repo is:pr is:merged merged:>$cutoffDate`", type: ISSUE, first: 100$afterClause) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { mergedBy { login } } } } }"
        } else {
            # files(first:100) and labels(first:20) are best-effort limits: PRs with more files or
            # labels get partial data, which is acceptable for activity signal collection.
            $q = "{ search(query: `"repo:$repo is:pr is:merged merged:>$cutoffDate`", type: ISSUE, first: 100$afterClause) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { mergedBy { login } files(first: 100) { nodes { path } } labels(first: 20) { nodes { name } } } } } }"
        }

        $result = $null
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

                    if (-not $SkipActivity) {
                        if (-not $repoActivity.ContainsKey($login)) {
                            $repoActivity[$login] = @{
                                paths  = [System.Collections.Generic.List[string]]@()
                                labels = [System.Collections.Generic.List[string]]@()
                                count  = 0
                            }
                        }
                        # Collect file path prefixes (first 2 segments)
                        if ($node.files -and $node.files.nodes) {
                            foreach ($f in $node.files.nodes) {
                                if ($f.path) {
                                    $parts = $f.path -split '/'
                                    $prefix = if ($parts.Count -ge 2) { "$($parts[0])/$($parts[1])" } else { $parts[0] }
                                    $repoActivity[$login].paths.Add($prefix)
                                }
                            }
                        }
                        # Collect area-* labels
                        if ($node.labels -and $node.labels.nodes) {
                            foreach ($lbl in $node.labels.nodes) {
                                if ($lbl.name -match '^area-') {
                                    $repoActivity[$login].labels.Add($lbl.name)
                                }
                            }
                        }
                    }
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

    if (-not $SkipActivity) {
        # Add merge_count from mergerCounts into each activity entry before storing.
        # All logins in $mergerCounts are guaranteed to have a $repoActivity entry already
        # (created in the inner loop when the login was first seen), so no fallback is needed.
        foreach ($login in @($mergerCounts.Keys)) {
            if ($repoActivity.ContainsKey($login)) {
                $repoActivity[$login].count = $mergerCounts[$login]
            }
        }
        $activityAccum[$repo] = $repoActivity
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

# Build ordered output matching docs/repos.json order, preserving repos not in repos.json
$orderedObj = [ordered]@{}
foreach ($entry in $repos) {
    $repo = $entry.repo
    $orderedObj[$repo] = @($updated[$repo])
}
# Preserve existing repos not present in repos.json (e.g., newly added repos awaiting first scan)
foreach ($repo in $existing.Keys | Sort-Object) {
    if (-not $orderedObj.Contains($repo)) {
        $orderedObj[$repo] = @($existing[$repo])
        Write-Host "  ${repo}: preserved (not in repos.json)" -ForegroundColor Yellow
    }
}

# Safety checks (key preservation + count non-decrease)
$safetyResult = Test-MaintainerSafety -Existing $existing -Proposed $orderedObj
if (-not $safetyResult.Safe) {
    throw "SAFETY ABORT: $($safetyResult.Reason)"
}

$oldTotal = $safetyResult.OldTotal
$newTotal = $safetyResult.NewTotal

if (-not $DryRun) {
    $json = $orderedObj | ConvertTo-Json -Depth 3
    Set-Content -Path $maintainersJsonPath -Value $json -Encoding utf8NoBOM
    Write-Host ""
    Write-Host "Updated $maintainersJsonPath ($oldTotal -> $newTotal maintainers)" -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "[DryRun] No files written. ($oldTotal -> $newTotal maintainers)" -ForegroundColor Yellow
    foreach ($repo in ($updated.Keys | Sort-Object)) {
        $existingForRepo = @($existing[$repo] ?? @())
        $added = @($updated[$repo] | Where-Object { $_ -notin $existingForRepo })
        if ($added.Count -gt 0) {
            Write-Host "  $repo would add: $($added -join ', ')" -ForegroundColor Yellow
        }
    }
}

# ─── Maintainer Activity File ─────────────────────────────────────────────────
if (-not $SkipActivity) {
    Write-Host ""
    Write-Host "Computing per-maintainer activity signals..." -ForegroundColor Cyan

    # Build the activity output: for each repo, for each maintainer in the final list,
    # record merge_count, top 5 path prefixes, and top 5 area-* labels.
    $activityOutput = [ordered]@{}
    foreach ($entry in $repos) {
        $repo = $entry.repo
        $repoMaintainers = @($orderedObj[$repo] ?? @())
        $repoAcc = $activityAccum[$repo]   # may be $null if repo fetch failed

        $repoObj = [ordered]@{}
        foreach ($m in ($repoMaintainers | Sort-Object)) {
            $mergeCount = 0
            $topPaths   = @()
            $topLabels  = @()

            if ($repoAcc -and $repoAcc.ContainsKey($m)) {
                $acc = $repoAcc[$m]
                $mergeCount = if ($acc.count) { [int]$acc.count } else { 0 }

                # Top 5 path prefixes by frequency
                $topPaths = @($acc.paths |
                    Group-Object |
                    Sort-Object -Property Count -Descending |
                    Select-Object -First 5 |
                    ForEach-Object { $_.Name })

                # Top 5 area-* labels by frequency
                $topLabels = @($acc.labels |
                    Group-Object |
                    Sort-Object -Property Count -Descending |
                    Select-Object -First 5 |
                    ForEach-Object { $_.Name })
            }

            $repoObj[$m] = [PSCustomObject]@{
                merge_count      = $mergeCount
                top_paths        = $topPaths
                top_area_labels  = $topLabels
            }
        }
        $activityOutput[$repo] = $repoObj
    }

    $activityJson = $activityOutput | ConvertTo-Json -Depth 4
    # Validate well-formed JSON before writing
    try {
        $activityJson | ConvertFrom-Json | Out-Null
    } catch {
        throw "Activity JSON validation failed: $_"
    }

    if (-not $DryRun) {
        Set-Content -Path $activityJsonPath -Value $activityJson -Encoding utf8NoBOM
        Write-Host "Updated $activityJsonPath" -ForegroundColor Cyan
    } else {
        Write-Host "[DryRun] Would write $activityJsonPath" -ForegroundColor Yellow
    }
}
