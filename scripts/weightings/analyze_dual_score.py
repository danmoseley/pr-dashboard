"""
Dual-score analysis with linked issue data.
Score 1: Closeness to Merge (PR mechanical state)
Score 2: Deserves Attention (impact + urgency + effort-at-risk)
"""

import json
import os
import numpy as np
import pandas as pd
import statsmodels.api as sm
from pathlib import Path
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import cross_val_score
import warnings
warnings.filterwarnings('ignore')

_SCRIPT_DIR = Path(__file__).resolve().parent
_DATA_DIR = os.environ.get("WEIGHTINGS_DATA_DIR", str(_SCRIPT_DIR / "data"))
DATA_FILE = os.path.join(_DATA_DIR, "merged_pr_features.json")
MAINTAINERS_FILE = os.path.join(_DATA_DIR, "inferred_maintainers.json")
ISSUES_FILE = os.path.join(_DATA_DIR, "linked_issues.json")

def load():
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        features = json.load(f)
    with open(MAINTAINERS_FILE, "r", encoding="utf-8") as f:
        maint_data = json.load(f)
    with open(ISSUES_FILE, "r", encoding="utf-8") as f:
        issues_data = json.load(f)
    
    repo_maint = {k: set(v) for k, v in maint_data["repo_maintainers"].items()}
    df = pd.DataFrame(features)
    df['is_community_inferred'] = df.apply(
        lambda r: r['author'].lower() not in repo_maint.get(r['repo'], set()), axis=1)
    df['log_age'] = np.log1p(df['age_days'])
    
    # Dashboard sub-scores
    df['f_ci'] = df['build_analysis_conclusion'].map({
        'SUCCESS': 1.0, 'ABSENT': 0.5, 'IN_PROGRESS': 0.5, 'FAILURE': 0.0
    }).fillna(0.5)
    
    df['f_approval'] = df.apply(lambda r:
        1.0 if (r['approval_count'] >= 2 and r['has_owner_approval']) else
        0.75 if r['has_owner_approval'] else
        0.5 if r['approval_count'] >= 1 else 0.0, axis=1)
    
    df['f_maint'] = 0.0
    df.loc[df['has_any_review'] & ~df['has_owner_approval'], 'f_maint'] = 0.5
    df.loc[df['has_owner_approval'], 'f_maint'] = 1.0
    
    df['f_feedback'] = df['unresolved_threads'].apply(lambda x: 1.0 if x == 0 else 0.5)
    df['f_size'] = df.apply(lambda r: 1.0 if (r['changed_files']<=5 and r['total_lines']<=200)
                            else (0.5 if (r['changed_files']<=20 and r['total_lines']<=500) else 0.0), axis=1)
    df['f_community'] = df['is_community_inferred'].map({True: 0.5, False: 1.0})
    df['f_align'] = df.apply(lambda r: 0.0 if (r['is_untriaged'] or not r['has_area_label']) else 1.0, axis=1)
    df['f_discussion'] = df.apply(lambda r:
        1.0 if (r['total_threads'] <= 5 and r['distinct_commenters'] <= 2) else
        0.5 if (r['total_threads'] <= 15 and r['distinct_commenters'] <= 5) else 0.0, axis=1)
    
    # Merge linked issue data
    regression_labels = {"regression-from-last-release", "regression",
                         "regression-from-previous-release", "Regression"}
    security_labels = {"security", "Security", "area-Security"}
    bug_labels = {"bug", "Bug"}
    
    issue_features = []
    for _, row in df.iterrows():
        key = f"{row['repo']}#{row['number']}"
        idata = issues_data.get(key, {})
        
        issues = idata.get("issues", [])
        pr_labels = set(idata.get("pr_labels", []))
        all_labels = set(pr_labels)
        for issue in issues:
            all_labels.update(issue.get("labels", []))
        
        total_issue_reactions = sum(i.get("reaction_count", 0) for i in issues)
        total_issue_thumbsup = sum(i.get("thumbs_up", 0) for i in issues)
        total_issue_comments = sum(i.get("comment_count", 0) for i in issues)
        max_issue_reactions = max((i.get("reaction_count", 0) for i in issues), default=0)
        max_issue_thumbsup = max((i.get("thumbs_up", 0) for i in issues), default=0)
        total_cross_refs = sum(i.get("cross_ref_count", 0) for i in issues)
        
        has_regression = bool(all_labels & regression_labels)
        has_security = bool(all_labels & security_labels)
        has_bug = bool(all_labels & bug_labels)
        has_milestone = idata.get("has_milestone", False)
        has_linked_issue = len(issues) > 0
        
        issue_features.append({
            'has_linked_issue': has_linked_issue,
            'linked_issue_count': len(issues),
            'total_issue_reactions': total_issue_reactions,
            'total_issue_thumbsup': total_issue_thumbsup,
            'max_issue_reactions': max_issue_reactions,
            'max_issue_thumbsup': max_issue_thumbsup,
            'total_issue_comments': total_issue_comments,
            'total_cross_refs': total_cross_refs,
            'is_regression': has_regression,
            'is_security': has_security,
            'is_bug': has_bug,
            'has_milestone': has_milestone,
        })
    
    issue_df = pd.DataFrame(issue_features)
    df = pd.concat([df.reset_index(drop=True), issue_df], axis=1)
    
    return df

