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

# ─── Invoke-RepoMaintainerScan ────────────────────────────────────────────────
# Scans a single repo for merged PRs via GitHub GraphQL API with retry/backoff.
# Returns a result object with Success, MergerCounts, Activity, TotalFetched, Error.
function Invoke-RepoMaintainerScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$CutoffDate,
        [Parameter(Mandatory)][string[]]$BotLogins,
        [string]$EndDate,
        [switch]$SkipActivity,
        [string]$DisplayPrefix = '  ',
        [int]$MaxRetries = 5
    )

    $mergerCounts = @{}
    $repoActivity = @{}
    $cursor = $null
    $totalFetched = 0

    # Build the merged: filter — use a date range when EndDate is provided,
    # otherwise use the open-ended >CutoffDate syntax.
    # Note: when EndDate is set, CutoffDate is treated as the inclusive start
    # of a date range (merged:A..B). Callers (e.g. Invoke-ChunkedRepoScan)
    # are responsible for adjusting dates to preserve the desired semantics.
    $mergedFilter = if ($EndDate) { "merged:$CutoffDate..$EndDate" } else { "merged:>$CutoffDate" }

    do {
        $afterClause = if ($cursor) { ", after: `"$cursor`"" } else { "" }
        if ($SkipActivity) {
            $q = "{ search(query: `"repo:$Repo is:pr is:merged $mergedFilter`", type: ISSUE, first: 100$afterClause) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { mergedBy { login } } } } }"
        } else {
            $q = "{ search(query: `"repo:$Repo is:pr is:merged $mergedFilter`", type: ISSUE, first: 100$afterClause) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { mergedBy { login } files(first: 100) { nodes { path } } labels(first: 20) { nodes { name } } } } } }"
        }

        $result = $null
        $succeeded = $false
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
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
            if ($attempt -lt $MaxRetries) {
                $delay = $attempt * 15
                Write-Host ""
                Write-Host "${DisplayPrefix}  Attempt $attempt/$MaxRetries failed: $displayErr" -ForegroundColor Yellow
                Write-Host "${DisplayPrefix}  Retrying in ${delay}s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $delay
            } else {
                Write-Host ""
                Write-Host "${DisplayPrefix}  Attempt $attempt/$MaxRetries failed: $displayErr" -ForegroundColor Red
            }
        }
        if (-not $succeeded) {
            return [PSCustomObject]@{
                Success      = $false
                MergerCounts = $null
                Activity     = $null
                TotalFetched = $totalFetched
                Error        = "Failed after $MaxRetries attempts"
            }
        }

        $searchData = $parsed.data.search
        foreach ($node in $searchData.nodes) {
            if ($node.mergedBy -and $node.mergedBy.login) {
                $login = $node.mergedBy.login
                if ($login -notin $BotLogins) {
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

    # Add merge_count into activity entries
    if (-not $SkipActivity) {
        foreach ($login in @($mergerCounts.Keys)) {
            if ($repoActivity.ContainsKey($login)) {
                $repoActivity[$login].count = $mergerCounts[$login]
            }
        }
    }

    return [PSCustomObject]@{
        Success      = $true
        MergerCounts = $mergerCounts
        Activity     = $repoActivity
        TotalFetched = $totalFetched
        Error        = ''
    }
}

# ─── Merge-ScanResult ────────────────────────────────────────────────────────
# Merges MergerCounts and Activity from a scan result into running accumulators.
function Merge-ScanResult {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Result,
        [Parameter(Mandatory)][hashtable]$MergedCounts,
        [Parameter(Mandatory)][hashtable]$MergedActivity,
        [bool]$IncludeActivity,
        [Parameter(Mandatory)][ref]$TotalFetched
    )
    $TotalFetched.Value += $Result.TotalFetched
    if ($Result.MergerCounts) {
        foreach ($kv in $Result.MergerCounts.GetEnumerator()) {
            $MergedCounts[$kv.Key] = ($MergedCounts[$kv.Key] ?? 0) + $kv.Value
        }
    }
    if ($IncludeActivity -and $Result.Activity) {
        foreach ($kv in $Result.Activity.GetEnumerator()) {
            $login = $kv.Key
            $acc = $kv.Value
            if (-not $MergedActivity.ContainsKey($login)) {
                $MergedActivity[$login] = @{
                    paths  = [System.Collections.Generic.List[string]]@()
                    labels = [System.Collections.Generic.List[string]]@()
                    count  = 0
                }
            }
            $MergedActivity[$login].count += $acc.count
            foreach ($p in $acc.paths)  { $MergedActivity[$login].paths.Add($p) }
            foreach ($l in $acc.labels) { $MergedActivity[$login].labels.Add($l) }
        }
    }
}

# ─── Invoke-ChunkedRepoScan ──────────────────────────────────────────────────
# Retries a failed repo by splitting the date range into smaller chunks.
# Returns the same shape as Invoke-RepoMaintainerScan, with partial results
# merged across successful chunks. FailedChunks lists any ranges that failed.
function Invoke-ChunkedRepoScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$CutoffDate,
        [Parameter(Mandatory)][string[]]$BotLogins,
        [switch]$SkipActivity,
        [string]$DisplayPrefix = '  ',
        [int]$MaxRetries = 5,
        [ValidateRange(1, 365)][int]$ChunkDays = 7,
        [ValidateRange(1, 365)][int]$MinChunkDays = 1,
        [string]$EndDate   # optional: limit scan to this date instead of today
    )

    # Clamp MinChunkDays to ChunkDays if misconfigured
    if ($MinChunkDays -gt $ChunkDays) { $MinChunkDays = $ChunkDays }

    # Compute non-overlapping date ranges from (CutoffDate + 1 day) to EndDate (or today).
    # The original query uses merged:>CutoffDate (exclusive), so chunks start
    # the day after CutoffDate to preserve semantics.
    $startDate = ([datetime]::Parse($CutoffDate)).AddDays(1)
    $scanEnd = if ($EndDate) { ([datetime]::Parse($EndDate)).Date } else { (Get-Date).Date }
    if ($startDate -gt $scanEnd) {
        return [PSCustomObject]@{
            Success      = $true
            MergerCounts = @{}
            Activity     = @{}
            TotalFetched = 0
            FailedChunks = @()
            Error        = ''
        }
    }

    $chunks = [System.Collections.Generic.List[hashtable]]::new()
    $chunkStart = $startDate
    while ($chunkStart -le $scanEnd) {
        $chunkEnd = $chunkStart.AddDays($ChunkDays - 1)
        if ($chunkEnd -gt $scanEnd) { $chunkEnd = $scanEnd }
        $chunks.Add(@{
            Start = $chunkStart.ToString('yyyy-MM-dd')
            End   = $chunkEnd.ToString('yyyy-MM-dd')
        })
        $chunkStart = $chunkEnd.AddDays(1)
    }

    Write-Host ""
    Write-Host "${DisplayPrefix}Splitting into $($chunks.Count) chunk(s) of up to $ChunkDays days" -ForegroundColor Cyan

    $mergedCounts = @{}
    $mergedActivity = @{}
    $totalFetched = 0
    $anyChunkSucceeded = $false
    $failedChunks = [System.Collections.Generic.List[string]]::new()

    foreach ($chunk in $chunks) {
        Write-Host "${DisplayPrefix}  $Repo [$($chunk.Start)..$($chunk.End)] ... " -NoNewline

        $scanResult = Invoke-RepoMaintainerScan -Repo $Repo -CutoffDate $chunk.Start -EndDate $chunk.End `
            -BotLogins $BotLogins -SkipActivity:$SkipActivity -DisplayPrefix "${DisplayPrefix}  " -MaxRetries $MaxRetries

        if (-not $scanResult.Success) {
            # Check the chunk's actual span, not configured ChunkDays, to avoid
            # redundant recursion on short tail chunks (e.g., a 1-day tail when ChunkDays=7).
            $actualSpanDays = (([datetime]::Parse($chunk.End)) - ([datetime]::Parse($chunk.Start))).Days + 1
            if ($actualSpanDays -gt $MinChunkDays) {
                $subChunkDays = [Math]::Max($MinChunkDays, [Math]::Floor($actualSpanDays / 2))
                Write-Host "FAILED — sub-chunking to ${subChunkDays}-day ranges" -ForegroundColor Yellow
                # CutoffDate is chunk.Start minus 1 day because the function adds 1 day back
                $subCutoff = ([datetime]::Parse($chunk.Start)).AddDays(-1).ToString('yyyy-MM-dd')
                $subResult = Invoke-ChunkedRepoScan -Repo $Repo -CutoffDate $subCutoff -EndDate $chunk.End `
                    -BotLogins $BotLogins -SkipActivity:$SkipActivity -DisplayPrefix "${DisplayPrefix}  " `
                    -MaxRetries $MaxRetries -ChunkDays $subChunkDays -MinChunkDays $MinChunkDays

                # Merge successful sub-chunk results
                Merge-ScanResult -Result $subResult -MergedCounts $mergedCounts -MergedActivity $mergedActivity -IncludeActivity (-not $SkipActivity) -TotalFetched ([ref]$totalFetched)
                # Propagate any sub-chunk failures
                if ($subResult.FailedChunks) {
                    foreach ($fc in $subResult.FailedChunks) { $failedChunks.Add($fc) }
                }
                if ($subResult.Success) { $anyChunkSucceeded = $true }
                continue
            }

            Write-Host "FAILED ($($scanResult.Error))" -ForegroundColor Red
            $failedChunks.Add("$($chunk.Start)..$($chunk.End)")
            continue
        }

        $anyChunkSucceeded = $true
        Write-Host "$($scanResult.TotalFetched) PRs" -ForegroundColor Green
        Merge-ScanResult -Result $scanResult -MergedCounts $mergedCounts -MergedActivity $mergedActivity -IncludeActivity (-not $SkipActivity) -TotalFetched ([ref]$totalFetched)
    }

    $anySuccess = $anyChunkSucceeded
    $errorMsg = ''
    if ($failedChunks.Count -gt 0) {
        $errorMsg = "Failed chunks: $($failedChunks -join ', ')"
    }

    return [PSCustomObject]@{
        Success      = $anySuccess
        MergerCounts = $mergedCounts
        Activity     = $mergedActivity
        TotalFetched = $totalFetched
        FailedChunks = $failedChunks
        Error        = $errorMsg
    }
}

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
$largeRepos = [System.Collections.Generic.HashSet[string]]@($repos | Where-Object { $_.largeRepo -eq $true } | ForEach-Object { $_.repo })
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

    $repoSkipActivity = $SkipActivity -or ($repo -in $largeRepos)
    if ($repoSkipActivity -and -not $SkipActivity) {
        Write-Host "(large repo, skip-activity) " -NoNewline -ForegroundColor DarkGray
    }

    $scanResult = Invoke-RepoMaintainerScan -Repo $repo -CutoffDate $cutoffDate -BotLogins $botLogins -SkipActivity:$repoSkipActivity

    if (-not $scanResult.Success) {
        Write-Host "  ERROR querying $repo ($($scanResult.Error)) — queued for retry" -ForegroundColor Red
        $failedRepos.Add($entry)
        $updated[$repo] = @($existing[$repo] ?? @())
        continue
    }

    $mergerCounts = $scanResult.MergerCounts
    if (-not $repoSkipActivity) {
        $activityAccum[$repo] = $scanResult.Activity
    }
    $discovered = @($mergerCounts.GetEnumerator() |
        Where-Object { $_.Value -ge $MinMerges } |
        Sort-Object Value -Descending |
        ForEach-Object { $_.Key })

    # Union with existing
    $existingForRepo = @($existing[$repo] ?? @())
    $merged = @($existingForRepo + $discovered | Sort-Object -Unique)

    $added = @($merged | Where-Object { $_ -notin $existingForRepo })

    $updated[$repo] = $merged

    Write-Host "$($scanResult.TotalFetched) merged PRs, $($discovered.Count) qualifying mergers" -NoNewline
    if ($added.Count -gt 0) {
        Write-Host " (+$($added.Count) new: $($added -join ', '))" -ForegroundColor Green
    } else {
        Write-Host " (no changes)" -ForegroundColor DarkGray
    }
}

