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
.PARAMETER SkipHistory
    If set, skip fetching merged PR stats via GraphQL and updating history.json.
    Use for offline/CI validation where API access is unavailable.
.PARAMETER ScheduleDesc
    Human-readable schedule description (e.g., "~twice daily") displayed in
    the report meta line. Passed through to ConvertTo-ReportHtml.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScanFile,
    [string]$DocsDir = "docs",
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Slug,
    [string[]]$ReportTypes = @("top15", "community", "quick-wins", "stale-close"),
    [string]$ScheduleDesc = "",
    [switch]$SkipAI,
    [switch]$SkipHistory
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

# Handle comma-separated string from bash (e.g., "top15,quick-wins" becomes one string element)
if ($ReportTypes.Count -eq 1 -and $ReportTypes[0] -match ',') {
    $ReportTypes = $ReportTypes[0] -split ','
}

$scan = Get-Content $ScanFile -Raw | ConvertFrom-Json

# Validate scan data
if (-not $scan -or -not $scan.prs) {
    if ($scan.error) {
        Write-Host "::warning::Scan reported error for ${Repo}: $($scan.error) — generating empty reports"
        $scan = @{ scanned = 0; analyzed = 0; prs = @() }
    } else {
        throw "Invalid scan file: $ScanFile — missing or has no .prs array"
    }
}
$allPrs = $scan.prs

