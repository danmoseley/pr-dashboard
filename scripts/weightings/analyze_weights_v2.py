"""
Round 2: Event-gap analysis and refined regression.
Instead of just correlating features at merge time with age_days,
analyze the TIME GAPS between specific events and merge.
This better captures the causal role of each event.
"""

import json
import os
import numpy as np
import pandas as pd
import statsmodels.api as sm
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LinearRegression, LogisticRegression
from sklearn.model_selection import cross_val_score
import warnings
warnings.filterwarnings('ignore')

DATA_FILE = r"C:\git\pr_data\merged_pr_features.json"

def load_data():
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        data = json.load(f)
    df = pd.DataFrame(data)
    print(f"Loaded {len(df)} PRs from {df['repo'].nunique()} repos")
    return df

def event_gap_analysis(df):
    """Analyze time gaps between key events and merge.
    The key question: once event X happens, how quickly does the PR merge?
    A small gap means the event was the 'last gate' before merge."""
    
    print("\n" + "="*70)
    print("EVENT-GAP ANALYSIS")
    print("(Smaller gap = this event was closer to being the 'last gate')")
    print("="*70)
    
    # Approval-to-merge gap
    has_approval_gap = df['approval_to_merge_days'].notna()
    approval_gaps = df.loc[has_approval_gap, 'approval_to_merge_days']
    print(f"\nFirst Approval → Merge (n={has_approval_gap.sum()}):")
    print(f"  Median: {approval_gaps.median():.2f} days")
    print(f"  Mean: {approval_gaps.mean():.2f} days")
    print(f"  P25/P75: {approval_gaps.quantile(0.25):.2f} / {approval_gaps.quantile(0.75):.2f}")
    print(f"  Merged within 1h of approval: {(approval_gaps <= 1/24).sum()} ({(approval_gaps <= 1/24).mean()*100:.0f}%)")
    print(f"  Merged within 1d of approval: {(approval_gaps <= 1).sum()} ({(approval_gaps <= 1).mean()*100:.0f}%)")
    
    # CI-to-merge gap
    has_ci_gap = df['ci_to_merge_days'].notna()
    ci_gaps = df.loc[has_ci_gap, 'ci_to_merge_days']
    print(f"\nCI Pass → Merge (n={has_ci_gap.sum()}):")
    print(f"  Median: {ci_gaps.median():.2f} days")
    print(f"  Mean: {ci_gaps.mean():.2f} days")
    print(f"  P25/P75: {ci_gaps.quantile(0.25):.2f} / {ci_gaps.quantile(0.75):.2f}")
    print(f"  Merged within 1h of CI: {(ci_gaps <= 1/24).sum()} ({(ci_gaps <= 1/24).mean()*100:.0f}%)")
    print(f"  Merged within 1d of CI: {(ci_gaps <= 1).sum()} ({(ci_gaps <= 1).mean()*100:.0f}%)")
    
    # Last activity to merge gap
    activity_gaps = df['last_activity_to_merge_days']
    print(f"\nLast Activity → Merge (n={len(activity_gaps)}):")
    print(f"  Median: {activity_gaps.median():.2f} days")
    print(f"  Mean: {activity_gaps.mean():.2f} days")
    print(f"  P25/P75: {activity_gaps.quantile(0.25):.2f} / {activity_gaps.quantile(0.75):.2f}")
    
    # Per-repo event gaps
    print("\n--- Per-Repo: Median gap from First Approval → Merge ---")
    for repo in sorted(df['repo'].unique()):
        rdf = df[(df['repo'] == repo) & df['approval_to_merge_days'].notna()]
        if len(rdf) > 5:
            print(f"  {repo}: {rdf['approval_to_merge_days'].median():.2f}d (n={len(rdf)})")
    
    print("\n--- Per-Repo: Median gap from CI Pass → Merge ---")
    for repo in sorted(df['repo'].unique()):
        rdf = df[(df['repo'] == repo) & df['ci_to_merge_days'].notna()]
        if len(rdf) > 5:
            print(f"  {repo}: {rdf['ci_to_merge_days'].median():.2f}d (n={len(rdf)})")
    
    return approval_gaps, ci_gaps

