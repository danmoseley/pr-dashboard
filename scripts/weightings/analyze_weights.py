"""
Analyze merged PR data to derive empirical weights for readiness score.
Runs OLS regression globally and per-repo, compares with current dashboard weights.
"""

import json
import os
import sys
import numpy as np
import pandas as pd
from pathlib import Path
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LinearRegression, LogisticRegression
from sklearn.model_selection import cross_val_score
import statsmodels.api as sm
import warnings
warnings.filterwarnings('ignore')

_SCRIPT_DIR = Path(__file__).resolve().parent
_DATA_DIR = os.environ.get("WEIGHTINGS_DATA_DIR", str(_SCRIPT_DIR / "data"))
DATA_FILE = os.path.join(_DATA_DIR, "merged_pr_features.json")
OUTPUT_DIR = _DATA_DIR

# Current dashboard weights for comparison
CURRENT_WEIGHTS = {
    'ci': 3.0,
    'conflict': 3.0,  # Not available historically
    'maint_review': 3.0,
    'feedback': 2.0,
    'approval': 2.0,
    'staleness': 1.5,
    'discussion': 1.5,
    'align': 1.0,
    'fresh': 1.0,
    'size': 1.0,
    'community': 0.5,
    'velocity': 0.5,
}

def load_data():
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        data = json.load(f)
    df = pd.DataFrame(data)
    print(f"Loaded {len(df)} PRs from {df['repo'].nunique()} repos")
    return df

def compute_features(df):
    """Compute feature columns that mirror the dashboard's sub-scores."""
    
    # CI score: 1 if SUCCESS, 0.5 if IN_PROGRESS/ABSENT, 0 if FAILURE
    df['f_ci'] = df['ci_status'].map({
        'SUCCESS': 1.0, 'IN_PROGRESS': 0.5, 'ABSENT': 0.5,
        'FAILURE': 0.0, 'UNKNOWN': 0.5
    }).fillna(0.5)
    
    # Approval score (simplified — triager approval not available in collected data,
    # so we only model owner vs. non-owner approval)
    def approval_score(row):
        if row['approval_count'] >= 2 and row['has_owner_approval']:
            return 1.0
        elif row['has_owner_approval']:
            return 0.75
        elif row['approval_count'] >= 1:
            return 0.5
        return 0.0
    df['f_approval'] = df.apply(approval_score, axis=1)
    if 'has_stale_approval' in df.columns:
        mask = df['has_stale_approval'] & (df['f_approval'] > 0)
        df.loc[mask, 'f_approval'] = (df.loc[mask, 'f_approval'] - 0.25).clip(lower=0)
    
    # Maintainer score
    def maint_score(row):
        if row['has_owner_approval']:
            return 1.0
        elif row['has_any_review']:
            return 0.5
        return 0.0
    df['f_maint'] = df.apply(maint_score, axis=1)
    
    # Feedback score
    def feedback_score(row):
        if row['unresolved_threads'] == 0:
            return 1.0
        return 0.5
    df['f_feedback'] = df.apply(feedback_score, axis=1)
    
    # Size score
    def size_score(row):
        if row['changed_files'] <= 5 and row['total_lines'] <= 200:
            return 1.0
        elif row['changed_files'] <= 20 and row['total_lines'] <= 500:
            return 0.5
        return 0.0
    df['f_size'] = df.apply(size_score, axis=1)
    
    # Community score
    df['f_community'] = df['is_community'].map({True: 0.5, False: 1.0}).fillna(1.0)
    
    # Alignment score
    def align_score(row):
        if row['is_untriaged'] or not row['has_area_label']:
            return 0.0
        return 1.0
    df['f_align'] = df.apply(align_score, axis=1)
    
    # Discussion score  
    # Discussion score (includes recency like the dashboard's daysSinceReview <= 14 case)
    def discussion_score(row):
        # Approximate dashboard's recency condition: days between last review and merge
        days_since_review = None
        if pd.notna(row.get('last_review_date')) and pd.notna(row.get('merged_at')):
            try:
                merged = pd.Timestamp(row['merged_at'])
                last_review = pd.Timestamp(row['last_review_date'])
                days_since_review = (merged - last_review).total_seconds() / 86400
            except Exception:
                pass
        if row['total_threads'] <= 5 and row['distinct_commenters'] <= 2:
            return 1.0
        elif days_since_review is not None and days_since_review <= 14:
            return 0.75
        elif row['total_threads'] <= 15 and row['distinct_commenters'] <= 5:
            return 0.5
        return 0.0
    df['f_discussion'] = df.apply(discussion_score, axis=1)
    
    # For continuous features useful in regression
    df['f_log_lines'] = np.log1p(df['total_lines'])
    df['f_log_files'] = np.log1p(df['changed_files'])
    df['f_log_threads'] = np.log1p(df['total_threads'])
    df['f_log_comments'] = np.log1p(df['total_comments'])
    df['f_has_approval'] = (df['approval_count'] > 0).astype(float)
    df['f_has_owner_approval'] = df['has_owner_approval'].astype(float)
    df['f_is_community'] = df['is_community'].astype(float)
    df['f_has_area_label'] = df['has_area_label'].astype(float)
    df['f_ci_passed'] = (df['ci_status'] == 'SUCCESS').astype(float)
    df['f_ci_failed'] = (df['ci_status'] == 'FAILURE').astype(float)
    df['f_changes_requested'] = (df['changes_requested_count'] > 0).astype(float)
    
    return df

