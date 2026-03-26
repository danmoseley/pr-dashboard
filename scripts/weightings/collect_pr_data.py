"""
Collect merged PR data from dotnet repos for readiness score weight calibration.
Uses gh CLI for authentication. Fetches PR metadata, reviews, check runs, threads.
"""

import subprocess
import json
import sys
import time
import os
from pathlib import Path
from datetime import datetime, timezone

REPOS = [
    "dotnet/runtime",
    "microsoft/aspire",
    "dotnet/aspnetcore",
    "dotnet/extensions",
    "dotnet/machinelearning",
    "dotnet/maui",
    "dotnet/msbuild",
    "dotnet/roslyn",
    "dotnet/sdk",
    "dotnet/winforms",
    "dotnet/wpf",
]

# Maintainers list (from config/maintainers.json in the dashboard repo)
# Per-repo dict to avoid cross-repo misclassification
MAINTAINERS_BY_REPO = {}  # {"dotnet/runtime": {"user1", "user2"}, ...}

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = os.environ.get("WEIGHTINGS_DATA_DIR", str(SCRIPT_DIR / "data"))

def gh_graphql(query, variables=None, retries=2):
    """Execute a GraphQL query via gh CLI."""
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    if variables:
        for k, v in variables.items():
            cmd.extend(["-f", f"{k}={v}"])
    for attempt in range(retries + 1):
        result = subprocess.run(cmd, capture_output=True, timeout=120,
                                encoding="utf-8", errors="replace")
        if result.returncode != 0:
            err = (result.stderr or "")[:300]
            if ("504" in err or "502" in err) and attempt < retries:
                print(f"  Retrying after HTTP error (attempt {attempt+1})...")
                time.sleep(5 * (attempt + 1))
                continue
            print(f"  GraphQL error: {err}", file=sys.stderr)
            return None
        if not result.stdout:
            return None
        return json.loads(result.stdout)
    return None

def fetch_maintainers():
    """Fetch maintainers list from the dashboard repo (per-repo)."""
    global MAINTAINERS_BY_REPO
    # Try local config first, fall back to GitHub API
    local_config = SCRIPT_DIR.parent.parent / "config" / "maintainers.json"
    data = None
    try:
        if local_config.exists():
            data = json.loads(local_config.read_text(encoding="utf-8"))
            print(f"Loaded maintainers from {local_config}")
    except Exception as e:
        print(f"Warning: couldn't read local maintainers: {e}")

    if data is None:
        # Fallback: fetch from the repo that hosts these scripts
        remote_repo = os.environ.get("WEIGHTINGS_MAINTAINERS_REPO",
                                     "danmoseley/pr-dashboard")
        try:
            result = subprocess.run(
                ["gh", "api", f"repos/{remote_repo}/contents/config/maintainers.json",
                 "-H", "Accept: application/vnd.github.v3.raw"],
                capture_output=True, text=True, timeout=30
            )
            if result.returncode == 0:
                data = json.loads(result.stdout)
                print(f"Loaded maintainers from GitHub API ({remote_repo})")
        except Exception as e:
            print(f"Warning: couldn't fetch maintainers: {e}")

    if data:
        for repo, users in data.items():
            if isinstance(users, list):
                MAINTAINERS_BY_REPO[repo] = {u.lower() for u in users}
        total = sum(len(v) for v in MAINTAINERS_BY_REPO.values())
        print(f"  {total} maintainers across {len(MAINTAINERS_BY_REPO)} repos")