def descriptive_stats(df):
    print("="*70)
    print("LINKED ISSUE DATA OVERVIEW")
    print("="*70)
    
    print(f"\n  Total PRs: {len(df)}")
    print(f"  PRs with linked issues: {df['has_linked_issue'].sum()} ({df['has_linked_issue'].mean()*100:.0f}%)")
    print(f"  PRs with milestones: {df['has_milestone'].sum()} ({df['has_milestone'].mean()*100:.0f}%)")
    print(f"  Regression-labeled: {df['is_regression'].sum()}")
    print(f"  Security-labeled: {df['is_security'].sum()}")
    print(f"  Bug-labeled: {df['is_bug'].sum()} ({df['is_bug'].mean()*100:.0f}%)")
    
    has_issues = df[df['has_linked_issue']]
    if len(has_issues) > 0:
        print(f"\n  Among PRs WITH linked issues (n={len(has_issues)}):")
        print(f"    Mean issue reactions: {has_issues['total_issue_reactions'].mean():.1f}")
        print(f"    Mean issue thumbsup: {has_issues['total_issue_thumbsup'].mean():.1f}")
        print(f"    Mean issue comments: {has_issues['total_issue_comments'].mean():.1f}")
        print(f"    Mean cross-references: {has_issues['total_cross_refs'].mean():.1f}")
        print(f"    Max reactions on any linked issue: {has_issues['max_issue_reactions'].max()}")
    
    print(f"\n  Linked issue rate by repo:")
    for repo in sorted(df['repo'].unique()):
        rdf = df[df['repo'] == repo]
        rate = rdf['has_linked_issue'].mean() * 100
        bug_rate = rdf['is_bug'].mean() * 100
        ms_rate = rdf['has_milestone'].mean() * 100
        print(f"    {repo}: issues={rate:.0f}%, bugs={bug_rate:.0f}%, milestones={ms_rate:.0f}%")

def test_issue_features_merge(df):
    """Do linked issue features predict merge speed?"""
    
    print("\n" + "="*70)
    print("DO ISSUE FEATURES PREDICT MERGE SPEED?")
    print("="*70)
    
    y = df['log_age']
    
    candidates = {
        'has_linked_issue': df['has_linked_issue'].astype(float),
        'log_issue_reactions': np.log1p(df['total_issue_reactions']),
        'log_issue_thumbsup': np.log1p(df['total_issue_thumbsup']),
        'log_issue_comments': np.log1p(df['total_issue_comments']),
        'is_bug': df['is_bug'].astype(float),
        'has_milestone': df['has_milestone'].astype(float),
        'log_cross_refs': np.log1p(df['total_cross_refs']),
    }
    
    print(f"\n  {'Feature':25s} {'R²':>6s} {'coef':>8s} {'t':>8s} {'p':>8s}")
    for name, feat in candidates.items():
        X = sm.add_constant(feat)
        m = sm.OLS(y, X).fit()
        sig = '***' if m.pvalues.iloc[1]<0.001 else '**' if m.pvalues.iloc[1]<0.01 else '*' if m.pvalues.iloc[1]<0.05 else ''
        print(f"  {name:25s} {m.rsquared:>6.3f} {m.params.iloc[1]:>+8.3f} {m.tvalues.iloc[1]:>8.2f} {m.pvalues.iloc[1]:>8.4f} {sig}")
    
    print(f"\n  Do issue features add predictive power BEYOND dashboard sub-scores?")
    
    dash_features = ['f_ci', 'f_approval', 'f_maint', 'f_feedback',
                     'f_size', 'f_community', 'f_align', 'f_discussion']
    
    X_base = sm.add_constant(df[dash_features])
    m_base = sm.OLS(y, X_base).fit()
    
    df['log_issue_reactions_f'] = np.log1p(df['total_issue_reactions'].astype(float))
    df['has_linked_issue_f'] = df['has_linked_issue'].astype(float)
    df['is_bug_f'] = df['is_bug'].astype(float)
    df['has_milestone_f'] = df['has_milestone'].astype(float)
    issue_cols = ['has_linked_issue_f', 'log_issue_reactions_f', 'is_bug_f', 'has_milestone_f']
    
    X_full = sm.add_constant(df[dash_features + issue_cols])
    m_full = sm.OLS(y, X_full).fit()
    
    print(f"  Dashboard only:              R² = {m_base.rsquared:.3f}")
    print(f"  Dashboard + issue features:  R² = {m_full.rsquared:.3f}")
    print(f"  Incremental R²:              {m_full.rsquared - m_base.rsquared:.3f}")
    
    print(f"\n  Issue feature coefficients in combined model:")
    for f in issue_cols:
        if f in m_full.params:
            sig = '***' if m_full.pvalues[f]<0.001 else '**' if m_full.pvalues[f]<0.01 else '*' if m_full.pvalues[f]<0.05 else ''
            print(f"    {f:25s}: coef={m_full.params[f]:+.3f}, t={m_full.tvalues[f]:.2f}, p={m_full.pvalues[f]:.4f} {sig}")

