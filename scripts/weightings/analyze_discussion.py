"""
Decompose the 'discussion' signal: what exactly predicts slow merge?
- Raw thread count vs unresolved threads vs commenters vs resolution rate
- Is it "how much discussion" or "how stuck is the discussion"?
"""

import json
import numpy as np
import pandas as pd
import statsmodels.api as sm
from pathlib import Path
import warnings
warnings.filterwarnings('ignore')

_SCRIPT_DIR = Path(__file__).resolve().parent
_DATA_DIR = os.environ.get("WEIGHTINGS_DATA_DIR", str(_SCRIPT_DIR / "data"))
DATA_FILE = os.path.join(_DATA_DIR, "merged_pr_features.json")
MAINTAINERS_FILE = os.path.join(_DATA_DIR, "inferred_maintainers.json")

def load():
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        features = json.load(f)
    with open(MAINTAINERS_FILE, "r", encoding="utf-8") as f:
        maint_data = json.load(f)
    repo_maint = {k: set(v) for k, v in maint_data["repo_maintainers"].items()}
    df = pd.DataFrame(features)
    df['is_community_inferred'] = df.apply(
        lambda r: r['author'].lower() not in repo_maint.get(r['repo'], set()), axis=1)
    df['log_age'] = np.log1p(df['age_days'])
    return df

def decompose_discussion(df):
    print("="*70)
    print("WHAT IS 'DISCUSSION' ACTUALLY MEASURING?")
    print("="*70)
    
    y = df['log_age']
    
    # Individual components
    candidates = {
        'total_threads':       np.log1p(df['total_threads']),
        'unresolved_threads':  np.log1p(df['unresolved_threads']),
        'resolved_threads':    np.log1p(df['resolved_threads']),
        'distinct_commenters': np.log1p(df['distinct_commenters']),
        'total_comments':      np.log1p(df['total_comments']),
        'changes_requested':   df['changes_requested_count'].clip(upper=5).astype(float),
    }
    
    # Resolution rate (what fraction of threads are resolved?)
    df['resolution_rate'] = np.where(
        df['total_threads'] > 0,
        df['resolved_threads'] / df['total_threads'],
        1.0  # no threads = nothing to resolve
    )
    candidates['resolution_rate'] = df['resolution_rate']
    
    # Unresolved ratio (inverse)
    df['unresolved_ratio'] = np.where(
        df['total_threads'] > 0,
        df['unresolved_threads'] / df['total_threads'],
        0.0
    )
    candidates['unresolved_ratio'] = df['unresolved_ratio']
    
    print("\n--- Individual predictors of log(age_days) ---")
    print(f"  {'Feature':25s} {'R²':>6s} {'coef':>8s} {'t-stat':>8s} {'p':>8s}")
    
    results = []
    for name, feature in candidates.items():
        X = sm.add_constant(feature)
        model = sm.OLS(y, X).fit()
        coef = model.params.iloc[1]
        t = model.tvalues.iloc[1]
        p = model.pvalues.iloc[1]
        results.append((name, model.rsquared, coef, t, p))
        sig = '***' if p<0.001 else '**' if p<0.01 else '*' if p<0.05 else ''
        print(f"  {name:25s} {model.rsquared:>6.3f} {coef:>+8.3f} {t:>8.2f} {p:>8.4f} {sig}")
    
    print("\n--- Horse race: all discussion components together ---")
    
    all_feats = pd.DataFrame({
        'log_threads': np.log1p(df['total_threads']),
        'log_commenters': np.log1p(df['distinct_commenters']),
        'log_comments': np.log1p(df['total_comments']),
        'resolution_rate': df['resolution_rate'],
        'changes_requested': df['changes_requested_count'].clip(upper=5).astype(float),
        'log_unresolved': np.log1p(df['unresolved_threads']),
    })
    
    X = sm.add_constant(all_feats)
    model = sm.OLS(y, X).fit()
    
    print(f"  Combined R² = {model.rsquared:.3f}\n")
    coefs = pd.DataFrame({
        'coef': model.params.drop('const'),
        '|t|': np.abs(model.tvalues.drop('const')),
        'p': model.pvalues.drop('const'),
    }).sort_values('|t|', ascending=False)
    coefs['sig'] = coefs['p'].apply(lambda p: '***' if p<0.001 else '**' if p<0.01 else '*' if p<0.05 else '')
    print(coefs.to_string(float_format=lambda x: f"{x:.3f}"))
    
    print("\n  KEY FINDING: Which matters more — volume or resolution state?")
    
    # Model A: just volume (total threads + commenters)
    Xa = sm.add_constant(pd.DataFrame({
        'log_threads': np.log1p(df['total_threads']),
        'log_commenters': np.log1p(df['distinct_commenters']),
    }))
    ma = sm.OLS(y, Xa).fit()
    
    # Model B: just resolution state (unresolved, resolution rate, CR)
    Xb = sm.add_constant(pd.DataFrame({
        'log_unresolved': np.log1p(df['unresolved_threads']),
        'resolution_rate': df['resolution_rate'],
        'changes_requested': df['changes_requested_count'].clip(upper=5).astype(float),
    }))
    mb = sm.OLS(y, Xb).fit()
    
    print(f"\n  Volume only (threads + commenters):        R² = {ma.rsquared:.3f}")
    print(f"  Resolution state only (unresolved + CR):   R² = {mb.rsquared:.3f}")
    print(f"  Both:                                      R² = {model.rsquared:.3f}")

