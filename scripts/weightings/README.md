# Weight Calibration Analysis

Empirical calibration of the ~12 PR readiness score weights using data from
980 recently merged PRs across 11 dotnet repos.

Full writeup: https://gist.github.com/danmoseley/ecfdccef799ade09f53ebfaa1ef9b46e

## Quick Results

### Two Scores, Not One

The analysis reveals that "closeness to merge" and "deserves attention" are
**anti-correlated (r=-0.63)**. A single score conflates them. We recommend two:

#### Score 1: Merge Readiness (how close to merging?)

| Feature | Current | Recommended | Confidence |
|---------|---------|-------------|------------|
| ciScore | 3.0 | **2.5** | Moderate |
| conflictScore | 3.0 | **3.0** | N/A (untestable) |
| approvalScore | 2.0 | **2.5** | Moderate |
| maintScore | 3.0 | **1.5** | Lower |
| feedbackScore | 2.0 | **2.5** | High |
| discussionScore | 1.5 | **2.5** | Very High |
| sizeScore | 1.0 | **2.0** | High |
| ↳ trivial | — | **(+1.0 bonus)** | Hand-tuned |
| communityScore | 0.5 | **1.0** | High |
| stalenessScore | 1.5 | **1.0** | Low |
| freshScore | 1.0 | **0.7** | Low |
| alignScore | 1.0 | **0.5** | Lower |
| velocityScore | 0.5 | **0.3** | Low |
| **TOTAL** | **20.0** | **20.0** | |

#### Score 2: Deserves Attention (how much should a maintainer prioritize this?)

Several features have **opposite** directions vs merge readiness: CI failing,
missing approval, large size, and community authorship all _lower_ merge readiness
but _raise_ the need for attention. Issue engagement is entirely new signal.

| Component | Inputs | Points | Direction vs Merge |
|-----------|--------|--------|--------------------|
| **Urgency** | regression label | +4 | New signal |
| | security label | +4 | New signal |
| | bug label | +1 | New signal |
| | has milestone | +1 | New signal |
| **Community demand** | issue thumbsup >= 10 | +2 | New signal |
| | issue thumbsup >= 3 | +1 | New signal |
| | issue comments >= 20 | +1.5 | New signal |
| | cross-references >= 3 | +1 | New signal |
| **Effort at risk** | community author | +2 | **Opposite** |
| | has reviews but no approval | +1 | **Opposite** |
| | large change (>200 lines) | +0.5 | **Opposite** |
| | trivial change (≤2 files, ≤20 lines) | +0.5 | Aligned |
| **Blocked** | CI failing | +1 | **Opposite** |
| | unresolved review feedback | +1 | Aligned |
| | no approval | +1.5 | **Opposite** |

Quadrant analysis of 980 PRs (split at median of each score):

| | High merge readiness | Low merge readiness |
|--|--|--|
| **High attention** | **Q1** "Help across finish line" (n=176, 72% community) | **Q2** "Invest review time" (n=355, 59% community) |
| **Low attention** | **Q3** "Will merge on its own" (n=337, 0% community) | **Q4** "Deprioritize" (n=112, 0% community) |

Key: community PRs dominate Q1+Q2; internal PRs dominate Q3+Q4. The attention
score primarily surfaces community contributions that need maintainer action.

### Top Findings

1. **Discussion is massively underweighted** (1.5 should be ~2.5-4.5). Dominant
   predictor in every model, every repo, every outcome definition.

2. **CI is a gate, not a gradient**. Build Analysis pass is the last gate before
   merge 70% of the time (median 0.6h to merge after BA passes). But BA is absent
   in ~40% of repos.

3. **maintScore is redundant** with approvalScore (Lasso drops it; bootstrap CV=127%).

4. **Size matters more than expected** (significant in 6/11 repos). Changed files,
   total lines, and additions-only all correlate similarly with merge time (r≈0.27–0.30
   on log scale), so the combined threshold approach in the dashboard is reasonable.
   Post-analysis refinement: trivial PRs (≤2 files, ≤20 lines) get a sizeScore of
   1.5 (vs 1.0 for small) and a +0.5 Need bonus — these are quick wins where a
   30-second review can close out a contribution.

5. **Raw discussion count creates a death spiral**. Recommend splitting into
   actionable feedback (unresolved threads) + engagement (distinct commenters, capped).

6. **Dual-score system may be more useful**: merge readiness vs. deserves-attention
   are anti-correlated (r=-0.63). PRs that need attention are typically NOT close
   to merging.

7. **Infer maintainers from mergedBy data** rather than a static list (community
   rate drops from 78% to 34%, signal becomes significant at p=0.002).

### Per-Repo Dynamics

