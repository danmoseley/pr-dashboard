<#
.SYNOPSIS
    Orchestrates PR triage report generation: filters, formats HTML, calls AI for observations.
.DESCRIPTION
    Reads a full-scan JSON file from Get-PrTriageData.ps1, produces multiple filtered HTML reports
    in the docs/ directory, and generates an index page.
.PARAMETER ScanFile
    Path to the full-scan JSON output from Get-PrTriageData.ps1.
.PARAMETER DocsDir
    Output directory for HTML files (default: docs/).
.PARAMETER Repo
    Repository slug (default: dotnet/runtime).
.PARAMETER SkipAI
    If set, skip AI observation generation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScanFile,
    [string]$DocsDir = "docs",
    [string]$Repo = "dotnet/runtime",
    [switch]$SkipAI
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

$scan = Get-Content $ScanFile -Raw | ConvertFrom-Json
$allPrs = $scan.prs
$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")

if (-not (Test-Path $DocsDir)) { New-Item -ItemType Directory -Path $DocsDir -Force | Out-Null }

# --- Report definitions ---
$reports = @(
    @{
        Id       = "top15"
        Title    = "Top 15 Most Actionable PRs"
        File     = "top15.html"
        Filter   = { param($prs) @($prs | Select-Object -First 15) }
        AiPrompt = "These are the top 15 most actionable PRs in $Repo ranked by merge-readiness score."
    },
    @{
        Id       = "community"
        Title    = "Community PRs Awaiting Review"
        File     = "community.html"
        Filter   = { param($prs) @($prs | Where-Object { $_.is_community -and $_.next_action -match "review" }) }
        AiPrompt = "These are community-contributed PRs that are awaiting maintainer review in $Repo. Note that community PRs may need more shepherding and may not align with current investment priorities."
    },
    @{
        Id       = "quick-wins"
        Title    = "Quick Wins: Ready to Merge"
        File     = "quick-wins.html"
        Filter   = { param($prs) @($prs | Where-Object { $_.next_action -match "Ready to merge" }) }
        AiPrompt = "These PRs in $Repo appear ready to merge (CI green, approved, no unresolved threads)."
    }
)

# Build nav links for all reports
$navLinks = @{ "Home" = "index.html" }
foreach ($r in $reports) { $navLinks[$r.Title] = $r.File }

# --- Generate each report ---
foreach ($report in $reports) {
    Write-Host "Generating $($report.Id)..."

    # Filter PRs
    $filtered = & $report.Filter $allPrs
    if ($null -eq $filtered) { $filtered = @() }
    $filteredArray = @($filtered)

    # Write filtered JSON to temp file
    $tempJson = Join-Path $DocsDir "$($report.Id)-data.json"
    $filteredArray | ConvertTo-Json -Depth 5 | Out-File -FilePath $tempJson -Encoding utf8

    # Generate AI observations
    $observations = ""
    if (-not $SkipAI -and $filteredArray.Count -gt 0) {
        try {
            # Build a compact summary for the AI
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
            # gh models run may return an array of lines; join into a single string
            $observations = if ($aiOutput -is [array]) { $aiOutput -join "`n" } else { [string]$aiOutput }
        } catch {
            Write-Warning "AI observation generation failed: $_"
            $observations = ""
        }
    }

    # Convert to HTML
    $htmlParams = @{
        InputFile    = $tempJson
        Title        = $report.Title
        Observations = $observations
        Repo         = $Repo
        OutputFile   = Join-Path $DocsDir $report.File
        Timestamp    = $timestamp
        NavLinks     = $navLinks
    }
    & "$scriptDir\ConvertTo-ReportHtml.ps1" @htmlParams

    # Clean up temp JSON
    Remove-Item $tempJson -ErrorAction SilentlyContinue

    Write-Host "  -> $($report.File) ($($filteredArray.Count) PRs)"
}

# --- Generate index.html ---
$scanMeta = @{
    scanned  = $scan.scanned
    analyzed = $scan.analyzed
    elapsed  = $scan.elapsed_seconds
}

$reportLinks = $reports | ForEach-Object {
    $filtered = & $_.Filter $allPrs
    $count = @($filtered).Count
    "<li><a href=`"$($_.File)`">$($_.Title)</a> ($count PRs)</li>"
}

$indexHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PR Dashboard - $Repo</title>
<style>
  :root { --bg: #0d1117; --fg: #e6edf3; --border: #30363d; --link: #58a6ff; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
         background: var(--bg); color: var(--fg); padding: 2em; max-width: 700px; }
  a { color: var(--link); text-decoration: none; }
  a:hover { text-decoration: underline; }
  h1 { margin-bottom: 0.3em; }
  .meta { color: #8b949e; font-size: 0.9em; margin-bottom: 1.5em; }
  ul { padding-left: 1.5em; }
  li { margin-bottom: 0.5em; font-size: 1.05em; }
  @media (prefers-color-scheme: light) {
    :root { --bg: #fff; --fg: #1f2328; --border: #d0d7de; --link: #0969da; }
  }
</style>
</head>
<body>
<h1>PR Dashboard</h1>
<p class="meta">
  <a href="https://github.com/$Repo">$Repo</a> &middot;
  Updated: $timestamp &middot;
  Scanned $($scanMeta.scanned) PRs, analyzed $($scanMeta.analyzed) in $($scanMeta.elapsed)s
</p>
<h2>Reports</h2>
<ul>
$($reportLinks -join "`n")
</ul>
<p class="meta" style="margin-top: 2em;">
  Generated by <a href="https://github.com/danmoseley/pr-dashboard">pr-dashboard</a> via GitHub Actions.
  Data from <a href="https://github.com/dotnet/runtime/pull/125005">pr-triage skill</a>.
</p>
</body>
</html>
"@

$indexHtml | Out-File -FilePath (Join-Path $DocsDir "index.html") -Encoding utf8
Write-Host "Generated index.html"
Write-Host "Done! $($reports.Count) reports in $DocsDir/"