def fetch_merged_prs(owner, repo, count=80):
    """Fetch recently merged PRs with detail via GraphQL pagination.
    Uses smaller batch size (20) and lighter query to avoid 504s on large repos.
    Note: orders by UPDATED_AT because GitHub GraphQL doesn't support ordering
    merged PRs by mergedAt. This may include PRs updated post-merge (labels, comments)
    but the sample is still representative of recent merge activity."""
    all_prs = []
    cursor = None
    per_page = 20  # Smaller batches to avoid timeouts

    while len(all_prs) < count:
        after_clause = f', after: "{cursor}"' if cursor else ""
        # Lighter query: fewer timeline items, fewer check contexts
        query = f"""
        {{
          repository(owner: "{owner}", name: "{repo}") {{
            pullRequests(
              states: MERGED,
              orderBy: {{field: UPDATED_AT, direction: DESC}},
              first: {per_page}{after_clause}
            ) {{
              pageInfo {{ hasNextPage endCursor }}
              nodes {{
                number
                title
                author {{ login }}
                createdAt
                mergedAt
                updatedAt
                additions
                deletions
                changedFiles
                labels(first: 20) {{ nodes {{ name }} }}
                reviews(first: 30) {{
                  nodes {{
                    author {{ login }}
                    state
                    submittedAt
                  }}
                }}
                # Note: pagination limits (30 threads, 5 comments/thread, 30 timeline items)
                # may undercount on high-activity PRs. totalCount is used where available
                # to mitigate; see also the analysis scripts which note this limitation.
                reviewThreads(first: 30) {{
                  nodes {{
                    isResolved
                    isOutdated
                    comments(first: 5) {{
                      totalCount
                      nodes {{ createdAt author {{ login }} }}
                    }}
                  }}
                }}
                commits(last: 1) {{
                  nodes {{
                    commit {{
                      oid
                      statusCheckRollup {{
                        contexts(first: 30) {{
                          nodes {{
                            ... on CheckRun {{
                              name
                              conclusion
                              status
                              completedAt
                            }}
                          }}
                        }}
                      }}
                    }}
                  }}
                }}
                timelineItems(first: 30, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_COMMIT]) {{
                  nodes {{
                    __typename
                    ... on IssueComment {{
                      author {{ login }}
                      createdAt
                    }}
                    ... on PullRequestCommit {{
                      commit {{ committedDate oid }}
                    }}
                  }}
                }}
              }}
            }}
          }}
        }}
        """
        data = gh_graphql(query)
        if not data or "data" not in data:
            print(f"  Failed to fetch page, got: {str(data)[:200]}")
            break

        prs_data = data["data"]["repository"]["pullRequests"]
        nodes = prs_data["nodes"]
        all_prs.extend(nodes)
        print(f"  Fetched {len(all_prs)}/{count} PRs...")

        if not prs_data["pageInfo"]["hasNextPage"] or len(nodes) == 0:
            break
        cursor = prs_data["pageInfo"]["endCursor"]

        # Delay between pages to avoid rate limits / 504s
        time.sleep(1.0)

    return all_prs[:count]

