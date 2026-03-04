<#
.SYNOPSIS
    Orchestrates PR triage report generation for a single repo.
.DESCRIPTION
    Reads a full-scan JSON file from Get-PrTriageData.ps1, produces filtered HTML reports
    in docs/{Slug}/, and writes meta.json for the index page.
.PARAMETER ScanFile
    Path to the full-scan JSON output from Get-PrTriageData.ps1.
.PARAMETER DocsDir
    Root output directory (default: docs/).
.PARAMETER Repo
    Repository slug (e.g., dotnet/runtime).
.PARAMETER Slug
    Short name for subdirectory (e.g., "runtime", "aspnetcore").
.PARAMETER ReportTypes
    Which reports to generate: top15, community, quick-wins. Default: all three.
.PARAMETER SkipAI
    If set, skip AI observation generation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScanFile,
    [string]$DocsDir = "docs",
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Slug,
    [string[]]$ReportTypes = @("top15", "community", "quick-wins", "stale-close"),
    [int]$ScheduleHours = 0,
    [switch]$SkipAI
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

# Handle comma-separated string from bash (e.g., "top15,quick-wins" becomes one string element)
if ($ReportTypes.Count -eq 1 -and $ReportTypes[0] -match ',') {
    $ReportTypes = $ReportTypes[0] -split ','
}

$scan = Get-Content $ScanFile -Raw | ConvertFrom-Json
$allPrs = $scan.prs
$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")
$timestampIso = (Get-Date).ToUniversalTime().ToString("o")

$outDir = Join-Path $DocsDir $Slug
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# --- All possible report definitions ---
$allReports = @{
    "top15" = @{
        Id       = "top15"
        Title    = "Most Actionable PRs"
        File     = "actionable.html"
        Filter   = { param($prs) @($prs | Select-Object -First 500) }
        AiPrompt = "These are the most actionable PRs in $Repo ranked by merge-readiness score."
    }
    "community" = @{
        Id       = "community"
        Title    = "Community PRs Awaiting Review"
        File     = "community.html"
        Filter   = { param($prs) @($prs | Where-Object { $_.is_community -and $_.next_action -match "review" }) }
        AiPrompt = "These are community-contributed PRs that are awaiting maintainer review in $Repo. Note that community PRs may need more shepherding and may not align with current investment priorities."
    }
    "quick-wins" = @{
        Id       = "quick-wins"
        Title    = "Quick Wins: Ready to Merge"
        File     = "quick-wins.html"
        Filter   = { param($prs) @($prs | Where-Object { $_.next_action -match "Ready to merge" }) }
        AiPrompt = "These PRs in $Repo appear ready to merge (CI green, approved, no unresolved threads)."
    }
    "stale-close" = @{
        Id       = "stale-close"
        Title    = "Consider Closing"
        File     = "consider-closing.html"
        Filter   = { param($prs) @($prs | Where-Object {
            ($_.age_days -gt 90 -and $_.days_since_update -gt 30) -or
            ($_.age_days -gt 180 -and $_.days_since_update -gt 14)
        } | Sort-Object -Property days_since_update -Descending) }
        AiPrompt = "These PRs in $Repo are old and stale — likely abandoned or superseded. Identify which ones seem most clearly closeable and why."
    }
}

$reports = @($ReportTypes | ForEach-Object { $allReports[$_] } | Where-Object { $_ })

# Build nav links for this repo's reports
$navLinks = @{ "Home" = "../index.html" }
foreach ($r in $reports) { $navLinks[$r.Title] = $r.File }

# Track PR counts for meta.json
$reportMeta = @{}

# --- Generate each report ---
foreach ($report in $reports) {
    Write-Host "Generating $Slug/$($report.Id)..."

    $filtered = & $report.Filter $allPrs
    if ($null -eq $filtered) { $filtered = @() }
    $filteredArray = @($filtered)

    $reportMeta[$report.Id] = @{ count = $filteredArray.Count; file = $report.File; title = $report.Title }

    # Write filtered JSON to temp file
    $tempJson = Join-Path $outDir "$($report.Id)-data.json"
    $filteredArray | ConvertTo-Json -Depth 5 | Out-File -FilePath $tempJson -Encoding utf8

    # Generate AI observations
    $observations = ""
    if (-not $SkipAI -and $filteredArray.Count -gt 0) {
        try {
            $summary = $filteredArray | ForEach-Object {
                "#$($_.number) score=$($_.score) ci=$($_.ci) action=`"$($_.next_action)`" who=`"$($_.who)`" threads=$($_.unresolved_threads) age=$($_.age_days)d community=$($_.is_community) author=$($_.author)"
            }
            $summaryText = $summary -join "`n"

            $prompt = @"
$($report.AiPrompt)

Here is the data (one line per PR):
$summaryText

Generate 3-5 concise bullet-point observations that are actionable for maintainers. Focus on:
- Quick wins (high score, no threads, just needs a click)
- Expensive/blocked PRs (heavy discussion, conflicts)
- Patterns (one reviewer is a bottleneck, cluster of stale PRs)
- Community PR shepherding notes
Do NOT repeat what's in the table. Output ONLY the bullet points, each starting with "- ".
"@
            Write-Host "  Calling AI for observations..."
            $aiOutput = ($prompt | gh models run openai/gpt-4o 2>&1)
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "AI observation generation failed, continuing without observations"
                $aiOutput = ""
            }
            $observations = if ($aiOutput -is [array]) { $aiOutput -join "`n" } else { [string]$aiOutput }
        } catch {
            Write-Warning "AI observation generation failed: $_"
            $observations = ""
        }
    }

    # Convert to HTML
    $htmlParams = @{
        InputFile     = $tempJson
        Title         = "$($report.Title) — $Repo"
        Observations  = $observations
        Repo          = $Repo
        OutputFile    = Join-Path $outDir $report.File
        Timestamp     = $timestamp
        ScheduleHours = $ScheduleHours
        NavLinks      = $navLinks
    }
    & "$scriptDir\ConvertTo-ReportHtml.ps1" @htmlParams

    Remove-Item $tempJson -ErrorAction SilentlyContinue
    Write-Host "  -> $Slug/$($report.File) ($($filteredArray.Count) PRs)"
}