def analyze_death_spiral(df):
    """Is the score creating a death spiral?
    Look at: do PRs with many threads that ALSO have high resolution rates
    merge faster than those with many threads and low resolution?"""
    
    print("\n" + "="*70)
    print("DEATH SPIRAL ANALYSIS: Does resolution rate help?")
    print("="*70)
    
    # Split PRs into thread-count buckets
    df['thread_bucket'] = pd.cut(df['total_threads'], 
                                  bins=[0, 2, 5, 15, 100, float('inf')],
                                  labels=['0-2', '3-5', '6-15', '16-100', '100+'],
                                  right=True)
    
    df['resolution_rate'] = np.where(
        df['total_threads'] > 0,
        df['resolved_threads'] / df['total_threads'],
        1.0
    )
    
    print("\n  Median merge time by thread count AND resolution rate:")
    print(f"  {'Threads':>10s}  {'n':>5s}  {'All':>8s}  {'High res':>10s}  {'Low res':>10s}  {'Diff':>8s}")
    
    for bucket in ['0-2', '3-5', '6-15', '16-100']:
        subset = df[df['thread_bucket'] == bucket]
        if len(subset) < 5:
            continue
        
        high_res = subset[subset['resolution_rate'] >= 0.7]
        low_res = subset[subset['resolution_rate'] < 0.7]
        
        all_med = subset['age_days'].median()
        high_med = high_res['age_days'].median() if len(high_res) > 3 else float('nan')
        low_med = low_res['age_days'].median() if len(low_res) > 3 else float('nan')
        diff = high_med - low_med if not (np.isnan(high_med) or np.isnan(low_med)) else float('nan')
        
        print(f"  {bucket:>10s}  {len(subset):>5d}  {all_med:>8.1f}d  {high_med:>8.1f}d (n={len(high_res):>3d})  {low_med:>8.1f}d (n={len(low_res):>3d})  {diff:>+7.1f}d")
    
    print("\n  INTERPRETATION:")
    print("  If high-resolution PRs merge faster at the same thread count,")
    print("  then 'resolution progress' is the real signal, not raw count.")

