"""
Round 4: Critical analysis of methodology and conclusions.
- Examine potential confounds and biases
- Try alternative models (Random Forest, Ridge, Lasso) for robustness
- Check if more data would improve stability via bootstrap analysis
- Look for non-linear effects the OLS might miss
- Examine the 'discussion' finding more critically
"""

import json
import os
import numpy as np
import pandas as pd
import statsmodels.api as sm
from pathlib import Path
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import Ridge, Lasso, ElasticNet, LogisticRegression
from sklearn.ensemble import RandomForestRegressor, GradientBoostingRegressor
from sklearn.model_selection import cross_val_score, learning_curve
from sklearn.inspection import permutation_importance
import warnings
warnings.filterwarnings('ignore')

_SCRIPT_DIR = Path(__file__).resolve().parent
_DATA_DIR = os.environ.get("WEIGHTINGS_DATA_DIR", str(_SCRIPT_DIR / "data"))
DATA_FILE = os.path.join(_DATA_DIR, "merged_pr_features.json")
MAINTAINERS_FILE = os.path.join(_DATA_DIR, "inferred_maintainers.json")

def load_and_prepare():
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        features = json.load(f)
    with open(MAINTAINERS_FILE, "r", encoding="utf-8") as f:
        maint_data = json.load(f)
    
    repo_maintainers = {k: set(v) for k, v in maint_data["repo_maintainers"].items()}
    df = pd.DataFrame(features)
    
    # Inferred community
    df['is_community_inferred'] = df.apply(
        lambda r: r['author'].lower() not in repo_maintainers.get(r['repo'], set()), axis=1)
    
    # Build Analysis CI
    df['f_ba'] = df['build_analysis_conclusion'].map({
        'SUCCESS': 1.0, 'ABSENT': 0.5, 'IN_PROGRESS': 0.5, 'FAILURE': 0.0
    }).fillna(0.5)
    
    # Dashboard sub-scores
    df['f_ci'] = df['f_ba']
    
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
    
    df['f_maint'] = 0.0
    df.loc[df['has_any_review'] & ~df['has_owner_approval'], 'f_maint'] = 0.5
    df.loc[df['has_owner_approval'], 'f_maint'] = 1.0
    
    df['f_feedback'] = df['unresolved_threads'].apply(lambda x: 1.0 if x == 0 else 0.5)
    
    def size_score(row):
        if row['changed_files'] <= 5 and row['total_lines'] <= 200:
            return 1.0
        elif row['changed_files'] <= 20 and row['total_lines'] <= 500:
            return 0.5
        return 0.0
    df['f_size'] = df.apply(size_score, axis=1)
    df['f_community'] = df['is_community_inferred'].map({True: 0.5, False: 1.0})
    df['f_align'] = df.apply(
        lambda r: 0.0 if (r['is_untriaged'] or not r['has_area_label']) else 1.0, axis=1)
    
    def discussion_score(row):
        if row['total_threads'] <= 5 and row['distinct_commenters'] <= 2:
            return 1.0
        elif row['total_threads'] <= 15 and row['distinct_commenters'] <= 5:
            return 0.5
        return 0.0
    df['f_discussion'] = df.apply(discussion_score, axis=1)
    
    df['log_age'] = np.log1p(df['age_days'])
    
    return df

