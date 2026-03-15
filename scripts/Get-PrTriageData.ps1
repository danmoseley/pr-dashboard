<#
.SYNOPSIS
    Fetches and scores open PRs in dotnet/runtime for merge readiness.
.DESCRIPTION
    Uses batched GraphQL to fetch reviews, review threads, and Build Analysis.
    Outputs scored JSON for the AI skill to format and annotate.
.PARAMETER Label
    Area label to filter by (e.g., "area-CodeGen-coreclr")
.PARAMETER Limit
    Maximum PRs to return from gh pr list (default 500)
.PARAMETER Repo
    Repository (default "dotnet/runtime")
.PARAMETER Maintainers
    Optional list of usernames to treat as area owners (fallback when
    area-owners.md is missing or has no match for a PR's labels).
.EXAMPLE
    .\Get-PrTriageData.ps1 -Label "area-CodeGen-coreclr"
#>
[CmdletBinding()]
param(
    [string]$Label,
    [string]$Author,
    [string]$Assignee,
    [switch]$Community,
    [int]$MinAge,
    [int]$MaxAge,
    [int]$UpdatedWithin,
    [int]$MinApprovals,
    [double]$MinScore,
    [string]$HasLabel,
    [string]$ExcludeLabel,
    [switch]$IncludeDrafts,
    [switch]$ExcludeCopilot,
    [switch]$IncludeNeedsAuthor,
    [switch]$IncludeStale,
    [string]$MyActions,
    [string]$NextAction,
    [string]$PrNumber,
    [int]$Top = 0,
    [int]$Limit = 500,
    [string]$Repo = "dotnet/runtime",
    [string[]]$Maintainers = @(),
    [switch]$OutputCsv
)

$ErrorActionPreference = "Stop"

# Retry wrapper for gh CLI calls (handles transient HTTP 5xx / 429 errors)
function Invoke-GhRetry {
    param([string[]]$Arguments, [int]$MaxAttempts = 4, [int[]]$DelaySeconds = @(60, 300, 1200))
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $output = & gh @Arguments 2>&1
        $errs = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $out  = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        $errText = ($errs | ForEach-Object { $_.ToString() }) -join '; '
        if ($LASTEXITCODE -eq 0 -and -not ($errText -match 'HTTP [45]\d{2}')) {
            return ($out -join "`n")
        }
        if ($i -lt $MaxAttempts) {
            $delay = $DelaySeconds[$i - 1]
            Write-Warning "gh failed (attempt $i/${MaxAttempts}): $errText — retrying in ${delay}s"
            Start-Sleep -Seconds $delay
        } else {
            Write-Warning "gh failed after $MaxAttempts attempts: $errText"
            return ($out -join "`n")
        }
    }
}

# Handle comma-separated string from bash (e.g., "a,b,c" becomes one string element)
if ($Maintainers.Count -eq 1 -and $Maintainers[0] -match ',') {
    $Maintainers = $Maintainers[0] -split ','
}
$scriptStart = Get-Date

