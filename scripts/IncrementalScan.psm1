<#
.SYNOPSIS
    Helpers for incremental PR scanning — extracted for testability.
    Used by Get-PrTriageData.ps1 to skip expensive GraphQL calls for unchanged PRs.
#>

# Cache version — bump when scoring logic or output schema changes.
$script:CacheVersion = 2

# Max age in seconds before a cached entry is considered stale (used as default for Get-IncrementalPartition).
$script:MaxReuseSec = 12 * 3600

function Get-IncrementalCacheVersion { $script:CacheVersion }

function Get-PrFingerprint {
    <#
    .SYNOPSIS
        Build a fingerprint from cheap PR list data for change detection.
        Changes to any of these fields trigger a full GraphQL re-fetch for that PR.
    #>
    param([Parameter(Mandatory)]$pr)
    $labelsSorted = ($pr.labels | ForEach-Object { $_.name } | Sort-Object) -join ','
    $assigneesSorted = ($pr.assignees | ForEach-Object { $_.login } | Sort-Object) -join ','
    return "$($pr.updatedAt)|$($pr.mergeable)|$($pr.isDraft)|$labelsSorted|$assigneesSorted|$($pr.changedFiles)|$($pr.additions)|$($pr.deletions)"
}

function Import-PreviousScan {
    <#
    .SYNOPSIS
        Load and validate a previous scan.json for incremental reuse.
    .OUTPUTS
        Hashtable with keys: Enabled, PrLookup, Fingerprints, Timestamp
    #>
    param(
        [string]$Path,
        [int]$RequiredCacheVersion,
        [string]$Repo = ''
    )
    $result = @{ Enabled = $false; PrLookup = @{}; Fingerprints = @{}; Timestamp = $null }
    if (-not $Path -or -not (Test-Path $Path)) { return $result }
    try {
        $prevScan = Get-Content $Path -Raw | ConvertFrom-Json
        if ($prevScan._cache_version -eq $RequiredCacheVersion -and $prevScan.prs) {
            # Validate repo matches to prevent cross-repo PR number collisions.
            # If prevScan.repo is absent (legacy scans pre-dating the repo field), allow
            # incremental mode rather than forcing a full scan for existing deployments.
            if ($Repo -and $prevScan.repo -and $prevScan.repo -ne $Repo) {
                Write-Warning "Previous scan repo '$($prevScan.repo)' does not match current repo '$Repo' — disabling incremental mode"
                return $result
            }
            if ($Repo -and -not $prevScan.repo) {
                Write-Verbose "Previous scan has no repo field (legacy) — proceeding with incremental mode for '$Repo'"
            }
            foreach ($p in $prevScan.prs) {
                $key = [string]$p.number
                $result.PrLookup[$key] = $p
                if ($p._fingerprint) { $result.Fingerprints[$key] = $p._fingerprint }
            }
            $result.Timestamp = if ($prevScan.timestamp) { [DateTime]::Parse($prevScan.timestamp) } else { $null }
            $result.Enabled = $true
        }
    } catch {
        # Fail safe: return disabled — caller will do a full scan
    }
    return $result
}

