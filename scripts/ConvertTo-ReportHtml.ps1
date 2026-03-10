<#
.SYNOPSIS
    Converts PR triage JSON data to a styled full-width HTML page.
.PARAMETER InputFile
    Path to the filtered JSON file (array of PR objects).
.PARAMETER Title
    Report title (e.g., "Most Actionable PRs").
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
    [int]$ScheduleHours = 0,
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

# Helper: replace @username with avatar + linked username + filter button
function ConvertTo-UserHtml([string]$text) {
    # Match @user or @app/bot-name as a single token
    [regex]::Replace($text, '@((?:app/)?[\w-]+)', {
        param($m)
        $full = $m.Groups[1].Value
        if ($full -match '^app/(.+)$') {
            # Bot app — link to GitHub Apps page, no avatar/filter
            $name = $Matches[1]
            "<a href=`"https://github.com/apps/$name`">@$name</a>"
        } else {
            $u = $full
            "<span class=`"user-ref`"><img class=`"avatar`" src=`"https://github.com/$u.png?size=32`" alt=`"$u`"><a href=`"https://github.com/$u`">@$u</a><a class=`"filter-btn`" href=`"#`" onclick=`"filterByUser('$u');return false`" title=`"Show only @$u`">&#x1F50D; only</a></span>"
        }
    })
}