# --- Enrich PRs with triple scores (merge readiness, value, action) ---
# Computes from cached fields so Regen-Html works without API calls.
foreach ($pr in $allPrs) {
    # Skip if already fully computed (all fields present from live API path)
    if ($null -ne $pr.action_score -and $null -ne $pr.merge_readiness -and
        $null -ne $pr.value_score -and $null -ne $pr.value_why -and $null -ne $pr.action_why) { continue }

    # --- Merge Readiness: calibrated weights from analysis (total 20.0) ---
    $ciS = switch ($pr.ci) { "SUCCESS" { 1.0 } "IN_PROGRESS" { 0.5 } default { 0.0 } }
    $conflictS = switch ($pr.mergeable) { "MERGEABLE" { 1.0 } "UNKNOWN" { 0.5 } "CONFLICTING" { 0.0 } default { 0.5 } }
    $hasNAA = $pr.blockers -match 'needs-author-action'
    $noReview = $pr.blockers -match 'No review'
    $noOwner = $pr.blockers -match 'No owner approval'
    $staleApproval = $pr.blockers -match 'Approval not on latest'
    $maintS = if ($noReview) { 0.0 } elseif ($noOwner) { 0.5 } else { 1.0 }
    $feedbackS = if ($hasNAA) { 0.0 } elseif ([int]$pr.unresolved_threads -eq 0) { 1.0 } else { 0.5 }
    $approvalS = if ([int]$pr.approval_count -ge 2) { 1.0 } elseif ([int]$pr.approval_count -ge 1) { 0.5 } else { 0.0 }
    if ($staleApproval -and $approvalS -gt 0) { $approvalS = [Math]::Max(0, $approvalS - 0.25) }
    $dsu = [int]$pr.days_since_update
    $dsr = if ($null -ne $pr.days_since_review) { [int]$pr.days_since_review } else { $dsu }
    $stalenessS = if ($dsu -le 3) { 1.0 } elseif ($dsu -le 14) { 0.5 } else { 0.0 }
    $tt = [int]$pr.total_threads; $dc = [int]$pr.distinct_commenters
    $discussionS = if ($tt -le 5 -and $dc -le 2) { 1.0 } elseif ($dsr -le 14) { 0.75 } elseif ($tt -le 15 -and $dc -le 5) { 0.5 } else { 0.0 }
    $freshS = if ($dsu -le 14) { 1.0 } elseif ($dsu -le 30) { 0.5 } else { 0.0 }
    $isTrivial = [int]$pr.changed_files -le 2 -and [int]$pr.lines_changed -le 20
    $sizeS = if ($isTrivial) { 1.5 } elseif ([int]$pr.changed_files -le 5 -and [int]$pr.lines_changed -le 200) { 1.0 } elseif ([int]$pr.changed_files -le 20 -and [int]$pr.lines_changed -le 500) { 0.5 } else { 0.0 }
    $communityS = if ($pr.is_community) { 0.5 } else { 1.0 }
    $alignS = if ($pr.area_labels -and @($pr.area_labels).Count -gt 0) { 1.0 } else { 0.0 }
    $velocityS = if ($dsu -le 7) { 1.0 } elseif ($dsu -le 14) { 0.5 } else { 0.0 }

    $mergeRaw = ($ciS * 2.5) + ($conflictS * 3.0) + ($approvalS * 2.5) + ($maintS * 1.5) +
        ($feedbackS * 2.5) + ($discussionS * 2.5) + ($sizeS * 2.0) + ($communityS * 1.0) +
        ($stalenessS * 1.0) + ($freshS * 0.7) + ($alignS * 0.5) + ($velocityS * 0.3)
    $mergeReadiness = [Math]::Round([Math]::Min(($mergeRaw / 20.0) * 10, 10.0), 1)

    # Merge tooltip with point contributions
    $mComps = @(
        [PSCustomObject]@{ key = "conflicts"; text = if ($conflictS -eq 1.0) { "no merge conflicts" } elseif ($conflictS -eq 0) { "has merge conflicts" } else { "mergeability unknown" }; val = $conflictS; w = 3.0 }
        [PSCustomObject]@{ key = "ci"; text = if ($ciS -eq 1.0) { "CI passing" } elseif ($ciS -eq 0.5) { "CI pending" } else { "CI failing/absent" }; val = $ciS; w = 2.5 }
        [PSCustomObject]@{ key = "needs approval"; text = if ($approvalS -ge 0.5) { "has approval" } else { "needs approval" }; val = $approvalS; w = 2.5 }
        [PSCustomObject]@{ key = "unresolved feedback"; text = if ($feedbackS -eq 1.0) { "feedback addressed" } elseif ($feedbackS -eq 0) { "has unresolved feedback" } else { "some unresolved feedback" }; val = $feedbackS; w = 2.5 }
        [PSCustomObject]@{ key = "discussion"; text = if ($discussionS -ge 0.5) { "discussion healthy" } else { "heavy unresolved discussion" }; val = $discussionS; w = 2.5 }
        [PSCustomObject]@{ key = "size"; text = if ($isTrivial) { "trivial change, 30-second review" } elseif ($sizeS -ge 0.5) { "small, easy to review" } else { "large change, harder to review" }; val = $sizeS; w = 2.0 }
        [PSCustomObject]@{ key = "maintainer review"; text = if ($maintS -ge 0.5) { "has maintainer review" } else { "needs maintainer review" }; val = $maintS; w = 1.5 }
        [PSCustomObject]@{ key = "staleness"; text = if ($stalenessS -ge 0.5) { "recently active" } else { "gone stale" }; val = $stalenessS; w = 1.0 }
        [PSCustomObject]@{ key = "community author"; text = if ($pr.is_community) { "community author" } else { "team author" }; val = $communityS; w = 1.0 }
        [PSCustomObject]@{ key = "freshness"; text = if ($freshS -ge 0.5) { "recently updated" } else { "no recent updates" }; val = $freshS; w = 0.7 }
        [PSCustomObject]@{ key = "triage"; text = if ($alignS -ge 0.5) { "well labeled" } else { "missing area labels" }; val = $alignS; w = 0.5 }
        [PSCustomObject]@{ key = "momentum"; text = if ($velocityS -ge 0.5) { "good review momentum" } else { "slow review momentum" }; val = $velocityS; w = 0.3 }
    )
    $mergeWhy = @($mComps | Sort-Object { $_.val * $_.w } -Descending | Where-Object { ($_.val * $_.w) -gt 0 } | ForEach-Object {
        $c = [Math]::Round($_.val * $_.w, 1); "$($_.text) (+$c)"
    })
    $whyStr = $mergeWhy -join "&#10;"

    # --- Value/Attention score (from cached fields; labels/issues add more on full refresh) ---
    $valueRaw = 0.0
    if ($pr.is_community) { $valueRaw += 1.0 }                                       # community effort at risk
    if ($tt -gt 0 -and [int]$pr.approval_count -eq 0) { $valueRaw += 1.0 }           # reviewed but not approved
    if ([int]$pr.lines_changed -gt 200) { $valueRaw += 0.5 }                         # large change
    if ([int]$pr.unresolved_threads -gt 0) { $valueRaw += 1.0 }                      # active feedback
    if ([int]$pr.approval_count -eq 0) { $valueRaw += 1.5 }                          # needs reviewer
    if ($tt -gt 10 -or $dc -gt 3) { $valueRaw += 1.0 }                              # high interest
    elseif ($tt -gt 5) { $valueRaw += 0.5 }
    if ([int]$pr.age_days -gt 30 -and $dsu -le 14) { $valueRaw += 0.5 }             # old but active
    if ($isTrivial -and [int]$pr.unresolved_threads -eq 0) { $valueRaw += 0.5 }  # quick win — trivial review
    # Author response latency (use field if available from full API refresh, else approximate from days_since_update)
    $dsac = if ($null -ne $pr.days_since_author_review_comment) { [int]$pr.days_since_author_review_comment }
           elseif ($null -ne $pr.days_since_author_comment) { [int]$pr.days_since_author_comment }
           else { [int]$pr.age_days }
    $ut = [int]$pr.unresolved_threads
    # Author response latency: if ball is in author's court, reduce attention (maintainer can't help)
    if ($ut -gt 0 -and $dsac -gt 14) { $valueRaw -= 1.5 }        # author silent — not actionable
    elseif ($ut -gt 0 -and $dsac -gt 7) { $valueRaw -= 0.5 }     # author slow — less actionable
    $valueClamped = $valueRaw -lt 0
    $valueRaw = [Math]::Max($valueRaw, 0.0)
    $valueScore = [Math]::Round([Math]::Min(($valueRaw / 9.0) * 10, 10.0), 1)

    # Value tooltip
    $vWhy = @()
    if ($pr.is_community) { $vWhy += "community author (+1.0)" }
    if ([int]$pr.approval_count -eq 0) { $vWhy += "no approval yet (+1.5)" }
    if ($ut -gt 0 -and $dsac -gt 14) { $vWhy += "author silent ${dsac}d, ball in their court (-1.5)" }
    if ($tt -gt 0 -and [int]$pr.approval_count -eq 0) { $vWhy += "reviewed, not approved (+1.0)" }
    if ([int]$pr.unresolved_threads -gt 0) { $vWhy += "unresolved feedback (+1.0)" }
    if ($tt -gt 10 -or $dc -gt 3) { $vWhy += "high interest: ${tt}t ${dc}ppl (+1.0)" }
    elseif ($tt -gt 5) {
        if ([int]$pr.unresolved_threads -gt 0) { $vWhy += "active discussion: ${tt}t, $([int]$pr.unresolved_threads) unresolved (+0.5)" }
        else { $vWhy += "thorough review: ${tt} resolved threads (+0.5)" }
    }
    if ($ut -gt 0 -and $dsac -gt 7 -and $dsac -le 14) { $vWhy += "author slow ${dsac}d, ball in their court (-0.5)" }
    if ([int]$pr.lines_changed -gt 200) { $vWhy += "large change: $([int]$pr.lines_changed) lines (+0.5)" }
    if ([int]$pr.age_days -gt 30 -and $dsu -le 14) { $vWhy += "old but active: $([int]$pr.age_days)d age (+0.5)" }
    if ($isTrivial -and [int]$pr.unresolved_threads -eq 0) { $vWhy += "trivial change, quick win (+0.5)" }
    if ($vWhy.Count -eq 0) { $vWhy += "no attention signals" }
    if ($valueClamped) { $vWhy += "(net negative, floored to 0)" }
    $valueWhyStr = $vWhy -join "&#10;"

    # --- Combined Action score: multiplicative (merge+1)*(value+1) normalized to 0-10 ---
    $actionRaw = ($mergeReadiness + 1) * ($valueScore + 1)
    $actionScore = [Math]::Round(($actionRaw / 121.0) * 10, 1)

    # Action tooltip: unified contributors from both scores, overlapping concepts combined
    $allC = @()
    foreach ($mc in $mComps) {
        $c = [Math]::Round($mc.val * $mc.w, 1)
        if ($c -gt 0) { $allC += [PSCustomObject]@{ key = $mc.key; text = $mc.text; pts = $c } }
    }
    if ($pr.is_community) { $allC += [PSCustomObject]@{ key = "community author"; text = "community author"; pts = 1.0 } }
    if ([int]$pr.approval_count -eq 0) { $allC += [PSCustomObject]@{ key = "needs approval"; text = "needs approval"; pts = 1.5 } }
    if ($tt -gt 0 -and [int]$pr.approval_count -eq 0) { $allC += [PSCustomObject]@{ key = "reviewed, not approved"; text = "reviewed, not approved"; pts = 1.0 } }
    if ([int]$pr.unresolved_threads -gt 0) { $allC += [PSCustomObject]@{ key = "unresolved feedback"; text = "has unresolved feedback"; pts = 1.0 } }
    if ($tt -gt 10 -or $dc -gt 3) { $allC += [PSCustomObject]@{ key = "high interest"; text = "high interest"; pts = 1.0 } }
    if ($ut -gt 0 -and $dsac -gt 14) { $allC += [PSCustomObject]@{ key = "author latency"; text = "author silent ${dsac}d, ball in their court"; pts = -1.5 } }
    elseif ($ut -gt 0 -and $dsac -gt 7) { $allC += [PSCustomObject]@{ key = "author latency"; text = "author slow ${dsac}d, ball in their court"; pts = -0.5 } }
    $grouped = $allC | Group-Object key | ForEach-Object {
        $total = ($_.Group | Measure-Object pts -Sum).Sum
        $bestText = ($_.Group | Sort-Object pts -Descending | Select-Object -First 1).text
        [PSCustomObject]@{ text = $bestText; pts = [Math]::Round($total, 1) }
    }
    $topC = @($grouped | Sort-Object pts -Descending | ForEach-Object {
        $sign = if ($_.pts -ge 0) { "+" } else { "" }
        "$($_.text) (${sign}$($_.pts))"
    })
    $actionWhyStr = ($topC -join "&#10;")

    $pr | Add-Member -NotePropertyName merge_readiness -NotePropertyValue $mergeReadiness -Force
    $pr | Add-Member -NotePropertyName value_score -NotePropertyValue $valueScore -Force
    $pr | Add-Member -NotePropertyName value_why -NotePropertyValue $valueWhyStr -Force
    $pr | Add-Member -NotePropertyName action_score -NotePropertyValue $actionScore -Force
    $pr | Add-Member -NotePropertyName action_why -NotePropertyValue $actionWhyStr -Force
    # Overwrite old emoji-based why with points-based merge tooltip
    $mergeWhy = @($mComps | Sort-Object { $_.val * $_.w } -Descending | Where-Object { ($_.val * $_.w) -gt 0 } | ForEach-Object {
        $c = [Math]::Round($_.val * $_.w, 1); "$($_.text) (+$c)"
    })
    $pr.why = $mergeWhy -join "&#10;"
}
$allPrs = @($allPrs | Sort-Object -Property action_score -Descending)

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
        Desc     = "All open PRs sorted by Action score. Higher-scored PRs are closer to merge-ready <em>and</em> would benefit most from maintainer attention."
        Filter   = { param($prs) @($prs | Select-Object -First 500) }
        AiPrompt = "These are the most actionable PRs in $Repo ranked by Action score (a combination of merge readiness and attention value)."
    }
    "community" = @{
        Id       = "community"
        Title    = "Community PRs Awaiting Review"
        File     = "community.html"
        Desc     = "Community-contributed PRs whose next step is a maintainer review. These authors may need extra shepherding and their PRs may not align with current investment priorities."
        Filter   = { param($prs) @($prs | Where-Object { $_.is_community -and $_.next_action -match "review" }) }
        AiPrompt = "These are community-contributed PRs that are awaiting maintainer review in $Repo. Note that community PRs may need more shepherding and may not align with current investment priorities."
    }
    "quick-wins" = @{
        Id       = "quick-wins"
        Title    = "Quick Wins: Ready to Merge"
        File     = "quick-wins.html"
        Desc     = "PRs that appear ready to merge: CI is green, at least one approval, and all review threads resolved. A maintainer can likely merge these with minimal effort."
        Filter   = { param($prs) @($prs | Where-Object { $_.next_action -match "Ready to merge" }) }
        AiPrompt = "These PRs in $Repo appear ready to merge (CI green, approved, no unresolved threads)."
    }
    "stale-close" = @{
        Id       = "stale-close"
        Title    = "Consider Closing"
        File     = "consider-closing.html"
        Desc     = "PRs that are old and have not been updated recently&mdash;likely abandoned or superseded. Consider closing with a polite note; authors can always reopen."
        DefaultSort = "upd"
        Filter   = { param($prs) @($prs | Where-Object {
            ($_.age_days -gt 90 -and $_.days_since_update -gt 30) -or
            ($_.age_days -gt 180 -and $_.days_since_update -gt 14)
        } | Sort-Object -Property days_since_update -Descending) }
        AiPrompt = "These PRs in $Repo are old and stale — likely abandoned or superseded. Identify which ones seem most clearly closeable and why."
    }
}