Repos have significantly different dynamics. Per-repo weights could improve
accuracy but are impractical with current sample sizes (~80 per repo).

| Repo | R² | Top Predictors | Median Age |
|------|-----|---------------|------------|
| sdk | 0.61 | discussion | 1.0d |
| maui | 0.58 | discussion, size, community, align | 5.5d |
| winforms | 0.44 | discussion, approval, size | 0.2d |
| extensions | 0.41 | discussion | 1.5d |
| aspnetcore | 0.41 | discussion | 0.7d |
| aspire | 0.36 | discussion, size | 0.2d |
| runtime | 0.33 | discussion, community | 2.2d |
| roslyn | 0.33 | approval, size | 0.8d |
| msbuild | 0.26 | approval | 1.9d |
| machinelearning | 0.20 | size | 1.7d |
| wpf | 0.05 | (none significant) | 1.0d |

Notable differences:
- **sdk** (R²=0.61): Most predictable repo. Discussion is the dominant signal.
  PRs with low thread counts merge very quickly.
- **maui** (R²=0.58): Most complex dynamics — discussion, size, community, and
  alignment all matter. Slowest repo (5.5d median, 76.5d mean — long tail of old
  PRs). Build Analysis is present but red 78% of the time.
- **winforms** (R²=0.44): Very fast (0.2d median). Discussion, approval, and size
  all significant. No Build Analysis check.
- **extensions** (R²=0.41): Discussion-dominated. No Build Analysis check.
- **aspnetcore** (R²=0.41): Fast (0.7d median). Discussion-dominated. Has Build
  Analysis; 92% have milestones.
- **aspire** (R²=0.36): Fastest repo (0.2d median). Discussion + size matter.
  99% have milestones. Only 4% have linked issues.
- **runtime** (R²=0.33): Community PRs take 3.3× longer (3.9d vs 1.2d). Discussion
  and community are the top predictors. Highest linked issue rate (21%). Build
  Analysis present but frequently red on unrelated legs.
- **roslyn** (R²=0.33): Approval is the key gate — compiler team requires specific
  reviewers. Size also matters. Community PRs are actually *faster* (they tend to
  be small). 59% have milestones.
- **msbuild** (R²=0.26): Approval-gated like roslyn. No Build Analysis check.
  No milestones used.
- **machinelearning** (R²=0.20): Size is the main signal. Largest community speed
  gap (4.9× slower). Low linked issue rate.
- **wpf** (R²=0.05): Essentially unpredictable from these features. Very few
  linked issues (0%), few milestones (4%). Small team, likely driven by factors
  not visible in API data (internal priorities, release schedule).

A pragmatic middle ground: rather than full per-repo weight sets, apply one or
two repo-specific adjustments (e.g., suppress CI score where Build Analysis is
absent; boost approval weight for roslyn/msbuild).

### Score Combination — Recommended Approach

The two scores are anti-correlated (r=-0.63): PRs that are nearly ready to merge
tend to need little attention, and vice versa. Three combination strategies were
considered:

| Strategy | Formula | Best for |
|----------|---------|----------|
| **Multiplicative (recommended)** | `(merge + 1) × (attention + 1)` | Default sort — "where does my time produce the most value?" |
| Sort by merge readiness | Rank by Score 1 only | "I have 5 minutes, clear the easy wins" |
| Sort by attention | Rank by Score 2 only | "Weekly triage — what's stuck or important?" |

**Recommendation: multiplicative with floor, as the default sort order.** This
naturally surfaces Q1 PRs ("help across the finish line" — high on both axes) at
the top. The `+1` offset prevents zeroing out one dimension. In practice:

- A PR with merge=8, attention=2 scores `9 × 3 = 27`
- A PR with merge=2, attention=8 scores `3 × 9 = 27` (equal priority — correct)
- A PR with merge=8, attention=0 scores `9 × 1 = 9` (lower — will merge on its own)
- A PR with merge=0, attention=8 scores `1 × 9 = 9` (lower — blocked, attention alone won't help)

The UI could also offer a toggle to sort by either dimension alone for focused
workflows (quick-win clearing vs. triage sessions).

## Scripts

### Data Collection
- `collect_pr_data.py` — Fetch merged PR features via GitHub GraphQL (reviews,
  check runs, threads, labels, size, author, timeline). Requires `gh` CLI auth.
- `collect_more_data.py` — Extension to fetch additional PRs for high-traffic repos.
- `fetch_maintainers.py` — Infer per-repo maintainers from mergedBy data.
- `fetch_linked_issues.py` — Fetch linked issue metadata (reactions, labels,
  comments, milestones, cross-references).

### Analysis
- `analyze_weights.py` — Round 1: OLS, logistic regression, descriptive stats.
- `analyze_weights_v2.py` — Round 2: event-gap analysis, continuous features.
- `analyze_weights_v3.py` — Round 3: Build Analysis CI, inferred maintainers, synthesis.
- `analyze_critical.py` — Critical methodology review: 6 critiques, bootstrap stability,
  learning curves, non-linear models (RF, GB).
- `analyze_discussion.py` — Discussion signal decomposition, death spiral analysis,
  alternative metrics comparison.
- `analyze_dual_score.py` — Dual-score analysis (merge readiness vs. deserves attention)
  with linked issue data.

### Data

Collected data files (~1.9MB total, ~30 min to regenerate) are stored locally
rather than checked in. By default, scripts read/write to a `data/` subdirectory
alongside the scripts. Override with the `WEIGHTINGS_DATA_DIR` environment variable:

```bash
# Use default (scripts/weightings/data/)
python collect_pr_data.py

# Or point to a custom location
export WEIGHTINGS_DATA_DIR=/path/to/data
python collect_pr_data.py
```

Files:
- `merged_pr_features.json` — 980 PR feature vectors (the core dataset).
- `inferred_maintainers.json` — Per-repo maintainer sets from mergedBy history.
- `linked_issues.json` — Linked issue metadata for all 980 PRs.

## Reproducing

```bash
# Prerequisites: gh CLI authenticated, Python 3.10+ with pandas, scikit-learn, statsmodels
pip install pandas scikit-learn statsmodels

# Collect data (takes ~30 min due to API rate limits)
python collect_pr_data.py
python fetch_maintainers.py
python fetch_linked_issues.py

# Run analyses
python analyze_weights_v3.py    # Main regression analysis
python analyze_critical.py      # Methodology critique
python analyze_discussion.py    # Discussion decomposition
python analyze_dual_score.py    # Dual-score with issue data
```

## Next Steps

### Near-term (apply findings to dashboard)

1. **Update weights in `Get-PrTriageData.ps1`** — apply the recommended single-score
   weight changes (the table above). Lowest-risk, highest-impact change.

2. **Split discussionScore into feedback + engagement** — separate unresolved threads
   (actionable, author can fix) from distinct commenters (complexity signal, cap at
   0.5 minimum to avoid death spiral).

3. **Show sub-scores in reports** — expose individual component scores (CI, approval,
   discussion, size, etc.) as columns or tooltips so maintainers can see *why* a PR
   ranks where it does and what's blocking it.

4. **Use Build Analysis specifically for CI** — already partially done; ensure repos
   without BA (extensions, msbuild, winforms, wpf) get a neutral CI score rather than
   misleading pass/fail from unrelated checks.

5. **Compute and display the attention score** — implement Score 2 alongside merge
   readiness. Show both in reports; default sort by multiplicative combination
   `(merge + 1) × (attention + 1)` with option to sort by either individually.

6. **Fetch linked issue metadata** — the dashboard's GraphQL query could include
   `closingIssuesReferences` to pull reactions, labels, and cross-references for
   the attention score. Adds minimal API cost.

7. **Track author response latency** — add `days_since_last_author_comment` as a
   signal, especially for community PRs with pending feedback. A community PR with
   8 unresolved comments and a response yesterday is healthy; the same PR with no
   response in 2 weeks is stalling. More actionable than `community × comments`
   as an interaction term, and avoids penalizing actively-worked community PRs.

### Longer-term (potential improvements to consider)

8. **Per-repo weight adjustments** — not full per-repo weight sets (overfitting risk
   with ~80 PRs each), but targeted overrides for the biggest differences:
   - Suppress CI score where Build Analysis is absent
   - Boost approval weight for roslyn/msbuild (approval-gated teams)
   - Boost community weight for runtime/machinelearning (3-5× speed gap)

9. **Periodic recalibration** — re-run analysis quarterly or after major team changes.
   The collection scripts are reusable; 30 minutes to regenerate data, instant analysis.

10. **Include abandoned/closed PRs** — current analysis only covers merged PRs (survivor
   bias). Analyzing closed-without-merge PRs would better capture how CI failures and
   conflicts actually block PRs, improving CI and conflict weight estimates.

11. **Time-series snapshots** — instead of one snapshot per PR at merge time, take
    periodic snapshots of open PRs to validate staleness/freshness/velocity weights
    (currently untestable, 3.0 of the 20.0 total weight budget).

12. **Sort mode toggle in UI** — let users switch between "ready to merge" (clear the
    queue), "needs attention" (triage), and "best ROI" (multiplicative) views.

13. **Weekend/day-of-week signal** — analysis shows Friday PRs take 2-3× longer.
    Could display expected merge timeline or adjust freshness scoring accordingly.