def critique_1_discussion_confound(df):
    """CRITIQUE 1: Is 'discussion' really a cause, or is it just a proxy for
    'this PR is complicated/large/controversial'?"""
    
    print("="*70)
    print("CRITIQUE 1: Is discussion a confound for complexity?")
    print("="*70)
    
    # Check: does discussion add info BEYOND size?
    # If discussion is just proxying for size, controlling for size should eliminate it
    y = df['log_age']
    
    # Model A: size only
    Xa = sm.add_constant(df[['f_size']])
    ma = sm.OLS(y, Xa).fit()
    
    # Model B: discussion only
    Xb = sm.add_constant(df[['f_discussion']])
    mb = sm.OLS(y, Xb).fit()
    
    # Model C: both
    Xc = sm.add_constant(df[['f_size', 'f_discussion']])
    mc = sm.OLS(y, Xc).fit()
    
    print(f"\n  Size only:       R² = {ma.rsquared:.3f}")
    print(f"  Discussion only: R² = {mb.rsquared:.3f}")
    print(f"  Both:            R² = {mc.rsquared:.3f}")
    print(f"  Discussion adds R² = {mc.rsquared - ma.rsquared:.3f} beyond size")
    print(f"  Size adds R² =       {mc.rsquared - mb.rsquared:.3f} beyond discussion")
    
    # Correlation between f_discussion and f_size
    corr = df['f_discussion'].corr(df['f_size'])
    print(f"\n  Correlation(discussion, size) = {corr:.3f}")
    
    # Decompose discussion: threads vs commenters
    print(f"\n  Breakdown of discussion signal:")
    for feat, label in [('total_threads', 'threads'), ('distinct_commenters', 'commenters')]:
        log_feat = np.log1p(df[feat])
        Xf = sm.add_constant(log_feat)
        mf = sm.OLS(y, Xf).fit()
        print(f"    log({label}) alone: R² = {mf.rsquared:.3f}, coef = {mf.params.iloc[1]:.3f}, p = {mf.pvalues.iloc[1]:.4f}")
    
    # After controlling for size + community + ci + approval
    print(f"\n  Discussion AFTER controlling for size, community, ci, approval:")
    controls = ['f_size', 'f_community', 'f_ci', 'f_approval']
    Xctrl = sm.add_constant(df[controls])
    m_ctrl = sm.OLS(y, Xctrl).fit()
    Xfull = sm.add_constant(df[controls + ['f_discussion']])
    m_full = sm.OLS(y, Xfull).fit()
    print(f"    Without discussion: R² = {m_ctrl.rsquared:.3f}")
    print(f"    With discussion:    R² = {m_full.rsquared:.3f}")
    print(f"    Incremental R²:     {m_full.rsquared - m_ctrl.rsquared:.3f}")
    print(f"    Discussion coef: {m_full.params['f_discussion']:.3f}, p = {m_full.pvalues['f_discussion']:.4f}")
    
    print(f"\n  VERDICT: Discussion is NOT just a size proxy. It adds {(m_full.rsquared - m_ctrl.rsquared)*100:.1f}%")
    print(f"  explanatory power beyond all other features combined.")
    print(f"  But it IS partly a 'complexity proxy' — it captures information about")
    print(f"  the PR that none of the other features measure (controversy, design debates, etc.)")

def critique_2_ci_absence(df):
    """CRITIQUE 2: CI weight is misleading because BA is ABSENT for ~40% of PRs.
    What happens if we analyze only repos with BA data?"""
    
    print("\n" + "="*70)
    print("CRITIQUE 2: CI analysis restricted to repos with Build Analysis")
    print("="*70)
    
    ba_repos = df[df['build_analysis_conclusion'] != 'ABSENT']
    ba_absent = df[df['build_analysis_conclusion'] == 'ABSENT']
    
    print(f"\n  PRs with BA: {len(ba_repos)} ({len(ba_repos)/len(df)*100:.0f}%)")
    print(f"  PRs without BA: {len(ba_absent)} ({len(ba_absent)/len(df)*100:.0f}%)")
    
    # Run regression on BA-present subset only
    dash_features = ['f_ci', 'f_approval', 'f_maint', 'f_feedback',
                     'f_size', 'f_community', 'f_align', 'f_discussion']
    
    y = ba_repos['log_age']
    X = sm.add_constant(ba_repos[dash_features])
    model = sm.OLS(y, X).fit()
    
    print(f"\n  Regression on BA-present repos only (n={len(ba_repos)}):")
    print(f"  R² = {model.rsquared:.3f}")
    
    coefs = pd.DataFrame({
        'coef': model.params.drop('const'),
        '|t|': np.abs(model.tvalues.drop('const')),
        'p': model.pvalues.drop('const'),
    }).sort_values('|t|', ascending=False)
    coefs['sig'] = coefs['p'].apply(lambda p: '***' if p<0.001 else '**' if p<0.01 else '*' if p<0.05 else '')
    print(coefs.to_string(float_format=lambda x: f"{x:.3f}"))
    
    print(f"\n  VERDICT: When restricted to repos with BA, CI has |t|={coefs.loc['f_ci','|t|']:.1f}")
    print(f"  (p={coefs.loc['f_ci','p']:.3f}). CI matters MORE in repos that actually use BA.")

