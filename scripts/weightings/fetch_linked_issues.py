"""
Fetch linked issue metadata for existing PR dataset.
For each PR, get closingIssuesReferences with reactions, labels, comments, age.
"""

import subprocess
import json
import time
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
_DATA_DIR = os.environ.get("WEIGHTINGS_DATA_DIR", str(SCRIPT_DIR / "data"))
DATA_FILE = os.path.join(_DATA_DIR, "merged_pr_features.json")
OUTPUT_FILE = os.path.join(_DATA_DIR, "linked_issues.json")

def gh_graphql(query, retries=2):
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    for attempt in range(retries + 1):
        result = subprocess.run(cmd, capture_output=True, timeout=120,
                                encoding="utf-8", errors="replace")
        if result.returncode != 0:
            err = (result.stderr or "")[:300]
            if ("504" in err or "502" in err) and attempt < retries:
                time.sleep(5 * (attempt + 1))
                continue
            return None
        if not result.stdout:
            return None
        return json.loads(result.stdout)
    return None

def fetch_issue_data_batch(owner, repo, pr_numbers):
    """Fetch linked issue data for a batch of PRs."""
    # Build individual PR queries
    fragments = []
    for i, num in enumerate(pr_numbers):
        fragments.append(f"""
        pr{i}: pullRequest(number: {num}) {{
          number
          labels(first: 20) {{ nodes {{ name }} }}
          milestone {{ title dueOn }}
          closingIssuesReferences(first: 10) {{
            nodes {{
              number
              title
              createdAt
              comments {{ totalCount }}
              reactions {{ totalCount }}
              reactionGroups {{
                content
                reactors {{ totalCount }}
              }}
              labels(first: 15) {{ nodes {{ name }} }}
              milestone {{ title }}
              timelineItems(itemTypes: [CROSS_REFERENCED_EVENT], first: 5) {{
                totalCount
              }}
            }}
          }}
        }}
        """)
    
    query = f"""
    {{
      repository(owner: "{owner}", name: "{repo}") {{
        {"".join(fragments)}
      }}
    }}
    """
    return gh_graphql(query)

def main():
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        features = json.load(f)
    
    # Load existing results if resuming
    existing = {}
    if os.path.exists(OUTPUT_FILE):
        with open(OUTPUT_FILE, "r", encoding="utf-8") as f:
            existing = json.load(f)
    
    # Group PRs by repo
    repo_prs = {}
    for feat in features:
        repo = feat['repo']
        num = feat['number']
        key = f"{repo}#{num}"
        if key not in existing:
            repo_prs.setdefault(repo, []).append(num)
    
    total_needed = sum(len(nums) for nums in repo_prs.values())
    print(f"Need to fetch issue data for {total_needed} PRs across {len(repo_prs)} repos")
    print(f"Already have {len(existing)} cached results")
    
    for repo_full, numbers in sorted(repo_prs.items()):
        owner, repo = repo_full.split("/")
        print(f"\n{repo_full}: {len(numbers)} PRs to fetch")
        
        # Batch in groups of 15 (GraphQL complexity limits)
        for batch_start in range(0, len(numbers), 15):
            batch = numbers[batch_start:batch_start + 15]
            data = fetch_issue_data_batch(owner, repo, batch)
            
            if not data or "data" not in data:
                print(f"  Failed batch starting at {batch_start}")
                time.sleep(2)
                continue
            
            repo_data = data["data"]["repository"]
            for i, num in enumerate(batch):
                pr_key = f"pr{i}"
                if pr_key in repo_data and repo_data[pr_key]:
                    pr_data = repo_data[pr_key]
                    key = f"{repo_full}#{num}"
                    
                    # Extract issue summary
                    issues = pr_data.get("closingIssuesReferences", {}).get("nodes", [])
                    pr_labels = [l["name"] for l in pr_data.get("labels", {}).get("nodes", [])]
                    milestone = pr_data.get("milestone")
                    
                    issue_summary = {
                        "pr_number": num,
                        "repo": repo_full,
                        "pr_labels": pr_labels,
                        "has_milestone": milestone is not None,
                        "milestone_title": milestone["title"] if milestone else None,
                        "linked_issue_count": len(issues),
                        "issues": []
                    }
                    
                    for issue in issues:
                        issue_labels = [l["name"] for l in issue.get("labels", {}).get("nodes", [])]
                        reactions = issue.get("reactions", {}).get("totalCount", 0)
                        
                        # Get thumbs-up specifically
                        thumbs_up = 0
                        for rg in issue.get("reactionGroups", []):
                            if rg["content"] == "THUMBS_UP":
                                thumbs_up = rg["reactors"]["totalCount"]
                        
                        cross_refs = issue.get("timelineItems", {}).get("totalCount", 0)
                        
                        issue_summary["issues"].append({
                            "number": issue["number"],
                            "title": issue.get("title", ""),
                            "created_at": issue.get("createdAt"),
                            "comment_count": issue.get("comments", {}).get("totalCount", 0),
                            "reaction_count": reactions,
                            "thumbs_up": thumbs_up,
                            "labels": issue_labels,
                            "cross_ref_count": cross_refs,
                            "has_milestone": issue.get("milestone") is not None,
                        })
                    
                    existing[key] = issue_summary
            
            if (batch_start + 15) % 60 == 0:
                print(f"  Fetched {min(batch_start + 15, len(numbers))}/{len(numbers)}")
            time.sleep(0.5)
        
        # Save incrementally
        os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)
        with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
            json.dump(existing, f, indent=2)
    
    print(f"\nTotal: {len(existing)} PR issue records saved to {OUTPUT_FILE}")
    
    # Quick stats
    has_issues = sum(1 for v in existing.values() if v["linked_issue_count"] > 0)
    has_milestone = sum(1 for v in existing.values() if v["has_milestone"])
    total_reactions = sum(
        sum(i["reaction_count"] for i in v["issues"])
        for v in existing.values()
    )
    
    print(f"\nQuick stats:")
    if len(existing) > 0:
        print(f"  PRs with linked issues: {has_issues} ({has_issues/len(existing)*100:.0f}%)")
        print(f"  PRs with milestones: {has_milestone} ({has_milestone/len(existing)*100:.0f}%)")
    else:
        print(f"  No PRs in dataset")
    print(f"  Total issue reactions: {total_reactions}")
    
    # Regression/security label check
    regression_labels = ["regression-from-last-release", "regression", 
                         "regression-from-previous-release", "Regression"]
    security_labels = ["security", "Security", "area-Security"]
    
    has_regression = 0
    has_security = 0
    for v in existing.values():
        all_labels = set(v["pr_labels"])
        for issue in v["issues"]:
            all_labels.update(issue["labels"])
        if any(l in all_labels for l in regression_labels):
            has_regression += 1
        if any(l in all_labels for l in security_labels):
            has_security += 1
    
    print(f"  Regression-labeled: {has_regression}")
    print(f"  Security-labeled: {has_security}")

if __name__ == "__main__":
    main()
