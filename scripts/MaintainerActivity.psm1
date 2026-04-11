<#
.SYNOPSIS
    Helpers for activity-based fallback reviewer selection.
#>

<#
.SYNOPSIS
    Scores maintainers by their activity signals and selects the top 2 as fallback reviewers.
.DESCRIPTION
    When a PR has no CODEOWNERS or area-label owners, this function selects the top 2 maintainers
    from the full maintainer pool using per-maintainer activity signals from maintainer-activity.json.

    Scoring per maintainer (excluding the PR author):
      +3  if any changed file path prefix (first 2 segments) matches maintainer's top_paths
      +2  if any PR area-* label matches maintainer's top_area_labels
      +min(merge_count / 10, 1)  activity bonus, capped at 1

    Tie-breaking: score desc → merge_count desc → login alphabetical (for determinism).

    If all scores are 0 (no activity data or no matches), falls back to top 2 by merge_count.
    If merge_counts are also all 0, picks the first 2 alphabetically.

.PARAMETER Maintainers
    Array of maintainer login names (from maintainers.json for the repo).

.PARAMETER ExcludeLogin
    The PR author login to exclude from the candidates (cannot review their own PR).

.PARAMETER Repo
    Repository slug (e.g., "dotnet/runtime") used to look up activity data.

.PARAMETER ActivityData
    Hashtable or PSCustomObject parsed from maintainer-activity.json.
    May be $null if the file was not loaded or the repo has no entry.

.PARAMETER ChangedFilePaths
    Array of file paths changed by the PR (first 100, best-effort).

.PARAMETER AreaLabels
    Array of area-* label names from the PR.
#>
function Select-FallbackReviewers {
    [CmdletBinding()]
    param(
        [string[]]$Maintainers,
        [string]$ExcludeLogin,
        [string]$Repo,
        $ActivityData,
        [string[]]$ChangedFilePaths,
        [string[]]$AreaLabels
    )

    # Compute first-2-segment path prefixes for the PR's changed files.
    # NOTE: This bucketing logic must stay in sync with Update-Maintainers.ps1,
    # which applies the same 2-segment prefix when collecting activity data.
    $prFilePrefixes = @($ChangedFilePaths | Where-Object { $_ } | ForEach-Object {
        $parts = $_ -split '/'
        if ($parts.Count -ge 2) { "$($parts[0])/$($parts[1])" } else { $parts[0] }
    } | Select-Object -Unique)

    # Locate the per-repo activity map (supports both hashtable and PSCustomObject from ConvertFrom-Json)
    $repoActivity = $null
    if ($ActivityData) {
        if ($ActivityData -is [hashtable] -and $ActivityData.ContainsKey($Repo)) {
            $repoActivity = $ActivityData[$Repo]
        } elseif ($ActivityData.PSObject.Properties[$Repo]) {
            $repoActivity = $ActivityData.PSObject.Properties[$Repo].Value
        }
    }

    $scores = [System.Collections.Generic.List[PSCustomObject]]@()
    foreach ($m in $Maintainers) {
        if ($m -eq $ExcludeLogin) { continue }

        $score = 0.0
        $mergeCount = 0

        # Look up this maintainer's activity entry
        $actData = $null
        if ($repoActivity) {
            if ($repoActivity -is [hashtable] -and $repoActivity.ContainsKey($m)) {
                $actData = $repoActivity[$m]
            } elseif ($repoActivity.PSObject.Properties[$m]) {
                $actData = $repoActivity.PSObject.Properties[$m].Value
            }
        }

        if ($actData) {
            $topPaths  = @($actData.top_paths  | Where-Object { $_ })
            $topLabels = @($actData.top_area_labels | Where-Object { $_ })
            $mergeCount = if ($actData.merge_count) { [int]$actData.merge_count } else { 0 }

            # +3 if any PR file prefix matches maintainer's top_paths
            if (@($topPaths | Where-Object { $prFilePrefixes -contains $_ }).Count -gt 0) {
                $score += 3
            }
            # +2 if any PR area-* label matches maintainer's top_area_labels
            if (@($topLabels | Where-Object { $AreaLabels -contains $_ }).Count -gt 0) {
                $score += 2
            }
            # +min(merge_count / 10, 1)
            $score += [Math]::Min($mergeCount / 10.0, 1.0)
        }

        $scores.Add([PSCustomObject]@{ Login = $m; Score = $score; MergeCount = $mergeCount })
    }

    if ($scores.Count -eq 0) { return @() }

    # If all scores are 0, fall back to top 2 by merge_count, then alphabetically
    $allZero = ($scores | Where-Object { $_.Score -gt 0 }).Count -eq 0

    if ($allZero) {
        return @($scores |
            Sort-Object -Property @{Expression='MergeCount'; Descending=$true}, @{Expression='Login'} |
            Select-Object -First 2 |
            ForEach-Object { $_.Login })
    }

    # Pick top 2 by score desc, then merge_count desc, then login alphabetical
    return @($scores |
        Sort-Object -Property @{Expression='Score'; Descending=$true}, @{Expression='MergeCount'; Descending=$true}, @{Expression='Login'} |
        Select-Object -First 2 |
        ForEach-Object { $_.Login })
}

Export-ModuleMember -Function Select-FallbackReviewers