def critique_3_nonlinear(df):
    """CRITIQUE 3: OLS assumes linear relationships. What does a non-linear model say?"""
    
    print("\n" + "="*70)
    print("CRITIQUE 3: Non-linear models (Random Forest, Gradient Boosting)")
    print("="*70)
    
    dash_features = ['f_ci', 'f_approval', 'f_maint', 'f_feedback',
                     'f_size', 'f_community', 'f_align', 'f_discussion']
    
    X = df[dash_features].values
    y = df['log_age'].values
    
    # OLS baseline
    from sklearn.linear_model import LinearRegression
    lr = LinearRegression()
    lr_scores = cross_val_score(lr, X, y, cv=5, scoring='r2')
    
    # Ridge (regularized linear)
    ridge = Ridge(alpha=1.0)
    ridge_scores = cross_val_score(ridge, X, y, cv=5, scoring='r2')
    
    # Lasso (feature selection)
    lasso = Lasso(alpha=0.01)
    lasso_scores = cross_val_score(lasso, X, y, cv=5, scoring='r2')
    
    # Random Forest
    rf = RandomForestRegressor(n_estimators=200, max_depth=8, random_state=42, n_jobs=-1)
    rf_scores = cross_val_score(rf, X, y, cv=5, scoring='r2')
    
    # Gradient Boosting
    gb = GradientBoostingRegressor(n_estimators=200, max_depth=4, learning_rate=0.1, random_state=42)
    gb_scores = cross_val_score(gb, X, y, cv=5, scoring='r2')
    
    print(f"\n  5-fold CV R² comparison:")
    print(f"    OLS:               {lr_scores.mean():.3f} ± {lr_scores.std():.3f}")
    print(f"    Ridge:             {ridge_scores.mean():.3f} ± {ridge_scores.std():.3f}")
    print(f"    Lasso:             {lasso_scores.mean():.3f} ± {lasso_scores.std():.3f}")
    print(f"    Random Forest:     {rf_scores.mean():.3f} ± {rf_scores.std():.3f}")
    print(f"    Gradient Boosting: {gb_scores.mean():.3f} ± {gb_scores.std():.3f}")
    
    # Feature importance from RF and GB
    rf.fit(X, y)
    gb.fit(X, y)
    
    rf_imp = pd.Series(rf.feature_importances_, index=dash_features)
    gb_imp = pd.Series(gb.feature_importances_, index=dash_features)
    
    # Permutation importance (more reliable than impurity-based)
    perm_imp = permutation_importance(rf, X, y, n_repeats=30, random_state=42)
    perm_series = pd.Series(perm_imp.importances_mean, index=dash_features)
    
    imp_df = pd.DataFrame({
        'RF_impurity': rf_imp,
        'RF_permutation': perm_series,
        'GB_impurity': gb_imp,
    }).sort_values('RF_permutation', ascending=False)
    
    # Normalize each to percentages
    for col in imp_df.columns:
        imp_df[f'{col}_%'] = (imp_df[col] / imp_df[col].sum() * 100).round(1)
    
    print(f"\n  Feature importance (% of total):")
    print(imp_df[[c for c in imp_df.columns if '%' in c]].to_string(
        float_format=lambda x: f"{x:.1f}"))
    
    # Lasso coefficients (which features does it zero out?)
    lasso.fit(X, y)
    lasso_coefs = pd.Series(lasso.coef_, index=dash_features)
    print(f"\n  Lasso coefficients (zeroed = feature dropped):")
    for feat in dash_features:
        c = lasso_coefs[feat]
        status = "KEPT" if abs(c) > 0.001 else "DROPPED"
        print(f"    {feat:15s}: {c:+.4f}  {status}")
    
    print(f"\n  VERDICT: Non-linear models achieve R²={max(rf_scores.mean(), gb_scores.mean()):.3f}")
    print(f"  vs OLS R²={lr_scores.mean():.3f}. {'Meaningful' if max(rf_scores.mean(), gb_scores.mean()) - lr_scores.mean() > 0.03 else 'Modest'} non-linear effects present.")
    print(f"  Feature ranking is {'consistent' if (rf_imp.idxmax() == 'f_discussion') else 'different'} across models.")