def run_global_regression(df):
    """Run OLS regression with age_days as target and feature scores as predictors."""
    print("\n" + "="*70)
    print("GLOBAL REGRESSION ANALYSIS")
    print("="*70)
    
    # --- Approach 1: Dashboard sub-scores predicting merge speed ---
    print("\n--- Approach 1: Dashboard sub-scores → age_days ---")
    print("(Do the dashboard's categorical scores correlate with how quickly PRs merge?)")
    
    feature_cols_dash = ['f_ci', 'f_approval', 'f_maint', 'f_feedback', 
                         'f_size', 'f_community', 'f_align', 'f_discussion']
    
    target = df['age_days'].copy()
    # Log-transform target for better regression (age_days is right-skewed)
    target_log = np.log1p(target)
    
    X = df[feature_cols_dash].copy()
    X_const = sm.add_constant(X)
    
    model = sm.OLS(target_log, X_const).fit()
    print(f"\nR² = {model.rsquared:.3f}, Adj R² = {model.rsquared_adj:.3f}")
    print(f"F-statistic p-value: {model.f_pvalue:.2e}")
    print("\nCoefficients (negative = faster merge, which means MORE ready):")
    
    coef_df = pd.DataFrame({
        'coef': model.params,
        'std_err': model.bse,
        'p_value': model.pvalues,
        't_stat': model.tvalues
    }).drop('const', errors='ignore')
    
    # A negative coefficient means higher feature value → lower age → faster merge → good
    # So we negate to get "readiness contribution"
    coef_df['readiness_direction'] = -coef_df['coef']
    coef_df = coef_df.sort_values('readiness_direction', ascending=False)
    
    print(coef_df.to_string(float_format=lambda x: f"{x:.4f}"))
    
    # --- Approach 2: Raw continuous features ---
    print("\n\n--- Approach 2: Continuous features → age_days ---")
    
    feature_cols_raw = ['f_ci_passed', 'f_ci_failed', 'f_has_approval', 
                        'f_has_owner_approval', 'f_log_lines', 'f_log_files',
                        'f_log_threads', 'f_log_comments', 'f_is_community',
                        'f_has_area_label', 'f_changes_requested']
    
    X2 = df[feature_cols_raw].copy()
    X2_const = sm.add_constant(X2)
    
    model2 = sm.OLS(target_log, X2_const).fit()
    print(f"\nR² = {model2.rsquared:.3f}, Adj R² = {model2.rsquared_adj:.3f}")
    print(f"F-statistic p-value: {model2.f_pvalue:.2e}")
    
    coef_df2 = pd.DataFrame({
        'coef': model2.params,
        'std_err': model2.bse,
        'p_value': model2.pvalues,
        't_stat': model2.tvalues
    }).drop('const', errors='ignore')
    coef_df2['readiness_direction'] = -coef_df2['coef']
    coef_df2 = coef_df2.sort_values('readiness_direction', ascending=False)
    
    print("\nCoefficients (negative coef = faster merge = more ready):")
    print(coef_df2.to_string(float_format=lambda x: f"{x:.4f}"))
    
    # --- Approach 3: Logistic regression (merged within 7 days? yes/no) ---
    print("\n\n--- Approach 3: Logistic regression — merged within 7 days ---")
    
    df['merged_fast'] = (df['age_days'] <= 7).astype(int)
    y_fast = df['merged_fast']
    
    X3 = df[feature_cols_dash].copy()
    scaler = StandardScaler()
    X3_scaled = scaler.fit_transform(X3)
    
    logit = LogisticRegression(max_iter=1000, C=1.0)
    scores = cross_val_score(logit, X3_scaled, y_fast, cv=5, scoring='accuracy')
    print(f"5-fold CV accuracy: {scores.mean():.3f} ± {scores.std():.3f}")
    
    logit.fit(X3_scaled, y_fast)
    logit_coefs = pd.DataFrame({
        'feature': feature_cols_dash,
        'coef': logit.coef_[0],
        'abs_coef': np.abs(logit.coef_[0])
    }).sort_values('abs_coef', ascending=False)
    
    print("\nLogistic regression coefficients (positive = predicts fast merge):")
    print(logit_coefs.to_string(float_format=lambda x: f"{x:.4f}", index=False))
    
    # --- Approach 4: Derive recommended weights ---
    print("\n\n--- Approach 4: Recommended Weights ---")
    derive_weights(model, feature_cols_dash, logit, scaler)
    
    return model, model2, logit, coef_df, coef_df2

