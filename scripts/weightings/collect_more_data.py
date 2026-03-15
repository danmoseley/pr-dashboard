"""
Collect additional merged PR data for high-traffic repos.
Extends the existing dataset with more PRs for better per-repo analysis.
"""

import subprocess
import json
import sys
import time
import os
from pathlib import Path
from datetime import datetime, timezone

# Only fetch more for repos where we want deeper analysis
REPOS_EXTRA = [
    ("dotnet/runtime", 200),      # Very high traffic
    ("dotnet/aspnetcore", 150),    # High traffic
    ("dotnet/roslyn", 150),        # High traffic
    ("dotnet/sdk", 150),           # High traffic
    ("dotnet/maui", 150),          # Interesting dynamics (long tail)
    ("dotnet/msbuild", 120),       # Approval-gated
]

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = os.environ.get("WEIGHTINGS_DATA_DIR", str(SCRIPT_DIR / "data"))
DATA_FILE = os.path.join(OUTPUT_DIR, "merged_pr_features.json")

# Import from the main collection script (same directory)
sys.path.insert(0, str(SCRIPT_DIR))
from collect_pr_data import (
    fetch_maintainers, fetch_merged_prs, extract_pr_features, MAINTAINERS
)

def main():
    # Load existing data
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        existing = json.load(f)
    
    # Index existing PRs to avoid duplicates
    existing_keys = set()
    for feat in existing:
        existing_keys.add(f"{feat['repo']}#{feat['number']}")
    
    print(f"Existing: {len(existing)} PRs ({len(existing_keys)} unique)")
    
    fetch_maintainers()
    
    new_count = 0
    for repo_full, target in REPOS_EXTRA:
        owner, repo = repo_full.split("/")
        # Count how many we already have for this repo
        current = sum(1 for f in existing if f['repo'] == repo_full)
        need = target - current
        
        if need <= 0:
            print(f"\n{repo_full}: already have {current}/{target}, skipping")
            continue
        
        # Fetch more than needed to account for overlap
        fetch_count = need + 20
        print(f"\n{'='*60}")
        print(f"Fetching {fetch_count} more PRs from {repo_full} (have {current}, want {target})...")
        print(f"{'='*60}")
        
        prs = fetch_merged_prs(owner, repo, count=fetch_count)
        print(f"  Got {len(prs)} PRs from API")
        
        added = 0
        for i, pr in enumerate(prs):
            key = f"{repo_full}#{pr['number']}"
            if key in existing_keys:
                continue
            try:
                features = extract_pr_features(pr, repo_full)
                existing.append(features)
                existing_keys.add(key)
                added += 1
            except Exception as e:
                print(f"  Error processing PR #{pr.get('number', '?')}: {e}")
            
            if (i + 1) % 20 == 0:
                print(f"  Processed {i+1}/{len(prs)} ({added} new)")
        
        new_count += added
        print(f"  Added {added} new PRs for {repo_full}")
        
        # Save incrementally
        with open(DATA_FILE, "w", encoding="utf-8") as f:
            json.dump(existing, f, indent=2, default=str)
    
    print(f"\nTotal: {len(existing)} PRs (added {new_count} new)")
    
    # Summary
    repos_summary = {}
    for feat in existing:
        r = feat["repo"]
        repos_summary[r] = repos_summary.get(r, 0) + 1
    print("\nPRs per repo:")
    for r, c in sorted(repos_summary.items()):
        print(f"  {r}: {c}")

if __name__ == "__main__":
    main()
