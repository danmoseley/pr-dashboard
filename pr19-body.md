Fix CI absent scoring, refresh tooltip, and scoring table annotations

## Changes

### 1. CI absent no longer inflates readiness score

Previously, CI absent and CI pending both scored 0.5 (contributing +1.25 to readiness). This was a heuristic assumption in the original implementation -- the [980-PR statistical analysis](https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md) calibrated the CI *weight* (2.5) but never validated the 0-1 input mapping for absent vs pending.

Now:
- **CI passing**: 1.0 (unchanged)
- **CI pending**: 0.5 (in progress, likely to pass)
- **CI absent/failing**: 0.0 (no information or known failure)

The analysis scripts (`analyze_weights_v3.py`) created separate binary features for `ba_absent` and `ba_pending` but never tested different score values -- both were hardcoded to 0.5.

### 2. Refresh button tooltip

Changed from "Refresh this PR from GitHub" to "Check if this PR was merged or closed" -- the refresh only checks merge/close status, it doesn't re-fetch most row data.

### 3. Scoring explainer table annotations

Ready weights derived from the statistical analysis now have a superscript link to the [weightings README](https://github.com/danmoseley/pr-dashboard/blob/main/scripts/weightings/README.md). The "No merge conflicts" row (3.0) has no annotation since conflict weight was hand-designed (can't measure historically). Need weights and the Action formula are also hand-designed and unmarked.

Updated in both per-repo template (`ConvertTo-ReportHtml.ps1`) and cross-repo page (`docs/all/actionable.html`).
