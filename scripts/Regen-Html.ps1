<#
.SYNOPSIS
    Regenerates HTML reports from cached scan.json files (no API calls).
.DESCRIPTION
    Re-runs Build-Reports.ps1 for each repo that has a docs/{slug}/scan.json,
    then rebuilds the index page. Useful after changing HTML templates.
.PARAMETER SkipAI
    Skip AI observation generation (default: true, since gh-models may not be available locally).
#>
[CmdletBinding()]
param(
    [switch]$SkipAI = $true
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$docsDir = Join-Path $root "docs"

# Repo config: slug -> full repo name and report types
$repos = @{
    "runtime"    = @{ Repo = "dotnet/runtime";     Types = "top15,community,quick-wins" }
    "aspnetcore" = @{ Repo = "dotnet/aspnetcore";   Types = "top15,quick-wins" }
    "sdk"        = @{ Repo = "dotnet/sdk";          Types = "top15,quick-wins" }
    "msbuild"    = @{ Repo = "dotnet/msbuild";      Types = "top15,quick-wins" }
    "winforms"   = @{ Repo = "dotnet/winforms";     Types = "top15,quick-wins" }
    "wpf"        = @{ Repo = "dotnet/wpf";          Types = "top15,quick-wins" }
    "roslyn"     = @{ Repo = "dotnet/roslyn";       Types = "top15,quick-wins" }
    "aspire"     = @{ Repo = "dotnet/aspire";       Types = "top15,quick-wins" }
}

$found = 0
foreach ($slug in $repos.Keys | Sort-Object) {
    $scanFile = Join-Path $docsDir "$slug/scan.json"
    if (-not (Test-Path $scanFile)) {
        Write-Host "  SKIP $slug (no scan.json)" -ForegroundColor DarkGray
        continue
    }
    $cfg = $repos[$slug]
    Write-Host "=== Regenerating $slug ===" -ForegroundColor Cyan
    $params = @{
        ScanFile    = $scanFile
        Repo        = $cfg.Repo
        Slug        = $slug
        ReportTypes = $cfg.Types
    }
    if ($SkipAI) { $params["SkipAI"] = $true }
    & "$PSScriptRoot\Build-Reports.ps1" @params
    $found++
}

if ($found -eq 0) {
    Write-Warning "No scan.json files found. Run the workflows first, or pull from origin to get cached data."
    exit 1
}

Write-Host "`n=== Rebuilding index ===" -ForegroundColor Cyan
& "$PSScriptRoot\Build-Index.ps1"

Write-Host "`nDone — regenerated $found repos from cached scan data." -ForegroundColor Green