def sequencing_analysis(df):
    """Determine typical sequencing: does approval or CI typically come last?
    This tells us which is the actual 'gate' in practice."""
    
    print("\n" + "="*70)
    print("SEQUENCING ANALYSIS: What's the last gate before merge?")
    print("="*70)
    
    # For PRs that have both approval and CI dates, which comes last?
    both = df[df['approval_to_merge_days'].notna() & df['ci_to_merge_days'].notna()].copy()
    print(f"\nPRs with both approval and CI dates: {len(both)}")
    
    if len(both) > 0:
        # Smaller gap = closer to merge = this was the later event
        both['approval_last'] = both['approval_to_merge_days'] < both['ci_to_merge_days']
        both['ci_last'] = both['ci_to_merge_days'] < both['approval_to_merge_days']
        both['simultaneous'] = (both['approval_to_merge_days'] - both['ci_to_merge_days']).abs() < 0.042  # within 1 hour
        
        print(f"  Approval was the last gate: {both['approval_last'].sum()} ({both['approval_last'].mean()*100:.0f}%)")
        print(f"  CI was the last gate: {both['ci_last'].sum()} ({both['ci_last'].mean()*100:.0f}%)")
        print(f"  ~Simultaneous (within 1h): {both['simultaneous'].sum()} ({both['simultaneous'].mean()*100:.0f}%)")
        
        print("\n  Per-repo breakdown:")
        for repo in sorted(both['repo'].unique()):
            rdf = both[both['repo'] == repo]
            if len(rdf) >= 5:
                a = rdf['approval_last'].mean()*100
                c = rdf['ci_last'].mean()*100
                s = rdf['simultaneous'].mean()*100
                print(f"    {repo}: approval_last={a:.0f}%, ci_last={c:.0f}%, simultaneous={s:.0f}% (n={len(rdf)})")

def alternative_regression(df):
    """Try regression with event gaps as additional features.
    Also try predicting 'remaining time' at various lifecycle points."""
    
    print("\n" + "="*70)
    print("ALTERNATIVE REGRESSION: Using event gaps + raw features")
    print("="*70)
    
    # Filter to PRs with rich data
    rich = df.copy()
    rich['has_approval'] = rich['approval_count'] > 0
    rich['log_age'] = np.log1p(rich['age_days'])
    rich['log_lines'] = np.log1p(rich['total_lines'])
    rich['log_files'] = np.log1p(rich['changed_files'])
    rich['log_threads'] = np.log1p(rich['total_threads'])
    rich['log_comments'] = np.log1p(rich['total_comments'])
    rich['ci_passed'] = (rich['ci_status'] == 'SUCCESS').astype(float)
    rich['ci_failed'] = (rich['ci_status'] == 'FAILURE').astype(float)
    rich['owner_approved'] = rich['has_owner_approval'].astype(float)
    rich['any_review'] = rich['has_any_review'].astype(float)
    rich['community'] = rich['is_community'].astype(float)
    rich['area_label'] = rich['has_area_label'].astype(float)
    rich['cr_count'] = rich['changes_requested_count']
    
    # Best model with all meaningful continuous features
    features = ['ci_passed', 'ci_failed', 'owner_approved', 
                'log_lines', 'log_files', 'log_threads', 'log_comments',
                'community', 'area_label', 'cr_count',
                'approval_count', 'unresolved_threads', 'distinct_commenters']
    
    X = rich[features].copy()
    y = rich['log_age']
    
    X_const = sm.add_constant(X)
    model = sm.OLS(y, X_const).fit()
    
    print(f"\nFull continuous model: R² = {model.rsquared:.3f}, Adj R² = {model.rsquared_adj:.3f}")
    
    coefs = pd.DataFrame({
        'coef': model.params.drop('const'),
        'std_err': model.bse.drop('const'),
        'p_value': model.pvalues.drop('const'),
        't_stat': model.tvalues.drop('const'),
    })
    coefs['significant'] = coefs['p_value'] < 0.05
    coefs = coefs.sort_values('t_stat')
    
    print("\nAll features (sorted by t-stat, negative = speeds merge):")
    print(coefs.to_string(float_format=lambda x: f"{x:.4f}"))
    
    # Standardized coefficients (for relative importance)
    print("\n--- Standardized coefficients (comparable magnitudes) ---")
    scaler = StandardScaler()
    X_std = pd.DataFrame(scaler.fit_transform(X), columns=features, index=X.index)
    X_std_const = sm.add_constant(X_std)
    model_std = sm.OLS(y, X_std_const).fit()
    
    std_coefs = pd.DataFrame({
        'std_coef': model_std.params.drop('const'),
        'p_value': model_std.pvalues.drop('const'),
        'abs_std_coef': np.abs(model_std.params.drop('const')),
    }).sort_values('abs_std_coef', ascending=False)
    
    print(std_coefs.to_string(float_format=lambda x: f"{x:.4f}"))
    
    # Relative importance as percentage
    total_importance = std_coefs['abs_std_coef'].sum()
    std_coefs['pct_importance'] = (std_coefs['abs_std_coef'] / total_importance * 100)
    
    print("\n--- Relative importance (% of total) ---")
    print(std_coefs[['abs_std_coef', 'pct_importance', 'p_value']].to_string(
        float_format=lambda x: f"{x:.2f}"))
    
    return model, std_coefs