def analyze_dual_scores(df):
    """Build and compare the two scores."""
    
    print("\n" + "="*70)
    print("DUAL SCORE ANALYSIS")
    print("="*70)
    
    # SCORE 1: CLOSENESS TO MERGE
    def merge_readiness(row):
        s = 0
        s += row['f_ci'] * 2.5
        s += row['f_approval'] * 2.5
        s += row['f_maint'] * 1.5
        s += row['f_feedback'] * 2.5
        s += row['f_size'] * 2.0
        s += row['f_community'] * 1.0
        s += row['f_discussion'] * 2.5
        s += row['f_align'] * 0.5
        return round(s / 15.0 * 10, 1)
    
    df['score_merge'] = df.apply(merge_readiness, axis=1)
    
    # SCORE 2: DESERVES ATTENTION
    def attention_score(row):
        s = 0
        # Urgency
        if row['is_regression']: s += 4.0
        if row['is_security']: s += 4.0
        if row['is_bug']: s += 1.0
        if row['has_milestone']: s += 1.0
        # Community demand
        if row['total_issue_thumbsup'] >= 10: s += 2.0
        elif row['total_issue_thumbsup'] >= 3: s += 1.0
        elif row['total_issue_reactions'] >= 5: s += 0.5
        if row['total_issue_comments'] >= 20: s += 1.5
        elif row['total_issue_comments'] >= 5: s += 0.5
        if row['total_cross_refs'] >= 3: s += 1.0
        elif row['total_cross_refs'] >= 1: s += 0.5
        # Effort at risk
        if row['is_community_inferred']: s += 2.0
        if row['has_any_review'] and row['f_approval'] < 0.75: s += 1.0
        if row['total_lines'] > 200: s += 0.5
        # Blockers
        if row['f_ci'] == 0: s += 1.0
        if row['unresolved_threads'] > 0: s += 1.0
        elif row['changes_requested_count'] > 0: s += 0.5
        if row['f_approval'] == 0: s += 1.5
        return round(min(s, 10.0), 1)
    
    df['score_attention'] = df.apply(attention_score, axis=1)
    
    corr = df['score_merge'].corr(df['score_attention'])
    print(f"\n  Correlation between scores: {corr:.3f}")
    print(f"  ({'They surface different PRs' if corr < 0 else 'Some overlap expected'})")
    
    # Quadrant analysis
    merge_med = df['score_merge'].median()
    attn_med = df['score_attention'].median()
    
    q1 = df[(df['score_merge'] >= merge_med) & (df['score_attention'] >= attn_med)]
    q2 = df[(df['score_merge'] < merge_med) & (df['score_attention'] >= attn_med)]
    q3 = df[(df['score_merge'] >= merge_med) & (df['score_attention'] < attn_med)]
    q4 = df[(df['score_merge'] < merge_med) & (df['score_attention'] < attn_med)]
    
    print(f"""
  QUADRANT ANALYSIS (split at median of each score):
  
  ┌──────────────────────────────┬──────────────────────────────┐
  │ Q1: HIGH merge + HIGH attn   │ Q2: LOW merge + HIGH attn    │
  │ "Help across finish line"    │ "Invest review time"         │
  │ n={len(q1):>4d}                      │ n={len(q2):>4d}                      │
  │ median age: {q1['age_days'].median():>6.1f}d          │ median age: {q2['age_days'].median():>6.1f}d          │
  │ community: {q1['is_community_inferred'].mean()*100:>5.0f}%           │ community: {q2['is_community_inferred'].mean()*100:>5.0f}%           │
  │ median lines: {q1['total_lines'].median():>6.0f}        │ median lines: {q2['total_lines'].median():>6.0f}        │
  │ has_linked_issue: {q1['has_linked_issue'].mean()*100:>3.0f}%       │ has_linked_issue: {q2['has_linked_issue'].mean()*100:>3.0f}%       │
  │ has_milestone: {q1['has_milestone'].mean()*100:>3.0f}%           │ has_milestone: {q2['has_milestone'].mean()*100:>3.0f}%           │
  │ is_bug: {q1['is_bug'].mean()*100:>3.0f}%                 │ is_bug: {q2['is_bug'].mean()*100:>3.0f}%                 │
  ├──────────────────────────────┼──────────────────────────────┤
  │ Q3: HIGH merge + LOW attn    │ Q4: LOW merge + LOW attn     │
  │ "Will merge on its own"      │ "Deprioritize / close"       │
  │ n={len(q3):>4d}                      │ n={len(q4):>4d}                      │
  │ median age: {q3['age_days'].median():>6.1f}d          │ median age: {q4['age_days'].median():>6.1f}d          │
  │ community: {q3['is_community_inferred'].mean()*100:>5.0f}%           │ community: {q4['is_community_inferred'].mean()*100:>5.0f}%           │
  │ median lines: {q3['total_lines'].median():>6.0f}        │ median lines: {q4['total_lines'].median():>6.0f}        │
  │ has_linked_issue: {q3['has_linked_issue'].mean()*100:>3.0f}%       │ has_linked_issue: {q4['has_linked_issue'].mean()*100:>3.0f}%       │
  │ has_milestone: {q3['has_milestone'].mean()*100:>3.0f}%           │ has_milestone: {q4['has_milestone'].mean()*100:>3.0f}%           │
  │ is_bug: {q3['is_bug'].mean()*100:>3.0f}%                 │ is_bug: {q4['is_bug'].mean()*100:>3.0f}%                 │
  └──────────────────────────────┴──────────────────────────────┘

  Q1 = Priority: close to merge AND needs help -> review/merge now
  Q2 = Investment: far from merge but deserving -> schedule review time
  Q3 = Autopilot: close to merge, self-service -> let it flow
  Q4 = Triage: far from merge, low priority -> close or deprioritize
""")
    
    # Feature direction comparison
    print("  FEATURE DIRECTION IN EACH SCORE:")
    print(f"  {'Feature':22s} {'Merge Score':>14s} {'Attention Score':>16s} {'Tension':>10s}")
    print("  " + "-"*65)
    
    comparisons = [
        ("CI passing",         "HIGH readiness",    "failing=needs help",  "Opposite"),
        ("Has approval",       "HIGH readiness",    "missing=needs review","Opposite"),
        ("Maintainer review",  "HIGH readiness",    "moderate signal",     "Weak"),
        ("Unresolved threads", "LOW readiness",     "needs response",      "Aligned"),
        ("Small size",         "HIGH readiness",    "large=significant",   "CONFLICT"),
        ("Internal author",    "HIGH readiness",    "community=waiting",   "CONFLICT"),
        ("Few commenters",     "HIGH readiness",    "many=important",      "CONFLICT"),
        ("Area labeled",       "HIGH readiness",    "triaged=good",        "Aligned"),
        ("Issue reactions",    "(not in score)",    "HIGH=community need", "Attn only"),
        ("Bug/regression",     "(not in score)",    "HIGH urgency",        "Attn only"),
        ("Milestone",          "(not in score)",    "has deadline",        "Attn only"),
        ("Cross-references",   "(not in score)",    "broad impact",        "Attn only"),
    ]
    
    for feat, merge, attn, tension in comparisons:
        print(f"  {feat:22s} {merge:>14s} {attn:>16s} {tension:>10s}")
    
    print(f"""
  PROPOSED ATTENTION SCORE COMPONENTS:
  
  URGENCY (0-4 pts):     regression +4, security +4, bug +1, milestone +1
  COMMUNITY DEMAND (0-3): issue thumbsup, comments, cross-references
  EFFORT-AT-RISK (0-3):  community author +2, has reviews but no approval +1,
                         significant change +0.5
  BLOCKED (0-2):         CI failing +1, unresolved feedback +1, no approval +1.5
  
  Key differences from merge score:
  - Community PRs score HIGHER (they're waiting on us)
  - Large/complex PRs score HIGHER (significant work at stake)
  - Issue engagement is a NEW signal (not in merge score)
  - CI failing scores HIGHER (needs help, not just "not ready")
  - No penalty for many commenters (avoids death spiral)
""")

def main():
    df = load()
    descriptive_stats(df)
    test_issue_features_merge(df)
    analyze_dual_scores(df)

if __name__ == "__main__":
    main()