$reports = @($ReportTypes | ForEach-Object { $allReports[$_] } | Where-Object { $_ })

# Build nav links for this repo's reports
$navLinks = @{ "Home" = "../index.html"; "All Repos" = "../all/actionable.html" }
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
                "#$($_.number) merge=$($_.merge_readiness) value=$($_.value_score) action=$($_.action_score) ci=$($_.ci) next_action=`"$($_.next_action)`" who=`"$($_.who)`" threads=$($_.unresolved_threads) age=$($_.age_days)d community=$($_.is_community) author=$($_.author)"
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
        Description   = if ($report.Desc) { $report.Desc } else { "" }
        Observations  = $observations
        Repo          = $Repo
        OutputFile    = Join-Path $outDir $report.File
        Timestamp     = $timestamp
        TimestampIso  = $timestampIso
        ScheduleDesc  = $ScheduleDesc
        NavLinks      = $navLinks
    }
    if ($report.DefaultSort) { $htmlParams["DefaultSort"] = $report.DefaultSort }
    & "$scriptDir\ConvertTo-ReportHtml.ps1" @htmlParams

    Remove-Item $tempJson -ErrorAction SilentlyContinue
    Write-Host "  -> $Slug/$($report.File) ($($filteredArray.Count) PRs)"
}

# --- Write meta.json ---
$meta = @{
    repo          = $Repo
    slug          = $Slug
    updated       = $timestampIso
    schedule_desc = $ScheduleDesc
    scanned       = $scan.scanned
    analyzed      = $scan.analyzed
    drafts        = if ($scan.screened_out) { [int]$scan.screened_out.drafts_count } else { 0 }
    bots          = if ($scan.screened_out -and $scan.screened_out.bots) { @($scan.screened_out.bots).Count } else { 0 }
    elapsed       = $scan.elapsed_seconds
    reports       = $reportMeta
}
$meta | ConvertTo-Json -Depth 3 | Out-File -FilePath (Join-Path $outDir "meta.json") -Encoding utf8

# --- Fetch recently merged PRs and append history ---
if ($SkipHistory) {
    Write-Host "  Skipping history update (-SkipHistory)"
} else {
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
} # end if (-not $SkipHistory)

Write-Host "Done! $($reports.Count) reports in $outDir/"
