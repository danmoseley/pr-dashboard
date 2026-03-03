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

    # Escape HTML in title
    $safeTitle = [System.Net.WebUtility]::HtmlEncode($pr.title)

    @"
<tr>
  <td class="score">$($pr.score)</td>
  <td class="pr-num"><a href="$prUrl">#$($pr.number)</a></td>
  <td class="title">$safeTitle</td>
  <td class="who">$([System.Net.WebUtility]::HtmlEncode($pr.who))</td>
  <td class="action">$([System.Net.WebUtility]::HtmlEncode($pr.next_action))</td>
  <td class="ci">$ciEmoji $($pr.ci_detail)</td>
  <td class="disc">$($pr.total_threads)t/$($pr.distinct_commenters)p</td>
  <td class="num">$($pr.age_days)d</td>
  <td class="num">$($pr.days_since_update)d</td>
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
        "<li>$([System.Net.WebUtility]::HtmlEncode($text))</li>"
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
  .author { white-space: nowrap; }
  .badge { font-size: 0.75em; padding: 1px 6px; border-radius: 10px; margin-left: 4px; }
  .badge.community { background: var(--badge-community); color: #fff; }
  .observations { margin-top: 1.5em; max-width: 900px; }
  .observations h3 { font-size: 1.1em; margin-bottom: 0.5em; }
  .observations ul { padding-left: 1.5em; }
  .observations li { margin-bottom: 0.4em; line-height: 1.4; }
  @media (prefers-color-scheme: light) {
    :root { --bg: #fff; --fg: #1f2328; --border: #d0d7de; --link: #0969da;
             --hover: #f6f8fa; --header-bg: #f6f8fa; }
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
</body>
</html>
"@

$html | Out-File -FilePath $OutputFile -Encoding utf8
Write-Verbose "Wrote $OutputFile ($prCount PRs)"