try {   # Top-level catch ensures stdout is always valid JSON

# --- Area owners lookup (parsed from docs/area-owners.md) ---
$areaOwners = @{}
$repoParts = $Repo -split '/'
$areaOwnersUrl = "repos/$($repoParts[0])/$($repoParts[1])/contents/docs/area-owners.md"
try {
    $areaOwnersMd = gh api -H "Accept: application/vnd.github.raw" $areaOwnersUrl 2>$null
    foreach ($line in $areaOwnersMd -split "`n") {
        if ($line -match '^\|\s*(area-\S+)\s*\|\s*@(\S+)\s*\|\s*(.+?)\s*\|') {
            $areaName = $matches[1].Trim()
            $lead = $matches[2].Trim().TrimEnd(',', ';')
            $ownerField = $matches[3].Trim()
            $people = @([regex]::Matches($ownerField, '@(\S+)') | ForEach-Object { $_.Groups[1].Value.TrimEnd(',', ';') } |
                Where-Object { $_ -notmatch '^dotnet/' })
            if ($people.Count -eq 0) { $people = @($lead) }
            $areaOwners[$areaName] = $people
        }
    }
    Write-Verbose "Loaded $($areaOwners.Count) area owners from docs/area-owners.md"
} catch {
    Write-Verbose "Warning: could not fetch area-owners.md, using empty owner table"
}

$communityTriagers = @("a74nh","am11","clamp03","Clockwork-Muse","filipnavara",
    "huoyaoyuan","martincostello","omajid","Sergio0694","shushanhf",
    "SingleAccretion","teo-tsirpanis","tmds","vcsjones","xoofx")

# --- Step 1: List PRs ---
Write-Verbose "Fetching PR list..."
$listArgs = @("pr","list","--repo",$Repo,"--state","open","--limit",$Limit,
    "--json","number,title,author,labels,mergeable,isDraft,createdAt,updatedAt,changedFiles,additions,deletions,assignees")
if ($Label) { $listArgs += @("--label",$Label) }
if ($Author) { $listArgs += @("--author",$Author) }
if ($Assignee) { $listArgs += @("--assignee",$Assignee) }

$prsRaw = (Invoke-GhRetry $listArgs) | ConvertFrom-Json

# --- Step 2: Quick-screen ---
$drafts = @($prsRaw | Where-Object { $_.isDraft })
$bots = @($prsRaw | Where-Object { -not $_.isDraft -and $_.author.login -match "^(app/)?dotnet-maestro|^(app/)?github-actions" })
$needsAuthor = @($prsRaw | Where-Object { -not $_.isDraft -and ($_.labels.name -contains "needs-author-action") })
$stale = @($prsRaw | Where-Object { -not $_.isDraft -and ($_.labels.name -contains "no-recent-activity") })
$candidates = @($prsRaw | Where-Object {
    ($IncludeDrafts -or -not $_.isDraft) -and
    $_.author.login -notmatch "^(app/)?dotnet-maestro|^(app/)?github-actions" -and
    (-not $ExcludeCopilot -or $_.author.login -notmatch "copilot-swe-agent") -and
    ($IncludeNeedsAuthor -or -not ($_.labels.name -contains "needs-author-action")) -and
    ($IncludeStale -or -not ($_.labels.name -contains "no-recent-activity"))
})

# Apply additional label filters
if ($Community) {
    $candidates = @($candidates | Where-Object { ($_.labels.name | Where-Object { $_ -match '^community' }).Count -gt 0 })
}
if ($HasLabel) {
    $candidates = @($candidates | Where-Object { $_.labels.name -contains $HasLabel })
}
if ($ExcludeLabel) {
    $candidates = @($candidates | Where-Object { $_.labels.name -notcontains $ExcludeLabel })
}

# Apply age filters
$now = Get-Date
if ($MinAge -gt 0) {
    $candidates = @($candidates | Where-Object { ($now - [DateTime]::Parse($_.createdAt)).TotalDays -ge $MinAge })
}
if ($MaxAge -gt 0) {
    $candidates = @($candidates | Where-Object { ($now - [DateTime]::Parse($_.createdAt)).TotalDays -le $MaxAge })
}
if ($UpdatedWithin -gt 0) {
    $candidates = @($candidates | Where-Object { ($now - [DateTime]::Parse($_.updatedAt)).TotalDays -le $UpdatedWithin })
}

# Single PR mode
if ($PrNumber) {
    $candidates = @($candidates | Where-Object { $_.number -eq [long]$PrNumber })
    if ($candidates.Count -eq 0) {
        # PR wasn't in filtered set - fetch it directly
        $singlePr = & gh pr view $PrNumber --repo $Repo --json number,title,author,labels,mergeable,isDraft,createdAt,updatedAt,changedFiles,additions,deletions,assignees | ConvertFrom-Json
        $candidates = @($singlePr)
    }
}

$excludedDrafts = if ($IncludeDrafts) { 0 } else { $drafts.Count }
$excludedBots = $bots.Count
Write-Verbose "Scanned $($prsRaw.Count) -> $($candidates.Count) candidates ($excludedDrafts drafts, $excludedBots bots, $($needsAuthor.Count) needs-author, $($stale.Count) stale excluded)"

if ($candidates.Count -eq 0) {
    Write-Verbose "No candidates to analyze."
    @{ scanned = $prsRaw.Count; analyzed = 0; prs = @() } | ConvertTo-Json -Depth 5
    return
}

# --- Step 3: Batched GraphQL (reviews, threads, Build Analysis, thread authors) ---
$fragment = 'number comments(last:20){totalCount nodes{author{login}}} reviews(last:10){nodes{author{login}state commit{oid}}} reviewRequests(first:10){nodes{requestedReviewer{...on User{login}...on Team{name}}}} reviewThreads(first:50){nodes{isResolved comments(first:5){nodes{author{login}createdAt}}}} commits(last:1){nodes{commit{oid statusCheckRollup{contexts(first:100){pageInfo{hasNextPage endCursor} nodes{...on CheckRun{name conclusion status}}}}}}}'

$graphqlData = @{}
$batches = [System.Collections.ArrayList]@()
$batch = [System.Collections.ArrayList]@()
foreach ($pr in $candidates) {
    [void]$batch.Add($pr.number)
    if ($batch.Count -eq 10) {
        [void]$batches.Add([long[]]$batch.ToArray())
        $batch = [System.Collections.ArrayList]@()
    }
}
if ($batch.Count -gt 0) { [void]$batches.Add([long[]]$batch.ToArray()) }

$repoParts = $Repo -split '/'
$repoOwner = $repoParts[0]
$repoName = $repoParts[1]

Write-Verbose "Fetching details in $($batches.Count) GraphQL batch(es)..."
foreach ($b in $batches) {
    $parts = @()
    for ($i = 0; $i -lt $b.Count; $i++) {
        $parts += "pr$($i): pullRequest(number:$($b[$i])) { $fragment }"
    }
    $query = "{ repository(owner:`"$repoOwner`",name:`"$repoName`") { $($parts -join ' ') } }"
    $result = (Invoke-GhRetry @("api","graphql","-f","query=$query")) | ConvertFrom-Json
    for ($i = 0; $i -lt $b.Count; $i++) {
        $prData = $result.data.repository."pr$i"
        if ($prData) { $graphqlData[$b[$i]] = $prData }
    }
}