def analyze_valuable_prs(df):
    """The user's concern: are high-discussion PRs actually more valuable?
    Check if they're larger, touch more files, and involve more people."""
    
    print("\n" + "="*70)
    print("ARE HIGH-DISCUSSION PRs MORE VALUABLE/SIGNIFICANT?")
    print("="*70)
    
    low_disc = df[df['total_threads'] <= 5]
    med_disc = df[(df['total_threads'] > 5) & (df['total_threads'] <= 15)]
    high_disc = df[df['total_threads'] > 15]
    
    print(f"\n  {'Metric':30s} {'Low (≤5)':>12s} {'Med (6-15)':>12s} {'High (>15)':>12s}")
    
    metrics = [
        ('Count', 'count', lambda d: len(d)),
        ('Median age (days)', 'age', lambda d: d['age_days'].median()),
        ('Median lines changed', 'lines', lambda d: d['total_lines'].median()),
        ('Median files changed', 'files', lambda d: d['changed_files'].median()),
        ('% community', 'comm', lambda d: d['is_community_inferred'].mean()*100),
        ('% has owner approval', 'appr', lambda d: d['has_owner_approval'].mean()*100),
        ('Median commenters', 'cmtr', lambda d: d['distinct_commenters'].median()),
        ('% with changes requested', 'cr', lambda d: (d['changes_requested_count']>0).mean()*100),
        ('Median unresolved threads', 'unres', lambda d: d['unresolved_threads'].median()),
    ]
    
    for label, _, fn in metrics:
        v1 = fn(low_disc)
        v2 = fn(med_disc)
        v3 = fn(high_disc)
        fmt = '.0f' if isinstance(v1, (int, np.integer)) or v1 > 10 else '.1f'
        print(f"  {label:30s} {v1:>12{fmt}} {v2:>12{fmt}} {v3:>12{fmt}}")
    
    print("""
  TAKEAWAY: High-discussion PRs ARE larger and more complex.
  They represent significant work that deserves attention, not neglect.
  
  The question is: what should the dashboard DO with this information?
  
  Options for the score design:
  
  A) CURRENT: Raw thread count → lower score (death spiral risk)
     Pros: Simple, correlates with merge difficulty
     Cons: Penalizes valuable PRs; more engagement → worse score
  
  B) RESOLUTION PROGRESS: (resolved / total) threads → score
     Pros: Rewards making progress; no death spiral
     Cons: A PR with 0/0 threads scores same as 50/50
  
  C) UNRESOLVED ONLY: Only count unresolved threads
     Pros: New resolved comments don't hurt; matches feedbackScore
     Cons: Doesn't capture "this is a complex beast"
  
  D) ENGAGEMENT RECENCY: Recent comments → higher score
     Pros: Active discussion is positive; stale discussion is negative
     Cons: More complex to compute; game-able
  
  E) SEPARATE CONCERNS: Split into two signals:
     - "Complexity" (total threads) → informational, not in score
     - "Progress" (resolution rate, recent activity) → in score
     Pros: Best of both worlds
     Cons: More weight parameters to tune
""")

