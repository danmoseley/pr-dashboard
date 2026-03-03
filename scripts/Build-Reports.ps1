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
    [string[]]$ReportTypes = @("top15", "community", "quick-wins"),
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
        InputFile    = $tempJson
        Title        = "$($report.Title) — $Repo"
        Observations = $observations
        Repo         = $Repo
        OutputFile   = Join-Path $outDir $report.File
        Timestamp    = $timestamp
        NavLinks     = $navLinks
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
    elapsed  = $scan.elapsed_seconds
    reports  = $reportMeta
}
$meta | ConvertTo-Json -Depth 3 | Out-File -FilePath (Join-Path $outDir "meta.json") -Encoding utf8
Write-Host "Done! $($reports.Count) reports in $outDir/"
