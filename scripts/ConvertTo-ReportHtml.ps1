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
.PARAMETER ScheduleDesc
    Human-readable schedule description (e.g., "~twice daily") displayed in
    the report meta line alongside the relative timestamp. Plain text, no HTML.
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
    [string]$ScheduleDesc = "",
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

# Compute 10th percentile of lines_changed for "small PR" icon
$sortedLines = @($prs | ForEach-Object { [int]$_.lines_changed } | Sort-Object)
$smallPrEnabled = $sortedLines.Count -ge 10
$smallPrThreshold = if ($smallPrEnabled) {
    $idx = [Math]::Floor(($sortedLines.Count - 1) * 0.10)
    $sortedLines[$idx]
} else { 0 }

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
    $sizeIcon = if ($smallPrEnabled -and [int]$pr.lines_changed -le $smallPrThreshold) { "&#x1F401; " } else { "" }

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

    $filesWord = if ($pr.changed_files -eq 1) { "file" } else { "files" }
    $linesWord = if ($pr.lines_changed -eq 1) { "line" } else { "lines" }

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
  <td class="num$filesHeat" title="$($pr.changed_files) $filesWord, $($pr.lines_changed) $linesWord (additions + deletions)">$sizeIcon$($pr.lines_changed)</td>
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
        <tr><td>2.5</td><td>CI passing <a href="https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md" title="Weight from 980-PR statistical analysis">&sup1;</a></td></tr>
        <tr><td>2.5</td><td>Has approval <a href="https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md" title="Weight from 980-PR statistical analysis">&sup1;</a></td></tr>
        <tr><td>2.5</td><td>Feedback addressed <a href="https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md" title="Weight from 980-PR statistical analysis">&sup1;</a></td></tr>
        <tr><td>2.5</td><td>Discussion healthy <a href="https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md" title="Weight from 980-PR statistical analysis">&sup1;</a></td></tr>
        <tr><td>2.0&ndash;3.0</td><td>Small, easy to review (2.0) / trivial &le;2 files, &le;20 lines (3.0) <a href="https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md" title="Base weight (2.0) from 980-PR statistical analysis">&sup1;</a></td></tr>
        <tr><td>1.5</td><td>Has maintainer review <a href="https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md" title="Weight from 980-PR statistical analysis">&sup1;</a></td></tr>
        <tr><td>1.0</td><td>Recently active <a href="https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md" title="Weight from 980-PR statistical analysis">&sup1;</a></td></tr>
        <tr><td>0.5&ndash;1.0</td><td>Team or known author (1.0) / community (0.5) <a href="https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md" title="Weight from 980-PR statistical analysis">&sup1;</a></td></tr>
        <tr><td>0.7</td><td>Recently updated <a href="https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md" title="Weight from 980-PR statistical analysis">&sup1;</a></td></tr>
        <tr><td>0.5</td><td>Well labeled <a href="https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md" title="Weight from 980-PR statistical analysis">&sup1;</a></td></tr>
        <tr><td>0.3</td><td>Good review momentum <a href="https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md" title="Weight from 980-PR statistical analysis">&sup1;</a></td></tr>
      </table>
    </div>
    <div style="flex:1; min-width:250px;">
      <h4 style="margin:0.5em 0 0.3em">Need &mdash; benefits from maintainer attention?</h4>
      <table class="scoring-table">
        <tr><th>Points</th><th>Signal</th></tr>
        <tr><td>1.5</td><td>No approval yet</td></tr>
        <tr><td>1.0</td><td>Community author</td></tr>
        <tr><td>1.0</td><td>Reviewed, not approved</td></tr>
        <tr><td>1.0</td><td>Has unresolved feedback</td></tr>
        <tr><td>1.0</td><td>High interest</td></tr>
        <tr><td>0.5</td><td>Large change (&gt;200 lines)</td></tr>
        <tr><td>0.5</td><td>Trivial change (&le;2 files, &le;20 lines, no unresolved threads)</td></tr>
        <tr><td>0.5</td><td>Old but active (&gt;30d)</td></tr>
        <tr><td>&minus;1.5</td><td>Author silent &gt;14d (ball in their court)</td></tr>
        <tr><td>&minus;0.5</td><td>Author slow 7&ndash;14d (ball in their court)</td></tr>
      </table>
    </div>
    <div style="flex:1; min-width:250px;">
      <h4 style="margin:0.5em 0 0.3em">Action &mdash; best use of your time?</h4>
      <p><code>(ready + 1) &times; (need + 1)</code><br>normalized to 0&ndash;10</p>
      <p>PRs that are both high-need <em>and</em> near-ready rank highest.</p>
      <p>&#x1F3AF; = action &ge; 5<br>&#x26A1; = action 4&ndash;5</p>
    </div>
  </div>
  <p style="font-size:0.85em; margin-top:0.8em;"><sup>1</sup> Weight from <a href="https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md">980-PR statistical analysis</a>. Click any column header to re-sort.</p>
</details>
"@