def extract_pr_features(pr, repo_slug):
    """Extract feature vector from a single PR's GraphQL data."""
    author = (pr.get("author") or {}).get("login", "unknown")
    created = pr["createdAt"]
    merged = pr["mergedAt"]

    created_dt = datetime.fromisoformat(created.replace("Z", "+00:00"))
    merged_dt = datetime.fromisoformat(merged.replace("Z", "+00:00"))
    age_days = (merged_dt - created_dt).total_seconds() / 86400

    additions = pr.get("additions", 0)
    deletions = pr.get("deletions", 0)
    changed_files = pr.get("changedFiles", 0)
    total_lines = additions + deletions

    # Labels
    label_names = [l["name"] for l in (pr.get("labels", {}).get("nodes", []))]
    has_area_label = any(l.startswith("area-") for l in label_names)
    is_untriaged = "untriaged" in label_names

    # Is external author? (author not in this repo's inferred maintainer list)
    # Note: the dashboard's communityScore uses a "community*" label, not author identity.
    # This field captures author-based community status for regression analysis.
    repo_maintainers = MAINTAINERS_BY_REPO.get(repo_slug, set())
    is_community = author.lower() not in repo_maintainers
    has_community_label = any(l.startswith("community") for l in label_names)

    # Reviews
    reviews = pr.get("reviews", {}).get("nodes", [])
    approvals = [r for r in reviews if r.get("state") == "APPROVED"]
    changes_requested = [r for r in reviews if r.get("state") == "CHANGES_REQUESTED"]
    approval_count = len(set((r.get("author") or {}).get("login", "") for r in approvals))

    has_owner_approval = any(
        (r.get("author") or {}).get("login", "").lower() in repo_maintainers
        for r in approvals
    )
    has_any_review = len(reviews) > 0

    # First approval date
    first_approval_dt = None
    if approvals:
        dates = [datetime.fromisoformat(r["submittedAt"].replace("Z", "+00:00"))
                 for r in approvals if r.get("submittedAt")]
        if dates:
            first_approval_dt = min(dates)

    # Last review date
    last_review_dt = None
    if reviews:
        dates = [datetime.fromisoformat(r["submittedAt"].replace("Z", "+00:00"))
                 for r in reviews if r.get("submittedAt")]
        if dates:
            last_review_dt = max(dates)

    # Time from first approval to merge
    approval_to_merge_days = None
    if first_approval_dt:
        approval_to_merge_days = (merged_dt - first_approval_dt).total_seconds() / 86400

    # Review threads
    threads = pr.get("reviewThreads", {}).get("nodes", [])
    total_threads = len(threads)
    unresolved_threads = sum(1 for t in threads if not t.get("isResolved", True))
    resolved_threads = total_threads - unresolved_threads

    # Distinct commenters across threads and timeline comments
    commenters = set()
    for t in threads:
        for c in t.get("comments", {}).get("nodes", []):
            login = (c.get("author") or {}).get("login")
            if login:
                commenters.add(login.lower())
    timeline_items = pr.get("timelineItems", {}).get("nodes", [])
    for item in timeline_items:
        if item.get("__typename") == "IssueComment":
            login = (item.get("author") or {}).get("login")
            if login:
                commenters.add(login.lower())
    distinct_commenters = len(commenters)

    # Total comments (actual review comment count + timeline comments)
    review_comment_count = sum(
        (t.get("comments") or {}).get("totalCount", len((t.get("comments") or {}).get("nodes", [])))
        for t in threads
    )
    timeline_comment_count = sum(
        1 for item in timeline_items if item.get("__typename") == "IssueComment"
    )
    total_comments = review_comment_count + timeline_comment_count

    # Check runs (CI)
    ci_passed = False
    ci_failed = False
    ci_pending = False
    build_analysis_conclusion = "ABSENT"
    check_pass_count = 0
    check_fail_count = 0
    check_pending_count = 0

    last_commit_node = (pr.get("commits", {}).get("nodes", []) or [None])[-1]
    if last_commit_node:
        rollup = (last_commit_node.get("commit", {}).get("statusCheckRollup") or {})
        contexts = rollup.get("contexts", {}).get("nodes", [])
        for ctx in contexts:
            name = ctx.get("name", "")
            # Skip non-CheckRun union members (e.g. StatusContext) that
            # deserialize as empty dicts from the `... on CheckRun` fragment
            if not name:
                continue
            status = ctx.get("status", "")
            conclusion = ctx.get("conclusion")

            if "build analysis" in name.lower() or "build_analysis" in name.lower():
                if status == "COMPLETED" and conclusion:
                    build_analysis_conclusion = conclusion.upper()
                elif status != "COMPLETED":
                    build_analysis_conclusion = "IN_PROGRESS"

            if status != "COMPLETED":
                check_pending_count += 1
            elif conclusion in ("SUCCESS", "SKIPPED", "NEUTRAL"):
                check_pass_count += 1
            else:
                check_fail_count += 1

    # ci_status: mirrors dashboard logic — uses BA when present, falls back to overall checks.
    # build_analysis_conclusion: BA-only (no fallback), for isolating BA's predictive power.
    ci_status = "UNKNOWN"
    if build_analysis_conclusion == "SUCCESS":
        ci_status = "SUCCESS"
    elif build_analysis_conclusion == "FAILURE":
        ci_status = "FAILURE"
    elif build_analysis_conclusion == "IN_PROGRESS":
        ci_status = "IN_PROGRESS"
    elif check_pending_count > 0:
        ci_status = "IN_PROGRESS"
    elif check_fail_count == 0 and check_pass_count > 0:
        ci_status = "SUCCESS"
    elif check_fail_count > 0:
        ci_status = "FAILURE"

    # CI pass date (completedAt of Build Analysis, approximation)
    ci_completed_dt = None
    if last_commit_node:
        rollup = (last_commit_node.get("commit", {}).get("statusCheckRollup") or {})
        contexts = rollup.get("contexts", {}).get("nodes", [])
        for ctx in contexts:
            name = ctx.get("name", "")
            if "build analysis" in name.lower() or "build_analysis" in name.lower():
                if ctx.get("completedAt"):
                    ci_completed_dt = datetime.fromisoformat(
                        ctx["completedAt"].replace("Z", "+00:00"))

    ci_to_merge_days = None
    if ci_completed_dt:
        ci_to_merge_days = (merged_dt - ci_completed_dt).total_seconds() / 86400

    # Commits timeline - for velocity
    commit_dates = []
    for item in timeline_items:
        if item.get("__typename") == "PullRequestCommit":
            cd = (item.get("commit") or {}).get("committedDate")
            if cd:
                commit_dates.append(datetime.fromisoformat(cd.replace("Z", "+00:00")))

    last_commit_dt = max(commit_dates) if commit_dates else created_dt

    # Stale approval check: was there a commit after the latest approval?
    has_stale_approval = False
    last_approval_dt = max(
        (datetime.fromisoformat(r["submittedAt"].replace("Z", "+00:00"))
         for r in reviews if r.get("state") == "APPROVED" and r.get("submittedAt")),
        default=None
    )
    if last_approval_dt and commit_dates:
        has_stale_approval = any(cd > last_approval_dt for cd in commit_dates)

    # Days from last activity to merge
    all_event_dates = []
    if last_review_dt:
        all_event_dates.append(last_review_dt)
    all_event_dates.append(last_commit_dt)
    for item in timeline_items:
        if item.get("__typename") == "IssueComment" and item.get("createdAt"):
            all_event_dates.append(
                datetime.fromisoformat(item["createdAt"].replace("Z", "+00:00")))

    last_activity_dt = max(all_event_dates) if all_event_dates else created_dt
    last_activity_to_merge_days = (merged_dt - last_activity_dt).total_seconds() / 86400

    # Compute the dashboard's own sub-scores for comparison
    days_since_activity_at_merge = 0  # at merge time, activity just happened
    ci_score_dash = {"SUCCESS": 1.0, "ABSENT": 0.5, "IN_PROGRESS": 0.5}.get(ci_status, 0.0)
    size_score_dash = 1.0 if (changed_files <= 5 and total_lines <= 200) else (0.5 if (changed_files <= 20 and total_lines <= 500) else 0.0)
    community_score_dash = 0.5 if is_community else 1.0
    align_score_dash = 0.0 if (is_untriaged or not has_area_label) else 1.0

    return {
        "repo": repo_slug,
        "number": pr["number"],
        "author": author,
        "is_community": is_community,
        "has_community_label": has_community_label,
        "created_at": created,
        "merged_at": merged,
        "age_days": round(age_days, 2),
        "additions": additions,
        "deletions": deletions,
        "changed_files": changed_files,
        "total_lines": total_lines,
        "has_area_label": has_area_label,
        "is_untriaged": is_untriaged,
        "approval_count": approval_count,
        "has_owner_approval": has_owner_approval,
        "has_any_review": has_any_review,
        "has_stale_approval": has_stale_approval,
        "total_threads": total_threads,
        "unresolved_threads": unresolved_threads,
        "resolved_threads": resolved_threads,
        "distinct_commenters": distinct_commenters,
        "total_comments": total_comments,
        "ci_status": ci_status,
        "build_analysis_conclusion": build_analysis_conclusion,
        "check_pass_count": check_pass_count,
        "check_fail_count": check_fail_count,
        "check_pending_count": check_pending_count,
        "ci_to_merge_days": ci_to_merge_days,
        "approval_to_merge_days": approval_to_merge_days,
        "last_activity_to_merge_days": round(last_activity_to_merge_days, 2),
        "first_approval_date": first_approval_dt.isoformat() if first_approval_dt else None,
        "last_review_date": last_review_dt.isoformat() if last_review_dt else None,
        "ci_completed_date": ci_completed_dt.isoformat() if ci_completed_dt else None,
        "ci_score_dash": ci_score_dash,
        "size_score_dash": size_score_dash,
        "community_score_dash": community_score_dash,
        "align_score_dash": align_score_dash,
        "changes_requested_count": len(changes_requested),
    }

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    output_file = os.path.join(OUTPUT_DIR, "merged_pr_features.json")

    # Load existing data if any (resume support)
    existing_features = []
    existing_repos = set()
    if os.path.exists(output_file):
        with open(output_file, "r", encoding="utf-8") as f:
            existing_features = json.load(f)
        existing_repos = set(feat["repo"] for feat in existing_features)
        print(f"Loaded {len(existing_features)} existing features from {len(existing_repos)} repos")

    print("Fetching maintainers list...")
    fetch_maintainers()

    all_features = list(existing_features)
    prs_per_repo = 80  # ~80 per repo = ~880+ total

    for repo_full in REPOS:
        if repo_full in existing_repos:
            print(f"\nSkipping {repo_full} (already collected)")
            continue

        owner, repo = repo_full.split("/")
        print(f"\n{'='*60}")
        print(f"Fetching {prs_per_repo} merged PRs from {repo_full}...")
        print(f"{'='*60}")

        prs = fetch_merged_prs(owner, repo, count=prs_per_repo)
        print(f"  Got {len(prs)} PRs")

        repo_features = []
        for i, pr in enumerate(prs):
            try:
                features = extract_pr_features(pr, repo_full)
                repo_features.append(features)
                if (i + 1) % 20 == 0:
                    print(f"  Processed {i+1}/{len(prs)}")
            except Exception as e:
                print(f"  Error processing PR #{pr.get('number', '?')}: {e}")

        all_features.extend(repo_features)

        # Save incrementally after each repo
        with open(output_file, "w", encoding="utf-8") as f:
            json.dump(all_features, f, indent=2, default=str)
        print(f"  Saved {len(repo_features)} features for {repo_full} (total: {len(all_features)})")

    # Final summary
    print(f"\nTotal: {len(all_features)} PR feature vectors in {output_file}")
    repos_summary = {}
    for feat in all_features:
        r = feat["repo"]
        repos_summary[r] = repos_summary.get(r, 0) + 1
    print("\nPRs per repo:")
    for r, c in sorted(repos_summary.items()):
        print(f"  {r}: {c}")

if __name__ == "__main__":
    main()
