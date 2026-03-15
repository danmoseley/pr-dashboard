<#
.SYNOPSIS
    Generates a changelog from git commit history, optionally using AI to summarize.
.DESCRIPTION
    Reads commits to main since the last changelog entry, filters out automated
    "Update reports" commits, groups them by calendar day (Pacific time), and
    optionally uses GitHub Models (GPT-4o) to produce concise summaries.
    Outputs docs/changelog.json (cumulative data) and docs/changelog.html.
.PARAMETER DocsDir
    Root docs directory (default: docs/).
.PARAMETER SkipAI
    If set, skip AI summarization and use cleaned-up commit messages instead.
.PARAMETER MaxDays
    Maximum number of days back to look for commits when no prior changelog exists (default: 90).
#>
[CmdletBinding()]
param(
    [string]$DocsDir = "docs",
    [switch]$SkipAI,
    [int]$MaxDays = 90
)

$ErrorActionPreference = "Stop"

$changelogJson = Join-Path $DocsDir "changelog.json"
$changelogHtml = Join-Path $DocsDir "changelog.html"

$pacific = try {
    [System.TimeZoneInfo]::FindSystemTimeZoneById("America/Los_Angeles")
} catch {
    [System.TimeZoneInfo]::FindSystemTimeZoneById("Pacific Standard Time")
}

