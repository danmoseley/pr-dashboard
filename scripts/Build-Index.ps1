<#
.SYNOPSIS
    Generates the table-based index.html from per-repo meta.json files.
.DESCRIPTION
    Scans docs/*/meta.json to discover all repos and their reports,
    then generates a table with repos as columns and report types as rows.
    Includes client-side JS for live "Xh ago" relative timestamps.
.PARAMETER DocsDir
    Root docs directory (default: docs/).
.PARAMETER ScheduleDesc
    Human-readable schedule description (e.g., "~twice daily") displayed
    alongside the relative timestamps in the generated index page.
#>
[CmdletBinding()]
param(
    [string]$DocsDir = "docs",
    [string]$ScheduleDesc = ""
)

$ErrorActionPreference = "Stop"

# Discover all repo metadata
$metaFiles = Get-ChildItem -Path $DocsDir -Filter "meta.json" -Recurse
$repos = @()
foreach ($mf in $metaFiles) {
    try {
        $raw = Get-Content $mf.FullName -Raw
        $meta = $raw | ConvertFrom-Json
        # Preserve ISO timestamp as string (ConvertFrom-Json may parse it as DateTime)
        if ($meta.updated -is [datetime]) {
            $meta.updated = $meta.updated.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        $repos += $meta
    } catch {
        Write-Host "::warning::Skipping $($mf.FullName): $_"
    }
}

if ($repos.Count -eq 0) {
    Write-Warning "No meta.json files found in $DocsDir"
    return
}

# Sort repos: runtime first, then alphabetical
$repos = @($repos | Sort-Object { if ($_.slug -eq "runtime") { "0" } else { $_.slug } })

# Load history data for each repo
$repoHistory = @{}
foreach ($repo in $repos) {
    $histFile = Join-Path $DocsDir "$($repo.slug)/history.json"
    if (Test-Path $histFile) {
        $repoHistory[$repo.slug] = @(Get-Content $histFile -Raw | ConvertFrom-Json)
    } else {
        $repoHistory[$repo.slug] = @()
    }
}

# --- Helper: generate SVG sparkline from an array of numbers ---
function New-Sparkline {
    param([double[]]$Values, [string]$Color = "#58a6ff", [int]$Width = 120, [int]$Height = 32)
    if ($Values.Count -lt 7) { return "" }
    $min = ($Values | Measure-Object -Minimum).Minimum
    $max = ($Values | Measure-Object -Maximum).Maximum
    $range = [Math]::Max($max - $min, 1)
    $points = @()
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $x = [Math]::Round($i * $Width / ($Values.Count - 1), 1)
        $y = [Math]::Round($Height - (($Values[$i] - $min) / $range) * ($Height - 4) - 2, 1)
        $points += "$x,$y"
    }
    $pathStr = $points -join " "
    "<svg width=`"$Width`" height=`"$Height`" viewBox=`"0 0 $Width $Height`" style=`"vertical-align:middle`"><polyline points=`"$pathStr`" fill=`"none`" stroke=`"$Color`" stroke-width=`"1.5`" stroke-linecap=`"round`" stroke-linejoin=`"round`"/></svg>"
}

# --- Helper: compute trend indicator vs 7 days ago ---
function Get-TrendIndicator {
    param([object[]]$History, [string]$Field, [string]$GoodDirection = "down")
    if ($History.Count -lt 2) { return @{ arrow = ""; cssClass = "" ; delta = 0; tooltip = "" } }
    $current = [double]$History[-1].$Field
    # Find entry closest to 7 days ago
    $cutoff = (Get-Date).AddDays(-7).ToUniversalTime().ToString("o")
    $weekAgo = $History | Where-Object { $_.date -le $cutoff } | Select-Object -Last 1
    if (-not $weekAgo) { $weekAgo = $History[0] }
    $prev = [double]$weekAgo.$Field
    $delta = $current - $prev
    $sign = if ($delta -gt 0) { "+" } else { "" }
    $tooltip = "vs 7 days ago: ${sign}$([int]$delta) (was $([int]$prev))"
    if ($delta -eq 0) {
        return @{ arrow = ""; cssClass = "trend-flat"; delta = 0; tooltip = "No change vs 7 days ago" }
    }
    $isGood = if ($GoodDirection -eq "down") { $delta -lt 0 } else { $delta -gt 0 }
    $arrow = if ($delta -gt 0) { "&#9650;" } else { "&#9660;" }  # ▲ ▼
    $cssClass = if ($isGood) { "trend-good" } else { "trend-bad" }
    return @{ arrow = "$arrow"; cssClass = $cssClass; delta = [int]$delta; tooltip = $tooltip }
}

# All known report types in display order
$reportTypes = @(
    @{ Id = "top15"; Title = "Most Actionable" }
    @{ Id = "community"; Title = "Community Awaiting Review" }
    @{ Id = "quick-wins"; Title = "Quick Wins: Ready to Merge" }
    @{ Id = "stale-close"; Title = "Consider Closing" }
)

# Build header row
$headerCells = $repos | ForEach-Object {
    $repoShort = $_.slug
    "<th><a href=`"$($_.slug)/actionable.html`">$repoShort</a></th>"
}
$headerRow = "<tr><th></th>$($headerCells -join '')</tr>"

# --- Hero metrics rows ---
# Open PRs row with sparkline and trend
$openCells = foreach ($repo in $repos) {
    $hist = $repoHistory[$repo.slug]
    $current = if ($hist.Count -gt 0) { [int]$hist[-1].open } else { [int]$repo.analyzed }
    $trend = Get-TrendIndicator -History $hist -Field "open" -GoodDirection "down"
    $sparkValues = @($hist | ForEach-Object { [double]$_.open })
    $spark = New-Sparkline -Values $sparkValues -Color $(if ($trend.cssClass -eq "trend-good") { "#3fb950" } elseif ($trend.cssClass -eq "trend-bad") { "#f85149" } else { "#58a6ff" })
    $trendHtml = if ($trend.arrow) { " <span class=`"trend-indicator $($trend.cssClass)`" title=`"$($trend.tooltip)`">$($trend.arrow)$([Math]::Abs($trend.delta))</span>" } else { "" }
    "<td class=`"metric`"><span class=`"metric-num`">$current</span>$trendHtml<br>$spark</td>"
}
$openRow = "<tr class=`"metric-row`"><td class=`"report-name`">Open PRs</td>$($openCells -join '')</tr>"

# Median age row with sparkline
$ageCells = foreach ($repo in $repos) {
    $hist = $repoHistory[$repo.slug]
    $current = if ($hist.Count -gt 0) { [int]$hist[-1].median_age_days } else { 0 }
    $trend = Get-TrendIndicator -History $hist -Field "median_age_days" -GoodDirection "down"
    $sparkValues = @($hist | ForEach-Object { [double]$_.median_age_days })
    $spark = New-Sparkline -Values $sparkValues -Color $(if ($trend.cssClass -eq "trend-good") { "#3fb950" } elseif ($trend.cssClass -eq "trend-bad") { "#f85149" } else { "#58a6ff" })
    $trendHtml = if ($trend.arrow) { " <span class=`"trend-indicator $($trend.cssClass)`" title=`"$($trend.tooltip)`">$($trend.arrow)$([Math]::Abs($trend.delta))d</span>" } else { "" }
    "<td class=`"metric`"><span class=`"metric-num`">${current}d</span>$trendHtml<br>$spark</td>"
}
$ageRow = "<tr class=`"metric-row`"><td class=`"report-name`">Median Age</td>$($ageCells -join '')</tr>"

# Merged this week row with sparkline
$mergedCells = foreach ($repo in $repos) {
    $hist = $repoHistory[$repo.slug]
    $merged = if ($hist.Count -gt 0 -and $null -ne $hist[-1].merged_7d) { [int]$hist[-1].merged_7d } else { 0 }
    $text = if ($merged -gt 0) { "$merged" } else { "&mdash;" }
    $sparkValues = @($hist | ForEach-Object { if ($null -ne $_.merged_7d) { [double]$_.merged_7d } else { 0 } })
    $spark = New-Sparkline -Values $sparkValues -Color "#58a6ff"
    "<td class=`"metric`"><span class=`"metric-num`">$text</span><br>$spark</td>"
}
$mergedRow = "<tr class=`"metric-row`"><td class=`"report-name`">Merged (7d)</td>$($mergedCells -join '')</tr>"

# Build data rows (report links)
$dataRows = foreach ($rt in $reportTypes) {
    $cells = foreach ($repo in $repos) {
        $reportInfo = $null
        if ($repo.reports -and $repo.reports.PSObject.Properties[$rt.Id]) {
            $reportInfo = $repo.reports.($rt.Id)
        }
        if ($reportInfo -and $reportInfo.count -ge 0) {
            "<td><a href=`"$($repo.slug)/$($reportInfo.file)`">$($reportInfo.count) PRs</a></td>"
        } else {
            "<td class=`"na`">&mdash;</td>"
        }
    }
    "<tr><td class=`"report-name`">$($rt.Title)</td>$($cells -join '')</tr>"
}

# Build updated row
$updatedCells = $repos | ForEach-Object {
    "<td class=`"updated`" data-updated=`"$($_.updated)`" data-schedule=`"$([System.Net.WebUtility]::HtmlEncode($ScheduleDesc))`">...</td>"
}
$updatedRow = "<tr class=`"updated-row`"><td class=`"report-name`">Updated</td>$($updatedCells -join '')</tr>"

# Build scan stats row
$statsCells = $repos | ForEach-Object {
    $drafts = if ($_.drafts) { [int]$_.drafts } else { 0 }
    $bots = if ($_.bots) { [int]$_.bots } else { 0 }
    $pullsUrl = "https://github.com/$($_.repo)/pulls?q=is%3Aopen+is%3Apr+draft%3Atrue"
    $parts = @()
    if ($drafts -gt 0) { $parts += "<a href=`"$pullsUrl`">$drafts drafts</a>" }
    if ($bots -gt 0) { $parts += "$bots bots" }
    $text = if ($parts.Count -gt 0) { ($parts -join ", ") + " excluded" } else { "&mdash;" }
    "<td class=`"stats`">$text</td>"
}
$statsRow = "<tr class=`"stats-row`"><td class=`"report-name`">Scan</td>$($statsCells -join '')</tr>"

# --- Per-repo merger rows ---
$botNames = @("dotnet-maestro", "github-actions", "unknown", "dependabot", "dotnet-maestro[bot]", "Copilot")

function Format-TopMergers {
    param([object]$MergerData, [string]$RepoName, [int]$TopN = 3)
    if (-not $MergerData) { return "&mdash;" }
    $entries = @()
    if ($MergerData -is [hashtable]) {
        $entries = @($MergerData.GetEnumerator() | Where-Object { $_.Name -notin $botNames -and $_.Name -notmatch '\[bot\]$' } | Sort-Object -Property Value -Descending | Select-Object -First $TopN)
    } elseif ($MergerData.PSObject) {
        $entries = @($MergerData.PSObject.Properties | Where-Object { $_.Name -notin $botNames -and $_.Name -notmatch '\[bot\]$' } | Sort-Object -Property { [int]$_.Value } -Descending | Select-Object -First $TopN)
    }
    if ($entries.Count -eq 0) { return "&mdash;" }
    $medals = @("&#129351;", "&#129352;", "&#129353;")  # 🥇🥈🥉
    $parts = for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        $name = $e.Name
        $count = [int]$e.Value
        $medal = if ($i -lt 3) { $medals[$i] } else { "" }
        "$medal<img src=`"https://github.com/$name.png?size=16`" class=`"avatar-sm`"><a href=`"https://github.com/$RepoName/pulls?q=is%3Apr+is%3Amerged+reviewed-by%3A$name`">$name</a>&nbsp;<span class=`"merge-count`">$count</span>"
    }
    return $parts -join "<br>"
}

# Community Champs row (who merged the most community PRs this week)
$communityChampCells = foreach ($repo in $repos) {
    $hist = $repoHistory[$repo.slug]
    $mergerData = if ($hist.Count -gt 0) { $hist[-1].top_community_mergers_7d } else { $null }
    $html = Format-TopMergers -MergerData $mergerData -RepoName $repo.repo -TopN 3
    "<td class=`"merger-cell`">$html</td>"
}
$communityChampRow = "<tr class=`"merger-row`"><td class=`"report-name`" title=`"Maintainers who merged the most community-contributed PRs this week`">&#127775; Community Champs (7d)</td>$($communityChampCells -join '')</tr>"

# Top Mergers row
$topMergerCells = foreach ($repo in $repos) {
    $hist = $repoHistory[$repo.slug]
    $mergerData = if ($hist.Count -gt 0) { $hist[-1].top_mergers_7d } else { $null }
    $html = Format-TopMergers -MergerData $mergerData -RepoName $repo.repo -TopN 3
    "<td class=`"merger-cell`">$html</td>"
}
$topMergerRow = "<tr class=`"merger-row`"><td class=`"report-name`">&#127942; Top Mergers (7d)</td>$($topMergerCells -join '')</tr>"

$indexHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PR Dashboard</title>
<style>
  :root { --bg: #0d1117; --fg: #e6edf3; --border: #30363d; --link: #58a6ff;
           --hover: #161b22; --header-bg: #161b22; --good: #3fb950; --bad: #f85149; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
         background: var(--bg); color: var(--fg); padding: 2em; }
  h1 { font-size: 1.6em; margin-bottom: 0.3em; }
  h2 { font-size: 1.1em; margin-bottom: 0.5em; color: var(--fg); }
  .meta { color: #8b949e; font-size: 0.85em; margin-bottom: 1.5em; }
  a { color: var(--link); text-decoration: none; }
  a:hover { text-decoration: underline; }
  table { border-collapse: collapse; margin-top: 1em; }
  th, td { padding: 8px 16px; border: 1px solid var(--border); text-align: center; }
  th { background: var(--header-bg); font-weight: 600; white-space: nowrap; }
  td.report-name { text-align: left; font-weight: 500; white-space: nowrap; }
  td.na { color: #484f58; }
  td.updated { color: #8b949e; font-size: 0.85em; }
  td.stats { color: #484f58; font-size: 0.8em; }
  td.metric { font-size: 0.95em; line-height: 1.6; padding: 6px 12px; }
  .metric-num { font-size: 1.3em; font-weight: 600; }
  .trend-good { color: var(--good); font-size: 0.95em; font-weight: 600; }
  .trend-bad { color: var(--bad); font-size: 0.95em; font-weight: 600; }
  .trend-flat { color: #8b949e; font-size: 0.95em; }
  .trend-indicator { cursor: help; }
  tr.metric-row td { border-bottom: none; }
  tr.metric-row + tr.metric-row td { border-top: none; }
  tr.separator-row td { border-top: 2px solid var(--border); padding: 0; height: 0; border-bottom: none; }
  tr.updated-row td, tr.stats-row td { border-top: 2px solid var(--border); }
  tr:hover { background: var(--hover); }
  td.merger-cell { font-size: 0.8em; text-align: left; line-height: 1.8; white-space: nowrap; padding: 6px 10px; }
  .avatar-sm { width: 16px; height: 16px; border-radius: 50%; vertical-align: middle; margin-right: 2px; }
  .merge-count { color: #8b949e; font-size: 0.9em; }
  tr.merger-row td { border-top: none; }
  .footer { margin-top: 2em; color: #8b949e; font-size: 0.85em; }
  a.feedback { font-size: 0.8em; background: #1f6feb; color: #fff; padding: 2px 10px;
              border-radius: 10px; text-decoration: none; margin-left: 8px; vertical-align: middle; }
  a.feedback:hover { background: #388bfd; color: #fff; text-decoration: none; }
  @media (prefers-color-scheme: light) {
    :root { --bg: #fff; --fg: #1f2328; --border: #d0d7de; --link: #0969da;
             --hover: #f6f8fa; --header-bg: #f6f8fa; --good: #1a7f37; --bad: #cf222e; }
    a.feedback { background: #0969da; }
    a.feedback:hover { background: #0550ae; }
  }
</style>
</head>
<body>
<h1>PR Dashboard</h1>
<p class="meta">Automated PR triage reports for dotnet repositories <a class="feedback" href="https://github.com/danmoseley/pr-dashboard/issues/new?title=Feedback" target="_blank">&#x1F4AC; Feedback</a></p>
<div style="overflow-x:auto">
<table>
<thead>
$headerRow
</thead>
<tbody>
$openRow
$ageRow
$mergedRow
$communityChampRow
$topMergerRow
<tr class="separator-row"><td class="report-name" colspan="$(1 + $repos.Count)"></td></tr>
$($dataRows -join "`n")
$updatedRow
$statsRow
<tr class="separator-row"><td class="report-name" colspan="$(1 + $repos.Count)"></td></tr>
<tr><td colspan="$(1 + $repos.Count)" style="text-align:center;padding:0.75em 1em;border:2px solid var(--link);background:var(--header-bg);font-weight:600;font-size:1.05em"><a href="all/actionable.html">&#x1F30D; My PRs across all repos</a></td></tr>
</tbody>
</table>
</div>

<p class="footer">
  Generated by <a href="https://github.com/danmoseley/pr-dashboard">pr-dashboard</a> via GitHub Actions.
  <a href="https://danmoseley.github.io/repo-health-metrics/" style="margin-left:1em">&#x1F4CA; Repo Health</a>
  <a href="changelog.html" style="margin-left:1em">&#x1F4DD; Changelog</a>
  <a href="https://github.com/danmoseley/pr-dashboard/actions/workflows/generate-reports.yml" style="margin-left:1em;color:#e06050">Pipeline status</a>
</p>

<script>
function timeAgo(iso) {
  const ms = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(ms / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return mins + 'm ago';
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return hrs + 'h ago';
  const days = Math.floor(hrs / 24);
  return days + 'd ago';
}
function updateTimestamps() {
  document.querySelectorAll('[data-updated]').forEach(function(el) {
    var ago = timeAgo(el.getAttribute('data-updated'));
    var schedule = el.getAttribute('data-schedule');
    el.textContent = ago + (schedule ? ', ' + schedule : '');
  });
}
updateTimestamps();
setInterval(updateTimestamps, 60000);
</script>
</body>
</html>
"@

$indexHtml | Out-File -FilePath (Join-Path $DocsDir "index.html") -Encoding utf8
Write-Host "Generated index.html ($($repos.Count) repos)"

# Write repos.json for the cross-repo page
$reposJson = $repos | ForEach-Object { [ordered]@{ slug = $_.slug; repo = $_.repo } } | ConvertTo-Json
$reposJson | Out-File -FilePath (Join-Path $DocsDir "repos.json") -Encoding utf8
Write-Host "Generated repos.json ($($repos.Count) repos)"