def derive_weights(ols_model, feature_cols, logit_model, scaler):
    """Combine OLS and logistic results into recommended weights."""
    
    # From OLS: use absolute t-statistics as importance (accounts for uncertainty)
    ols_importance = pd.Series(
        np.abs(ols_model.tvalues.drop('const', errors='ignore').values),
        index=feature_cols
    )
    
    # From logistic: use absolute coefficients (already on standardized scale)
    logit_importance = pd.Series(
        np.abs(logit_model.coef_[0]),
        index=feature_cols
    )
    
    # Combine (average of normalized ranks)
    ols_rank = ols_importance.rank()
    logit_rank = logit_importance.rank()
    combined = (ols_rank + logit_rank) / 2
    
    # Map feature names to dashboard weight names
    name_map = {
        'f_ci': 'ci',
        'f_approval': 'approval',
        'f_maint': 'maint_review',
        'f_feedback': 'feedback',
        'f_size': 'size',
        'f_community': 'community',
        'f_align': 'align',
        'f_discussion': 'discussion',
    }
    
    # Scale to sum to 20 (like current weights minus conflict which we can't measure)
    # Current weights minus conflict: 20 - 3 = 17, but let's use the full 20 scale
    total_target = 20.0 - 3.0  # Exclude conflict (not measurable)
    
    scaled = (combined / combined.sum()) * total_target
    
    result = pd.DataFrame({
        'feature': [name_map.get(f, f) for f in feature_cols],
        'empirical_weight': scaled.values,
        'current_weight': [CURRENT_WEIGHTS.get(name_map.get(f, f), 0) for f in feature_cols],
        'ols_t_stat': np.abs(ols_model.tvalues.drop('const', errors='ignore').values),
        'logit_coef': np.abs(logit_model.coef_[0]),
        'ols_p_value': ols_model.pvalues.drop('const', errors='ignore').values,
    })
    
    # Add conflict back with its current weight (can't validate)
    conflict_row = pd.DataFrame([{
        'feature': 'conflict',
        'empirical_weight': np.nan,
        'current_weight': 3.0,
        'ols_t_stat': np.nan,
        'logit_coef': np.nan,
        'ols_p_value': np.nan,
    }])
    result = pd.concat([result, conflict_row], ignore_index=True)
    
    result = result.sort_values('empirical_weight', ascending=False, na_position='last')
    
    print("\nWeight Comparison:")
    print(result.to_string(float_format=lambda x: f"{x:.2f}", index=False, na_rep="N/A"))
    
    return result

def run_per_repo_regression(df):
    """Run regression per repo and compare."""
    print("\n" + "="*70)
    print("PER-REPO REGRESSION ANALYSIS")
    print("="*70)
    
    feature_cols = ['f_ci', 'f_approval', 'f_maint', 'f_feedback', 
                    'f_size', 'f_community', 'f_align', 'f_discussion']
    
    results = {}
    for repo in sorted(df['repo'].unique()):
        repo_df = df[df['repo'] == repo]
        if len(repo_df) < 30:
            print(f"\n{repo}: skipped (only {len(repo_df)} PRs)")
            continue
            
        target_log = np.log1p(repo_df['age_days'])
        X = repo_df[feature_cols].copy()
        X_const = sm.add_constant(X)
        
        try:
            model = sm.OLS(target_log, X_const).fit()
            # Use t-statistics for importance
            t_stats = model.tvalues.drop('const', errors='ignore')
            results[repo] = {
                'r2': model.rsquared,
                'r2_adj': model.rsquared_adj,
                'n': len(repo_df),
                'mean_age': repo_df['age_days'].mean(),
                'median_age': repo_df['age_days'].median(),
                'coefs': model.params.drop('const', errors='ignore'),
                't_stats': t_stats,
                'p_values': model.pvalues.drop('const', errors='ignore'),
            }
            
            sig_features = t_stats[model.pvalues.drop('const', errors='ignore') < 0.05]
            print(f"\n{repo}: R²={model.rsquared:.3f}, n={len(repo_df)}, "
                  f"median_age={repo_df['age_days'].median():.1f}d")
            print(f"  Significant features (p<0.05): "
                  f"{', '.join(f'{k}(t={v:.1f})' for k,v in sig_features.items()) or 'none'}")
        except Exception as e:
            print(f"\n{repo}: regression failed: {e}")
    
    # Compare feature importance across repos
    if results:
        print("\n\n--- Cross-Repo Feature Importance (|t-statistic|) ---")
        importance_df = pd.DataFrame({
            repo: np.abs(data['t_stats']) 
            for repo, data in results.items()
        }).T
        importance_df.columns = [c.replace('f_', '') for c in importance_df.columns]
        
        print(importance_df.to_string(float_format=lambda x: f"{x:.2f}"))
        
        print("\n--- Mean |t-stat| across repos (higher = more consistently important) ---")
        mean_importance = importance_df.mean().sort_values(ascending=False)
        print(mean_importance.to_string(float_format=lambda x: f"{x:.2f}"))
        
        print("\n--- Median merge age by repo ---")
        for repo, data in sorted(results.items(), key=lambda x: x[1]['median_age']):
            print(f"  {repo}: median {data['median_age']:.1f}d, mean {data['mean_age']:.1f}d")
    
    return results