function Get-IncrementalPartition {
    <#
    .SYNOPSIS
        Partition PR candidates into refresh vs reuse sets.
    .DESCRIPTION
        Compares current PR fingerprints against previous scan data.
        PRs are forced to refresh when:
        - No previous entry or fingerprint exists (new PR)
        - Fingerprint changed (labels, mergeable, draft status, etc.)
        - Previous CI was anything other than SUCCESS (e.g. IN_PROGRESS, ABSENT, or FAILURE)
        - Previous mergeable was UNKNOWN
        - Cache TTL exceeded (MaxReuseSeconds)
        - Previous entry is missing required fields (corrupt)
    .OUTPUTS
        Hashtable with keys: RefreshCandidates, ReusedEntries, Fallback
    #>
    param(
        [array]$Candidates,
        [hashtable]$PreviousPrLookup,
        [hashtable]$PreviousFingerprints,
        [AllowNull()][Nullable[DateTime]]$PreviousTimestamp = $null,
        [int]$MaxReuseSeconds = $script:MaxReuseSec
    )
    $result = @{
        RefreshCandidates = $Candidates
        ReusedEntries = @{}
        Fallback = $false
    }

    try {
        $refresh = [System.Collections.ArrayList]@()
        $reused = @{}
        $now = Get-Date

        foreach ($pr in $Candidates) {
            $key = [string]$pr.number
            $currentFp = Get-PrFingerprint $pr
            $prevEntry = $PreviousPrLookup[$key]
            $prevFp = $PreviousFingerprints[$key]
            $mustRefresh = $false

            if (-not $prevEntry -or -not $prevFp) {
                $mustRefresh = $true
            } elseif ($currentFp -ne $prevFp) {
                $mustRefresh = $true
            } elseif ($prevEntry.ci -ne 'SUCCESS') {
                $mustRefresh = $true  # non-success CI can change via rerun without PR fields changing
            } elseif ($prevEntry.mergeable -eq 'UNKNOWN') {
                $mustRefresh = $true
            } else {
                # Per-PR TTL: use _refreshed_at (when this PR was last fully analyzed)
                # Falls back to PreviousTimestamp for entries from before _refreshed_at was added
                $refreshedAt = $null
                if ($prevEntry._refreshed_at) {
                    try { $refreshedAt = [datetime]$prevEntry._refreshed_at } catch { }
                }
                if (-not $refreshedAt -and $PreviousTimestamp) {
                    $refreshedAt = $PreviousTimestamp
                }
                if (-not $refreshedAt) {
                    $refreshedAt = [datetime]::MinValue
                }
                $prAgeSec = ($now - $refreshedAt).TotalSeconds
                if ($prAgeSec -gt $MaxReuseSeconds) {
                    $mustRefresh = $true
                }
            }

            if ($mustRefresh) {
                [void]$refresh.Add($pr)
            } else {
                if ($prevEntry.number -and $null -ne $prevEntry.score -and $prevEntry.next_action) {
                    $reused[$key] = $prevEntry
                } else {
                    [void]$refresh.Add($pr)
                }
            }
        }
        $result.RefreshCandidates = @($refresh)
        $result.ReusedEntries = $reused
    } catch {
        $result.RefreshCandidates = $Candidates
        $result.ReusedEntries = @{}
        $result.Fallback = $true
    }

    return $result
}

function Merge-ReusedEntries {
    <#
    .SYNOPSIS
        Merge carried-forward PR entries into the results array, updating fingerprints.
    .PARAMETER ReusedEntries
        Hashtable of {string key -> previous scan entry} from Get-IncrementalPartition.
    .PARAMETER PrListData
        Array of raw PR objects from gh pr list (used to refresh fingerprints).
    .PARAMETER Results
        Array of freshly-scored PR result objects to merge into.
    .OUTPUTS
        Combined array of results + reused entries with updated fingerprints.
    #>
    param(
        [hashtable]$ReusedEntries,
        [array]$PrListData,
        [array]$Results
    )
    if ($ReusedEntries.Count -eq 0) { return $Results }

    $byNumber = @{}
    foreach ($p in $PrListData) { $byNumber[[string]$p.number] = $p }

    $merged = [System.Collections.ArrayList]@($Results)
    foreach ($entry in $ReusedEntries.Values) {
        $listPr = $byNumber[[string]$entry.number]
        if ($listPr) {
            # Only update _fingerprint for next-run comparison.
            # age_days/days_since_update and _refreshed_at are intentionally NOT updated:
            # updating age without recomputing score/next_action would make scan.json
            # internally inconsistent. _refreshed_at must reflect when the PR was last
            # fully analyzed, so the per-PR TTL can eventually force a re-fetch.
            $entry._fingerprint = Get-PrFingerprint $listPr
        }
        [void]$merged.Add($entry)
    }
    return @($merged)
}

Export-ModuleMember -Function Get-PrFingerprint, Import-PreviousScan, Get-IncrementalPartition, Get-IncrementalCacheVersion, Merge-ReusedEntries