# Paginate statusCheckRollup contexts for PRs with >100 checks
foreach ($prNum in @($graphqlData.Keys)) {
    $gql = $graphqlData[$prNum]
    if (-not $gql -or -not $gql.commits.nodes -or $gql.commits.nodes.Count -eq 0) { continue }
    $rollup = $gql.commits.nodes[0].commit.statusCheckRollup
    if (-not $rollup -or -not $rollup.contexts.pageInfo.hasNextPage) { continue }

    $cursor = $rollup.contexts.pageInfo.endCursor
    $allNodes = [System.Collections.ArrayList]@($rollup.contexts.nodes)
    while ($cursor) {
        $q = "{ repository(owner:`"$repoOwner`",name:`"$repoName`") { pullRequest(number:$prNum) { commits(last:1) { nodes { commit { statusCheckRollup { contexts(first:100, after:`"$cursor`") { pageInfo { hasNextPage endCursor } nodes { ...on CheckRun { name conclusion status } } } } } } } } } }"
        $res = (Invoke-GhRetry @("api","graphql","-f","query=$q")) | ConvertFrom-Json
        if (-not $res -or -not $res.data -or $res.errors) {
            Write-Warning "Failed to paginate checks for PR #${prNum}: $($res.errors.message -join '; ')"
            break
        }
        $ctx = $res.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts
        if ($ctx -and $ctx.nodes) {
            foreach ($node in $ctx.nodes) { [void]$allNodes.Add($node) }
        }
        $cursor = if ($ctx.pageInfo.hasNextPage -and $ctx.pageInfo.endCursor) { $ctx.pageInfo.endCursor } else { $null }
    }
    $rollup.contexts | Add-Member -NotePropertyName nodes -NotePropertyValue @($allNodes) -Force
    Write-Verbose "PR #${prNum}: fetched $($allNodes.Count) total checks (paginated beyond 100)"
}

# --- Step 4: Determine area owners for label ---
$owners = @()
if ($Label -and $areaOwners.ContainsKey($Label)) {
    $owners = $areaOwners[$Label]
}
# Also try matching each PR's area labels
function Get-OwnersForPr($labelNames) {
    foreach ($lbl in $labelNames) {
        if ($areaOwners.ContainsKey($lbl)) { return $areaOwners[$lbl] }
    }
    return @()
}

# --- Step 4b: Detect Copilot review errors (targeted query, avoids fetching body for all reviews) ---
$copilotErrorPRs = @{}
$prsWithCopilotReview = @($candidates | Where-Object {
    $gql = $graphqlData[$_.number]
    $gql -and ($gql.reviews.nodes | Where-Object { $_.author.login -eq "copilot-pull-request-reviewer" })
})
if ($prsWithCopilotReview.Count -gt 0) {
    # Use larger batches since this is a lightweight fragment (only fetches copilot review bodies)
    $copilotBatches = [System.Collections.ArrayList]@()
    $cb = [System.Collections.ArrayList]@()
    foreach ($pr in $prsWithCopilotReview) {
        [void]$cb.Add($pr.number)
        if ($cb.Count -eq 50) { [void]$copilotBatches.Add([long[]]$cb.ToArray()); $cb = [System.Collections.ArrayList]@() }
    }
    if ($cb.Count -gt 0) { [void]$copilotBatches.Add([long[]]$cb.ToArray()) }
    Write-Verbose "Checking $($prsWithCopilotReview.Count) PR(s) for Copilot review errors in $($copilotBatches.Count) batch(es)..."
    foreach ($b in $copilotBatches) {
        $parts = @()
        for ($i = 0; $i -lt $b.Count; $i++) {
            $parts += "pr$($i): pullRequest(number:$($b[$i])) { number reviews(last:5) { nodes { author{login} body } } }"
        }
        $query = "{ repository(owner:`"$repoOwner`",name:`"$repoName`") { $($parts -join ' ') } }"
        $result = (Invoke-GhRetry @("api","graphql","-f","query=$query")) | ConvertFrom-Json
        for ($i = 0; $i -lt $b.Count; $i++) {
            $prData = $result.data.repository."pr$i"
            if ($prData) {
                # Only flag if the MOST RECENT copilot review is an error
                # (a successful review on a newer commit supersedes an earlier error)
                $lastCopilotReview = $prData.reviews.nodes |
                    Where-Object { $_.author.login -eq "copilot-pull-request-reviewer" } |
                    Select-Object -Last 1
                if ($lastCopilotReview -and $lastCopilotReview.body -match "Copilot encountered an error") {
                    $copilotErrorPRs[$b[$i]] = $true
                }
            }
        }
    }
    Write-Verbose "Found $($copilotErrorPRs.Count) PR(s) with Copilot review errors"
}

# --- Step 4c: Detect who triggered Copilot-authored PRs (isolated query to avoid breaking main batch) ---
$copilotTriggers = @{}
$copilotAuthoredPRs = @($candidates | Where-Object { $_.author.login -match "^(app/)?copilot-swe-agent$" })
if ($copilotAuthoredPRs.Count -gt 0) {
    $triggerBatches = [System.Collections.ArrayList]@()
    $tb = [System.Collections.ArrayList]@()
    foreach ($pr in $copilotAuthoredPRs) {
        [void]$tb.Add($pr.number)
        if ($tb.Count -eq 50) { [void]$triggerBatches.Add([long[]]$tb.ToArray()); $tb = [System.Collections.ArrayList]@() }
    }
    if ($tb.Count -gt 0) { [void]$triggerBatches.Add([long[]]$tb.ToArray()) }
    Write-Verbose "Looking up trigger user for $($copilotAuthoredPRs.Count) Copilot PR(s) in $($triggerBatches.Count) batch(es)..."
    foreach ($b in $triggerBatches) {
        $parts = @()
        for ($i = 0; $i -lt $b.Count; $i++) {
            $parts += "pr$($i): pullRequest(number:$($b[$i])) { number timelineItems(first:5,itemTypes:ASSIGNED_EVENT) { nodes { ... on AssignedEvent { actor{login} assignee{...on User{login}...on Bot{login}} } } } }"
        }
        $query = "{ repository(owner:`"$repoOwner`",name:`"$repoName`") { $($parts -join ' ') } }"
        $result = (Invoke-GhRetry @("api","graphql","-f","query=$query")) | ConvertFrom-Json
        for ($i = 0; $i -lt $b.Count; $i++) {
            $prData = $result.data.repository."pr$i"
            if ($prData) {
                $trigger = $prData.timelineItems.nodes |
                    Where-Object { $_.actor.login -match "copilot-swe-agent" -and $_.assignee.login -and $_.assignee.login -notmatch "^(app/)?copilot-swe-agent$|^Copilot$" } |
                    Select-Object -First 1 -ExpandProperty assignee |
                    Select-Object -ExpandProperty login -ErrorAction SilentlyContinue
                if ($trigger) { $copilotTriggers[$b[$i]] = $trigger }
            }
        }
    }
    Write-Verbose "Found trigger user for $($copilotTriggers.Count) of $($copilotAuthoredPRs.Count) Copilot PR(s)"
}

# --- Step 5: Score each PR ---
$now = Get-Date
$results = @()

foreach ($pr in $candidates) {
    $n = $pr.number
    $gql = $graphqlData[$n]
    $labelNames = @($pr.labels | ForEach-Object { $_.name })

    # Per-PR owners (use label-specific or fallback to filter-level, then -Maintainers)
    $prOwners = Get-OwnersForPr $labelNames
    if ($prOwners.Count -eq 0) { $prOwners = $owners }
    if ($prOwners.Count -eq 0 -and $Maintainers.Count -gt 0) { $prOwners = $Maintainers }

    # For bot-authored PRs, find the human who triggered it
    $botTrigger = $null
    if ($pr.author.login -match "^(app/)?copilot-swe-agent$") {
        # Primary: from isolated AssignedEvent query (step 4c)
        $botTrigger = $copilotTriggers[$n]
        # Fallback: non-Copilot assignee on the PR
        if (-not $botTrigger) {
            $botTrigger = $pr.assignees | Where-Object { $_.login -ne "Copilot" -and $_.login -ne "app/copilot-swe-agent" } |
                Select-Object -First 1 -ExpandProperty login -ErrorAction SilentlyContinue
        }
    }

    # Resolve effective author early (needed for $prioritizedOwners exclusion and scoring)
    $authorLogin = $pr.author.login
    if ($botTrigger) { $authorLogin = $botTrigger }

    # Extract Build Analysis
    $checks = @()
    $baConclusion = "ABSENT"
    $headCommitOid = $null
    if ($gql -and $gql.commits.nodes.Count -gt 0) {
        $headCommitOid = $gql.commits.nodes[0].commit.oid
        $rollup = $gql.commits.nodes[0].commit.statusCheckRollup
        if ($rollup -and $rollup.contexts.nodes) {
            $checks = @($rollup.contexts.nodes | Where-Object { $_.name })
            $baNode = $checks | Where-Object { $_.name -eq "Build Analysis" } | Select-Object -First 1
            if ($baNode) {
                $baConclusion = if ($baNode.conclusion) { $baNode.conclusion } else { "IN_PROGRESS" }
            }
        }
    }

    # Detect Copilot review errors (from pre-computed lookup)
    $copilotReviewFailed = $copilotErrorPRs.ContainsKey($n)

    # Extract reviews (skip copilot reviewer)
    $reviews = @()
    if ($gql -and $gql.reviews.nodes) {
        $reviews = @($gql.reviews.nodes | Where-Object { $_.author.login -ne "copilot-pull-request-reviewer" })
    }

    # Extract threads, commenters, discussion metrics
    $unresolvedThreads = 0
    $totalThreads = 0
    $threadAuthors = @()
    $allCommenters = @()
    $prCommentCount = 0
    $prCommentAuthors = @()
    if ($gql) {
        $prCommentCount = if ($gql.comments.totalCount) { $gql.comments.totalCount } else { 0 }
        # Extract PR (timeline) comment authors for engagement detection
        if ($gql.comments.nodes) {
            $prCommentAuthors = @($gql.comments.nodes | ForEach-Object {
                if ($_.author) { $_.author.login }
            } | Where-Object { $_ } | Select-Object -Unique)
        }
    }
    if ($gql -and $gql.reviewThreads.nodes) {
        $totalThreads = $gql.reviewThreads.nodes.Count
        $unresolved = @($gql.reviewThreads.nodes | Where-Object { -not $_.isResolved })
        $unresolvedThreads = $unresolved.Count
        $threadAuthors = @($unresolved | ForEach-Object {
            if ($_.comments.nodes.Count -gt 0) { $_.comments.nodes[0].author.login }
        } | Where-Object { $_ } | Select-Object -Unique)
        # All distinct commenters across all threads (resolved + unresolved) + PR comments
        $allCommenters = @(@($gql.reviewThreads.nodes | ForEach-Object {
            $_.comments.nodes | ForEach-Object { $_.author.login }
        }) + @($prCommentAuthors) | Where-Object { $_ } | Select-Object -Unique)
    } elseif ($prCommentAuthors.Count -gt 0) {
        $allCommenters = @($prCommentAuthors)
    }
    $threadCommentSum = if ($gql -and $gql.reviewThreads.nodes) {
        ($gql.reviewThreads.nodes | ForEach-Object { $_.comments.nodes.Count } | Measure-Object -Sum).Sum
    } else { 0 }
    $totalComments = $prCommentCount + $threadCommentSum
    $distinctCommenters = $allCommenters.Count

    # Find the most recent review comment date (for engagement freshness)
    $lastReviewCommentDate = $null
    if ($gql -and $gql.reviewThreads.nodes) {
        $commentDates = @($gql.reviewThreads.nodes | ForEach-Object {
            $_.comments.nodes | ForEach-Object {
                if ($_.createdAt) { [DateTime]::Parse($_.createdAt) }
            }
        } | Where-Object { $_ })
        if ($commentDates.Count -gt 0) {
            $lastReviewCommentDate = ($commentDates | Sort-Object -Descending | Select-Object -First 1)
        }
    }

    # Classify reviewers
    $hasOwnerApproval = $false
    $hasCurrentOwnerApproval = $false
    $hasTriagerApproval = $false
    $hasAnyApproval = $false
    $hasStaleApproval = $false
    $approvalCount = 0
    $reviewerLogins = @()
    $approverLogins = @()
    foreach ($rev in $reviews) {
        $login = $rev.author.login
        # Skip self-approvals (author signing off on their own PR isn't meaningful)
        $isSelfReview = ($login -eq $pr.author.login) -or ($login -eq $botTrigger)
        $reviewerLogins += $login
        if ($rev.state -eq "APPROVED" -and -not $isSelfReview) {
            $approvalCount++
            $hasAnyApproval = $true
            $approverLogins += $login
            # Check if approval is on the current head commit
            $isStale = $headCommitOid -and $rev.commit -and $rev.commit.oid -and ($rev.commit.oid -ne $headCommitOid)
            if ($isStale) { $hasStaleApproval = $true }
            if ($prOwners -contains $login) {
                $hasOwnerApproval = $true
                if (-not $isStale) { $hasCurrentOwnerApproval = $true }
            }
            elseif ($communityTriagers -contains $login) { $hasTriagerApproval = $true }
        }
    }
    $reviewerLogins = @($reviewerLogins | Select-Object -Unique)
    $hasAnyReview = $reviews.Count -gt 0

    # Extract explicitly requested reviewers (GitHub "Reviewers" sidebar)
    $requestedReviewerLogins = @()
    if ($gql -and $gql.reviewRequests.nodes) {
        $requestedReviewerLogins = @($gql.reviewRequests.nodes | ForEach-Object {
            if ($_.requestedReviewer.login) { $_.requestedReviewer.login }
        } | Where-Object { $_ } | Select-Object -Unique)
    }

    # Build engagement-prioritized owner list for $who selection.
    # Priority: (1) assigned reviewers, (2) area owners, (3) engaged maintainers, (4) remaining.
    # $prOwners is kept for ownership membership checks (e.g., $hasOwnerApproval).
    $allMaintainerPool = @(@($prOwners) + @($Maintainers) | Select-Object -Unique)
    $prioritizedOwners = [System.Collections.ArrayList]@()
    # Tier 1: Requested reviewers who are maintainers
    foreach ($r in $requestedReviewerLogins) {
        if ($r -ne $authorLogin -and $allMaintainerPool -contains $r -and $prioritizedOwners -notcontains $r) {
            [void]$prioritizedOwners.Add($r)
        }
    }
    # Tier 2: Area owners (from label match)
    foreach ($o in (Get-OwnersForPr $labelNames)) {
        if ($o -ne $authorLogin -and $prioritizedOwners -notcontains $o) {
            [void]$prioritizedOwners.Add($o)
        }
    }
    # Tier 3: Maintainers engaged in the PR (reviewers, thread/PR commenters)
    foreach ($e in @(@($reviewerLogins) + @($allCommenters) | Select-Object -Unique)) {
        if ($e -ne $authorLogin -and $allMaintainerPool -contains $e -and $prioritizedOwners -notcontains $e) {
            [void]$prioritizedOwners.Add($e)
        }
    }
    # Tier 4: Remaining from $prOwners (preserves original order)
    foreach ($m in $prOwners) {
        if ($m -ne $authorLogin -and $prioritizedOwners -notcontains $m) {
            [void]$prioritizedOwners.Add($m)
        }
    }
    $prioritizedOwners = @($prioritizedOwners)

    # Labels
    $isCommunity = ($labelNames | Where-Object { $_ -match '^community' }).Count -gt 0
    $hasAreaLabel = ($labelNames | Where-Object { $_ -match "^area-" }).Count -gt 0
    $isUntriaged = $labelNames -contains "untriaged"

    # Dates
    $updatedAt = [DateTime]::Parse($pr.updatedAt)
    $createdAt = [DateTime]::Parse($pr.createdAt)
    $daysSinceUpdate = ($now - $updatedAt).TotalDays
    $ageInDays = ($now - $createdAt).TotalDays

    # Check counts
    $passed = @($checks | Where-Object { $_.conclusion -eq "SUCCESS" }).Count
    $failed = @($checks | Where-Object { $_.conclusion -eq "FAILURE" }).Count
    $running = @($checks | Where-Object { $_.status -eq "IN_PROGRESS" -or $_.status -eq "QUEUED" }).Count

    # No Build Analysis check (non-runtime repos): infer CI from overall check results
    if ($baConclusion -eq "ABSENT" -and $checks.Count -gt 0) {
        if ($failed -gt 0) { $baConclusion = "FAILURE" }
        elseif ($running -gt 0) { $baConclusion = "IN_PROGRESS" }
        elseif ($passed -gt 0) { $baConclusion = "SUCCESS" }
    }

    # --- DIMENSION SCORING ---
    # Use the most recent activity date (PR update or review comment, whichever is newer)
    $effectiveUpdateDate = $updatedAt
    if ($lastReviewCommentDate -and $lastReviewCommentDate -gt $updatedAt) {
        $effectiveUpdateDate = $lastReviewCommentDate
    }
    $daysSinceActivity = ($now - $effectiveUpdateDate).TotalDays

    $ciScore = switch ($baConclusion) { "SUCCESS" { 1.0 } "ABSENT" { 0.5 } "IN_PROGRESS" { 0.5 } default { 0.0 } }
    $stalenessScore = if ($daysSinceActivity -le 3) { 1.0 } elseif ($daysSinceActivity -le 14) { 0.5 } else { 0.0 }
    $maintScore = if ($hasOwnerApproval) { 1.0 } elseif ($hasTriagerApproval) { 0.75 } elseif ($hasAnyReview) { 0.5 } else { 0.0 }
    $hasNeedsAuthorAction = $labelNames -contains "needs-author-action"
    $feedbackScore = if ($hasNeedsAuthorAction) { 0.0 } elseif ($unresolvedThreads -eq 0) { 1.0 } else { 0.5 }
    $conflictScore = switch ($pr.mergeable) { "MERGEABLE" { 1.0 } "UNKNOWN" { 0.5 } "CONFLICTING" { 0.0 } default { 0.5 } }
    $alignScore = if ($isUntriaged -or -not $hasAreaLabel) { 0.0 } else { 1.0 }
    $freshScore = if ($daysSinceActivity -le 14) { 1.0 } elseif ($daysSinceActivity -le 30) { 0.5 } else { 0.0 }
    $totalLines = $pr.additions + $pr.deletions
    $sizeScore = if ($pr.changedFiles -le 5 -and $totalLines -le 200) { 1.0 } elseif ($pr.changedFiles -le 20 -and $totalLines -le 500) { 0.5 } else { 0.0 }
    $communityScore = if ($isCommunity) { 0.5 } else { 1.0 }
    # Stale approval: reduce approval score if approval is not on current commit
    $approvalScore = if ($approvalCount -ge 2 -and $hasOwnerApproval) { 1.0 }
                     elseif ($hasOwnerApproval -or ($hasTriagerApproval -and $approvalCount -ge 2)) { 0.75 }
                     elseif ($hasTriagerApproval -or $approvalCount -ge 2) { 0.5 }
                     elseif ($approvalCount -ge 1) { 0.5 }
                     else { 0.0 }
    if ($hasStaleApproval -and $approvalScore -gt 0) { $approvalScore = [Math]::Max(0, $approvalScore - 0.25) }
    $velocityScore = if ($reviews.Count -eq 0) { if ($ageInDays -le 14) { 0.5 } else { 0.0 } }
                     elseif ($daysSinceActivity -le 7) { 1.0 } elseif ($daysSinceActivity -le 14) { 0.5 } else { 0.0 }
    # Discussion: light discussion or recent engagement is positive; stale heavy discussion is harder to push forward
    $daysSinceReview = if ($lastReviewCommentDate) { ($now - $lastReviewCommentDate).TotalDays } else { $daysSinceUpdate }
    $discussionScore = if ($totalThreads -le 5 -and $distinctCommenters -le 2) { 1.0 }
                       elseif ($daysSinceReview -le 14) { 0.75 }
                       elseif ($totalThreads -le 15 -and $distinctCommenters -le 5) { 0.5 }
                       else { 0.0 }

    # Composite: weighted sum normalized to 0-10 scale
    $rawMax = 20.0
    $rawScore = ($ciScore * 3) + ($conflictScore * 3) + ($maintScore * 3) +
        ($feedbackScore * 2) + ($approvalScore * 2) + ($stalenessScore * 1.5) +
        ($discussionScore * 1.5) +
        ($alignScore * 1) + ($freshScore * 1) + ($sizeScore * 1) +
        ($communityScore * 0.5) + ($velocityScore * 0.5)
    $composite = [Math]::Round(($rawScore / $rawMax) * 10, 1)

    # --- WHO OWNS NEXT ACTION ---
    # Identify 1-2 specific people responsible for the next step
    $prNextAction = ""
    $who = @()

    if ($pr.mergeable -eq "CONFLICTING") {
        $prNextAction = "@$($authorLogin): resolve conflicts"
        $who = @($authorLogin)
    }
    elseif ($baConclusion -eq "FAILURE") {
        if ($hasNeedsAuthorAction) {
            $prNextAction = "@$($authorLogin): address feedback (needs-author-action)"
            $who = @($authorLogin)
        } elseif ($unresolvedThreads -gt 0) {
            $prNextAction = "@$($authorLogin): respond to $unresolvedThreads thread(s)"
            $who = @($authorLogin)
            $waitingOn = @($threadAuthors | Where-Object { $_ -ne $authorLogin }) | Select-Object -First 2
            if ($waitingOn.Count -gt 0) {
                $prNextAction += " from @$($waitingOn -join ', @')"
            }
        } elseif ($hasAnyApproval) {
            # Reviews done, no open threads — CI is the real blocker
            $prNextAction = "@$($authorLogin): fix CI failures"
            $who = @($authorLogin)
        } else {
            # No approvals yet — review is the more actionable need; CI column shows the failure
            $prNextAction = "Maintainer: review needed"
            if ($requestedReviewerLogins.Count -gt 0) {
                $who = @($requestedReviewerLogins | Select-Object -First 2)
            } elseif ($prioritizedOwners.Count -gt 0) {
                $who = @($prioritizedOwners | Select-Object -First 2)
            } else {
                $who = @("area owner")
            }
        }
    }
    elseif ($hasNeedsAuthorAction) {
        $prNextAction = "@$($authorLogin): address feedback (needs-author-action)"
        $who = @($authorLogin)
    }
    elseif ($unresolvedThreads -gt 0) {
        $prNextAction = "@$($authorLogin): respond to $unresolvedThreads thread(s)"
        $who = @($authorLogin)
        # Note who's waiting on them (thread authors)
        $waitingOn = @($threadAuthors | Where-Object { $_ -ne $authorLogin }) | Select-Object -First 2
        if ($waitingOn.Count -gt 0) {
            $prNextAction += " from @$($waitingOn -join ', @')"
        }
    }
    elseif (-not $hasAnyReview) {
        $prNextAction = "Maintainer: review needed"
        # Prefer explicitly requested reviewers, then prioritized owners
        if ($requestedReviewerLogins.Count -gt 0) {
            $who = @($requestedReviewerLogins | Select-Object -First 2)
        } elseif ($prioritizedOwners.Count -gt 0) {
            $who = @($prioritizedOwners | Select-Object -First 2)
        } else {
            $who = @("area owner")
        }
    }
    elseif ($daysSinceUpdate -gt 14) {
        $prNextAction = "@$($authorLogin): merge main (stale $([int]$daysSinceUpdate)d)"
        $who = @($authorLogin)
    }
    elseif ($hasOwnerApproval -and -not $hasCurrentOwnerApproval) {
        $prNextAction = "Maintainer: re-review needed (approval on older commit)"
        $staleOwners = @($approverLogins | Where-Object { $prOwners -contains $_ }) | Select-Object -First 2
        if ($staleOwners.Count -gt 0) { $who = $staleOwners }
        elseif ($prioritizedOwners.Count -gt 0) { $who = @($prioritizedOwners | Select-Object -First 2) }
    }
    elseif ($ciScore -eq 1 -and $conflictScore -eq 1 -and $maintScore -ge 0.75 -and $feedbackScore -eq 1) {
        $prNextAction = "Ready to merge"
        # Who should click merge? The approving owner or area lead
        if ($approverLogins.Count -gt 0) {
            $who = @($approverLogins | Where-Object { $prOwners -contains $_ } | Select-Object -First 1)
            if (-not $who -or $who.Count -eq 0) { $who = @($approverLogins | Select-Object -First 1) }
        } elseif ($prioritizedOwners.Count -gt 0) {
            $who = @($prioritizedOwners | Select-Object -First 1)
        }
    }
    elseif (-not $hasOwnerApproval -and -not $hasTriagerApproval) {
        $prNextAction = "Maintainer: review needed"
        # Prefer explicitly requested reviewers, then prioritized owners not yet reviewing
        if ($requestedReviewerLogins.Count -gt 0) {
            $who = @($requestedReviewerLogins | Select-Object -First 2)
        } else {
            $nonReviewingOwners = @($prioritizedOwners | Where-Object { $reviewerLogins -notcontains $_ }) | Select-Object -First 2
            if ($nonReviewingOwners.Count -gt 0) { $who = $nonReviewingOwners }
            elseif ($prioritizedOwners.Count -gt 0) { $who = @($prioritizedOwners | Select-Object -First 2) }
        }
    }
    elseif ($baConclusion -eq "IN_PROGRESS" -or $baConclusion -eq "ABSENT") {
        $prNextAction = "Wait for CI"
        $who = @($authorLogin)
    }
    else {
        $prNextAction = "Maintainer: review/merge"
        if ($prioritizedOwners.Count -gt 0) { $who = @($prioritizedOwners | Select-Object -First 2) }
    }

    # If primary action is resolve conflicts, also note the next most important secondary action
    if ($prNextAction -match 'resolve conflicts') {
        if ($hasNeedsAuthorAction) {
            $prNextAction += "; address feedback (needs-author-action)"
        }
        elseif ($unresolvedThreads -gt 0) {
            $prNextAction += "; respond to $unresolvedThreads thread(s)"
        }
        elseif (-not $hasAnyReview) {
            $reviewWho = if ($requestedReviewerLogins.Count -gt 0) { @($requestedReviewerLogins | Select-Object -First 2) }
                         elseif ($prOwners.Count -gt 0) { @($prOwners | Select-Object -First 2) }
                         else { @() }
            if ($reviewWho.Count -gt 0) {
                $prNextAction += "; @$($reviewWho -join ', @'): review needed"
                $who += $reviewWho
            } else {
                $prNextAction += "; review needed"
            }
        }
        elseif ($hasOwnerApproval -and -not $hasCurrentOwnerApproval) {
            $staleReviewers = @($approverLogins | Where-Object { $prOwners -contains $_ }) | Select-Object -First 2
            $reviewWho = if ($requestedReviewerLogins.Count -gt 0) { @($requestedReviewerLogins | Select-Object -First 2) }
                         elseif ($staleReviewers.Count -gt 0) { $staleReviewers }
                         elseif ($prOwners.Count -gt 0) { @($prOwners | Select-Object -First 2) }
                         else { @() }
            if ($reviewWho.Count -gt 0) {
                $prNextAction += "; @$($reviewWho -join ', @'): re-review needed"
                $who += $reviewWho
            } else {
                $prNextAction += "; re-review needed"
            }
        }
        elseif (-not $hasOwnerApproval -and -not $hasTriagerApproval) {
            $pendingOwners = @($prOwners | Where-Object { $reviewerLogins -notcontains $_ }) | Select-Object -First 2
            $reviewWho = if ($requestedReviewerLogins.Count -gt 0) { @($requestedReviewerLogins | Select-Object -First 2) }
                         elseif ($pendingOwners.Count -gt 0) { $pendingOwners }
                         elseif ($prOwners.Count -gt 0) { @($prOwners | Select-Object -First 2) }
                         else { @() }
            if ($reviewWho.Count -gt 0) {
                $prNextAction += "; @$($reviewWho -join ', @'): review needed"
                $who += $reviewWho
            } else {
                $prNextAction += "; review needed"
            }
        }
    }

    # For bot-authored PRs, substitute the human trigger person
    if ($botTrigger -and $who.Count -gt 0 -and $who[0] -eq $pr.author.login) {
        $who = @($botTrigger)
    }

    # Append Copilot re-request suggestion if its review errored
    if ($copilotReviewFailed) {
        $prNextAction += "; rerequest Copilot review"
    }

    $whoStr = if ($who.Count -gt 0) { "@" + ($who -join ", @") } else { "" }

    # Fold who names into next_action so the Who column is redundant
    if ($whoStr -and $prNextAction -match '^Maintainer:\s*(.+)') {
        $prNextAction = "$whoStr`: $($Matches[1])"
    } elseif ($whoStr -and $prNextAction -eq "Ready to merge") {
        $prNextAction = "$whoStr`: Ready to merge"
    }

    # Blockers
    $blockers = @()
    if ($pr.mergeable -eq "CONFLICTING") { $blockers += "Conflicts" }
    if ($baConclusion -eq "FAILURE") { $blockers += "CI fail ($failed failed)" }
    if ($baConclusion -eq "IN_PROGRESS") { $blockers += "CI running" }
    if ($baConclusion -eq "ABSENT") { $blockers += "No CI" }
    if ($unresolvedThreads -gt 0) { $blockers += "$unresolvedThreads threads" }
    if ($hasNeedsAuthorAction) { $blockers += "needs-author-action" }
    if (-not $hasAnyReview) { $blockers += "No review" }
    elseif (-not $hasOwnerApproval -and -not $hasTriagerApproval) { $blockers += "No owner approval" }
    if ($daysSinceUpdate -gt 14) { $blockers += "Stale $([int]$daysSinceUpdate)d" }
    if ($hasStaleApproval) { $blockers += "Approval not on latest commit" }
    if ($copilotReviewFailed) { $blockers += "Copilot review errored" }
    $blockersStr = if ($blockers.Count -gt 0) { $blockers -join ", " } else { "—" }

    # Why (use HTML entities for emojis to avoid encoding issues across platforms)
    $why = @()
    $why += if ($ciScore -eq 1) { "&#x2705; CI passed" } elseif ($ciScore -eq 0) { "&#x274C; CI failing" } else { "&#x1F7E1; CI pending" }
    if ($conflictScore -eq 0) { $why += "&#x26A0;&#xFE0F; has conflicts" }
    if ($hasOwnerApproval) { $why += "&#x1F44D; owner approved" }
    elseif ($hasTriagerApproval) { $why += "&#x1F44D; triager approved" }
    elseif ($hasAnyApproval) { $why += "&#x1F44D; community reviewed" }
    elseif ($hasAnyReview) { $why += "&#x1F440; reviewed, not approved" }
    else { $why += "&#x1F50D; no review yet" }
    if ($hasStaleApproval) { $why += "&#x26A0;&#xFE0F; approval on older commit" }
    if ($unresolvedThreads -gt 0) { $why += "&#x1F4AC; $unresolvedThreads unresolved" }
    if ($totalThreads -gt 15) { $why += "&#x1F5E8;&#xFE0F; busy ($totalThreads threads, $distinctCommenters people)" }
    elseif ($totalThreads -gt 5) { $why += "&#x1F5E8;&#xFE0F; active ($totalThreads threads)" }
    if ($isCommunity) { $why += "&#x1F310; community" }
    if ($sizeScore -eq 1) { $why += "&#x1F4E6; small change" }
    elseif ($sizeScore -eq 0) { $why += "&#x1F4E6; large ($($pr.changedFiles) files, $($totalLines) lines)" }
    if ($daysSinceUpdate -gt 14) { $why += "&#x23F3; stale ($([int]$daysSinceUpdate)d)" }
    if ($ageInDays -gt 90) { $why += "&#x1F570;&#xFE0F; old ($([int]$ageInDays)d)" }
    $whyStr = $why -join " &#183; "

    $results += [PSCustomObject]@{
        number = $n
        title = $pr.title
        author = $pr.author.login
        copilot_trigger = $botTrigger
        score = $composite
        ci = $baConclusion
        ci_detail = "$passed/$failed/$running"
        unresolved_threads = $unresolvedThreads
        total_threads = $totalThreads
        total_comments = $totalComments
        distinct_commenters = $distinctCommenters
        mergeable = $pr.mergeable
        approval_count = $approvalCount
        is_community = $isCommunity
        area_labels = @($labelNames | Where-Object { $_ -match "^area-" })
        age_days = [int]$ageInDays
        days_since_update = [int]$daysSinceUpdate
        changed_files = $pr.changedFiles
        lines_changed = $totalLines
        next_action = $prNextAction
        who = $whoStr
        blockers = $blockersStr
        why = $whyStr
    }
}

# Sort by score descending
$results = $results | Sort-Object -Property score -Descending

# --- Post-scoring filters ---
if ($MinApprovals -gt 0) {
    $results = @($results | Where-Object { $_.approval_count -ge $MinApprovals })
}
if ($MinScore -gt 0) {
    $results = @($results | Where-Object { $_.score -ge $MinScore })
}
if ($NextAction) {
    # Filter by next-action type: "ready", "review", "author", "conflicts", "ci"
    $pattern = switch ($NextAction.ToLower()) {
        "ready"     { "Ready to merge" }
        "review"    { "review needed" }
        "author"    { "^Author:" }
        "conflicts" { "resolve conflicts" }
        "ci"        { "fix CI" }
        default     { $NextAction }
    }
    $results = @($results | Where-Object { $_.next_action -match $pattern })
}
if ($MyActions) {
    $me = $MyActions.TrimStart('@')
    $results = @($results | Where-Object {
        $_.who -match $me -or
        ($_.author -eq $me -and $_.next_action -match "^Author:")
    })
}
$totalResults = $results.Count
if ($Top -gt 0) {
    $results = @($results | Select-Object -First $Top)
}

# --- Output JSON ---
$output = @{
    timestamp = $now.ToString("o")
    repo = $Repo
    filters = @{
        label = if ($Label) { $Label } else { $null }
        author = if ($Author) { $Author } else { $null }
        assignee = if ($Assignee) { $Assignee } else { $null }
        community = [bool]$Community
        min_age = $MinAge
        max_age = $MaxAge
        updated_within = $UpdatedWithin
        min_approvals = $MinApprovals
        min_score = $MinScore
        next_action = if ($NextAction) { $NextAction } else { $null }
        my_actions = if ($MyActions) { $MyActions } else { $null }
        top = $Top
    }
    owners = $owners
    scanned = $prsRaw.Count
    analyzed = $candidates.Count
    returned = $results.Count
    total_after_filters = $totalResults
    screened_out = @{
        drafts_count = $drafts.Count
        drafts = @($drafts | Select-Object -First 10 | ForEach-Object { @{ number = $_.number; author = $_.author.login; title = $_.title.Substring(0, [Math]::Min(60, $_.title.Length)) } })
        bots = @($bots | ForEach-Object { @{ number = $_.number; author = $_.author.login } })
        needs_author_action = @($needsAuthor | ForEach-Object { @{ number = $_.number; author = $_.author.login } })
        stale = @($stale | ForEach-Object { @{ number = $_.number; author = $_.author.login } })
    }
    quick_actions = @{
        ready_to_merge = @($results | Where-Object { $_.next_action -match "Ready to merge" }).Count
        needs_maintainer_review = @($results | Where-Object { $_.next_action -match "review needed" }).Count
        needs_author_action = @($results | Where-Object { $_.next_action -match "^Author:" }).Count
        blocked_conflicts = @($results | Where-Object { $_.mergeable -eq "CONFLICTING" }).Count
    }
    prs = @($results)
    elapsed_seconds = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
}

if ($OutputCsv) {
    # Tab-separated output for easy SQL/spreadsheet import
    $header = "number`ttitle`tauthor`tscore`tci`tci_detail`tunresolved_threads`ttotal_threads`ttotal_comments`tdistinct_commenters`tmergeable`tapproval_count`tis_community`tage_days`tdays_since_update`tchanged_files`tlines_changed`tnext_action`twho`tblockers`twhy"
    $lines = @($header)
    foreach ($r in $results) {
        $t = ($r.title -replace "`t"," ").Substring(0, [Math]::Min(70, $r.title.Length))
        if ($t.Length -gt 0 -and $t[0] -in '=','+','-','@') { $t = "'$t" }
        $lines += "$($r.number)`t$t`t$($r.author)`t$($r.score)`t$($r.ci)`t$($r.ci_detail)`t$($r.unresolved_threads)`t$($r.total_threads)`t$($r.total_comments)`t$($r.distinct_commenters)`t$($r.mergeable)`t$($r.approval_count)`t$(if ($r.is_community) {1} else {0})`t$($r.age_days)`t$($r.days_since_update)`t$($r.changed_files)`t$($r.lines_changed)`t$($r.next_action)`t$($r.who)`t$($r.blockers)`t$($r.why)"
    }
    $lines -join "`n"
} else {
    $output | ConvertTo-Json -Depth 5
}

} catch {
    # Ensure stdout is always valid JSON so downstream scripts don't crash
    Write-Warning "Get-PrTriageData failed for ${Repo}: $_"
    @{
        repo = $Repo
        scanned = 0
        analyzed = 0
        total_after_filters = 0
        prs = @()
        error = "$_"
        elapsed_seconds = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
    } | ConvertTo-Json -Depth 5
    exit 1
}