def map_to_dashboard_weights(std_coefs, df):
    """Map continuous-feature importance back to dashboard weight categories."""
    
    print("\n" + "="*70)
    print("MAPPING TO DASHBOARD WEIGHT CATEGORIES")
    print("="*70)
    
    # Group continuous features into dashboard categories
    category_map = {
        'ci_passed': 'ci',
        'ci_failed': 'ci',
        'owner_approved': 'approval/maint',
        'approval_count': 'approval/maint',
        'log_threads': 'discussion',
        'log_comments': 'discussion',
        'distinct_commenters': 'discussion',
        'unresolved_threads': 'feedback',
        'cr_count': 'feedback',
        'log_lines': 'size',
        'log_files': 'size',
        'community': 'community',
        'area_label': 'align',
    }
    
    importance = std_coefs['abs_std_coef'].copy()
    
    category_importance = {}
    for feature, cat in category_map.items():
        if feature in importance.index:
            category_importance[cat] = category_importance.get(cat, 0) + importance[feature]
    
    cat_df = pd.DataFrame([
        {'category': k, 'importance': v}
        for k, v in category_importance.items()
    ]).sort_values('importance', ascending=False)
    
    # Scale to sum to 17 (20 minus 3 for conflict)
    total = cat_df['importance'].sum()
    cat_df['weight_17'] = cat_df['importance'] / total * 17
    
    # Current weights for comparison
    current = {
        'ci': 3.0,
        'approval/maint': 5.0,  # maintScore(3) + approvalScore(2)
        'discussion': 1.5,
        'feedback': 2.0,
        'size': 1.0,
        'community': 0.5,
        'align': 1.0,
    }
    cat_df['current_weight'] = cat_df['category'].map(current)
    
    # Also split into the original finer categories
    # For the recommendation, split approval/maint proportionally
    
    print("\nCategory weights (scaled to sum to 17, excluding conflict):")
    print(cat_df.to_string(float_format=lambda x: f"{x:.2f}", index=False))
    
    print("\n--- Final Recommended Weights (20-point scale, including conflict) ---")
    
    # Conflict: keep at current weight since we can't measure it
    # But note: it's a hard gate like CI, so it deserves significant weight
    recommendations = []
    for _, row in cat_df.iterrows():
        cat = row['category']
        new_wt = row['weight_17']
        old_wt = row['current_weight']
        
        if cat == 'approval/maint':
            # Split into maintScore and approvalScore
            # Original ratio: maintScore=3.0, approvalScore=2.0 (60/40)
            # Keep similar ratio but adjust total
            recommendations.append({'feature': 'maintScore', 'new_weight': new_wt * 0.5,
                                    'current_weight': 3.0, 'change': f"{new_wt*0.5 - 3.0:+.1f}"})
            recommendations.append({'feature': 'approvalScore', 'new_weight': new_wt * 0.5,
                                    'current_weight': 2.0, 'change': f"{new_wt*0.5 - 2.0:+.1f}"})
        else:
            # Map back to original dashboard feature names
            name_map = {'ci': 'ciScore', 'discussion': 'discussionScore',
                       'feedback': 'feedbackScore', 'size': 'sizeScore',
                       'community': 'communityScore', 'align': 'alignScore'}
            fname = name_map.get(cat, cat)
            orig = {'ciScore': 3.0, 'discussionScore': 1.5, 'feedbackScore': 2.0,
                    'sizeScore': 1.0, 'communityScore': 0.5, 'alignScore': 1.0}.get(fname, 0)
            recommendations.append({'feature': fname, 'new_weight': new_wt,
                                    'current_weight': orig, 'change': f"{new_wt - orig:+.1f}"})
    
    # Add conflict (unchanged)
    recommendations.append({'feature': 'conflictScore', 'new_weight': 3.0,
                            'current_weight': 3.0, 'change': '+0.0'})
    
    # Add staleness/freshness/velocity (merged into other categories in our analysis)
    # These are time-based features that our cross-sectional data can't easily capture
    # since all PRs are measured at merge time
    
    rec_df = pd.DataFrame(recommendations).sort_values('new_weight', ascending=False)
    print(rec_df.to_string(index=False, float_format=lambda x: f"{x:.1f}"))
    
    new_total = rec_df['new_weight'].sum()
    print(f"\nTotal new weights: {new_total:.1f} (target: 20.0)")
    
    return rec_df

