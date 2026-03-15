"""
Round 3: Refined analysis with:
1. Inferred per-repo maintainers (from mergedBy data)
2. Build Analysis as the CI signal (not overall check status)
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

def load_data():
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        features = json.load(f)
    with open(MAINTAINERS_FILE, "r", encoding="utf-8") as f:
        maint_data = json.load(f)
    
    repo_maintainers = {k: set(v) for k, v in maint_data["repo_maintainers"].items()}
    
    df = pd.DataFrame(features)
    print(f"Loaded {len(df)} PRs from {df['repo'].nunique()} repos")
    
    # Re-derive is_community using inferred maintainers
    def is_community(row):
        maintainers = repo_maintainers.get(row['repo'], set())
        return row['author'].lower() not in maintainers
    
    df['is_community_inferred'] = df.apply(is_community, axis=1)
    
    # Use Build Analysis as a separate CI signal (BA-only, no fallback).
    # Note: the dashboard falls back to overall check results when BA is absent.
    # The dataset's ci_status field has that fallback; build_analysis_conclusion does not.
    # Here we isolate BA to test its specific predictive power.
    df['ba_passed'] = (df['build_analysis_conclusion'] == 'SUCCESS').astype(float)
    df['ba_failed'] = (df['build_analysis_conclusion'] == 'FAILURE').astype(float)
    df['ba_absent'] = (df['build_analysis_conclusion'] == 'ABSENT').astype(float)
    df['ba_pending'] = (df['build_analysis_conclusion'] == 'IN_PROGRESS').astype(float)
    
    # Dashboard-style BA score
    df['f_ba'] = df['build_analysis_conclusion'].map({
        'SUCCESS': 1.0, 'ABSENT': 0.5, 'IN_PROGRESS': 0.5, 'FAILURE': 0.0
    }).fillna(0.5)
    
    print(f"\nBuild Analysis distribution:")
    print(df['build_analysis_conclusion'].value_counts().to_string())
    print(f"\nCommunity (inferred): {df['is_community_inferred'].sum()} "
          f"({df['is_community_inferred'].mean()*100:.0f}%)")
    print(f"Community (old list): {df['is_community'].sum()} "
          f"({df['is_community'].mean()*100:.0f}%)")
    
    return df, repo_maintainers

def compute_features(df):
    """Compute all features for regression."""
    
    # Dashboard sub-scores (using Build Analysis for CI)
    df['f_ci'] = df['f_ba']  # Use Build Analysis instead of overall CI
    
    def approval_score(row):
        if row['approval_count'] >= 2 and row['has_owner_approval']:
            return 1.0
        elif row['has_owner_approval']:
            return 0.75
        elif row['approval_count'] >= 2:
            return 0.5
        elif row['approval_count'] >= 1:
            return 0.5
        return 0.0
    df['f_approval'] = df.apply(approval_score, axis=1)
    if 'has_stale_approval' in df.columns:
        mask = df['has_stale_approval'] & (df['f_approval'] > 0)
        df.loc[mask, 'f_approval'] = (df.loc[mask, 'f_approval'] - 0.25).clip(lower=0)
    
    df['f_maint'] = df['has_owner_approval'].map({True: 1.0, False: 0.0}).where(
        df['has_any_review'], other=0.0)
    df.loc[df['has_any_review'] & ~df['has_owner_approval'], 'f_maint'] = 0.5
    
    def feedback_score(row):
        if row['unresolved_threads'] == 0:
            return 1.0
        return 0.5
    df['f_feedback'] = df.apply(feedback_score, axis=1)
    
    def size_score(row):
        if row['changed_files'] <= 5 and row['total_lines'] <= 200:
            return 1.0
        elif row['changed_files'] <= 20 and row['total_lines'] <= 500:
            return 0.5
        return 0.0
    df['f_size'] = df.apply(size_score, axis=1)
    
    df['f_community'] = df['is_community_inferred'].map({True: 0.5, False: 1.0})
    
    def align_score(row):
        if row['is_untriaged'] or not row['has_area_label']:
            return 0.0
        return 1.0
    df['f_align'] = df.apply(align_score, axis=1)
    
    def discussion_score(row):
        if row['total_threads'] <= 5 and row['distinct_commenters'] <= 2:
            return 1.0
        elif row['total_threads'] <= 15 and row['distinct_commenters'] <= 5:
            return 0.5
        return 0.0
    df['f_discussion'] = df.apply(discussion_score, axis=1)
    
    # Continuous features
    df['log_age'] = np.log1p(df['age_days'])
    df['log_lines'] = np.log1p(df['total_lines'])
    df['log_files'] = np.log1p(df['changed_files'])
    df['log_threads'] = np.log1p(df['total_threads'])
    df['log_comments'] = np.log1p(df['total_comments'])
    df['community_f'] = df['is_community_inferred'].astype(float)
    df['owner_approved_f'] = df['has_owner_approval'].astype(float)
    df['area_label_f'] = df['has_area_label'].astype(float)
    df['cr_count'] = df['changes_requested_count']
    
    return df

def run_full_analysis(df):
    """Run complete analysis with all three approaches."""
    
    # ============================================================
    # APPROACH 1: Dashboard sub-scores → log(age_days)
    # ============================================================
    print("\n" + "="*70)
    print("APPROACH 1: Dashboard Sub-Scores (with Build Analysis CI)")
    print("="*70)
    
    dash_features = ['f_ci', 'f_approval', 'f_maint', 'f_feedback',
                     'f_size', 'f_community', 'f_align', 'f_discussion']
    
    X = df[dash_features].copy()
    y = df['log_age']
    X_c = sm.add_constant(X)
    model1 = sm.OLS(y, X_c).fit()
    
    print(f"R² = {model1.rsquared:.3f}, Adj R² = {model1.rsquared_adj:.3f}")
    
    coefs1 = pd.DataFrame({
        'coef': model1.params.drop('const'),
        'p_value': model1.pvalues.drop('const'),
        '|t|': np.abs(model1.tvalues.drop('const')),
    }).sort_values('|t|', ascending=False)
    coefs1['sig'] = coefs1['p_value'].apply(lambda p: '***' if p<0.001 else '**' if p<0.01 else '*' if p<0.05 else '')
    print("\nCoefficients (negative = faster merge):")
    print(coefs1.to_string(float_format=lambda x: f"{x:.4f}"))
    
    # ============================================================
    # APPROACH 2: Continuous features (with BA + inferred community)
    # ============================================================
    print("\n" + "="*70)
    print("APPROACH 2: Continuous Features (Build Analysis + inferred maintainers)")
    print("="*70)
    
    cont_features = ['ba_passed', 'ba_failed', 'owner_approved_f',
                     'log_lines', 'log_files', 'log_threads', 'log_comments',
                     'community_f', 'area_label_f', 'cr_count',
                     'approval_count', 'unresolved_threads', 'distinct_commenters']
    
    X2 = df[cont_features].copy()
    y2 = df['log_age']
    X2_c = sm.add_constant(X2)
    model2 = sm.OLS(y2, X2_c).fit()
    
    print(f"R² = {model2.rsquared:.3f}, Adj R² = {model2.rsquared_adj:.3f}")
    
    # Standardized coefficients for relative importance
    scaler = StandardScaler()
    X2_std = pd.DataFrame(scaler.fit_transform(X2), columns=cont_features, index=X2.index)
    X2_std_c = sm.add_constant(X2_std)
    model2_std = sm.OLS(y2, X2_std_c).fit()
    
    std_coefs = pd.DataFrame({
        'raw_coef': model2.params.drop('const'),
        'std_coef': model2_std.params.drop('const'),
        '|std_coef|': np.abs(model2_std.params.drop('const')),
        'p_value': model2.pvalues.drop('const'),
    }).sort_values('|std_coef|', ascending=False)
    std_coefs['sig'] = std_coefs['p_value'].apply(lambda p: '***' if p<0.001 else '**' if p<0.01 else '*' if p<0.05 else '')
    
    print("\nStandardized coefficients (|std_coef| = relative importance):")
    print(std_coefs.to_string(float_format=lambda x: f"{x:.4f}"))
    
    # ============================================================
    # APPROACH 3: Logistic — merged within 7 days
    # ============================================================
    print("\n" + "="*70)
    print("APPROACH 3: Logistic Regression — Merged Within 7 Days")
    print("="*70)
    
    df['fast_merge'] = (df['age_days'] <= 7).astype(int)
    X3 = df[dash_features].copy()
    X3_scaled = StandardScaler().fit_transform(X3)
    
    logit = LogisticRegression(max_iter=1000, C=1.0)
    cv_scores = cross_val_score(logit, X3_scaled, df['fast_merge'], cv=5, scoring='accuracy')
    print(f"5-fold CV accuracy: {cv_scores.mean():.3f} ± {cv_scores.std():.3f}")
    
    logit.fit(X3_scaled, df['fast_merge'])
    logit_df = pd.DataFrame({
        'feature': dash_features,
        'coef': logit.coef_[0],
        '|coef|': np.abs(logit.coef_[0]),
    }).sort_values('|coef|', ascending=False)
    
    print("\nLogistic coefficients (positive = predicts fast merge):")
    print(logit_df.to_string(float_format=lambda x: f"{x:.4f}", index=False))
    
    # ============================================================
    # EVENT-GAP ANALYSIS
    # ============================================================
    print("\n" + "="*70)
    print("EVENT-GAP: Time from Build Analysis pass → merge")
    print("="*70)
    
    has_ci = df['ci_to_merge_days'].notna()
    ci_gaps = df.loc[has_ci, 'ci_to_merge_days']
    print(f"CI(BA) pass → merge (n={has_ci.sum()}):")
    print(f"  Median: {ci_gaps.median():.3f} days ({ci_gaps.median()*24:.1f}h)")
    print(f"  Within 1h: {(ci_gaps.abs() <= 1/24).sum()} ({(ci_gaps.abs() <= 1/24).mean()*100:.0f}%)")
    
    has_appr = df['approval_to_merge_days'].notna()
    appr_gaps = df.loc[has_appr, 'approval_to_merge_days']
    print(f"\nFirst approval → merge (n={has_appr.sum()}):")
    print(f"  Median: {appr_gaps.median():.3f} days ({appr_gaps.median()*24:.1f}h)")
    print(f"  Within 1h: {(appr_gaps <= 1/24).sum()} ({(appr_gaps <= 1/24).mean()*100:.0f}%)")
    
    # Which comes last?
    both = df[has_ci & has_appr].copy()
    if len(both) > 0:
        both['ci_last'] = both['ci_to_merge_days'] < both['approval_to_merge_days']
        print(f"\nCI was last gate: {both['ci_last'].mean()*100:.0f}% (n={len(both)})")
    
    # ============================================================
    # SYNTHESIS: Recommended weights
    # ============================================================
    print("\n" + "="*70)
    print("SYNTHESIS: Recommended Weights")
    print("="*70)
    
    synthesize_weights(model1, dash_features, model2_std, cont_features, logit, df)
    
    # ============================================================
    # PER-REPO ANALYSIS
    # ============================================================
    per_repo_analysis(df, dash_features)
    
    return model1, model2, logit

def synthesize_weights(ols1, dash_feats, ols2_std, cont_feats, logit, df):
    """Combine all evidence into final weight recommendations."""
    
    # Category mapping for continuous features
    cat_map = {
        'ba_passed': 'ci', 'ba_failed': 'ci',
        'owner_approved_f': 'approval', 'approval_count': 'approval',
        'log_threads': 'discussion', 'log_comments': 'discussion',
        'distinct_commenters': 'discussion',
        'unresolved_threads': 'feedback', 'cr_count': 'feedback',
        'log_lines': 'size', 'log_files': 'size',
        'community_f': 'community',
        'area_label_f': 'align',
    }
    
    # Aggregate continuous feature importance by category
    std_importance = ols2_std.params.drop('const')
    cat_importance = {}
    for feat, cat in cat_map.items():
        if feat in std_importance.index:
            cat_importance[cat] = cat_importance.get(cat, 0) + abs(std_importance[feat])
    
    # OLS1 t-stats for dashboard sub-score importance
    ols1_t = np.abs(ols1.tvalues.drop('const'))
    dash_cat_map = {
        'f_ci': 'ci', 'f_approval': 'approval', 'f_maint': 'maint_review',
        'f_feedback': 'feedback', 'f_size': 'size', 'f_community': 'community',
        'f_align': 'align', 'f_discussion': 'discussion',
    }
    
    # Logistic importance
    logit_imp = dict(zip(
        [dash_cat_map[f] for f in ['f_ci','f_approval','f_maint','f_feedback',
                                    'f_size','f_community','f_align','f_discussion']],
        np.abs(logit.coef_[0])
    ))
    
    # Event-gap evidence (qualitative)
    # CI: last gate 69% of time, 53% merge within 1h → strong gate
    # Approval: 41% merge within 1h → strong gate
    
    # Build final weights - combine multiple evidence sources
    categories = ['ci', 'approval', 'maint_review', 'feedback', 'discussion',
                  'size', 'community', 'align']
    
    current = {
        'ci': 3.0, 'approval': 2.0, 'maint_review': 3.0,
        'feedback': 2.0, 'discussion': 1.5,
        'size': 1.0, 'community': 0.5, 'align': 1.0,
    }
    
    # Combine evidence
    results = []
    for cat in categories:
        # OLS1 t-stat (dashboard sub-scores)
        feat_key = [k for k,v in dash_cat_map.items() if v == cat]
        ols1_evidence = max([abs(ols1_t.get(f, 0)) for f in feat_key]) if feat_key else 0
        
        # Continuous model category importance
        cont_evidence = cat_importance.get(cat, 0)
        
        # Logistic
        logit_evidence = logit_imp.get(cat, 0)
        
        results.append({
            'category': cat,
            'ols_t': ols1_evidence,
            'cont_importance': cont_evidence,
            'logit_coef': logit_evidence,
            'current_weight': current[cat],
        })
    
    rdf = pd.DataFrame(results)
    
    # Normalize each evidence source to 0-1, then average
    for col in ['ols_t', 'cont_importance', 'logit_coef']:
        mx = rdf[col].max()
        if mx > 0:
            rdf[f'{col}_norm'] = rdf[col] / mx
        else:
            rdf[f'{col}_norm'] = 0
    
    rdf['combined_score'] = (rdf['ols_t_norm'] + rdf['cont_importance_norm'] + rdf['logit_coef_norm']) / 3
    
    # Apply gate adjustments:
    # CI: regression underestimates because it's a binary gate. Event-gap shows it's
    # the last gate 69% of time. Boost to minimum 2.0.
    # Conflict: can't measure, keep at 3.0
    
    # Scale combined to sum to 17 (20 - 3 for conflict)
    total = rdf['combined_score'].sum()
    rdf['raw_weight'] = rdf['combined_score'] / total * 17.0
    
    # Apply gate floor for CI (event-gap evidence)
    ci_idx = rdf[rdf['category'] == 'ci'].index[0]
    if rdf.loc[ci_idx, 'raw_weight'] < 2.0:
        deficit = 2.0 - rdf.loc[ci_idx, 'raw_weight']
        rdf.loc[ci_idx, 'raw_weight'] = 2.0
        # Redistribute deficit proportionally from others
        others = rdf.index[rdf['category'] != 'ci']
        other_sum = rdf.loc[others, 'raw_weight'].sum()
        rdf.loc[others, 'raw_weight'] -= deficit * (rdf.loc[others, 'raw_weight'] / other_sum)
    
    rdf['recommended'] = rdf['raw_weight'].round(1)
    rdf['change'] = rdf['recommended'] - rdf['current_weight']
    
    # Add conflict
    conflict = pd.DataFrame([{
        'category': 'conflict',
        'ols_t': np.nan, 'cont_importance': np.nan, 'logit_coef': np.nan,
        'current_weight': 3.0, 'combined_score': np.nan,
        'raw_weight': 3.0, 'recommended': 3.0, 'change': 0.0,
    }])
    rdf = pd.concat([rdf, conflict], ignore_index=True)
    
    print("\n┌─────────────────────────────────────────────────────────────────────┐")
    print("│              FINAL WEIGHT RECOMMENDATIONS                          │")
    print("├───────────────┬─────────┬──────────────┬────────┬─────────────────┤")
    print("│ Feature       │ Current │ Recommended  │ Change │ Evidence        │")
    print("├───────────────┼─────────┼──────────────┼────────┼─────────────────┤")
    
    display_order = ['discussion', 'ci', 'conflict', 'approval', 'maint_review',
                     'feedback', 'size', 'community', 'align']
    
    evidence_notes = {
        'discussion': 'Strongest predictor in all models',
        'ci': 'Gate: last gate 69% of time',
        'conflict': 'Gate: cannot merge (unmeasurable)',
        'approval': 'Gate: 41% merge within 1h',
        'maint_review': 'Moderate; overlaps approval',
        'feedback': 'CR count is very predictive',
        'size': 'Significant in most repos',
        'community': 'Moderate; inferred maintainers',
        'align': 'Weak predictor overall',
    }
    
    for cat in display_order:
        row = rdf[rdf['category'] == cat].iloc[0]
        c = row['current_weight']
        r = row['recommended']
        ch = row['change']
        ev = evidence_notes.get(cat, '')
        sign = '+' if ch >= 0 else ''
        print(f"│ {cat:<13} │  {c:>4.1f}   │    {r:>4.1f}      │ {sign}{ch:>4.1f}  │ {ev:<15} │")
    
    print("├───────────────┼─────────┼──────────────┼────────┼─────────────────┤")
    total_cur = rdf['current_weight'].sum()
    total_new = rdf['recommended'].sum()
    print(f"│ TOTAL         │  {total_cur:>4.1f}   │    {total_new:>4.1f}      │        │                 │")
    print("└───────────────┴─────────┴──────────────┴────────┴─────────────────┘")

def per_repo_analysis(df, dash_features):
    """Per-repo analysis with refined features."""
    
    print("\n" + "="*70)
    print("PER-REPO: Significant Features (Build Analysis CI, inferred maintainers)")
    print("="*70)
    
    repo_results = {}
    for repo in sorted(df['repo'].unique()):
        rdf = df[df['repo'] == repo]
        if len(rdf) < 30:
            continue
        
        X = rdf[dash_features].copy()
        y = rdf['log_age']
        
        # Drop zero-variance columns
        valid = [c for c in dash_features if X[c].std() > 0]
        if len(valid) < 3:
            continue
        
        X_v = X[valid]
        X_c = sm.add_constant(X_v)
        
        try:
            model = sm.OLS(y, X_c).fit()
            sig = {f: (model.tvalues[f], model.pvalues[f]) 
                   for f in valid if model.pvalues[f] < 0.10}
            
            repo_results[repo] = {
                'r2': model.rsquared,
                'n': len(rdf),
                'median_age': rdf['age_days'].median(),
                'significant': sig,
                'ba_dist': rdf['build_analysis_conclusion'].value_counts().to_dict(),
            }
            
            sig_str = ', '.join(f"{f.replace('f_','')}(t={t:.1f}{'*' if p<0.05 else ''})"
                                for f, (t, p) in sorted(sig.items(), key=lambda x: abs(x[1][0]), reverse=True))
            
            ba_dist = rdf['build_analysis_conclusion'].value_counts()
            ba_str = ', '.join(f"{k}:{v}" for k,v in ba_dist.items())
            
            print(f"\n{repo} (n={len(rdf)}, R²={model.rsquared:.2f}, "
                  f"median_age={rdf['age_days'].median():.1f}d)")
            print(f"  BA dist: {ba_str}")
            print(f"  Significant (p<0.10): {sig_str or 'none'}")
            
            # Community breakdown
            comm = rdf['is_community_inferred']
            comm_age = rdf.loc[comm, 'age_days'].median()
            maint_age = rdf.loc[~comm, 'age_days'].median()
            print(f"  Community median age: {comm_age:.1f}d vs maintainer: {maint_age:.1f}d")
        except Exception as e:
            print(f"\n{repo}: error: {e}")
    
    # Summary table
    print("\n--- Per-Repo: Which features matter most? ---")
    print("(Features significant at p<0.10 in each repo's regression)\n")
    
    feature_counts = {}
    for repo, data in repo_results.items():
        for feat in data['significant']:
            fname = feat.replace('f_', '')
            feature_counts[fname] = feature_counts.get(fname, 0) + 1
    
    print("Feature significance frequency across repos:")
    for feat, count in sorted(feature_counts.items(), key=lambda x: -x[1]):
        repos_with = [r.split('/')[1] for r, d in repo_results.items() 
                      if feat in [f.replace('f_','') for f in d['significant']]]
        print(f"  {feat}: {count}/{len(repo_results)} repos ({', '.join(repos_with)})")

def main():
    print("Loading data with refined maintainer classification...")
    df, repo_maint = load_data()
    
    print("\nComputing features...")
    df = compute_features(df)
    
    model1, model2, logit = run_full_analysis(df)

if __name__ == "__main__":
    main()
