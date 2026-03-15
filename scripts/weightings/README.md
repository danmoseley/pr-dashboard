# Weight Calibration Analysis

Empirical calibration of the ~12 PR readiness score weights using data from
980 recently merged PRs across 11 dotnet repos.

Full writeup: https://gist.github.com/danmoseley/ecfdccef799ade09f53ebfaa1ef9b46e

## Quick Results

### Recommended Single-Score Weight Changes

| Feature | Current | Recommended | Confidence |
|---------|---------|-------------|------------|
| ciScore | 3.0 | **2.5** | Moderate |
| conflictScore | 3.0 | **3.0** | N/A (untestable) |
| approvalScore | 2.0 | **2.5** | Moderate |
| maintScore | 3.0 | **1.5** | Lower |
| feedbackScore | 2.0 | **2.5** | High |
| discussionScore | 1.5 | **2.5** | Very High |
| sizeScore | 1.0 | **2.0** | High |
| communityScore | 0.5 | **1.0** | High |
| stalenessScore | 1.5 | **1.0** | Low |
| freshScore | 1.0 | **0.7** | Low |
| alignScore | 1.0 | **0.5** | Lower |
| velocityScore | 0.5 | **0.3** | Low |
| **TOTAL** | **20.0** | **20.0** | |

### Top Findings

1. **Discussion is massively underweighted** (1.5 should be ~2.5-4.5). Dominant
   predictor in every model, every repo, every outcome definition.

2. **CI is a gate, not a gradient**. Build Analysis pass is the last gate before
   merge 70% of the time (median 0.6h to merge after BA passes). But BA is absent
   in ~40% of repos.

3. **maintScore is redundant** with approvalScore (Lasso drops it; bootstrap CV=127%).

4. **Size matters more than expected** (significant in 6/11 repos).

5. **Raw discussion count creates a death spiral**. Recommend splitting into
   actionable feedback (unresolved threads) + engagement (distinct commenters, capped).

6. **Dual-score system may be more useful**: merge readiness vs. deserves-attention
   are anti-correlated (r=-0.63). PRs that need attention are typically NOT close
   to merging.

7. **Infer maintainers from mergedBy data** rather than a static list (community
   rate drops from 78% to 34%, signal becomes significant at p=0.002).

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

### Data (`data/`)
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