# Build table rows
$rowIndex = 0
$rows = foreach ($pr in $prs) {
    $rowIndex++
    $prUrl = "https://github.com/$Repo/pull/$($pr.number)"
    $ciEmoji = switch ($pr.ci) {
        "SUCCESS"     { "&#x2705;" }
        "FAILURE"     { "&#x274C;" }
        "IN_PROGRESS" { "&#x23F3;" }
        default       { "&#x26A0;&#xFE0F;" }
    }
    # Parse ci_detail (passed/failed/running) to detect failures behind a passing Build Analysis
    $ciFailCount = 0
    if ($pr.ci_detail -match '^(\d+)/(\d+)/(\d+)$') { $ciFailCount = [int]$Matches[2] }
    $ciTitle = ""
    $ciFailHint = ""
    if ($pr.ci -eq "SUCCESS" -and $ciFailCount -gt 0) {
        $ciTitle = " title=`"Build Analysis passed; $ciFailCount non-blocking check(s) failed`""
        $ciFailHint = "<sup class=`"ci-warn`">$ciFailCount</sup>"
    }
    $communityBadge = if ($pr.is_community) { ' <span class="badge community">community</span>' } else { "" }
    # Show community badge in Who column when it contains the community PR author
    $whoCommunityBadge = if ($pr.is_community -and $pr.who -match [regex]::Escape($pr.author)) { ' <span class="badge community">community</span>' } else { "" }
    $authorDisplay = ConvertTo-UserHtml "@$($pr.author)"
    if ($pr.author -match "copilot-swe-agent") {
        if ($pr.copilot_trigger) {
            $authorDisplay = "$(ConvertTo-UserHtml "@$($pr.copilot_trigger)") <span class=`"badge`" title=`"authored by Copilot`">via &#x1F916;</span>"
        } else {
            $authorDisplay = "&#x1F916; copilot"
        }
    }

    # Emoji prefix for next action
    $actionEmoji = if ($pr.next_action -match "Ready to merge") { "&#x1F7E2; " }       # 🟢
                   elseif ($pr.next_action -match "review needed") { "&#x1F441; " }     # 👁
                   elseif ($pr.next_action -match "resolve conflicts") { "&#x1F6D1; " } # 🛑
                   elseif ($pr.next_action -match "fix CI") { "&#x1F6D1; " }            # 🛑
                   elseif ($pr.next_action -match "respond to") { "" }                    # no emoji, text is clear
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
    $filesHeat = if ($pr.changed_files -gt 20 -or $pr.lines_changed -gt 500) { " heat-2" } elseif ($pr.changed_files -gt 5 -or $pr.lines_changed -gt 200) { " heat-1" } else { "" }

    $safeWhy = [System.Net.WebUtility]::HtmlEncode($pr.why)
    $safeBlockers = [System.Net.WebUtility]::HtmlEncode($pr.blockers)

    # Collect all @usernames for filtering
    $allText = "$($pr.who) @$($pr.author) $($pr.next_action)"
    if ($pr.copilot_trigger) { $allText += " @$($pr.copilot_trigger)" }
    $people = @([regex]::Matches($allText, '@([\w-]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ','

    $moreClass = if ($rowIndex -gt 100) { ' class="more-row" style="display:none"' } else { "" }

    @"
<tr$moreClass data-people="$people">
  <td class="score" title="$safeWhy">$($pr.score)</td>
  <td class="pr-num"><a href="$prUrl">#$($pr.number)</a></td>
  <td class="title">$safeTitle</td>
  <td class="who">$(ConvertTo-UserHtml ([System.Net.WebUtility]::HtmlEncode($pr.who)))$whoCommunityBadge</td>
  <td class="action" title="$safeBlockers">$actionEmoji$(ConvertTo-UserHtml ([System.Net.WebUtility]::HtmlEncode($pr.next_action)))</td>
  <td class="ci"$ciTitle>$ciEmoji$ciFailHint $($pr.ci_detail)</td>
  <td class="disc$discHeat">$discEmoji$($pr.unresolved_threads)/$($pr.total_threads)t $($pr.distinct_commenters)p</td>
  <td class="num$ageHeat">$($pr.age_days)d</td>
  <td class="num$updateHeat">$($pr.days_since_update)d</td>
  <td class="num$filesHeat" title="$($pr.lines_changed) lines changed">$($pr.changed_files)</td>
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

# Show more / collapse toggle (pages of 100)
$toggleHtml = ""
if ($prCount -gt 100) {
    $extraCount = $prCount - 100
    $toggleHtml = @"
<button class="show-more-btn" id="toggle-more">Show $extraCount more &#x25BC;</button>
<script>
(function() {
  var btn = document.getElementById('toggle-more');
  btn.addEventListener('click', function() {
    var rows = document.querySelectorAll('.more-row');
    var showing = rows[0] && rows[0].style.display !== 'none';
    rows.forEach(function(r) { r.style.display = showing ? 'none' : ''; });
    btn.innerHTML = showing ? 'Show $extraCount more \u25BC' : 'Show fewer \u25B2';
  });
})();
</script>
"@
}

# Scoring explainer
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
  <p>Higher score = fewer blockers remaining (green CI, approvals, no unresolved threads, etc.). The &ldquo;Next Action&rdquo; column identifies who needs to act and what they need to do.
  See <a href="https://github.com/dotnet/runtime/pull/125005">pr-triage skill</a> for full details.</p>
</details>
"@

$scheduleNote= if ($ScheduleHours -gt 0) { "Updated every ${ScheduleHours}h, last at $Timestamp" } else { "Updated: $Timestamp" }

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
  .ci-warn { color: #d29922; font-size: 0.7em; vertical-align: super; margin-left: -2px; }
  .disc, .num { text-align: right; white-space: nowrap; }
  .heat-1 { background: rgba(187, 128, 9, 0.15); }
  .heat-2 { background: rgba(210, 105, 30, 0.22); }
  .heat-3 { background: rgba(218, 54, 51, 0.25); color: #f85149; }
  .author { white-space: nowrap; }
  .avatar { width: 16px; height: 16px; border-radius: 50%; vertical-align: text-bottom; margin-right: 2px; }
  .badge { font-size: 0.75em; padding: 1px 6px; border-radius: 10px; margin-left: 4px; }
  .badge.community { background: var(--badge-community); color: #fff; }
  .observations { margin-top: 1.5em; max-width: 900px; }
  .observations h3 { font-size: 1.1em; margin-bottom: 0.5em; }
  .observations ul { padding-left: 1.5em; }
  .observations li { margin-bottom: 0.4em; line-height: 1.4; }
  .scoring { margin: 0.5em 0 1em; max-width: 900px; color: #8b949e; font-size: 0.85em; }
  .scoring summary { cursor: pointer; color: var(--fg); font-weight: 500; }
  .scoring p { margin: 0.5em 0; line-height: 1.4; }
  .scoring-table { width: auto; font-size: 0.95em; margin: 0.5em 0; }
  .scoring-table th, .scoring-table td { padding: 3px 10px; border: 1px solid var(--border); }
  .show-more-btn { display: block; margin: 1em auto; padding: 6px 20px; font-size: 0.9em; cursor: pointer;
    background: var(--header-bg); color: var(--link); border: 1px solid var(--border);
    border-radius: 6px; font-weight: 500; }
  .show-more-btn:hover { background: var(--hover); text-decoration: underline; }
  .user-ref { position: relative; display: inline-block; }
  .filter-btn { font-size: 0.7em; margin-left: 2px; padding: 0 3px; border-radius: 3px;
    background: var(--header-bg); border: 1px solid var(--border); color: #484f58; vertical-align: middle;
    text-decoration: none !important; cursor: pointer; filter: grayscale(1) opacity(0.5); }
  .filter-btn:hover { color: var(--link); border-color: var(--link); filter: none; }
  .filter-banner { position: sticky; top: 0; z-index: 2; background: var(--header-bg); border: 1px solid var(--border);
    border-radius: 6px; padding: 6px 14px; margin-bottom: 0.5em; font-size: 0.9em; display: none; }
  .filter-banner a { margin-left: 8px; }
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
<p class="meta">$scheduleNote &middot; $prCount PRs &middot; <a href="https://github.com/$Repo">$Repo</a></p>
$scoringHtml
<div class="filter-banner" id="filter-banner">Showing PRs for <strong id="filter-name"></strong> <a href="#" onclick="clearFilter();return false">&#x2715; Clear</a></div>
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
$toggleHtml
$obsHtml
<script>
function filterByUser(name) {
  var rows = document.querySelectorAll('tbody tr');
  var count = 0;
  rows.forEach(function(r) {
    var people = (',' + (r.getAttribute('data-people') || '') + ',').toLowerCase();
    if (people.indexOf(',' + name.toLowerCase() + ',') >= 0) {
      r.style.display = '';
      count++;
    } else {
      r.style.display = 'none';
    }
  });
  var banner = document.getElementById('filter-banner');
  document.getElementById('filter-name').textContent = '@' + name;
  banner.style.display = 'block';
  var btn = document.getElementById('toggle-more');
  if (btn) btn.style.display = 'none';
  history.replaceState(null, '', location.pathname + '?user=' + encodeURIComponent(name));
}
function clearFilter() {
  var rows = document.querySelectorAll('tbody tr');
  rows.forEach(function(r) {
    r.style.display = r.classList.contains('more-row') ? 'none' : '';
  });
  document.getElementById('filter-banner').style.display = 'none';
  var btn = document.getElementById('toggle-more');
  if (btn) btn.style.display = '';
  history.replaceState(null, '', location.pathname);
}
// Apply ?user=X filter on page load
(function() {
  var params = new URLSearchParams(location.search);
  var user = params.get('user');
  if (user) filterByUser(user);
})();
</script>
</body>
</html>
"@

$html | Out-File -FilePath $OutputFile -Encoding utf8
Write-Verbose "Wrote $OutputFile ($prCount PRs)"