def per_repo_heatmap(df):
    """Show which features matter most in each repo using standardized coefficients."""
    
    print("\n" + "="*70)
    print("PER-REPO FEATURE IMPORTANCE HEATMAP (standardized |coef|)")
    print("="*70)
    
    features = ['ci_passed', 'owner_approved', 'log_lines', 'log_threads',
                'log_comments', 'community', 'area_label', 'cr_count',
                'approval_count', 'unresolved_threads']
    
    results = {}
    for repo in sorted(df['repo'].unique()):
        rdf = df[df['repo'] == repo].copy()
        if len(rdf) < 30:
            continue
        
        rdf['log_age'] = np.log1p(rdf['age_days'])
        rdf['log_lines'] = np.log1p(rdf['total_lines'])
        rdf['log_threads'] = np.log1p(rdf['total_threads'])
        rdf['log_comments'] = np.log1p(rdf['total_comments'])
        rdf['ci_passed'] = (rdf['ci_status'] == 'SUCCESS').astype(float)
        rdf['owner_approved'] = rdf['has_owner_approval'].astype(float)
        rdf['community'] = rdf['is_community'].astype(float)
        rdf['area_label'] = rdf['has_area_label'].astype(float)
        rdf['cr_count'] = rdf['changes_requested_count']
        
        X = rdf[features].copy()
        y = rdf['log_age']
        
        # Check for zero-variance columns
        valid_cols = [c for c in features if X[c].std() > 0]
        if len(valid_cols) < 3:
            continue
        
        scaler = StandardScaler()
        X_std = pd.DataFrame(scaler.fit_transform(X[valid_cols]), 
                             columns=valid_cols, index=X.index)
        X_std_const = sm.add_constant(X_std)
        
        try:
            model = sm.OLS(y, X_std_const).fit()
            std_coefs = model.params.drop('const')
            p_values = model.pvalues.drop('const')
            
            # Mark significance
            display = {}
            for feat in valid_cols:
                val = abs(std_coefs[feat])
                sig = '*' if p_values[feat] < 0.05 else (' ' if p_values[feat] < 0.10 else ' ')
                display[feat] = f"{val:.2f}{sig}"
            
            results[repo.split('/')[1]] = display
            results[repo.split('/')[1]]['R²'] = f"{model.rsquared:.2f}"
        except Exception:
            pass
    
    if results:
        heatmap_df = pd.DataFrame(results).T.fillna('-')
        print("\n(* = p<0.05)")
        print(heatmap_df.to_string())

def main():
    df = load_data()
    
    # Compute additional features
    df['has_approval'] = df['approval_count'] > 0
    df['log_age'] = np.log1p(df['age_days'])
    
    event_gap_analysis(df)
    sequencing_analysis(df)
    model, std_coefs = alternative_regression(df)
    rec_df = map_to_dashboard_weights(std_coefs, df)
    per_repo_heatmap(df)

if __name__ == "__main__":
    main()