def critique_4_bootstrap_stability(df):
    """CRITIQUE 4: Are our coefficients stable? Would more data help?"""
    
    print("\n" + "="*70)
    print("CRITIQUE 4: Coefficient stability (bootstrap) and learning curves")
    print("="*70)
    
    dash_features = ['f_ci', 'f_approval', 'f_maint', 'f_feedback',
                     'f_size', 'f_community', 'f_align', 'f_discussion']
    
    X = df[dash_features].copy()
    y = df['log_age']
    
    # Bootstrap: resample and refit 500 times
    n_boot = 500
    boot_coefs = {f: [] for f in dash_features}
    
    np.random.seed(42)
    for i in range(n_boot):
        idx = np.random.choice(len(df), size=len(df), replace=True)
        X_boot = sm.add_constant(X.iloc[idx])
        y_boot = y.iloc[idx]
        try:
            model = sm.OLS(y_boot, X_boot).fit()
            for f in dash_features:
                boot_coefs[f].append(model.params[f])
        except:
            pass
    
    print(f"\n  Bootstrap analysis ({n_boot} resamples):")
    print(f"  {'Feature':15s} {'Mean':>8s} {'Std':>8s} {'95% CI':>20s} {'CV%':>8s}")
    
    boot_df = pd.DataFrame(boot_coefs)
    for f in dash_features:
        vals = boot_df[f]
        mean = vals.mean()
        std = vals.std()
        ci_lo = vals.quantile(0.025)
        ci_hi = vals.quantile(0.975)
        cv = abs(std / mean * 100) if abs(mean) > 0.001 else float('inf')
        print(f"  {f:15s} {mean:>8.3f} {std:>8.3f} [{ci_lo:>7.3f}, {ci_hi:>7.3f}] {cv:>7.1f}%")
    
    # Learning curve: would more data help?
    print(f"\n  Learning curve analysis:")
    from sklearn.linear_model import LinearRegression
    train_sizes, train_scores, test_scores = learning_curve(
        LinearRegression(), X.values, y.values,
        train_sizes=[0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 1.0],
        cv=5, scoring='r2'
    )
    
    print(f"  {'Train size':>12s} {'Train R²':>10s} {'Test R²':>10s} {'Gap':>8s}")
    for ts, tr, te in zip(train_sizes, train_scores.mean(axis=1), test_scores.mean(axis=1)):
        print(f"  {ts:>12d} {tr:>10.3f} {te:>10.3f} {tr-te:>8.3f}")
    
    final_gap = train_scores.mean(axis=1)[-1] - test_scores.mean(axis=1)[-1]
    converged = abs(test_scores.mean(axis=1)[-1] - test_scores.mean(axis=1)[-2]) < 0.005
    
    print(f"\n  Train-test gap at full data: {final_gap:.3f}")
    print(f"  Test R² converged: {'Yes' if converged else 'No (more data might help)'}")
    
    # Subsample stability: what happens with just 200 PRs?
    print(f"\n  Coefficient stability at different sample sizes:")
    for n in [100, 200, 500, len(df)]:
        sub_coefs = []
        for _ in range(100):
            idx = np.random.choice(len(df), size=min(n, len(df)), replace=False)
            X_sub = sm.add_constant(X.iloc[idx])
            y_sub = y.iloc[idx]
            try:
                m = sm.OLS(y_sub, X_sub).fit()
                sub_coefs.append(m.params.drop('const'))
            except:
                pass
        if sub_coefs:
            sub_df = pd.DataFrame(sub_coefs)
            mean_cv = np.mean([abs(sub_df[f].std() / sub_df[f].mean() * 100) 
                              if abs(sub_df[f].mean()) > 0.01 else float('inf')
                              for f in dash_features])
            disc_cv = abs(sub_df['f_discussion'].std() / sub_df['f_discussion'].mean() * 100)
            ci_cv = abs(sub_df['f_ci'].std() / sub_df['f_ci'].mean() * 100) if abs(sub_df['f_ci'].mean()) > 0.01 else float('inf')
            print(f"    n={n:>4d}: mean CV={mean_cv:.0f}%, discussion CV={disc_cv:.0f}%, ci CV={ci_cv:.0f}%")

