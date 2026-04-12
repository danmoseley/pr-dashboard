<#
.SYNOPSIS
    Discovers maintainers by analyzing who merged PRs recently, and updates config/maintainers.json.

.DESCRIPTION
    For each repo listed in docs/repos.json, queries GitHub's GraphQL API to find PRs merged
    in the last N days. Users who merged at least -MinMerges PRs (excluding bots) are considered
    maintainers. The results are unioned with the existing config/maintainers.json and written back.

    Also collects per-maintainer activity signals (file paths and area labels from merged PRs) and
    writes them to config/maintainer-activity.json. These signals are used by Get-PrTriageData.ps1
    to rank maintainers when no CODEOWNERS or area-label owner matches a PR.

    Activity signals use best-effort limits (files(first:100), labels(first:20)) because full
    pagination of files per PR would significantly increase API usage. Large PRs touching more than
    100 files will be underrepresented in top_paths, but this is acceptable for signal collection.

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
Import-Module "$PSScriptRoot/MaintainerActivity.psm1" -Force
Import-Module "$PSScriptRoot/GraphQLHelper.psm1" -Force

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
$failedRepos = [System.Collections.Generic.List[object]]@()   # entries to retry in a second pass

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
        $maxRetries = 5
        $succeeded = $false
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            $errFile = [System.IO.Path]::GetTempFileName()
            $errText = ''
            try {
                $result = gh api graphql -f query="$q" 2>$errFile
                $exitCode = $LASTEXITCODE
                if ($exitCode -ne 0) {
                    $errText = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) ?? ''
                } else {
                    # gh can return exit 0 with GraphQL-level errors in the body
                    $validation = Test-GraphQLResponse -RawJson $result
                    $parsed = $validation.Parsed
                    if (-not $validation.Success) {
                        $exitCode = 1
                        $errText = $validation.Error
                    }
                }
                if ($exitCode -eq 0) {
                    $succeeded = $true
                    break
                }
            } finally {
                Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
            }
            $displayErr = $errText.Trim()
            if ([string]::IsNullOrWhiteSpace($displayErr)) {
                $displayErr = "gh api graphql exited with code $exitCode"
            }
            if ($attempt -lt $maxRetries) {
                $delay = $attempt * 15
                Write-Host "" # finish the "repo ..." line
                Write-Host "    Attempt $attempt/$maxRetries failed: $displayErr" -ForegroundColor Yellow
                Write-Host "    Retrying in ${delay}s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $delay
                Write-Host "  $repo ... " -NoNewline  # re-print the prefix for the next attempt
            } else {
                Write-Host "" # finish the "repo ..." line
                Write-Host "    Attempt $attempt/$maxRetries failed: $displayErr" -ForegroundColor Red
            }
        }
        if (-not $succeeded) {
            Write-Host "  ERROR querying $repo after $maxRetries attempts (skipping)" -ForegroundColor Red
            $mergerCounts = $null
            break
        }

        # $parsed was already validated inside the retry loop
        $searchData = $parsed.data.search

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
                        # Collect file path prefixes (first 3 segments, e.g. src/libraries/System.IO).
                        if ($node.files -and $node.files.nodes) {
                            foreach ($f in $node.files.nodes) {
                                if ($f.path) {
                                    $prefix = Get-PathPrefix $f.path
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

    # Skip repo if fetch failed — queue for second pass
    if ($null -eq $mergerCounts) {
        $failedRepos.Add($entry)
        $updated[$repo] = @($existing[$repo] ?? @())
        continue
    }

    if (-not $SkipActivity) {
        # Add merge_count from mergerCounts into each activity entry before storing.
        # Invariant (holds because this block only runs when -SkipActivity is false): all logins
        # in $mergerCounts also have a $repoActivity entry — both are populated in the inner loop
        # above under the same `-not $SkipActivity` guard, so they stay in sync.
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

# ─── Second pass: retry repos that failed in the first pass ───────────────────
# By the time we reach here, minutes have elapsed processing other repos, giving
# GitHub's API time to recover from transient 502/504 errors.
if ($failedRepos.Count -gt 0) {
    $retryDelay = 60
    Write-Host ""
    Write-Host "Retrying $($failedRepos.Count) failed repo(s) after ${retryDelay}s cooldown..." -ForegroundColor Yellow
    Start-Sleep -Seconds $retryDelay

    foreach ($entry in $failedRepos) {
        $repo = $entry.repo
        Write-Host "  $repo (retry) ... " -NoNewline

        $mergerCounts = @{}
        $repoActivity = @{}
        $cursor = $null
        $totalFetched = 0

        do {
            $afterClause = if ($cursor) { ", after: `"$cursor`"" } else { "" }
            if ($SkipActivity) {
                $q = "{ search(query: `"repo:$repo is:pr is:merged merged:>$cutoffDate`", type: ISSUE, first: 100$afterClause) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { mergedBy { login } } } } }"
            } else {
                $q = "{ search(query: `"repo:$repo is:pr is:merged merged:>$cutoffDate`", type: ISSUE, first: 100$afterClause) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { mergedBy { login } files(first: 100) { nodes { path } } labels(first: 20) { nodes { name } } } } } }"
            }

            $result = $null
            $maxRetries = 5
            $succeeded = $false
            for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                $errFile = [System.IO.Path]::GetTempFileName()
                $errText = ''
                try {
                    $result = gh api graphql -f query="$q" 2>$errFile
                    $exitCode = $LASTEXITCODE
                    if ($exitCode -ne 0) {
                        $errText = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) ?? ''
                    } else {
                        $validation = Test-GraphQLResponse -RawJson $result
                        $parsed = $validation.Parsed
                        if (-not $validation.Success) {
                            $exitCode = 1
                            $errText = $validation.Error
                        }
                    }
                    if ($exitCode -eq 0) {
                        $succeeded = $true
                        break
                    }
                } finally {
                    Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
                }
                $displayErr = $errText.Trim()
                if ([string]::IsNullOrWhiteSpace($displayErr)) {
                    $displayErr = "gh api graphql exited with code $exitCode"
                }
                if ($attempt -lt $maxRetries) {
                    $delay = $attempt * 15
                    Write-Host ""
                    Write-Host "    Attempt $attempt/$maxRetries failed: $displayErr" -ForegroundColor Yellow
                    Write-Host "    Retrying in ${delay}s..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $delay
                    Write-Host "  $repo (retry) ... " -NoNewline
                } else {
                    Write-Host ""
                    Write-Host "    Attempt $attempt/$maxRetries failed: $displayErr" -ForegroundColor Red
                }
            }
            if (-not $succeeded) {
                Write-Host "  ERROR querying $repo on second pass (giving up)" -ForegroundColor Red
                $mergerCounts = $null
                break
            }

            $searchData = $parsed.data.search
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
                            if ($node.files -and $node.files.nodes) {
                                foreach ($f in $node.files.nodes) {
                                    if ($f.path) {
                                        $prefix = Get-PathPrefix $f.path
                                        $repoActivity[$login].paths.Add($prefix)
                                    }
                                }
                            }
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

        if ($null -eq $mergerCounts) {
            # Still failed — keep existing entry
            continue
        }

        # Success on second pass — process results
        if (-not $SkipActivity) {
            foreach ($login in @($mergerCounts.Keys)) {
                if ($repoActivity.ContainsKey($login)) {
                    $repoActivity[$login].count = $mergerCounts[$login]
                }
            }
            $activityAccum[$repo] = $repoActivity
        }

        $discovered = @($mergerCounts.GetEnumerator() |
            Where-Object { $_.Value -ge $MinMerges } |
            Sort-Object Value -Descending |
            ForEach-Object { $_.Key })

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
    # record merge_count, top 10 path prefixes, and top 5 area-* labels.
    # If a repo fetch failed ($repoAcc is null), preserve the prior repo entry when
    # available rather than overwriting good data with empty activity signals.
    $existingActivity = $null
    if (Test-Path -LiteralPath $activityJsonPath) {
        try {
            $existingActivity = Get-Content -LiteralPath $activityJsonPath -Raw | ConvertFrom-Json
        } catch {
            Write-Warning "Failed to read existing activity file '$activityJsonPath'. Continuing without fallback activity data. $_"
        }
    }

    $activityOutput = [ordered]@{}
    foreach ($entry in $repos) {
        $repo = $entry.repo
        $repoMaintainers = @($orderedObj[$repo] ?? @())
        $repoAcc = $activityAccum[$repo]   # may be $null if repo fetch failed

        if ($null -eq $repoAcc) {
            # Repo fetch failed — preserve existing data if available
            $existingRepoData = $null
            if ($existingActivity) {
                if ($existingActivity -is [hashtable] -and $existingActivity.ContainsKey($repo)) {
                    $existingRepoData = $existingActivity[$repo]
                } elseif ($existingActivity.PSObject.Properties[$repo]) {
                    $existingRepoData = $existingActivity.PSObject.Properties[$repo].Value
                }
            }
            if ($existingRepoData) {
                $activityOutput[$repo] = $existingRepoData
                Write-Warning "Activity fetch failed for $repo; preserving existing activity data."
            } else {
                Write-Warning "Activity fetch failed for $repo and no existing activity data found; omitting from output."
            }
            continue
        }

        $repoObj = [ordered]@{}
        foreach ($m in ($repoMaintainers | Sort-Object)) {
            $mergeCount = 0
            $topPaths   = @()
            $topLabels  = @()

            if ($repoAcc -and $repoAcc.ContainsKey($m)) {
                $acc = $repoAcc[$m]
                $mergeCount = if ($acc.count) { [int]$acc.count } else { 0 }

                # Top 10 path prefixes by frequency, with Name as a stable tie-breaker
                $topPaths = @($acc.paths |
                    Group-Object |
                    Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } |
                    Select-Object -First 10 |
                    ForEach-Object { $_.Name })

                # Top 5 area-* labels by frequency, with Name as a stable tie-breaker
                $topLabels = @($acc.labels |
                    Group-Object |
                    Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } |
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
