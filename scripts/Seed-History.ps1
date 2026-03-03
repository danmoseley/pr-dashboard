<#
.SYNOPSIS
    Seeds history.json for all repos from current scan.json files.
.DESCRIPTION
    One-time bootstrap script. Reads existing scan.json, computes stats,
    and writes a single history entry per repo. Does not call any APIs.
.PARAMETER DocsDir
    Root docs directory (default: docs/).
#>
[CmdletBinding()]
param(
    [string]$DocsDir = "docs"
)

$ErrorActionPreference = "Stop"

$scanFiles = Get-ChildItem -Path $DocsDir -Filter "scan.json" -Recurse
foreach ($sf in $scanFiles) {
    $slug = $sf.Directory.Name
    $scan = Get-Content $sf.FullName -Raw | ConvertFrom-Json
    $allPrs = $scan.prs
    if (-not $allPrs -or $allPrs.Count -eq 0) {
        Write-Host "Skipping $slug (no PRs)"
        continue
    }

    $ages = @($allPrs | ForEach-Object { [int]$_.age_days } | Sort-Object)
    $openCount = $ages.Count
    $medianAge = $ages[[math]::Floor($ages.Count / 2)]
    $p90Age = $ages[[math]::Floor($ages.Count * 0.9)]
    $opened7d = @($allPrs | Where-Object { [int]$_.age_days -le 7 }).Count

    $historyFile = Join-Path $sf.DirectoryName "history.json"
    $existing = if (Test-Path $historyFile) {
        @(Get-Content $historyFile -Raw | ConvertFrom-Json)
    } else { @() }

    $entry = [ordered]@{
        date            = (Get-Date).ToUniversalTime().ToString("o")
        open            = $openCount
        median_age_days = $medianAge
        p90_age_days    = $p90Age
        merged_7d       = 0
        opened_7d       = $opened7d
        top_mergers_7d  = @{}
    }
    $existing += $entry
    ConvertTo-Json -InputObject @($existing) -Depth 4 | Out-File -FilePath $historyFile -Encoding utf8
    Write-Host "$slug`: seeded with $openCount open PRs, median age ${medianAge}d"
}
Write-Host "Done! History files seeded."