$safeScheduleDesc = [System.Net.WebUtility]::HtmlEncode($ScheduleDesc)
$scheduleNote= if ($ScheduleDesc) { "Updated $safeScheduleDesc, last <span id=`"last-updated`" data-updated=`"$TimestampIso`">at $Timestamp</span>" } else { "Updated: <span id=`"last-updated`" data-updated=`"$TimestampIso`">$Timestamp</span>" }
$defaultColIndex = switch ($DefaultSort) { "merge" { 0 } "value" { 1 } "action" { 2 } "upd" { 9 } default { 2 } }

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$([System.Net.WebUtility]::HtmlEncode($Title)) - PR Dashboard</title>
<link rel="stylesheet" href="../shared-styles.css">
<style>
  /* Page-specific styles for per-repo reports */
  .report-desc { font-size: 0.9em; margin: 0.3em 0 0.8em; line-height: 1.4; }
  .observations { margin-top: 1.5em; max-width: 900px; }
  .observations h3 { font-size: 1.1em; margin-bottom: 0.5em; }
  .observations ul { padding-left: 1.5em; }
  .observations li { margin-bottom: 0.4em; line-height: 1.4; }
</style>
</head>
<body data-server-updated="$TimestampIso">
$navHtml
<h1>$([System.Net.WebUtility]::HtmlEncode($Title))</h1>
<p class="meta">$scheduleNote &middot; $prCount PRs &middot; <a href="https://github.com/$Repo">$Repo</a></p>
$(if ($Description) { "<p class=`"report-desc`">$Description</p><!-- Description is trusted HTML from hardcoded report definitions -->" })
$scoringHtml
<div class="filter-banner" id="filter-banner">Showing PRs for <strong id="filter-name"></strong> <a href="#" onclick="clearFilter();return false">&#x2715; Clear</a></div>
$(if ($prCount -eq 0) {
'<table><tbody><tr><td style="padding: 2em; text-align: center; color: #8b949e; font-style: italic;">No PRs currently match this filter.</td></tr></tbody></table>'
} else {

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
  <th class="sortable" data-sort="num" title="Ready: how close is this PR to being mergeable? Based on CI, approvals, conflicts, size, etc.">Ready</th><th class="sortable" data-sort="num" title="Need: how much does this PR benefit from attention? Community PRs, stalled feedback, missing approvals score higher.">Need</th><th class="sortable action-col" data-sort="num" title="Action: combined score = (ready+1) x (need+1), normalized 0-10. PRs that are both high-need and near-ready rank highest.">Action</th><th class="sortable" data-sort="num" title="Pull request number">PR</th><th class="sortable" data-sort="alpha" title="PR title and labels">Title</th><th title="Who needs to act next and what they should do">Next Action</th>
  <th title="CI status from Build Analysis (or latest check run)">CI</th><th class="sortable" data-sort="num" title="Discussion: sort by sum of all discussion numbers (unresolved + total threads + commenters)">Disc</th><th class="sortable" data-sort="num" title="Age in days since PR was opened">Age</th><th class="sortable" data-sort="num" title="Days since last update (push, comment, or review)">Upd</th><th class="sortable" data-sort="num" title="Total lines changed (additions + deletions). &#x1F401; = smallest 10%">Size</th><th class="sortable" data-sort="alpha" title="PR author">Author</th>$(if ($hasAnyAreaLabels) { "<th class=`"sortable`" data-sort=`"alpha`" title=`"Area labels assigned to this PR`">Area</th>" })
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
<script src="../shared-ui.js"></script>
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
$(if ($prCount -gt 0) { "initTableSort('pr-table', $defaultColIndex);`ninitResizableColumns('pr-table');" })
// Live relative timestamp for "last Xh ago"
(function() {
  function timeAgo(iso) {
    var ms = Date.now() - new Date(iso).getTime();
    var mins = Math.floor(ms / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return mins + 'm ago';
    var hrs = Math.floor(mins / 60);
    if (hrs < 24) return hrs + 'h ago';
    return Math.floor(hrs / 24) + 'd ago';
  }
  var el = document.getElementById('last-updated');
  if (el) {
    var iso = el.getAttribute('data-updated');
    el.textContent = timeAgo(iso);
    setInterval(function() { el.textContent = timeAgo(iso); }, 60000);
  }
})();
</script>
<script src="../pr-refresh.js"></script>
<footer style="margin-top:2em;padding-top:1em;border-top:1px solid var(--border);font-size:0.8em;color:#8b949e;text-align:center;">
  <a href="https://github.com/danmoseley/pr-dashboard/actions/workflows/generate-reports.yml"><img src="https://github.com/danmoseley/pr-dashboard/actions/workflows/generate-reports.yml/badge.svg" alt="Generate All Reports" style="vertical-align:middle"></a>
</footer>
</body>
</html>
"@

$html | Out-File -FilePath $OutputFile -Encoding utf8
Write-Verbose "Wrote $OutputFile ($prCount PRs)"