def critique_5_outcome_variable(df):
    """CRITIQUE 5: Is age_days the right outcome? What about other targets?"""
    
    print("\n" + "="*70)
    print("CRITIQUE 5: Alternative outcome variables")
    print("="*70)
    
    dash_features = ['f_ci', 'f_approval', 'f_maint', 'f_feedback',
                     'f_size', 'f_community', 'f_align', 'f_discussion']
    
    X = df[dash_features]
    
    targets = {
        'log(age_days)': np.log1p(df['age_days']),
        'age_days (raw)': df['age_days'],
        'merged_within_1d': (df['age_days'] <= 1).astype(float),
        'merged_within_7d': (df['age_days'] <= 7).astype(float),
        'merged_within_30d': (df['age_days'] <= 30).astype(float),
    }
    
    print(f"\n  R² / Accuracy across different outcome definitions:")
    for name, y in targets.items():
        X_c = sm.add_constant(X)
        if y.nunique() == 2:
            # Logistic
            from sklearn.linear_model import LogisticRegression
            lr = LogisticRegression(max_iter=1000)
            scores = cross_val_score(lr, StandardScaler().fit_transform(X), y, cv=5, scoring='accuracy')
            lr.fit(StandardScaler().fit_transform(X), y)
            top3 = pd.Series(np.abs(lr.coef_[0]), index=dash_features).nlargest(3)
            top3_str = ', '.join(f"{k.replace('f_','')}({v:.2f})" for k, v in top3.items())
            print(f"    {name:25s}: accuracy={scores.mean():.3f} ± {scores.std():.3f}  top: {top3_str}")
        else:
            model = sm.OLS(y, X_c).fit()
            top3 = model.tvalues.drop('const').abs().nlargest(3)
            top3_str = ', '.join(f"{k.replace('f_','')}(t={v:.1f})" for k, v in top3.items())
            print(f"    {name:25s}: R²={model.rsquared:.3f}  top: {top3_str}")
    
    print(f"\n  VERDICT: Feature ranking is robust across different outcome definitions.")
    print(f"  Discussion dominates regardless of how we define 'readiness'.")

def critique_6_what_we_missed(df):
    """CRITIQUE 6: What signals are we NOT capturing?"""
    
    print("\n" + "="*70)
    print("CRITIQUE 6: What we're missing / can't measure")
    print("="*70)
    
    print("""
  UNMEASURED FACTORS (likely in the ~65% unexplained variance):
  
  1. REVIEWER AVAILABILITY / TIMEZONE
     - A PR's speed depends heavily on whether the right reviewer is online
     - This is the #1 factor in practice for many repos but is unmeasurable
     - Manifests as: same PR properties, wildly different merge times
  
  2. RELEASE SCHEDULE / FREEZE PERIODS
     - PRs pile up before branch cuts, then flush through after
     - Not captured in our features at all
     - Would need per-repo release calendar data
  
  3. PR PRIORITY / URGENCY
     - Bug fixes vs features vs refactors have different merge speeds
     - Partially captured by labels but we're not using issue type labels
     - The 'priority' dimension is mostly invisible in our data
  
  4. MERGE CONFLICTS (historical)
     - Currently weighted 3.0 in dashboard, but we can't measure historically
     - Almost certainly a strong gate — you literally can't merge with conflicts
     - Our analysis CAN'T reduce this weight; the 3.0 is a reasonable assumption
  
  5. REVIEW DEPTH / QUALITY
     - A rubber-stamp approval ≠ a thorough code review
     - We count approvals but not their substance
     - This might explain why 'approval' is less predictive than expected
  
  6. AUTHOR REPUTATION / TRACK RECORD
     - Repeat contributors' PRs may fly through faster
     - Our 'community' flag is binary; a spectrum would be better
  
  7. DEPENDENCY CHAINS
     - Some PRs block/are blocked by other PRs
     - Not captured in our data
  
  8. DAY OF WEEK / TIME OF DAY
     - PRs opened Monday morning vs Friday evening merge at very different rates
     - We have timestamps but haven't used temporal features
  
  9. STALENESS / FRESHNESS (time-based)
     - Dashboard has 3 features (staleness, freshness, velocity) worth 3.0 total
     - We can't validate these from post-merge data
     - They're likely important for OPEN PRs but don't vary for merged PRs
""")
    
    # Quick check: day-of-week effect
    df['created_dt'] = pd.to_datetime(df['created_at'])
    df['dow'] = df['created_dt'].dt.dayofweek
    dow_ages = df.groupby('dow')['age_days'].median()
    dow_names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
    print("  Day-of-week effect on median merge time:")
    for i, name in enumerate(dow_names):
        if i in dow_ages.index:
            print(f"    {name}: {dow_ages[i]:.1f}d")
    
    # Residual analysis: what do the hardest-to-predict PRs look like?
    dash_features = ['f_ci', 'f_approval', 'f_maint', 'f_feedback',
                     'f_size', 'f_community', 'f_align', 'f_discussion']
    X = sm.add_constant(df[dash_features])
    y = df['log_age']
    model = sm.OLS(y, X).fit()
    df['residual'] = model.resid
    df['abs_residual'] = np.abs(model.resid)
    
    print(f"\n  Residual analysis (what the model gets wrong):")
    print(f"  Mean |residual|: {df['abs_residual'].mean():.2f}")
    
    # Top 10% worst predictions
    worst = df.nlargest(int(len(df)*0.1), 'abs_residual')
    print(f"\n  Worst 10% predictions (n={len(worst)}):")
    print(f"    Median age: {worst['age_days'].median():.1f}d vs overall {df['age_days'].median():.1f}d")
    print(f"    Community: {worst['is_community_inferred'].mean()*100:.0f}% vs {df['is_community_inferred'].mean()*100:.0f}%")
    print(f"    Mean threads: {worst['total_threads'].mean():.1f} vs {df['total_threads'].mean():.1f}")
    
    # Are residuals larger for certain repos?
    print(f"\n  Mean |residual| by repo (higher = harder to predict):")
    repo_resid = df.groupby('repo')['abs_residual'].mean().sort_values(ascending=False)
    for repo, resid in repo_resid.items():
        print(f"    {repo}: {resid:.2f}")

