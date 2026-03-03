<#
.SYNOPSIS
    Converts PR triage JSON data to a styled full-width HTML page.
.PARAMETER InputFile
    Path to the filtered JSON file (array of PR objects).
.PARAMETER Title
    Report title (e.g., "Top 15 Most Actionable PRs").
.PARAMETER Observations
    AI-generated observations text (markdown bullet list). Optional.
.PARAMETER Repo
    Repository slug for PR links (default: dotnet/runtime).
.PARAMETER OutputFile
    Path to write the HTML output.
.PARAMETER Timestamp
    ISO 8601 timestamp string for the "Updated" line.
.PARAMETER NavLinks
    Hashtable of name→filename for navigation links.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [Parameter(Mandatory)][string]$Title,
    [string]$Observations = "",
    [string]$Repo = "dotnet/runtime",
    [Parameter(Mandatory)][string]$OutputFile,
    [string]$Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm 'UTC'"),
    [hashtable]$NavLinks = @{}
)

$ErrorActionPreference = "Stop"

$prs = Get-Content $InputFile -Raw | ConvertFrom-Json

# Build nav HTML
$navHtml = ""
if ($NavLinks.Count -gt 0) {
    $links = $NavLinks.GetEnumerator() | Sort-Object Name | ForEach-Object {
        "<a href=`"$($_.Value)`">$($_.Name)</a>"
    }
    $navHtml = "<nav>$($links -join ' | ')</nav>"
}

# Build table rows
$rows = foreach ($pr in $prs) {
    $prUrl = "https://github.com/$Repo/pull/$($pr.number)"
    $ciEmoji = switch ($pr.ci) {
        "SUCCESS"     { "&#x2705;" }
        "FAILURE"     { "&#x274C;" }
        "IN_PROGRESS" { "&#x23F3;" }
        default       { "&#x26A0;&#xFE0F;" }
    }
    $communityBadge = if ($pr.is_community) { ' <span class="badge community">community</span>' } else { "" }
    $authorDisplay = $pr.author
    if ($pr.author -match "copilot-swe-agent") { $authorDisplay = "&#x1F916; copilot" }

    # Emoji prefix for next action
    $actionEmoji = if ($pr.next_action -match "Ready to merge") { "&#x1F7E2; " }       # 🟢
                   elseif ($pr.next_action -match "review needed") { "&#x1F441; " }     # 👁
                   elseif ($pr.next_action -match "resolve conflicts") { "&#x1F6D1; " } # 🛑
                   elseif ($pr.next_action -match "fix CI") { "&#x1F6D1; " }            # 🛑
                   elseif ($pr.next_action -match "respond to") { "&#x1F4AC; " }        # 💬
                   elseif ($pr.next_action -match "Wait for CI") { "&#x23F3; " }        # ⏳
                   elseif ($pr.next_action -match "merge main") { "&#x1F504; " }        # 🔄
                   else { "" }

    # Escape HTML in title
    $safeTitle = [System.Net.WebUtility]::HtmlEncode($pr.title)

    # Heat classes for age, staleness, and discussion
    $ageHeat = if ($pr.age_days -ge 60) { " heat-3" } elseif ($pr.age_days -ge 30) { " heat-2" } elseif ($pr.age_days -ge 14) { " heat-1" } else { "" }
    $updateHeat = if ($pr.days_since_update -ge 30) { " heat-3" } elseif ($pr.days_since_update -ge 14) { " heat-2" } elseif ($pr.days_since_update -ge 7) { " heat-1" } else { "" }
    $discHeat = if ($pr.total_threads -gt 15 -or $pr.distinct_commenters -gt 5) { " heat-3" } elseif ($pr.total_threads -gt 8 -or $pr.distinct_commenters -gt 3) { " heat-2" } elseif ($pr.total_threads -gt 4) { " heat-1" } else { "" }
    $discEmoji = if ($pr.total_threads -gt 15 -or $pr.distinct_commenters -gt 5) { "&#x1F525; " } else { "" }

    @"
<tr>
  <td class="score">$($pr.score)</td>
  <td class="pr-num"><a href="$prUrl">#$($pr.number)</a></td>
  <td class="title">$safeTitle</td>
  <td class="who">$([System.Net.WebUtility]::HtmlEncode($pr.who))</td>
  <td class="action">$actionEmoji$([System.Net.WebUtility]::HtmlEncode($pr.next_action))</td>
  <td class="ci">$ciEmoji $($pr.ci_detail)</td>
  <td class="disc$discHeat">$discEmoji$($pr.total_threads)t/$($pr.distinct_commenters)p</td>
  <td class="num$ageHeat">$($pr.age_days)d</td>
  <td class="num$updateHeat">$($pr.days_since_update)d</td>
  <td class="num">$($pr.changed_files)</td>
  <td class="author">$authorDisplay$communityBadge</td>
</tr>
"@
}

# Build observations HTML
$obsHtml = ""
if ($Observations.Trim()) {
    # Convert markdown bullets to HTML list items
    $items = $Observations -split "`n" | Where-Object { $_.Trim() -match "^[-*]" } | ForEach-Object {
        $text = ($_ -replace "^[\s]*[-*]\s*", "").Trim()
        $encoded = [System.Net.WebUtility]::HtmlEncode($text)
        # Hyperlink PR references like #12345
        $encoded = [regex]::Replace($encoded, '#(\d{3,})', "<a href=`"https://github.com/$Repo/pull/`$1`">#`$1</a>")
        "<li>$encoded</li>"
    }
    if ($items.Count -gt 0) {
        $obsHtml = @"
<div class="observations">
  <h3>Observations</h3>
  <ul>
    $($items -join "`n    ")
  </ul>
</div>
"@
    }
}

$prCount = @($prs).Count

# Scoring explainer for "actionable" reports
$scoringHtml = ""
if ($Title -match "Actionable|Top 15") {
    $scoringHtml = @"
<details class="scoring">
  <summary>How is the score calculated?</summary>
  <p>Each PR is scored 0&ndash;10 on a weighted composite of 12 dimensions:</p>
  <table class="scoring-table">
    <tr><th>Weight</th><th>Dimension</th><th>What it measures</th></tr>
    <tr><td>3.0</td><td>CI (Build Analysis)</td><td>Hard blocker &mdash; can&rsquo;t merge if CI is red</td></tr>
    <tr><td>3.0</td><td>Merge conflicts</td><td>Hard blocker &mdash; unmergeable</td></tr>
    <tr><td>3.0</td><td>Maintainer review</td><td>Hard blocker &mdash; requires owner/triager approval</td></tr>
    <tr><td>2.0</td><td>Feedback</td><td>Unresolved review threads</td></tr>
    <tr><td>2.0</td><td>Approval strength</td><td>Who approved: area owner &gt; triager &gt; contributor</td></tr>
    <tr><td>1.5</td><td>Staleness</td><td>Days since last update</td></tr>
    <tr><td>1.5</td><td>Discussion complexity</td><td>Thread count and distinct commenters</td></tr>
    <tr><td>1.0</td><td>Alignment</td><td>Has area label, not untriaged</td></tr>
    <tr><td>1.0</td><td>Freshness</td><td>Recent activity</td></tr>
    <tr><td>1.0</td><td>Size</td><td>Smaller = easier to review</td></tr>
    <tr><td>0.5</td><td>Community</td><td>Flags community PRs for visibility</td></tr>
    <tr><td>0.5</td><td>Velocity</td><td>Review momentum</td></tr>
  </table>
  <p>Higher score = closer to merge-ready. The &ldquo;Next Action&rdquo; column identifies who needs to act and what they need to do.
  See <a href="https://github.com/dotnet/runtime/pull/125005">pr-triage skill</a> for full details.</p>
</details>
"@
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$([System.Net.WebUtility]::HtmlEncode($Title)) - PR Dashboard</title>
<style>
  :root { --bg: #0d1117; --fg: #e6edf3; --border: #30363d; --link: #58a6ff;
           --badge-community: #238636; --hover: #161b22; --header-bg: #161b22; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
         background: var(--bg); color: var(--fg); padding: 1em 2em; }
  nav { margin-bottom: 1em; font-size: 0.9em; }
  nav a { color: var(--link); text-decoration: none; margin: 0 0.3em; }
  nav a:hover { text-decoration: underline; }
  h1 { font-size: 1.4em; margin-bottom: 0.2em; }
  .meta { color: #8b949e; font-size: 0.85em; margin-bottom: 1em; }
  table { border-collapse: collapse; width: 100%; font-size: 0.85em; }
  thead { position: sticky; top: 0; z-index: 1; }
  th { background: var(--header-bg); padding: 6px 10px; text-align: left;
       border-bottom: 2px solid var(--border); white-space: nowrap; font-weight: 600; }
  td { padding: 5px 10px; border-bottom: 1px solid var(--border); vertical-align: top; }
  tr:hover { background: var(--hover); }
  a { color: var(--link); text-decoration: none; }
  a:hover { text-decoration: underline; }
  .score { font-weight: bold; text-align: right; white-space: nowrap; }
  .pr-num { white-space: nowrap; }
  .title { max-width: 350px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .who, .action { white-space: nowrap; }
  .ci { white-space: nowrap; }
  .disc, .num { text-align: right; white-space: nowrap; }
  .heat-1 { background: rgba(187, 128, 9, 0.15); }
  .heat-2 { background: rgba(210, 105, 30, 0.22); }
  .heat-3 { background: rgba(218, 54, 51, 0.25); color: #f85149; }
  .author { white-space: nowrap; }
  .badge { font-size: 0.75em; padding: 1px 6px; border-radius: 10px; margin-left: 4px; }
  .badge.community { background: var(--badge-community); color: #fff; }
  .observations { margin-top: 1.5em; max-width: 900px; }
  .observations h3 { font-size: 1.1em; margin-bottom: 0.5em; }
  .observations ul { padding-left: 1.5em; }
  .observations li { margin-bottom: 0.4em; line-height: 1.4; }
  .scoring { margin-top: 1.5em; max-width: 900px; color: #8b949e; font-size: 0.85em; }
  .scoring summary { cursor: pointer; color: var(--fg); font-weight: 500; }
  .scoring p { margin: 0.5em 0; line-height: 1.4; }
  .scoring-table { width: auto; font-size: 0.95em; margin: 0.5em 0; }
  .scoring-table th, .scoring-table td { padding: 3px 10px; border: 1px solid var(--border); }
  @media (prefers-color-scheme: light) {
    :root { --bg: #fff; --fg: #1f2328; --border: #d0d7de; --link: #0969da;
             --hover: #f6f8fa; --header-bg: #f6f8fa; }
    .heat-1 { background: rgba(187, 128, 9, 0.1); }
    .heat-2 { background: rgba(210, 105, 30, 0.15); }
    .heat-3 { background: rgba(218, 54, 51, 0.18); color: #cf222e; }
  }
</style>
</head>
<body>
$navHtml
<h1>$([System.Net.WebUtility]::HtmlEncode($Title))</h1>
<p class="meta">Updated: $Timestamp &middot; $prCount PRs &middot; <a href="https://github.com/$Repo">$Repo</a></p>
<table>
<thead>
<tr>
  <th>Score</th><th>PR</th><th>Title</th><th>Who</th><th>Next Action</th>
  <th>CI</th><th>Disc</th><th>Age</th><th>Updated</th><th>Files</th><th>Author</th>
</tr>
</thead>
<tbody>
$($rows -join "`n")
</tbody>
</table>
$obsHtml
$scoringHtml
</body>
</html>
"@

$html | Out-File -FilePath $OutputFile -Encoding utf8
Write-Verbose "Wrote $OutputFile ($prCount PRs)"
