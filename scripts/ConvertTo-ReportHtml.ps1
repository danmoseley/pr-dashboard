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
.PARAMETER TimestampIso
    ISO 8601 UTC timestamp used for the page's data-server-updated attribute,
    which enables client-side cache invalidation for per-PR refresh.
.PARAMETER NavLinks
    Hashtable of name→filename for navigation links.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [Parameter(Mandatory)][string]$Title,
    [string]$Description = "",
    [string]$Observations = "",
    [string]$Repo = "dotnet/runtime",
    [Parameter(Mandatory)][string]$OutputFile,
    [string]$Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm 'UTC'"),
    [string]$TimestampIso = (Get-Date).ToUniversalTime().ToString("o"),
    [int]$ScheduleHours = 0,
    [hashtable]$NavLinks = @{},
    [string]$DefaultSort = "action"
)

$ErrorActionPreference = "Stop"

$prs = Get-Content $InputFile -Raw | ConvertFrom-Json

# Detect whether any PR has area labels (to conditionally show Area column)
$hasAnyAreaLabels = @($prs | Where-Object { $_.area_labels -and $_.area_labels.Count -gt 0 }).Count -gt 0

# Build nav HTML
$navHtml = ""
if ($NavLinks.Count -gt 0) {
    $homeLink = ""
    $otherLinks = @()
    foreach ($entry in ($NavLinks.GetEnumerator() | Sort-Object Name)) {
        if ($entry.Name -eq "Home") {
            $homeLink = "<a href=`"$($entry.Value)`">$($entry.Name)</a>"
        } else {
            $otherLinks += "<a href=`"$($entry.Value)`">$($entry.Name)</a>"
        }
    }
    $allLinks = if ($homeLink) { @($homeLink) + $otherLinks } else { $otherLinks }
    $navHtml = "<nav>$($allLinks -join ' | ') | <a class=`"feedback`" href=`"https://github.com/danmoseley/pr-dashboard/issues/new?title=Feedback&amp;body=Report:%20$Repo/$($OutputFile | Split-Path -Leaf)`" target=`"_blank`">&#x1F4AC; Feedback</a></nav>"
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
            "<span class=`"user-ref`"><img class=`"avatar`" src=`"https://github.com/$u.png?size=32`" alt=`"$u`"><a href=`"https://github.com/$u`">@$u</a><a class=`"filter-btn`" href=`"#`" onclick=`"filterByUser('$u');return false`" title=`"Show only @$u`">&#x1F50D;</a></span>"
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
    if ($pr.ci_detail -match '^(\d+)/(\d+)/(\d+)$') {
        $ciPassed = $Matches[1]; $ciFailed = $Matches[2]; $ciRunning = $Matches[3]
        $ciTitle = " title=`"$ciPassed passed, $ciFailed failed, $ciRunning running`""
        if ($pr.ci -eq "SUCCESS" -and $ciFailCount -gt 0) {
            $ciTitle = " title=`"Build Analysis passed; $ciFailCount non-blocking check(s) failed&#10;$ciPassed passed, $ciFailed failed, $ciRunning running`""
            $ciFailHint = "<sup class=`"ci-warn`">$ciFailCount</sup>"
        }
    }
    $communityBadge = if ($pr.is_community) { ' <span class="badge community" title="community">C</span>' } else { "" }
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
                   elseif ($pr.next_action -match "resolve conflicts") { "&#x1F6D1; " } # 🛑
                   elseif ($pr.next_action -match "fix CI") { "&#x1F6D1; " }            # 🛑
                   elseif ($pr.next_action -match "review needed") { "&#x1F441; " }     # 👁
                   elseif ($pr.next_action -match "respond to") { "" }                    # no emoji, text is clear
                   elseif ($pr.next_action -match "Wait for CI") { "&#x23F3; " }        # ⏳
                   elseif ($pr.next_action -match "merge main") { "&#x1F504; " }        # 🔄
                   else { "" }

    # Escape HTML in title
    $safeTitle = [System.Net.WebUtility]::HtmlEncode($pr.title)

    # Area label badges (shown before title)
    $areaLabelHtml = ""
    if ($pr.area_labels) {
        $areaLabelHtml = ($pr.area_labels | ForEach-Object {
            $name = $_ -replace '^area-', ''
            $safeName = [System.Net.WebUtility]::HtmlEncode($name)
            $safeFullName = [System.Net.WebUtility]::HtmlEncode($_)
            " <a class=`"badge area-label`" href=`"#`" onclick=`"filterByLabel('$safeFullName');return false`" title=`"Show only $safeFullName`">$safeName</a>"
        }) -join ""
    }

    # Heat classes for age, staleness, and discussion
    $ageHeat = if ($pr.age_days -ge 60) { " heat-3" } elseif ($pr.age_days -ge 30) { " heat-2" } elseif ($pr.age_days -ge 14) { " heat-1" } else { "" }
    $updateHeat = if ($pr.days_since_update -ge 30) { " heat-3" } elseif ($pr.days_since_update -ge 14) { " heat-2" } elseif ($pr.days_since_update -ge 7) { " heat-1" } else { "" }
    $discHeat = if ($pr.total_threads -gt 15 -or $pr.distinct_commenters -gt 5) { " heat-3" } elseif ($pr.total_threads -gt 8 -or $pr.distinct_commenters -gt 3) { " heat-2" } elseif ($pr.total_threads -gt 4) { " heat-1" } else { "" }
    $discEmoji = if ($pr.total_threads -gt 15 -or $pr.distinct_commenters -gt 5) { "&#x1F525; " } else { "" }
    $filesHeat = if ($pr.changed_files -gt 20 -or $pr.lines_changed -gt 500) { " heat-2" } elseif ($pr.changed_files -gt 5 -or $pr.lines_changed -gt 200) { " heat-1" } else { "" }

    $safeWhy = $pr.why
    $safeBlockers = [System.Net.WebUtility]::HtmlEncode($pr.blockers)

    # Collect all @usernames for filtering
    $allText = "$($pr.who) @$($pr.author) $($pr.next_action)"
    if ($pr.copilot_trigger) { $allText += " @$($pr.copilot_trigger)" }
    $people = @([regex]::Matches($allText, '@([\w-]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ','

    $labelsList = if ($pr.area_labels) { ($pr.area_labels -join ',') } else { "" }

    $moreClass = if ($rowIndex -gt 100) { ' class="more-row" style="display:none"' } else { "" }

    $safeValueWhy = $pr.value_why
    $safeActionWhy = $pr.action_why

    $readyClass = if ([double]$pr.merge_readiness -ge 6) { " ready-high" } else { "" }
    $actionClass = if ([double]$pr.action_score -ge 5) { " action-hot" } elseif ([double]$pr.action_score -ge 4) { " action-warm" } else { "" }
    $actionEmoji2 = ""
    if ([double]$pr.action_score -ge 5) {
        $actionEmoji2 = "&#x1F3AF; "
    } elseif ([double]$pr.action_score -ge 4) {
        # Opacity scales from 0.3 at 4.0 to 0.9 at 4.9
        $boltOpacity = [Math]::Round(0.3 + (([double]$pr.action_score - 4.0) / 1.0) * 0.6, 2)
        $actionEmoji2 = "<span style=`"opacity:$boltOpacity`">&#x26A1;</span> "
    }

    @"
<tr$moreClass data-people="$people" data-labels="$labelsList">
  <td class="score$readyClass">$($pr.merge_readiness)<button type="button" class="why-btn" onclick="showWhy(this)" data-why="$safeWhy" aria-label="Show Ready score breakdown">?</button></td>
  <td class="score">$($pr.value_score)<button type="button" class="why-btn" onclick="showWhy(this)" data-why="$safeValueWhy" aria-label="Show Need score breakdown">?</button></td>
  <td class="action-score$actionClass">$actionEmoji2$($pr.action_score)<button type="button" class="why-btn action-why-btn" onclick="showWhy(this)" data-why="$safeActionWhy" aria-label="Show Action score breakdown">?</button></td>
  <td class="pr-num"><a href="$prUrl" title="$safeTitle">#$($pr.number)</a></td>
  <td class="title">$safeTitle</td>
  <td class="action" title="$safeBlockers">$actionEmoji$(ConvertTo-UserHtml ([System.Net.WebUtility]::HtmlEncode($pr.next_action)))</td>
  <td class="ci"$ciTitle>$ciEmoji$ciFailHint $($pr.ci_detail)</td>
  <td class="disc$discHeat">$discEmoji$($pr.unresolved_threads)/$($pr.total_threads)t $($pr.distinct_commenters)ppl<button type="button" class="why-btn" onclick="showWhy(this)" data-why="$($pr.unresolved_threads) unresolved of $($pr.total_threads) review threads&#10;$($pr.distinct_commenters) distinct commenters" aria-label="Show discussion breakdown">?</button></td>
  <td class="num$ageHeat">$($pr.age_days)d</td>
  <td class="num$updateHeat">$($pr.days_since_update)d</td>
  <td class="num$filesHeat" title="$($pr.lines_changed) lines changed">$($pr.changed_files)</td>
  <td class="author">$communityBadge$authorDisplay</td>
  $(if ($hasAnyAreaLabels) { "<td class=`"area-col`">$areaLabelHtml</td>" })
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
  <summary>How are the scores calculated?</summary>
  <p>Each PR has three scores on a 0&ndash;10 scale:</p>
  <div style="display:flex; gap:1.5em; flex-wrap:wrap;">
    <div style="flex:1; min-width:250px;">
      <h4 style="margin:0.5em 0 0.3em">Ready &mdash; how close to merging?</h4>
      <table class="scoring-table">
        <tr><th>Points</th><th>Signal</th></tr>
        <tr><td>3.0</td><td>No merge conflicts</td></tr>
        <tr><td>2.5</td><td>CI passing</td></tr>
        <tr><td>2.5</td><td>Has approval</td></tr>
        <tr><td>2.5</td><td>Feedback addressed</td></tr>
        <tr><td>2.5</td><td>Discussion healthy</td></tr>
        <tr><td>2.0</td><td>Small, easy to review</td></tr>
        <tr><td>1.5</td><td>Has maintainer review</td></tr>
        <tr><td>1.0</td><td>Recently active</td></tr>
        <tr><td>0.5&ndash;1.0</td><td>Team or known author (1.0) / community (0.5)</td></tr>
        <tr><td>0.7</td><td>Recently updated</td></tr>
        <tr><td>0.5</td><td>Well labeled</td></tr>
        <tr><td>0.3</td><td>Good review momentum</td></tr>
      </table>
    </div>
    <div style="flex:1; min-width:250px;">
      <h4 style="margin:0.5em 0 0.3em">Need &mdash; benefits from attention?</h4>
      <table class="scoring-table">
        <tr><th>Points</th><th>Signal</th></tr>
        <tr><td>1.5</td><td>No approval yet</td></tr>
        <tr><td>1.5</td><td>Pending feedback, author silent &gt;14d</td></tr>
        <tr><td>1.0</td><td>Community author</td></tr>
        <tr><td>1.0</td><td>Reviewed, not approved</td></tr>
        <tr><td>1.0</td><td>Has unresolved feedback</td></tr>
        <tr><td>1.0</td><td>High interest</td></tr>
        <tr><td>0.5</td><td>Pending feedback, author slow (7&ndash;14d)</td></tr>
        <tr><td>0.5</td><td>Large change (&gt;200 lines)</td></tr>
        <tr><td>0.5</td><td>Old but active (&gt;30d)</td></tr>
      </table>
    </div>
    <div style="flex:1; min-width:250px;">
      <h4 style="margin:0.5em 0 0.3em">Action &mdash; best use of your time?</h4>
      <p><code>(ready + 1) &times; (need + 1)</code><br>normalized to 0&ndash;10</p>
      <p>PRs that are both high-need <em>and</em> near-ready rank highest.</p>
      <p>&#x1F3AF; = action &ge; 5<br>&#x26A1; = action 4&ndash;5</p>
    </div>
  </div>
  <p style="font-size:0.85em; margin-top:0.8em;">Click any column header to re-sort. See <a href="https://github.com/danmoseley/pr-dashboard/pull/4">weight calibration analysis</a> for methodology.</p>
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
           --badge-community: #238636; --badge-area: #d4c5f9; --hover: #161b22; --header-bg: #161b22; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
         background: var(--bg); color: var(--fg); padding: 1em 2em; }
  nav { margin-bottom: 1em; font-size: 0.9em; }
  nav a { color: var(--link); text-decoration: none; margin: 0 0.3em; }
  nav a:hover { text-decoration: underline; }
  h1 { font-size: 1.4em; margin-bottom: 0.2em; }
  .meta { color: #8b949e; font-size: 0.85em; margin-bottom: 1em; }
  .report-desc { font-size: 0.9em; margin: 0.3em 0 0.8em; line-height: 1.4; }
  table { border-collapse: collapse; width: 100%; font-size: 0.85em; table-layout: auto; }
  thead { position: sticky; top: 0; z-index: 1; }
  th { background: var(--header-bg); padding: 6px 10px; text-align: left;
       border-bottom: 2px solid var(--border); white-space: nowrap; font-weight: 600; overflow: hidden; text-overflow: ellipsis; }
  td { padding: 5px 10px; border-bottom: 1px solid var(--border); vertical-align: top; }
  tr:hover { background: var(--hover); }
  a { color: var(--link); text-decoration: none; }
  a:hover { text-decoration: underline; }
  .score { font-weight: bold; text-align: right; white-space: nowrap; font-size: 0.95em; position: relative; }
  .ready-high { background: rgba(35, 134, 54, 0.12); }
  .action-score { font-weight: 800; text-align: right; white-space: nowrap; font-size: 1.25em; color: #f0c674;
    background: rgba(240, 198, 116, 0.08); border-left: 2px solid rgba(240, 198, 116, 0.3); border-right: 2px solid rgba(240, 198, 116, 0.3); position: relative; }
  .action-hot { background: rgba(35, 134, 54, 0.18); border-color: rgba(35, 134, 54, 0.4); }
  .action-warm { background: rgba(35, 134, 54, 0.08); border-color: rgba(35, 134, 54, 0.2); }
  .why-btn { display: inline-block; font-size: 0.7em; font-family: inherit; color: #484f58; cursor: pointer; margin-left: 3px;
    vertical-align: middle; font-weight: normal; text-decoration: none; padding: 0 3px; border-radius: 3px;
    background: var(--header-bg); border: 1px solid var(--border); filter: grayscale(1) opacity(0.65); line-height: 1.4; }
  .why-btn:hover { opacity: 1; color: var(--link); border-color: var(--link); filter: none; }
  .action-why-btn { color: #8b7640; }
  .action-why-btn:hover { color: #f0c674; border-color: #f0c674; }
  .why-popup { position: fixed; background: #1c2128; border: 1px solid #444c56; border-radius: 6px; padding: 10px 14px;
    font-size: 0.85em; color: #e6edf3; z-index: 100; max-width: 350px; white-space: pre-line; line-height: 1.5;
    box-shadow: 0 4px 12px rgba(0,0,0,0.4); pointer-events: auto; }
  th.action-col { background: rgba(240, 198, 116, 0.15) !important; color: #f0c674; font-weight: 700; }
  th.sortable { cursor: pointer; user-select: none; }
  th.sortable:hover { color: var(--link); }
  th.sorted { color: var(--link); }
  .pr-num { white-space: nowrap; }
  .title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .area-col { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .action { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ci { white-space: nowrap; padding: 5px 4px; }
  .ci-warn { color: #d29922; font-size: 0.7em; vertical-align: super; margin-left: -2px; }
  .disc { text-align: right; white-space: nowrap; padding: 5px 3px; font-size: 0.8em; }
  .num { text-align: right; white-space: nowrap; padding: 5px 4px; }
  .heat-1 { background: rgba(187, 128, 9, 0.15); }
  .heat-2 { background: rgba(210, 105, 30, 0.22); }
  .heat-3 { background: rgba(218, 54, 51, 0.25); color: #f85149; }
  .author { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .avatar { width: 16px; height: 16px; border-radius: 50%; vertical-align: text-bottom; margin-right: 2px; }
  .badge { font-size: 0.75em; padding: 1px 6px; border-radius: 10px; margin-left: 4px; }
  .badge.community { background: var(--badge-community); color: #fff; margin-left: 0; margin-right: 4px; }
  .badge.area-label { background: var(--badge-area); color: #1f2328; margin-left: 2px; text-decoration: none; cursor: pointer; }
  .badge.area-label:hover { text-decoration: none; opacity: 0.8; }
  .observations { margin-top: 1.5em; max-width: 900px; }
  .observations h3 { font-size: 1.1em; margin-bottom: 0.5em; }
  .observations ul { padding-left: 1.5em; }
  .observations li { margin-bottom: 0.4em; line-height: 1.4; }
  .scoring { margin: 0.5em 0 1em; max-width: 900px; color: var(--fg); font-size: 0.85em; }
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
    .action-score { color: #9a6700; background: rgba(154, 103, 0, 0.06); border-color: rgba(154, 103, 0, 0.2); }
    th.action-col { background: rgba(154, 103, 0, 0.1) !important; color: #9a6700; }
  }
  a.feedback { font-size: 0.8em; background: #1f6feb; color: #fff; padding: 2px 10px;
              border-radius: 10px; text-decoration: none; margin-left: 4px; }
  a.feedback:hover { background: #388bfd; color: #fff; text-decoration: none; }
</style>
</head>
<body data-server-updated="$TimestampIso">
$navHtml
<h1>$([System.Net.WebUtility]::HtmlEncode($Title))</h1>
<p class="meta">$scheduleNote &middot; $prCount PRs &middot; <a href="https://github.com/$Repo">$Repo</a></p>
$(if ($Description) { "<p class=`"report-desc`">$Description</p>" })
$scoringHtml
<div class="filter-banner" id="filter-banner">Showing PRs for <strong id="filter-name"></strong> <a href="#" onclick="clearFilter();return false">&#x2715; Clear</a></div>
$(if ($prCount -eq 0) {
'<table><tbody><tr><td style="padding: 2em; text-align: center; color: #8b949e; font-style: italic;">No PRs currently match this filter.</td></tr></tbody></table>'
} else {
$sortedMerge = if ($DefaultSort -eq "merge") { ' sorted desc' } else { '' }
$sortedValue = if ($DefaultSort -eq "value") { ' sorted desc' } else { '' }
$sortedAction = if ($DefaultSort -eq "action") { ' sorted desc' } else { '' }
$sortedUpd = if ($DefaultSort -eq "upd") { ' sorted desc' } else { '' }
$arrowMerge = if ($DefaultSort -eq "merge") { '<span class="sort-arrow"> &#x25BC;</span>' } else { '' }
$arrowValue = if ($DefaultSort -eq "value") { '<span class="sort-arrow"> &#x25BC;</span>' } else { '' }
$arrowAction = if ($DefaultSort -eq "action") { '<span class="sort-arrow"> &#x25BC;</span>' } else { '' }
$arrowUpd = if ($DefaultSort -eq "upd") { '<span class="sort-arrow"> &#x25BC;</span>' } else { '' }

@"
<table id="pr-table">
<colgroup>
  <col style="width:4.5%">
  <col style="width:4%">
  <col style="width:5%">
  <col style="width:4%">
  <col>
  <col style="width:24%">
  <col style="width:7%">
  <col style="width:3%">
  <col style="width:2.5%">
  <col style="width:2.5%">
  <col style="width:2.5%">
  <col style="width:8%">
  $(if ($hasAnyAreaLabels) { '<col style="width:7%">' })
</colgroup>
<thead>
<tr>
  <th class="sortable$sortedMerge" data-sort="num" title="Ready: how close is this PR to being mergeable? Based on CI, approvals, conflicts, size, etc.">Ready$arrowMerge</th><th class="sortable$sortedValue" data-sort="num" title="Need: how much does this PR benefit from attention? Community PRs, stalled feedback, missing approvals score higher.">Need$arrowValue</th><th class="sortable$sortedAction action-col" data-sort="num" title="Action: combined score = (ready+1) x (need+1), normalized 0-10. PRs that are both high-need and near-ready rank highest.">Action$arrowAction</th><th class="sortable" data-sort="num" title="Pull request number">PR</th><th class="sortable" data-sort="alpha" title="PR title and labels">Title</th><th title="Who needs to act next and what they should do">Next Action</th>
  <th title="CI status from Build Analysis (or latest check run)">CI</th><th class="sortable" data-sort="num" title="Discussion: sort by sum of all discussion numbers (unresolved + total threads + commenters)">Disc</th><th class="sortable" data-sort="num" title="Age in days since PR was opened">Age</th><th class="sortable$sortedUpd" data-sort="num" title="Days since last update (push, comment, or review)">Upd$arrowUpd</th><th class="sortable" data-sort="num" title="Number of files changed">Files</th><th class="sortable" data-sort="alpha" title="PR author">Author</th>$(if ($hasAnyAreaLabels) { "<th class=`"sortable`" data-sort=`"alpha`" title=`"Area labels assigned to this PR`">Area</th>" })
</tr>
</thead>
<tbody>
$($rows -join "`n")
</tbody>
</table>
"@
})
$toggleHtml
$obsHtml
<script>
var _filterKey = 'prFilter:' + location.pathname;
function filterByLabel(label) {
  var rows = document.querySelectorAll('tbody tr');
  var count = 0;
  rows.forEach(function(r) {
    var labels = (',' + (r.getAttribute('data-labels') || '') + ',').toLowerCase();
    if (labels.indexOf(',' + label.toLowerCase() + ',') >= 0) {
      r.style.display = '';
      count++;
    } else {
      r.style.display = 'none';
    }
  });
  var banner = document.getElementById('filter-banner');
  document.getElementById('filter-name').textContent = label;
  banner.style.display = 'block';
  var btn = document.getElementById('toggle-more');
  if (btn) btn.style.display = 'none';
  history.replaceState(null, '', location.pathname + '?label=' + encodeURIComponent(label));
  try { localStorage.setItem(_filterKey, JSON.stringify({type:'label',value:label})); } catch(e) {}
}
function filterByUser(name) {
  var rows = document.querySelectorAll('#pr-table tbody tr');
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
  try { localStorage.setItem(_filterKey, JSON.stringify({type:'user',value:name})); } catch(e) {}
}
function clearFilter() {
  var rows = document.querySelectorAll('#pr-table tbody tr');
  rows.forEach(function(r) {
    r.style.display = r.classList.contains('more-row') ? 'none' : '';
  });
  document.getElementById('filter-banner').style.display = 'none';
  var btn = document.getElementById('toggle-more');
  if (btn) btn.style.display = '';
  history.replaceState(null, '', location.pathname);
  try { localStorage.removeItem(_filterKey); } catch(e) {}
}
// Apply ?user=X or ?label=X filter on page load, or restore from localStorage
(function() {
  var params = new URLSearchParams(location.search);
  var user = params.get('user');
  var label = params.get('label');
  if (user) filterByUser(user);
  else if (label) filterByLabel(label);
  else {
    try {
      var saved = JSON.parse(localStorage.getItem(_filterKey));
      if (saved && saved.type === 'user') filterByUser(saved.value);
      else if (saved && saved.type === 'label') filterByLabel(saved.value);
    } catch(e) {}
  }
})();
// Resizable columns: drag right edge of any <th> to resize
(function() {
  var ths = document.querySelectorAll('thead th');
  ths.forEach(function(th) {
    var grip = document.createElement('div');
    grip.style.cssText = 'position:absolute;top:0;right:0;bottom:0;width:5px;cursor:col-resize;user-select:none';
    th.style.position = 'relative';
    grip.addEventListener('mousedown', function(e) {
      lockLayout();
      var startX = e.pageX, startW = th.offsetWidth;
      function onMove(e2) { th.style.width = Math.max(30, startW + e2.pageX - startX) + 'px'; th.style.minWidth = th.style.width; th.style.maxWidth = th.style.width; }
      function onUp() { document.removeEventListener('mousemove', onMove); document.removeEventListener('mouseup', onUp); }
      document.addEventListener('mousemove', onMove);
      document.addEventListener('mouseup', onUp);
      e.preventDefault();
    });
    th.appendChild(grip);
  });
  // On first drag, snapshot auto widths so resizing works predictably
  var tbl = document.querySelector('table'), locked = false;
  function lockLayout() {
    if (locked) return; locked = true;
  }
})();
// Show tooltip popup on [?] click
var activePopup = null;
var activePopupBtn = null;
function showWhy(el) {
  if (activePopup) {
    activePopup.remove();
    var wasSame = (activePopupBtn === el);
    activePopup = null; activePopupBtn = null;
    if (wasSame) return; // 2nd click on same [?] dismisses
  }
  var why = (el.getAttribute('data-why') || '').replace(/&#10;/g, '\n');
  if (!why) return;
  var popup = document.createElement('div');
  popup.className = 'why-popup';
  popup.textContent = why;
  document.body.appendChild(popup);
  var rect = el.getBoundingClientRect();
  popup.style.left = Math.max(0, Math.min(rect.right + 5, window.innerWidth - 360)) + 'px';
  popup.style.top = Math.max(0, rect.top) + 'px';
  activePopup = popup;
  activePopupBtn = el;
  // Dismiss on click outside
  var dismissClick = function(e) {
    if (!popup.parentNode) { document.removeEventListener('click', dismissClick); document.removeEventListener('mousemove', dismissMouse); return; }
    if (!popup.contains(e.target) && e.target !== el) { popup.remove(); activePopup = null; activePopupBtn = null; document.removeEventListener('click', dismissClick); document.removeEventListener('mousemove', dismissMouse); }
  };
  var dismissMouse = function(e) {
    if (!popup.parentNode) { document.removeEventListener('mousemove', dismissMouse); document.removeEventListener('click', dismissClick); return; }
    var r = popup.getBoundingClientRect();
    var pad = 50;
    if (e.clientX < r.left - pad || e.clientX > r.right + pad || e.clientY < r.top - pad || e.clientY > r.bottom + pad) {
      popup.remove(); activePopup = null; activePopupBtn = null; document.removeEventListener('mousemove', dismissMouse); document.removeEventListener('click', dismissClick);
    }
  };
  setTimeout(function() { document.addEventListener('click', dismissClick); }, 0);
  document.addEventListener('mousemove', dismissMouse);
}
// Sortable columns: click any th.sortable to sort the table
(function() {
  var table = document.getElementById('pr-table');
  if (!table) return;
  var tbody = table.querySelector('tbody');
  var headers = table.querySelectorAll('thead th');
  headers.forEach(function(th, colIdx) {
    if (!th.classList.contains('sortable')) return;
    th.addEventListener('click', function(e) {
      if (e.target.style && e.target.style.cursor === 'col-resize') return;
      var isDesc = th.classList.contains('desc');
      var newDir = isDesc ? 'asc' : 'desc';
      headers.forEach(function(h) {
        h.classList.remove('sorted','asc','desc');
        var old = h.querySelector('.sort-arrow');
        if (old) old.remove();
      });
      th.classList.add('sorted', newDir);
      var arrow = document.createElement('span');
      arrow.className = 'sort-arrow';
      arrow.textContent = newDir === 'desc' ? ' \u25BC' : ' \u25B2';
      th.insertBefore(arrow, th.querySelector('div'));
      var rows = Array.from(tbody.querySelectorAll('tr'));
      var sortType = th.getAttribute('data-sort') || 'num';
      rows.sort(function(a, b) {
        var aCell = a.cells[colIdx], bCell = b.cells[colIdx];
        if (!aCell || !bCell) return 0;
        if (sortType === 'alpha') {
          var aText = aCell.textContent.trim().toLowerCase();
          var bText = bCell.textContent.trim().toLowerCase();
          var cmp = aText < bText ? -1 : aText > bText ? 1 : 0;
          return newDir === 'desc' ? -cmp : cmp;
        }
        // Numeric: sum all numbers found in cell (handles "2/5t 3ppl" → 10)
        var aText = aCell.textContent.replace(/[#?]/g, '');
        var bText = bCell.textContent.replace(/[#?]/g, '');
        var aNums = aText.match(/[\d.]+/g) || [0];
        var bNums = bText.match(/[\d.]+/g) || [0];
        var aVal = aNums.reduce(function(s,n){ return s + parseFloat(n); }, 0);
        var bVal = bNums.reduce(function(s,n){ return s + parseFloat(n); }, 0);
        return newDir === 'desc' ? bVal - aVal : aVal - bVal;
      });
      rows.forEach(function(r) { tbody.appendChild(r); });
    });
  });
})();
</script>
<script src="../pr-refresh.js"></script>
</body>
</html>
"@

$html | Out-File -FilePath $OutputFile -Encoding utf8
Write-Verbose "Wrote $OutputFile ($prCount PRs)"
