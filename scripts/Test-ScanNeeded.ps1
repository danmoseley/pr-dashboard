<#
.SYNOPSIS
    Lightweight probe to check whether a full/incremental scan is needed for a repo.
    Makes a single cheap GraphQL query and compares against the previous scan.
.DESCRIPTION
    Returns "true" (scan needed) or "false" (safe to skip).
    Fail-safe: any error returns "true" (always scan when in doubt).
.PARAMETER Repo
    Repository in owner/repo format.
.PARAMETER PreviousScanFile
    Path to the previous scan.json for this repo.
.PARAMETER MaxSkipSeconds
    Maximum age of previous scan before forcing a rescan regardless of probe result.
    Default: 10800 (3 hours). Should be well under the incremental TTL (12h).
#>
param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$PreviousScanFile,
    [int]$MaxSkipSeconds = 10800
)

# Fail-safe wrapper: any unhandled error → scan needed
try {
    if (-not (Test-Path $PreviousScanFile)) {
        Write-Host "true"  # No previous scan — must scan
        exit 0
    }

    $prevScan = Get-Content $PreviousScanFile -Raw | ConvertFrom-Json

    # Check previous scan timestamp — don't skip if too old
    if ($prevScan.timestamp) {
        $age = ((Get-Date) - [DateTime]::Parse($prevScan.timestamp)).TotalSeconds
        if ($age -gt $MaxSkipSeconds) {
            Write-Verbose "Previous scan is $([int]($age/60))m old (max $([int]($MaxSkipSeconds/60))m) — scan needed"
            Write-Host "true"
            exit 0
        }
    } else {
        Write-Host "true"  # No timestamp — must scan
        exit 0
    }

    # Check for unstable PRs in previous scan — don't skip if any exist
    if ($prevScan.prs) {
        $unstable = @($prevScan.prs | Where-Object {
            ($_.ci -and $_.ci -ne 'SUCCESS') -or
            ($_.mergeable -and $_.mergeable -eq 'UNKNOWN')
        })
        if ($unstable.Count -gt 0) {
            Write-Verbose "$($unstable.Count) unstable PRs in previous scan — scan needed"
            Write-Host "true"
            exit 0
        }
    }

    # Check for previous probe hash
    if (-not $prevScan._probe_hash) {
        Write-Host "true"  # No probe hash stored — must scan
        exit 0
    }

    # Cheap GraphQL query: get open PR numbers + updatedAt
    $owner, $name = $Repo -split '/', 2
    $query = @"
query {
  repository(owner: "$owner", name: "$name") {
    pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
      totalCount
      nodes { number updatedAt }
      pageInfo { hasNextPage endCursor }
    }
  }
}
"@
    $result = gh api graphql -f query="$query" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Verbose "GraphQL probe failed — scan needed"
        Write-Host "true"
        exit 0
    }
    $data = $result | ConvertFrom-Json
    $prData = $data.data.repository.pullRequests

    # If more than 100 open PRs, probe hash can't match full scan hash — must scan
    if ($prData.pageInfo.hasNextPage) {
        Write-Verbose "More than 100 open PRs ($($prData.totalCount)) — scan needed"
        Write-Host "true"
        exit 0
    }

    $pairs = @($prData.nodes | ForEach-Object { "$($_.number):$($_.updatedAt)" } | Sort-Object)
    $hashInput = "total=$($prData.totalCount)|" + ($pairs -join '|')

    # Hash the probe data
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput)
    $probeHash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').Substring(0, 16).ToLower()

    if ($probeHash -eq $prevScan._probe_hash) {
        Write-Verbose "Probe hash unchanged ($probeHash) — skip scan"
        Write-Host "false"
    } else {
        Write-Verbose "Probe hash changed (was $($prevScan._probe_hash), now $probeHash) — scan needed"
        Write-Host "true"
    }
} catch {
    Write-Verbose "Probe error: $_ — scan needed (fail-safe)"
    Write-Host "true"
}