# --- Write meta.json ---
$meta = @{
    repo     = $Repo
    slug     = $Slug
    updated  = $timestampIso
    scanned  = $scan.scanned
    analyzed = $scan.analyzed
    drafts   = if ($scan.screened_out) { [int]$scan.screened_out.drafts_count } else { 0 }
    bots     = if ($scan.screened_out -and $scan.screened_out.bots) { @($scan.screened_out.bots).Count } else { 0 }
    elapsed  = $scan.elapsed_seconds
    reports  = $reportMeta
}
$meta | ConvertTo-Json -Depth 3 | Out-File -FilePath (Join-Path $outDir "meta.json") -Encoding utf8

# --- Fetch recently merged PRs and append history ---
$historyFile = Join-Path $outDir "history.json"
[System.Collections.ArrayList]$existingHistory = @()
if (Test-Path $historyFile) {
    $parsed = Get-Content $historyFile -Raw | ConvertFrom-Json
    if ($parsed) {
        foreach ($item in @($parsed)) { $existingHistory.Add($item) | Out-Null }
    }
}

# Compute age stats from scan data
$ages = @($allPrs | ForEach-Object { [int]$_.age_days } | Sort-Object)
$openCount = $ages.Count
$medianAge = if ($ages.Count -gt 0) { $ages[[math]::Floor($ages.Count / 2)] } else { 0 }
$p90Age = if ($ages.Count -gt 0) { $ages[[math]::Floor($ages.Count * 0.9)] } else { 0 }

# Helper: fetch merged PRs for a given period via GraphQL (includes labels for community detection)
function Get-MergedPrs {
    param([string]$RepoName, [int]$Days)
    $cutoff = (Get-Date).AddDays(-$Days).ToString("yyyy-MM-dd")
    $all = @()
    $cur = $null
    do {
        $after = if ($cur) { ", after: `"$cur`"" } else { "" }
        $q = "query { search(query: `"repo:$RepoName is:pr is:merged merged:>$cutoff`", type: ISSUE, first: 100$after) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { number mergedBy { login } labels(first: 10) { nodes { name } } } } } }"
        $res = gh api graphql -f query="$q" 2>$null | ConvertFrom-Json
        $s = $res.data.search
        $all += @($s.nodes)
        $cur = if ($s.pageInfo.hasNextPage) { $s.pageInfo.endCursor } else { $null }
    } while ($cur)
    return $all
}

# Fetch merged PRs in last 7 days
$merged7d = 0
$topMergers = @{}
$topCommunityMergers = @{}
try {
    $allMerged = @(Get-MergedPrs -RepoName $Repo -Days 7)
    $merged7d = $allMerged.Count
    foreach ($pr in $allMerged) {
        $merger = if ($pr.mergedBy -and $pr.mergedBy.login) { $pr.mergedBy.login } else { "unknown" }
        $topMergers[$merger] = if ($topMergers.ContainsKey($merger)) { $topMergers[$merger] + 1 } else { 1 }
        # Check if community PR
        $isCommunity = $false
        if ($pr.labels -and $pr.labels.nodes) {
            $isCommunity = @($pr.labels.nodes | Where-Object { $_.name -match '^community' }).Count -gt 0
        }
        if ($isCommunity) {
            $topCommunityMergers[$merger] = if ($topCommunityMergers.ContainsKey($merger)) { $topCommunityMergers[$merger] + 1 } else { 1 }
        }
    }
    Write-Host "  Merged in last 7d: $merged7d (community: $($topCommunityMergers.Values | Measure-Object -Sum | Select-Object -ExpandProperty Sum))"
} catch {
    Write-Warning "Failed to fetch merged PRs: $_"
}

# Count PRs opened in last 7 days (from scan data — created_at not available, use age_days)
$opened7d = @($allPrs | Where-Object { [int]$_.age_days -le 7 }).Count

$historyEntry = [ordered]@{
    date                     = $timestampIso
    open                     = $openCount
    median_age_days          = $medianAge
    p90_age_days             = $p90Age
    merged_7d                = $merged7d
    opened_7d                = $opened7d
    top_mergers_7d           = $topMergers
    top_community_mergers_7d = $topCommunityMergers
}
$existingHistory.Add([PSCustomObject]$historyEntry) | Out-Null
# Keep last 90 days (~180 entries at 12h cadence)
$cutoffDate = (Get-Date).AddDays(-90).ToUniversalTime().ToString("o")
$trimmed = @($existingHistory | Where-Object { $_.date -gt $cutoffDate })
ConvertTo-Json -InputObject @($trimmed) -Depth 4 | Out-File -FilePath $historyFile -Encoding utf8
Write-Host "  History: $($trimmed.Count) entries in $historyFile"

Write-Host "Done! $($reports.Count) reports in $outDir/"