def descriptive_stats(df):
    """Print descriptive statistics of the dataset."""
    print("\n" + "="*70)
    print("DESCRIPTIVE STATISTICS")
    print("="*70)
    
    print(f"\nTotal PRs: {len(df)}")
    print(f"Repos: {df['repo'].nunique()}")
    print(f"\nAge (days to merge):")
    print(f"  Mean: {df['age_days'].mean():.1f}")
    print(f"  Median: {df['age_days'].median():.1f}")
    print(f"  Std: {df['age_days'].std():.1f}")
    print(f"  Min: {df['age_days'].min():.1f}")
    print(f"  Max: {df['age_days'].max():.1f}")
    
    print(f"\nMerged within 1 day: {(df['age_days'] <= 1).sum()} ({(df['age_days'] <= 1).mean()*100:.0f}%)")
    print(f"Merged within 7 days: {(df['age_days'] <= 7).sum()} ({(df['age_days'] <= 7).mean()*100:.0f}%)")
    print(f"Merged within 30 days: {(df['age_days'] <= 30).sum()} ({(df['age_days'] <= 30).mean()*100:.0f}%)")
    
    print(f"\nCI status distribution:")
    print(df['ci_status'].value_counts().to_string())
    
    print(f"\nCommunity PRs: {df['is_community'].sum()} ({df['is_community'].mean()*100:.0f}%)")
    print(f"Has owner approval: {df['has_owner_approval'].sum()} ({df['has_owner_approval'].mean()*100:.0f}%)")
    print(f"Has area label: {df['has_area_label'].sum()} ({df['has_area_label'].mean()*100:.0f}%)")
    print(f"Has any review: {df['has_any_review'].sum()} ({df['has_any_review'].mean()*100:.0f}%)")
    
    print(f"\nSize distribution:")
    print(f"  Small (≤5 files, ≤200 lines): {((df['changed_files']<=5) & (df['total_lines']<=200)).sum()}")
    print(f"  Medium (≤20 files, ≤500 lines): {((df['changed_files']<=20) & (df['total_lines']<=500)).sum()}")
    print(f"  Large: {((df['changed_files']>20) | (df['total_lines']>500)).sum()}")
    
    # Correlation matrix
    print("\n--- Pairwise correlations with age_days ---")
    corr_cols = ['age_days', 'f_ci', 'f_approval', 'f_maint', 'f_feedback',
                 'f_size', 'f_community', 'f_align', 'f_discussion',
                 'total_lines', 'changed_files', 'total_threads', 
                 'approval_count', 'distinct_commenters']
    available = [c for c in corr_cols if c in df.columns]
    corr = df[available].corr()['age_days'].drop('age_days').sort_values()
    print(corr.to_string(float_format=lambda x: f"{x:.3f}"))

def main():
    print("Loading data...")
    df = load_data()
    
    print("Computing features...")
    df = compute_features(df)
    
    descriptive_stats(df)
    
    ols_model, ols_model2, logit, coef_df, coef_df2 = run_global_regression(df)
    
    per_repo = run_per_repo_regression(df)
    
    # Save full results
    results_file = os.path.join(OUTPUT_DIR, "analysis_results.txt")
    
    print(f"\n\nAnalysis complete. Full output above.")
    print(f"Data: {DATA_FILE}")

if __name__ == "__main__":
    main()