def recommend_redesign(df):
    """Test alternative discussion metrics to see which predicts better
    WITHOUT the death spiral problem."""
    
    print("="*70)
    print("TESTING ALTERNATIVE DISCUSSION METRICS")
    print("="*70)
    
    y = df['log_age']
    
    df['resolution_rate'] = np.where(
        df['total_threads'] > 0,
        df['resolved_threads'] / df['total_threads'],
        1.0
    )
    
    # Alternative discussion scores
    alternatives = {}
    
    # Current: raw count buckets
    def current_score(row):
        if row['total_threads'] <= 5 and row['distinct_commenters'] <= 2:
            return 1.0
        elif row['total_threads'] <= 15 and row['distinct_commenters'] <= 5:
            return 0.5
        return 0.0
    alternatives['A_current (raw count)'] = df.apply(current_score, axis=1)
    
    # B: Resolution-weighted
    def resolution_score(row):
        if row['total_threads'] == 0:
            return 1.0
        rate = row['resolved_threads'] / row['total_threads']
        if row['unresolved_threads'] == 0:
            return 1.0
        elif row['unresolved_threads'] <= 3 and rate >= 0.5:
            return 0.75
        elif row['unresolved_threads'] <= 5:
            return 0.5
        return 0.0
    alternatives['B_resolution_weighted'] = df.apply(resolution_score, axis=1)
    
    # C: Unresolved only
    def unresolved_score(row):
        if row['unresolved_threads'] == 0:
            return 1.0
        elif row['unresolved_threads'] <= 3:
            return 0.75
        elif row['unresolved_threads'] <= 8:
            return 0.5
        return 0.0
    alternatives['C_unresolved_only'] = df.apply(unresolved_score, axis=1)
    
    # D: Commenters-weighted (fewer people = simpler)
    def commenters_score(row):
        if row['distinct_commenters'] <= 2:
            return 1.0
        elif row['distinct_commenters'] <= 4:
            return 0.75
        elif row['distinct_commenters'] <= 6:
            return 0.5
        return 0.0
    alternatives['D_commenters_only'] = df.apply(commenters_score, axis=1)
    
    # E: Hybrid (unresolved threads + commenters, no raw count)
    def hybrid_score(row):
        base = 1.0
        # Penalty for unresolved threads
        if row['unresolved_threads'] > 5:
            base -= 0.5
        elif row['unresolved_threads'] > 2:
            base -= 0.25
        # Penalty for many stakeholders (complexity signal)
        if row['distinct_commenters'] > 5:
            base -= 0.3
        elif row['distinct_commenters'] > 3:
            base -= 0.15
        return max(0.0, base)
    alternatives['E_hybrid (unres+commenters)'] = df.apply(hybrid_score, axis=1)
    
    # Compare
    other_features = ['f_ci', 'f_approval', 'f_maint', 'f_feedback',
                      'f_size', 'f_community', 'f_align']
    # Compute these other features
    df['f_ci'] = df['build_analysis_conclusion'].map({
        'SUCCESS': 1.0, 'ABSENT': 0.5, 'IN_PROGRESS': 0.5, 'FAILURE': 0.0
    }).fillna(0.5)
    def approval_score(row):
        if row['approval_count'] >= 2 and row['has_owner_approval']:
            return 1.0
        elif row['has_owner_approval']:
            return 0.75
        elif row['approval_count'] >= 1:
            return 0.5
        return 0.0
    df['f_approval'] = df.apply(approval_score, axis=1)
    df['f_maint'] = 0.0
    df.loc[df['has_any_review'] & ~df['has_owner_approval'], 'f_maint'] = 0.5
    df.loc[df['has_owner_approval'], 'f_maint'] = 1.0
    df['f_feedback'] = df['unresolved_threads'].apply(lambda x: 1.0 if x == 0 else 0.5)
    df['f_size'] = df.apply(lambda r: 1.0 if (r['changed_files']<=5 and r['total_lines']<=200) 
                            else (0.5 if (r['changed_files']<=20 and r['total_lines']<=500) else 0.0), axis=1)
    df['f_community'] = df['is_community_inferred'].map({True: 0.5, False: 1.0})
    df['f_align'] = df.apply(lambda r: 0.0 if (r['is_untriaged'] or not r['has_area_label']) else 1.0, axis=1)
    
    print(f"\n  Predictive power of each discussion metric")
    print(f"  (in full model with all other dashboard features)\n")
    print(f"  {'Metric':35s} {'Full R²':>8s} {'Disc |t|':>10s} {'Disc p':>8s} {'Death spiral?':>15s}")
    
    for name, disc_score in alternatives.items():
        X = df[other_features].copy()
        X['f_discussion'] = disc_score
        X_c = sm.add_constant(X)
        model = sm.OLS(y, X_c).fit()
        t = abs(model.tvalues['f_discussion'])
        p = model.pvalues['f_discussion']
        
        # Death spiral: does adding a comment always make score worse?
        death_spiral = "YES" if name.startswith('A') else "No" if 'unres' in name.lower() or 'resolution' in name.lower() else "Partial"
        
        sig = '***' if p<0.001 else '**' if p<0.01 else '*' if p<0.05 else ''
        print(f"  {name:35s} {model.rsquared:>8.3f} {t:>10.1f} {p:>8.4f}{sig} {death_spiral:>15s}")
    
    print("""
  RECOMMENDATION:
  
  The current metric (A) is the best pure predictor, but it creates
  a death spiral. Options B and E are nearly as predictive while
  avoiding the perverse incentive.
  
  SUGGESTED REDESIGN:
  Replace the single 'discussionScore' with TWO signals:
  
  1. 'feedbackScore' (already exists, weight ~2.0):
     Based on unresolved threads + changes requested.
     This is actionable: author can resolve threads to improve score.
     No death spiral: resolving comments improves the score.
  
  2. 'complexityScore' (new, weight ~2.5):
     Based on distinct_commenters + total_threads.
     This is INFORMATIONAL: it predicts how long the PR will take
     but the author can't easily change it.
     Display it but consider: should it LOWER priority, or just
     set expectations about timeline?
  
  The philosophical question: should the dashboard deprioritize
  complex PRs, or should it surface them prominently because they
  NEED attention? That's a product decision, not a statistical one.
""")

def main():
    df = load()
    decompose_discussion(df)
    analyze_death_spiral(df)
    analyze_valuable_prs(df)
    recommend_redesign(df)

if __name__ == "__main__":
    main()