# ─── Second pass: retry failed repos using chunked date ranges ────────────────
# When a repo fails all retries (typically persistent 502 for large repos),
# splitting the date range into smaller chunks often succeeds because each
# chunk queries fewer results. A 60s cooldown gives the API time to recover.
if ($failedRepos.Count -gt 0) {
    $retryDelay = 60
    Write-Host ""
    Write-Host "Retrying $($failedRepos.Count) failed repo(s) with chunked date ranges after ${retryDelay}s cooldown..." -ForegroundColor Yellow
    Start-Sleep -Seconds $retryDelay

    foreach ($entry in $failedRepos) {
        $repo = $entry.repo
        Write-Host "  $repo (chunked retry) ..."

        $repoSkipActivity = $SkipActivity -or ($repo -in $largeRepos)
        $scanResult = Invoke-ChunkedRepoScan -Repo $repo -CutoffDate $cutoffDate -BotLogins $botLogins -SkipActivity:$repoSkipActivity -DisplayPrefix '  '

        if (-not $scanResult.Success) {
            Write-Host "  ERROR querying $repo on chunked retry (giving up)" -ForegroundColor Red
            if ($scanResult.FailedChunks -and $scanResult.FailedChunks.Count -gt 0) {
                Write-Host "    Failed chunks: $($scanResult.FailedChunks -join ', ')" -ForegroundColor DarkGray
            }
            continue
        }

        if ($scanResult.PSObject.Properties['FailedChunks'] -and $scanResult.FailedChunks.Count -gt 0) {
            Write-Host "    Partial success — failed chunks: $($scanResult.FailedChunks -join ', ')" -ForegroundColor Yellow
        }

        $mergerCounts = $scanResult.MergerCounts
        if (-not $repoSkipActivity) {
            $activityAccum[$repo] = $scanResult.Activity
        }

        $discovered = @($mergerCounts.GetEnumerator() |
            Where-Object { $_.Value -ge $MinMerges } |
            Sort-Object Value -Descending |
            ForEach-Object { $_.Key })

        $existingForRepo = @($existing[$repo] ?? @())
        $merged = @($existingForRepo + $discovered | Sort-Object -Unique)
        $added = @($merged | Where-Object { $_ -notin $existingForRepo })
        $updated[$repo] = $merged

        Write-Host "$($scanResult.TotalFetched) merged PRs, $($discovered.Count) qualifying mergers" -NoNewline
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