function Write-ChangelogHtml {
    param(
        [array]$Entries,
        [string]$OutputFile
    )

    $entriesHtml = foreach ($entry in $Entries) {
        # Sort: feature first, then normal, then trivial
        $tierOrder = @{ feature = 0; normal = 1; trivial = 2 }
        $sorted = @($entry.bullets | Sort-Object { $tierOrder[($_.tier ?? 'normal')] })

        $bulletsHtml = ($sorted | ForEach-Object {
            $text = [System.Net.WebUtility]::HtmlEncode($_.text)
            switch ($_.tier) {
                'feature' { "  <li class=`"feature`"><strong>$text</strong></li>" }
                'trivial' { "  <li class=`"trivial`">$text</li>" }
                default   { "  <li>$text</li>" }
            }
        }) -join "`n"
        @"
<section class="entry">
  <h2>$([System.Net.WebUtility]::HtmlEncode($entry.display))</h2>
  <ul>
$bulletsHtml
  </ul>
</section>
"@
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Changelog — PR Dashboard</title>
<style>
  :root { --bg: #0d1117; --fg: #e6edf3; --border: #30363d; --link: #58a6ff;
           --header-bg: #161b22; --muted: #8b949e; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
         background: var(--bg); color: var(--fg); padding: 2em; max-width: 800px; margin: 0 auto; }
  nav { margin-bottom: 1.5em; font-size: 0.9em; }
  nav a { color: var(--link); text-decoration: none; }
  nav a:hover { text-decoration: underline; }
  h1 { font-size: 1.6em; margin-bottom: 0.3em; }
  .subtitle { color: var(--muted); font-size: 0.85em; margin-bottom: 2em; }
  .entry { margin-bottom: 2em; }
  .entry h2 { font-size: 1.15em; color: var(--link); border-bottom: 1px solid var(--border);
              padding-bottom: 0.3em; margin-bottom: 0.6em; }
  .entry ul { list-style: disc; padding-left: 1.5em; }
  .entry li { margin-bottom: 0.4em; line-height: 1.5; }
  .entry li.feature { font-size: 1.05em; }
  .entry li.trivial { font-size: 0.75em; line-height: 1.3; color: var(--muted); }
  .footer { margin-top: 3em; color: var(--muted); font-size: 0.8em; text-align: center; }
  .footer a { color: var(--link); text-decoration: none; }
  .footer a:hover { text-decoration: underline; }
  @media (prefers-color-scheme: light) {
    :root { --bg: #fff; --fg: #1f2328; --border: #d0d7de; --link: #0969da;
             --header-bg: #f6f8fa; --muted: #656d76; }
  }
</style>
</head>
<body>
<nav><a href="index.html">&larr; Dashboard</a></nav>
<h1>&#x1F4DD; Changelog</h1>
<p class="subtitle">Notable changes to the PR Dashboard, updated daily.</p>

$($entriesHtml -join "`n`n")

<p class="footer">
  <a href="https://github.com/danmoseley/pr-dashboard">pr-dashboard</a> &middot;
  <a href="index.html">Back to dashboard</a>
</p>
</body>
</html>
"@

    $html | Out-File -FilePath $OutputFile -Encoding utf8
    Write-Host "Generated $OutputFile ($($Entries.Count) entries)"
}

# Heuristic tier classification (fallback when AI unavailable)
function Get-BulletTier([string]$text) {
    $lower = $text.ToLower()
    # Feature: new capabilities, new views, significant additions
    if ($lower -match '\b(add (cross-repo|per-pr|new|dotnet/|area-label|feedback)|new feature|support for|introduce|cross-repo)\b') {
        return 'feature'
    }
    # Trivial: formatting, docs, regenerate, gitignore, link changes, minor cleanups
    if ($lower -match '\b(regenerate|formatting|readme|gitignore|document |link format|screenshot|fetch full titles|remove unused|unused variable|typo|whitespace)\b') {
        return 'trivial'
    }
    # If a commit message has two parts joined by semicolon and one part is trivial,
    # check the parts individually — but keep the overall item at its highest tier
    return 'normal'
}

# --- Main logic ---

try {

# Load existing changelog entries
$entries = @()
if (Test-Path $changelogJson) {
    $entries = @(Get-Content $changelogJson -Raw | ConvertFrom-Json)
}

# Determine the cutoff: last entry's newest commit, or MaxDays ago
if ($entries.Count -gt 0) {
    $sinceCommit = $entries[0].commit_range -split '\.\.' | Select-Object -Last 1
    # Try range-based log first (most accurate)
    $gitArgs = @("log", "$sinceCommit..origin/main", "--format=%H||%s||%cI")
} else {
    $cutoff = (Get-Date).AddDays(-$MaxDays).ToString("yyyy-MM-dd")
    $gitArgs = @("log", "origin/main", "--format=%H||%s||%cI", "--since=$cutoff")
}

Write-Host "Fetching commits..."
$logOutput = & git @gitArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    # If range-based log fails (e.g., force-pushed history), fall back to date-based
    if ($entries.Count -gt 0) {
        Write-Warning "Range-based log failed, falling back to date-based"
        $gitArgs = @("log", "origin/main", "--format=%H||%s||%cI", "--since=$($entries[0].date_utc)")
        $logOutput = & git @gitArgs 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "git log failed: $logOutput"
        exit 0
    }
}

$rawCommits = @($logOutput | Where-Object { $_ -match '\|\|' })
Write-Host "  Found $($rawCommits.Count) total commits"

# Filter out automated report-update commits and merge commits
$meaningful = @($rawCommits | Where-Object {
    $parts = $_ -split '\|\|', 3
    $msg = $parts[1].Trim()
    $msg -notmatch '^Update reports ' -and
    $msg -notmatch '^Merge (pull request|branch) '
})
Write-Host "  $($meaningful.Count) meaningful commits after filtering"

if ($meaningful.Count -eq 0) {
    Write-Host "No new meaningful commits — skipping changelog update"
    if ($entries.Count -gt 0) {
        Write-ChangelogHtml -Entries $entries -OutputFile $changelogHtml
    }
    exit 0
}

# Group commits by Pacific calendar day
$grouped = [ordered]@{}
foreach ($line in $meaningful) {
    $parts = $line -split '\|\|', 3
    $sha = $parts[0].Trim()
    $msg = $parts[1].Trim()
    $dateUtc = [DateTimeOffset]::Parse($parts[2].Trim()).UtcDateTime
    $datePacific = [System.TimeZoneInfo]::ConvertTimeFromUtc($dateUtc, $pacific)
    $dayKey = $datePacific.ToString("yyyy-MM-dd")

    if (-not $grouped.Contains($dayKey)) {
        $grouped[$dayKey] = @()
    }
    $grouped[$dayKey] += @{ sha = $sha; message = $msg; date_utc = $dateUtc.ToString("o") }
}

# Allow re-generating the most recent day (may have new commits since last run)
$existingDays = @{}
$latestDay = $null
foreach ($e in $entries) {
    if (-not $latestDay -or $e.day -gt $latestDay) { $latestDay = $e.day }
    $existingDays[$e.day] = $true
}

$newEntries = @()
foreach ($dayKey in $grouped.Keys) {
    if ($existingDays.ContainsKey($dayKey) -and $dayKey -ne $latestDay) {
        Write-Host "  Skipping $dayKey (already in changelog)"
        continue
    }

    $dayCommits = $grouped[$dayKey]
    $commitMessages = ($dayCommits | ForEach-Object { $_.message }) -join "`n"
    $commitShas = $dayCommits | ForEach-Object { $_.sha }

    # Summarize with AI if available
    $bullets = @()
    if (-not $SkipAI -and $dayCommits.Count -gt 0) {
        try {
            $prompt = @"
Below are git commit messages from a single day on a PR triage dashboard project.
Summarize them into a concise bulleted list of distinct changes. Rules:
- One bullet per distinct fix, feature, or improvement
- Merge related commits into a single bullet
- Use clear, user-facing language (not raw commit messages)
- Classify each bullet as [feature], [normal], or [trivial]:
  [feature] = significant new capability or major improvement
  [normal] = bug fix, moderate improvement, behavior change
  [trivial] = formatting, docs-only, regeneration, link tweaks, gitignore
- Format: "- [tier] description"
- Do NOT include automated/CI changes
- Be concise: aim for 1 sentence per bullet

Commits:
$commitMessages
"@
            Write-Host "  Calling AI for $dayKey summary ($($dayCommits.Count) commits)..."
            $aiOutput = ($prompt | gh models run openai/gpt-4o 2>&1)
            if ($LASTEXITCODE -eq 0) {
                $aiText = if ($aiOutput -is [array]) { $aiOutput -join "`n" } else { [string]$aiOutput }
                $bullets = @($aiText -split "`n" | Where-Object { $_ -match '^\s*-\s+' } | ForEach-Object {
                    $line = ($_ -replace '^\s*-\s+', '').Trim()
                    $tier = 'normal'
                    if ($line -match '^\[(feature|normal|trivial)\]\s*') {
                        $tier = $Matches[1]
                        $line = ($line -replace '^\[(feature|normal|trivial)\]\s*', '').Trim()
                    }
                    @{ text = $line; tier = $tier }
                } | Where-Object { $_.text })
            } else {
                Write-Warning "AI summarization failed for $dayKey, falling back to raw commits"
            }
        } catch {
            Write-Warning "AI summarization failed for ${dayKey}: $_"
        }
    }

    # Fallback: use cleaned-up raw commit messages with heuristic tiers
    if ($bullets.Count -eq 0) {
        # Strip trivial suffixes from semicolon-joined messages
        $trivialSuffixes = ';\s*(remove unused\b.*|clean ?up\b.*|minor\b.*|fix typo\b.*)$'
        $bullets = @($dayCommits | ForEach-Object {
            ($_.message -replace $trivialSuffixes, '').Trim()
        } | Sort-Object -Unique | ForEach-Object {
            @{ text = $_; tier = (Get-BulletTier $_) }
        })
    }

    $pacificDate = [datetime]::ParseExact($dayKey, "yyyy-MM-dd", $null)
    $displayDate = $pacificDate.ToString("MMMM d, yyyy")

    $entry = @{
        day          = $dayKey
        date_utc     = $dayCommits[0].date_utc  # newest commit (git log is newest-first)
        display      = $displayDate
        bullets      = $bullets
        commit_range = "$($commitShas[-1])..$($commitShas[0])"
    }
    $newEntries += $entry
    Write-Host "  Added changelog entry for $dayKey ($($bullets.Count) bullets)"
}

if ($newEntries.Count -eq 0) {
    Write-Host "No new changelog entries to add"
    if ($entries.Count -gt 0) {
        Write-ChangelogHtml -Entries $entries -OutputFile $changelogHtml
    }
    exit 0
}

# Merge new entries with existing (replace any re-generated days), sort newest first
$replacedDays = @{}
$newEntries | ForEach-Object { $replacedDays[$_.day] = $true }
$kept = @($entries | Where-Object { -not $replacedDays.ContainsKey($_.day) })
$allEntries = @($newEntries) + $kept | Sort-Object -Property { $_.day } -Descending

# Save JSON
$allEntries | ConvertTo-Json -Depth 5 | Out-File -FilePath $changelogJson -Encoding utf8
Write-Host "Saved $($allEntries.Count) entries to $changelogJson"

# Render HTML
Write-ChangelogHtml -Entries $allEntries -OutputFile $changelogHtml

} catch {
    Write-Warning "Changelog generation failed: $_"
    Write-Warning "Continuing without changelog update"
    exit 0
}
