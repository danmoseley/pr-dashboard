"""
Quick fetch of mergedBy for all repos to infer maintainer sets.
"""

import subprocess
import json
import time
import os
import sys
from pathlib import Path
from collections import defaultdict

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = os.environ.get("WEIGHTINGS_DATA_DIR", str(SCRIPT_DIR / "data"))

REPOS = [
    "dotnet/runtime", "dotnet/aspire", "dotnet/aspnetcore",
    "dotnet/extensions", "dotnet/machinelearning", "dotnet/maui",
    "dotnet/msbuild", "dotnet/roslyn", "dotnet/sdk",
    "dotnet/winforms", "dotnet/wpf",
]

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
            print(f"  GraphQL error: {err}", file=sys.stderr)
            return None
        if not result.stdout:
            return None
        return json.loads(result.stdout)
    return None

def fetch_mergers(owner, repo, count=200):
    """Fetch who merged recent PRs."""
    all_mergers = []
    cursor = None
    
    while len(all_mergers) < count:
        after = f', after: "{cursor}"' if cursor else ""
        query = f"""
        {{
          repository(owner: "{owner}", name: "{repo}") {{
            pullRequests(states: MERGED, orderBy: {{field: UPDATED_AT, direction: DESC}},
                         first: 50{after}) {{
              pageInfo {{ hasNextPage endCursor }}
              nodes {{
                number
                mergedBy {{ login }}
                author {{ login }}
              }}
            }}
          }}
        }}
        """
        data = gh_graphql(query)
        if not data or "data" not in data:
            break
        prs = data["data"]["repository"]["pullRequests"]
        for pr in prs["nodes"]:
            merger = (pr.get("mergedBy") or {}).get("login")
            author = (pr.get("author") or {}).get("login")
            if merger:
                all_mergers.append({
                    "number": pr["number"],
                    "merger": merger.lower(),
                    "author": (author or "").lower()
                })
        if not prs["pageInfo"]["hasNextPage"]:
            break
        cursor = prs["pageInfo"]["endCursor"]
        time.sleep(0.5)
    
    return all_mergers[:count]

def main():
    # Fetch mergers for all repos
    repo_maintainers = {}
    all_merger_data = {}
    
    for repo_full in REPOS:
        owner, repo = repo_full.split("/")
        print(f"Fetching mergers for {repo_full}...")
        mergers = fetch_mergers(owner, repo, count=300)
        print(f"  Got {len(mergers)} merge records")
        
        all_merger_data[repo_full] = mergers
        
        # Infer maintainers: users who have merged PRs (excluding known bots)
        merger_counts = defaultdict(int)
        for m in mergers:
            if m["merger"] not in ("github-actions[bot]", "dotnet-maestro[bot]",
                                    "dependabot[bot]", "dotnet-maestro-bot"):
                merger_counts[m["merger"]] += 1
        
        # Anyone who merged at least 2 PRs is likely a maintainer
        maintainers = {user for user, count in merger_counts.items() if count >= 2}
        repo_maintainers[repo_full] = maintainers
        
        top = sorted(merger_counts.items(), key=lambda x: -x[1])[:10]
        print(f"  Top mergers: {', '.join(f'{u}({c})' for u,c in top)}")
        print(f"  Inferred {len(maintainers)} maintainers (merged ≥2 PRs)")
    
    # Save
    output = {
        "repo_maintainers": {k: sorted(v) for k, v in repo_maintainers.items()},
        "merger_data": all_merger_data,
    }
    
    out_file = os.path.join(OUTPUT_DIR, "inferred_maintainers.json")
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)
    print(f"\nSaved to {out_file}")
    
    # Cross-repo overlap check
    print("\n--- Cross-repo maintainer overlap ---")
    all_repos = list(repo_maintainers.keys())
    for i, r1 in enumerate(all_repos):
        for r2 in all_repos[i+1:]:
            overlap = repo_maintainers[r1] & repo_maintainers[r2]
            if overlap:
                print(f"  {r1.split('/')[1]} ∩ {r2.split('/')[1]}: {len(overlap)} ({', '.join(sorted(overlap)[:5])}{'...' if len(overlap)>5 else ''})")

if __name__ == "__main__":
    main()