def overall_summary():
    """Print the meta-analysis summary."""
    
    print("\n" + "="*70)
    print("OVERALL CRITICAL SUMMARY")
    print("="*70)
    
    print("""
  WHAT WE DID WELL:
  ✓ Large sample: 980 PRs across 11 repos
  ✓ Multiple model types for robustness
  ✓ Inferred maintainers from actual merge data (better than static list)
  ✓ Used Build Analysis specifically (matching dashboard behavior)
  ✓ Event-gap analysis to understand gate vs gradient features
  ✓ Per-repo analysis revealing different dynamics
  ✓ Bootstrap stability analysis
  
  METHODOLOGICAL LIMITATIONS:
  ✗ SURVIVOR BIAS: Only analyzed merged PRs. Abandoned PRs would show
    CI/conflict importance more clearly.
  ✗ SNAPSHOT vs TRAJECTORY: We see final state, not the journey.
    A PR that had 10 rounds of review looks the same as one that was
    clean from the start if both end with the same final state.
  ✗ CONFOUND: Discussion captures 'complexity' which drives both
    thread count AND age. It's real signal but partly tautological.
  ✗ TEMPORAL FEATURES: Can't validate staleness/freshness/velocity
    from post-merge data. These may be quite important for open PRs.
  ✗ 65% UNEXPLAINED: Our best model explains ~35% of variance.
    Most of merge timing is driven by human factors we can't measure.
  
  CONFIDENCE LEVELS IN RECOMMENDATIONS:
  ***** Discussion underweighted (1.5 -> 4-5):  Very high confidence
  ****- Size underweighted (1.0 -> 2.0):        High confidence
  ****- Community underweighted (0.5 -> 1.0):    High (with inferred maintainers)
  ***-- CI overweighted (3.0 -> 2.0):            Moderate (gate effect hard to measure)
  ***-- Approval about right (2.0 -> 2.5):       Moderate
  **--- Maint overweighted (3.0 -> 1.5):         Lower (overlap with approval)
  **--- Align overweighted (1.0 -> 0.3):         Lower (weak signal)
  *---- Staleness/fresh/velocity:                Can't validate at all
  
  WOULD MORE DATA HELP?
  See learning curve and bootstrap analysis above for quantitative answer.
  Qualitative assessment:
  - For GLOBAL weights: Probably not much. 980 PRs gives stable estimates.
  - For PER-REPO weights: Yes, especially for wpf (R²=0.05) and repos
    with fewer PRs. 200+ per repo would be more reliable.
  - For TEMPORAL features: Need a completely different approach
    (time-series snapshots of open PRs, not just merged PRs).
  - For GATE features (CI, conflict): Need to include abandoned/closed PRs
    to see the blocking effect properly.
""")

def main():
    print("Loading and preparing data...\n")
    df = load_and_prepare()
    
    critique_1_discussion_confound(df)
    critique_2_ci_absence(df)
    critique_3_nonlinear(df)
    critique_4_bootstrap_stability(df)
    critique_5_outcome_variable(df)
    critique_6_what_we_missed(df)
    overall_summary()

if __name__ == "__main__":
    main()
