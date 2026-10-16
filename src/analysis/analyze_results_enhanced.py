#!/usr/bin/env python3
"""
Robust statistical analysis script for the Docker vs Apple container benchmark
Statistical analysis with methodological rigor
"""

import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
from scipy import stats
from scipy.stats import mannwhitneyu, kruskal, levene, shapiro, normaltest, anderson
from statsmodels.stats.multitest import multipletests
from statsmodels.stats.power import TTestIndPower, TTestPower
# from statsmodels.stats.contingency import chi2_contingency  # Not needed for this analysis
import argparse
import os
import sys
from pathlib import Path
import warnings
import logging
from typing import Dict, Any, Optional, Tuple, List
warnings.filterwarnings('ignore')

# Import sample size analysis function (Raj Jain)
# The import is done dynamically in validate_methodological_rigor
# to avoid problems if the module is not available
JAIN_ANALYSIS_AVAILABLE = None  # Will be set on the first call

# Basic logging configuration (will be reconfigured in main with the output directory)
# By default, do not send logs to stdout (file only)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[]  # No handlers by default - configured in setup_logging
)
logger = logging.getLogger(__name__)

def setup_logging(output_dir, quiet=False):
    """Configure logging with a file in the output directory
    
    Args:
        output_dir: Directory where the log file is saved
        quiet: If True, do not send logs to stdout (file only)
    """
    log_file = os.path.join(output_dir, 'analysis.log')
    file_handler = logging.FileHandler(log_file, encoding='utf-8')
    file_handler.setLevel(logging.DEBUG)
    file_formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
    file_handler.setFormatter(file_formatter)
    logger.addHandler(file_handler)
    
    # Only add the stdout handler if not in quiet mode
    if not quiet:
        stdout_handler = logging.StreamHandler(sys.stdout)
        stdout_handler.setLevel(logging.WARNING)  # Only warnings and errors on stdout
        stdout_handler.setFormatter(logging.Formatter('%(levelname)s: %(message)s'))
        logger.addHandler(stdout_handler)
    
    logger.info(f"Logging configured. Log file: {log_file}")

def load_data(base_dir, quiet=False):
    """Load all result CSVs
    
    Args:
        base_dir: Base directory containing the CSVs
        quiet: If True, do not print loading messages
    """
    data = {}
    
    csv_files = {
        'main': 'results_main.csv',
        'sysbench': 'results_sysbench.csv', 
        'fs': 'results_fs.csv',
        'wrk': 'results_wrk.csv',
        'fio': 'results_fio.csv',
        'stream': 'results_stream.csv',
        'math': 'results_math.csv'
    }
    
    for key, filename in csv_files.items():
        filepath = os.path.join(base_dir, filename)
        if os.path.exists(filepath):
            try:
                data[key] = pd.read_csv(filepath)
                # Normalize historical vs current schemas to avoid breaking the analysis.
                # run_experiment.sh (historical) uses different columns in sysbench and wrk.
                if key == 'sysbench' and 'test' not in data[key].columns and 'test_type' in data[key].columns:
                    data[key] = data[key].rename(columns={'test_type': 'test'})
                if key == 'wrk':
                    if 'test' not in data[key].columns and 'url' in data[key].columns:
                        # For per-scenario analysis, treat the URL as "test".
                        data[key] = data[key].rename(columns={'url': 'test'})
                    # Ensure columns expected by some reports/plots
                    if 'threads' not in data[key].columns:
                        data[key]['threads'] = np.nan
                    if 'connections' not in data[key].columns:
                        data[key]['connections'] = np.nan
                logger.info(f"Loaded {filename}: {len(data[key])} records")
                if not quiet:
                    print(f"✓ Loaded {filename}: {len(data[key])} records")
            except pd.errors.EmptyDataError:
                logger.warning(f"File {filename} is empty")
                if not quiet:
                    print(f"⚠ Empty file: {filename}")
            except pd.errors.ParserError as e:
                logger.error(f"Error parsing file {filename}: {e}")
                if not quiet:
                    print(f"⚠ Error reading {filename}: corrupted file or invalid format")
            except PermissionError as e:
                logger.error(f"No permission to read file {filename}: {e}")
                if not quiet:
                    print(f"⚠ No permission to read {filename}")
            except Exception as e:
                logger.error(f"Unexpected error loading {filename}: {type(e).__name__}: {e}", exc_info=True)
                if not quiet:
                    print(f"⚠ Error loading {filename}: {e}")
        else:
            logger.debug(f"File not found: {filename} (expected at {filepath})")
            if not quiet:
                print(f"⚠ File not found: {filename}")
    
    return data

def validate_methodological_rigor(data, min_iterations=30, min_valid=25, compact=False, 
                                   desired_precision_percent=5.0, confidence_level=0.95):
    """
    Validate the methodological rigor of the collected data
    Checks sample size, data quality, and statistical power
    
    Uses Raj Jain's methodology (Ch. 13) to dynamically compute the required
    number of replications based on data variability.
    
    Args:
        data: Dictionary of DataFrames with the data
        min_iterations: Minimum recommended number of iterations (fallback if Jain is not available)
        min_valid: Minimum acceptable number of iterations (fallback if Jain is not available)
        compact: If True, show only a compact summary
        desired_precision_percent: Desired relative precision in % (default: 5.0%)
        confidence_level: Confidence level (default: 0.95 = 95%)
    """
    global JAIN_ANALYSIS_AVAILABLE
    
    # Try to import the Jain function on the first call
    if JAIN_ANALYSIS_AVAILABLE is None:
        try:
            # Try to import from the same directory
            import sys
            import os
            current_dir = os.path.dirname(os.path.abspath(__file__))
            if current_dir not in sys.path:
                sys.path.insert(0, current_dir)
            from sample_size_analysis import calculate_required_replications
            JAIN_ANALYSIS_AVAILABLE = True
            # Store the function globally for reuse
            validate_methodological_rigor._calculate_required_replications = calculate_required_replications
        except ImportError:
            JAIN_ANALYSIS_AVAILABLE = False
            logger.debug("Module sample_size_analysis not available. Using default values for validation.")
    
    if not compact:
        print("\n" + "="*70)
        print("🔬 METHODOLOGICAL RIGOR VALIDATION")
        print("="*70)
    
    issues = []
    warnings = []
    
    # Rigor settings
    MIN_ITERATIONS_RECOMMENDED = min_iterations  # Fallback if Jain is not available
    MIN_ITERATIONS_ACCEPTABLE = min_valid  # Fallback if Jain is not available
    MAX_CV_PERCENT = 10.0  # Maximum recommended coefficient of variation
    MAX_OUTLIER_PERCENT = 20.0  # Maximum percentage of outliers
    
    # Store Jain analysis results for the summary
    jain_results = []
    
    # Validate each dataset
    for data_key, df in data.items():
        if df.empty:
            continue
        
        if not compact:
            print(f"\n📊 Analyzing: {data_key}")
        
        # Determine grouping and metric columns
        if 'tool' in df.columns and 'scenario' in df.columns:
            group_cols = ['tool', 'scenario']
            metric_col = 'value' if 'value' in df.columns else df.select_dtypes(include=[np.number]).columns[0]
        elif 'tool' in df.columns and 'test' in df.columns:
            group_cols = ['tool', 'test']
            metric_col = 'value' if 'value' in df.columns else df.select_dtypes(include=[np.number]).columns[0]
        else:
            # Try to identify grouping columns
            if 'tool' in df.columns:
                group_cols = ['tool']
                metric_col = 'value' if 'value' in df.columns else df.select_dtypes(include=[np.number]).columns[0]
            else:
                if not compact:
                    print(f"   ⚠️  Unrecognized data structure, skipping validation")
                continue

        # If there are multiple thread levels, they define distinct scenarios (e.g., sysbench 1t vs 2t, STREAM Copy 1t vs 2t).
        # Grouping without threads mixes different workloads and distorts the validation.
        # Likewise, if there are multiple metrics (e.g., math has time_seconds and throughput_digits_per_sec),
        # mixing them produces groups with incompatible units.
        try:
            if 'threads' in df.columns and 'threads' not in group_cols:
                threads_unique = df['threads'].dropna().unique()
                if len(threads_unique) > 1:
                    group_cols = group_cols + ['threads']
            if 'metric' in df.columns and 'metric' not in group_cols:
                metrics_unique = df['metric'].dropna().unique()
                if len(metrics_unique) > 1:
                    group_cols = group_cols + ['metric']
        except Exception:
            pass
        
        # Validate each group
        for group_name, group_df in df.groupby(group_cols):
            values = pd.to_numeric(group_df[metric_col], errors='coerce')
            values = values.dropna()
            
            if len(values) == 0:
                continue
            
            n = len(values)
            runtime = group_name[0] if isinstance(group_name, tuple) else group_name
            scenario = group_name[1] if isinstance(group_name, tuple) and len(group_name) > 1 else "N/A"
            
            if not compact:
                print(f"\n   🔬 {runtime} - {scenario}:")
                print(f"      Iterations: {n}")
            
            # 1. Validate sample size using Raj Jain's methodology (if available)
            required_n = None
            jain_sufficient = None
            
            if JAIN_ANALYSIS_AVAILABLE and n >= 2:
                # Compute the required number using Jain's methodology
                try:
                    calculate_required_replications = validate_methodological_rigor._calculate_required_replications
                    jain_result = calculate_required_replications(
                        values,
                        desired_precision_percent=desired_precision_percent,
                        confidence_level=confidence_level,
                        use_t_distribution=True
                    )
                    
                    if 'error' not in jain_result:
                        required_n = jain_result['required_replications']
                        jain_sufficient = jain_result['sufficient']
                        
                        # Store for the summary
                        jain_results.append({
                            'data_key': data_key,
                            'runtime': runtime,
                            'scenario': scenario,
                            'current_n': n,
                            'required_n': required_n,
                            'sufficient': jain_sufficient,
                            'cv': jain_result.get('sample_cv', np.nan),
                            'margin_error_percent': jain_result.get('margin_of_error_percent', np.nan)
                        })
                        
                        if not compact:
                            print(f"      📊 Jain (Raj Jain, Cap. 13):")
                            print(f"         Required: {required_n} iterations (precision ±{desired_precision_percent}%, confidence {confidence_level*100:.0f}%)")
                            print(f"         Current margin of error: ±{jain_result.get('margin_of_error_percent', np.nan):.2f}%")
                        
                        # Validate using the value computed by Jain
                        if not jain_sufficient:
                            issues.append(f"{data_key} - {runtime} {scenario}: {n} iterations (Jain requires at least {required_n} for precision ±{desired_precision_percent}%)")
                            if not compact:
                                print(f"      ⚠️  {n} iterations insufficient (Jain requires at least {required_n})")
                        elif n < MIN_ITERATIONS_RECOMMENDED:
                            warnings.append(f"{data_key} - {runtime} {scenario}: {n} iterations (Jain OK, but below the general recommendation: {MIN_ITERATIONS_RECOMMENDED})")
                            if not compact:
                                print(f"      ⚠️  {n} iterations below the general recommendation ({MIN_ITERATIONS_RECOMMENDED})")
                                print(f"      ✅ Sufficient according to Jain (≥ {required_n})")
                        else:
                            if not compact:
                                print(f"      ✅ Adequate sample size (≥ {required_n} per Jain, ≥ {MIN_ITERATIONS_RECOMMENDED} general)")
                    else:
                        # Error in the Jain calculation, use fallback
                        logger.debug(f"Error in Jain calculation for {data_key} - {runtime} {scenario}: {jain_result.get('error')}")
                        required_n = None
                except Exception as e:
                    logger.warning(f"Error computing required replications (Jain) for {data_key} - {runtime} {scenario}: {e}")
                    required_n = None
            
            # Fallback: use fixed values if Jain is unavailable or failed
            if required_n is None:
                if n < MIN_ITERATIONS_ACCEPTABLE:
                    issues.append(f"{data_key} - {runtime} {scenario}: {n} iterations (below the recommended minimum: {MIN_ITERATIONS_ACCEPTABLE})")
                    if not compact:
                        print(f"      ⚠️  {n} iterations below the recommended minimum (< {MIN_ITERATIONS_ACCEPTABLE})")
                elif n < MIN_ITERATIONS_RECOMMENDED:
                    warnings.append(f"{data_key} - {runtime} {scenario}: {n} iterations (below the ideal: {MIN_ITERATIONS_RECOMMENDED})")
                    if not compact:
                        print(f"      ⚠️  {n} iterations below the ideal ({MIN_ITERATIONS_RECOMMENDED})")
                        print(f"      ✅ Acceptable for exploratory analysis (≥ {MIN_ITERATIONS_ACCEPTABLE})")
                else:
                    if not compact:
                        print(f"      ✅ Adequate sample size (≥ {MIN_ITERATIONS_RECOMMENDED})")
            
            # 2. Validate data quality
            mean = np.mean(values)
            std = np.std(values, ddof=1)
            cv = (std / mean * 100) if mean > 0 else np.inf
            
            # Detect outliers using IQR
            q1 = np.percentile(values, 25)
            q3 = np.percentile(values, 75)
            iqr = q3 - q1
            lower_bound = q1 - 1.5 * iqr
            upper_bound = q3 + 1.5 * iqr
            outliers = values[(values < lower_bound) | (values > upper_bound)]
            outlier_percent = (len(outliers) / n) * 100 if n > 0 else 0
            
            if not compact:
                print(f"      CV: {cv:.2f}%")
                print(f"      Outliers: {len(outliers)}/{n} ({outlier_percent:.1f}%)")
            
            if cv > MAX_CV_PERCENT:
                warnings.append(f"{data_key} - {runtime} {scenario}: High variability (CV={cv:.2f}%)")
                if not compact:
                    print(f"      ⚠️  High variability (CV > {MAX_CV_PERCENT}%)")
            
            if outlier_percent > MAX_OUTLIER_PERCENT:
                warnings.append(f"{data_key} - {runtime} {scenario}: Many outliers ({outlier_percent:.1f}%)")
                if not compact:
                    print(f"      ⚠️  Many outliers ({outlier_percent:.1f}% > {MAX_OUTLIER_PERCENT}%)")
    
    # Summary and recommendations (informational only)
    if not compact:
        print("\n" + "="*70)
        print("📋 METHODOLOGICAL RIGOR ASSESSMENT SUMMARY")
        print("="*70)
        print("(Informational assessment - does not prevent the statistical analysis)\n")
    
    if len(issues) == 0 and len(warnings) == 0:
        print("✅ DATA MEET METHODOLOGICAL RIGOR")
        print("   - Adequate sample size")
        print("   - Acceptable data quality")
    else:
        if len(issues) > 0:
            print(f"\n⚠️  POINTS OF ATTENTION ({len(issues)}):")
            for issue in issues[:5]:  # Show only the first 5
                print(f"   - {issue}")
            if len(issues) > 5:
                print(f"   ... and {len(issues) - 5} more")
            print("   RECOMMENDATION: For full methodological rigor, run with 30 iterations")
        
        if len(warnings) > 0:
            print(f"\n💡 RECOMMENDATIONS ({len(warnings)}):")
            for warning in warnings[:5]:  # Show only the first 5
                print(f"   - {warning}")
            if len(warnings) > 5:
                print(f"   ... and {len(warnings) - 5} more recommendations")
            print("   RECOMMENDATION: For full methodological rigor, run with 30 iterations")
    
    print("\n" + "="*70)
    print("📋 REQUIREMENTS FOR METHODOLOGICAL RIGOR")
    print("="*70)
    
    if JAIN_ANALYSIS_AVAILABLE and jain_results:
        print(f"✅ Methodology: Raj Jain (Ch. 13) - Dynamic calculation based on variability")
        print(f"✅ Desired precision: ±{desired_precision_percent}% of the mean")
        print(f"✅ Confidence level: {confidence_level*100:.0f}%")
        
        # Summary of Jain results
        insufficient_jain = [r for r in jain_results if not r['sufficient']]
        if insufficient_jain:
            print(f"\n⚠️  {len(insufficient_jain)} scenario(s) with insufficient n according to Jain:")
            for r in insufficient_jain[:5]:
                print(f"   - {r['data_key']} - {r['runtime']} {r['scenario']}: n={r['current_n']} (requires {r['required_n']})")
            if len(insufficient_jain) > 5:
                print(f"   ... and {len(insufficient_jain) - 5} more scenarios")
        
        # Overall statistics
        if jain_results:
            avg_required = np.mean([r['required_n'] for r in jain_results])
            max_required = max([r['required_n'] for r in jain_results])
            print(f"\n📊 Statistics (Jain):")
            print(f"   - Mean required n: {avg_required:.1f}")
            print(f"   - Maximum required n: {max_required}")
    else:
        print(f"✅ Recommended minimum: {MIN_ITERATIONS_RECOMMENDED} iterations per scenario")
        print(f"✅ Acceptable minimum: {MIN_ITERATIONS_ACCEPTABLE} valid iterations per scenario")
        if not JAIN_ANALYSIS_AVAILABLE:
            print("⚠️  Jain analysis not available - using fixed values")
    
    print("✅ For robust statistical tests: n ≥ 20 per group")
    print("✅ For power analysis: n ≥ 30 per group")
    print(f"✅ Coefficient of variation: CV < {MAX_CV_PERCENT}% indicates good stability")
    print(f"✅ Outliers: < {MAX_OUTLIER_PERCENT}% of the sample")
    print("="*70 + "\n")
    
    return {
        'issues': issues,
        'warnings': warnings,
        'status': 'PASS' if len(issues) == 0 else 'FAIL',
        'ready_for_analysis': len(issues) == 0,
        'jain_results': jain_results if JAIN_ANALYSIS_AVAILABLE else [],
        'jain_available': JAIN_ANALYSIS_AVAILABLE
    }

def calculate_enhanced_statistics(df, metric_col='value', group_cols=['tool', 'scenario'], alpha=0.05):
    """Compute robust descriptive statistics"""
    def calc_iqr(x):
        return np.percentile(x, 75) - np.percentile(x, 25)
    
    stats_df = df.groupby(group_cols)[metric_col].agg([
        'count', 'mean', 'median', 'std', 'min', 'max',
        lambda x: np.percentile(x, 25),  # Q1
        lambda x: np.percentile(x, 75),  # Q3
        calc_iqr,                         # IQR (Q3 - Q1)
        lambda x: np.percentile(x, 5),   # P5
        lambda x: np.percentile(x, 95),  # P95
        lambda x: stats.skew(x),         # Skewness
        lambda x: stats.kurtosis(x)      # Kurtosis
    ]).round(4)
    
    stats_df.columns = ['count', 'mean', 'median', 'std', 'min', 'max', 'q25', 'q75', 'iqr', 'p5', 'p95', 'skew', 'kurtosis']
    
    # Compute confidence intervals (consistent with alpha)
    confidence_level = 1.0 - float(alpha)
    if not (0.0 < confidence_level < 1.0):
        confidence_level = 0.95

    def ci_95(x):
        if len(x) > 1:
            return stats.t.interval(confidence_level, len(x)-1, loc=np.mean(x), scale=stats.sem(x))
        return (np.nan, np.nan)
    
    ci_df = df.groupby(group_cols)[metric_col].apply(ci_95).apply(pd.Series)
    ci_df.columns = ['ci_lower', 'ci_upper']
    ci_df = ci_df.round(4)
    
    return stats_df, ci_df

def test_normality_robust(data, alpha=0.05):
    """Test normality with multiple tests"""
    results = {}
    
    if len(data) < 3:
        return {'shapiro': 'N/A', 'normaltest': 'N/A', 'anderson': 'N/A', 'conclusion': 'Insufficient data'}
    
    # Shapiro-Wilk test (for n <= 5000)
    if len(data) <= 5000:
        shapiro_stat, shapiro_p = shapiro(data)
        results['shapiro'] = {'statistic': shapiro_stat, 'p_value': shapiro_p, 'normal': shapiro_p > alpha}
    else:
        results['shapiro'] = 'N/A (n > 5000)'
    
    # D'Agostino test (for n >= 8)
    if len(data) >= 8:
        normaltest_stat, normaltest_p = normaltest(data)
        results['normaltest'] = {'statistic': normaltest_stat, 'p_value': normaltest_p, 'normal': normaltest_p > alpha}
    else:
        results['normaltest'] = 'N/A (n < 8)'
    
    # Anderson-Darling test
    try:
        anderson_stat, anderson_critical, anderson_significance = anderson(data, dist='norm')
        # anderson_significance is in % (typically [15, 10, 5, 2.5, 1]).
        target = float(alpha) * 100.0
        # choose the closest available level
        idx = int(np.argmin(np.abs(np.array(anderson_significance) - target)))
        anderson_normal = anderson_stat < anderson_critical[idx]
        results['anderson'] = {
            'statistic': anderson_stat,
            'critical': anderson_critical[idx],
            'significance_level_percent': anderson_significance[idx],
            'normal': anderson_normal
        }
    except ValueError as e:
        logger.warning(f"Error in Anderson-Darling test (insufficient or invalid data): {e}")
        results['anderson'] = 'N/A'
    except Exception as e:
        logger.error(f"Unexpected error in Anderson-Darling test: {type(e).__name__}: {e}", exc_info=True)
        results['anderson'] = 'N/A'
    
    # Conclusion based on the majority of tests
    normal_tests = [v for v in results.values() if isinstance(v, dict) and 'normal' in v]
    if normal_tests:
        normal_count = sum(1 for test in normal_tests if test['normal'])
        results['conclusion'] = 'Normal' if normal_count > len(normal_tests)/2 else 'Non-normal'
    else:
        results['conclusion'] = 'Inconclusive'
    
    return results

def test_homogeneity_variance(data1, data2, alpha=0.05):
    """Test homogeneity of variances (Levene's test)"""
    if len(data1) < 2 or len(data2) < 2:
        return {'statistic': np.nan, 'p_value': np.nan, 'homogeneous': 'N/A'}
    
    try:
        levene_stat, levene_p = levene(data1, data2)
        return {
            'statistic': levene_stat,
            'p_value': levene_p,
            'homogeneous': levene_p > alpha
        }
    except ValueError as e:
        logger.warning(f"Error in Levene test (insufficient data or zero variance): {e}")
        return {'statistic': np.nan, 'p_value': np.nan, 'homogeneous': 'N/A'}
    except Exception as e:
        logger.error(f"Unexpected error in Levene test: {type(e).__name__}: {e}", exc_info=True)
        return {'statistic': np.nan, 'p_value': np.nan, 'homogeneous': 'N/A'}

def calculate_effect_size(data1, data2):
    """Compute effect size (Cohen's d)"""
    if len(data1) < 2 or len(data2) < 2:
        return np.nan
    
    # Cohen's d
    pooled_std = np.sqrt(((len(data1) - 1) * np.var(data1, ddof=1) + 
                         (len(data2) - 1) * np.var(data2, ddof=1)) / 
                        (len(data1) + len(data2) - 2))
    
    if pooled_std == 0:
        return np.nan
    
    cohens_d = (np.mean(data1) - np.mean(data2)) / pooled_std
    
    # Effect size interpretation
    if abs(cohens_d) < 0.2:
        effect_interpretation = "Negligible"
    elif abs(cohens_d) < 0.5:
        effect_interpretation = "Small"
    elif abs(cohens_d) < 0.8:
        effect_interpretation = "Medium"
    else:
        effect_interpretation = "Large"
    
    return {
        'cohens_d': cohens_d,
        'interpretation': effect_interpretation
    }

def calculate_statistical_power(data1, data2, alpha=0.05, effect_size=None, test_type='two_sample'):
    """Compute statistical power"""
    if len(data1) < 2 or len(data2) < 2:
        return {'power': np.nan, 'interpretation': 'N/A'}
    
    n1, n2 = len(data1), len(data2)
    
    if effect_size is None:
        effect_size = calculate_effect_size(data1, data2)['cohens_d']
    
    if np.isnan(effect_size):
        return {'power': np.nan, 'interpretation': 'N/A'}
    
    # Statistical power: use the correct class for the test type
    if test_type == 'paired':
        power = TTestPower().power(effect_size=abs(effect_size), nobs=min(n1, n2), alpha=alpha, alternative='two-sided')
    else:
        ratio = (n2 / n1) if n1 > 0 else 1.0
        power = TTestIndPower().power(effect_size=abs(effect_size), nobs1=n1, alpha=alpha, ratio=ratio, alternative='two-sided')

    # Numerical robustness: some combinations (e.g., very high effect_size) may return NaN.
    # In these cases, treat power as ~1 (very high), since the effect is huge.
    if isinstance(power, (float, np.floating)) and np.isnan(power):
        if abs(effect_size) >= 2.0:
            power = 1.0
    
    # Power interpretation
    if power < 0.5:
        power_interpretation = "Low"
    elif power < 0.8:
        power_interpretation = "Moderate"
    else:
        power_interpretation = "High"
    
    return {
        'power': power,
        'interpretation': power_interpretation
    }

def perform_robust_statistical_tests(df, metric_col='value', tool_col='tool', scenario_col='scenario', alpha=0.05):
    """Run robust statistical tests"""
    results = []
    
    scenarios = df[scenario_col].unique()
    
    for scenario in scenarios:
        scenario_data = df[df[scenario_col] == scenario]
        
        docker_data = scenario_data[scenario_data[tool_col] == 'docker'][metric_col].values
        container_data = scenario_data[scenario_data[tool_col] == 'container'][metric_col].values
        
        if len(docker_data) > 1 and len(container_data) > 1:
            # Normality tests
            docker_normality = test_normality_robust(docker_data, alpha=alpha)
            container_normality = test_normality_robust(container_data, alpha=alpha)
            
            # Homogeneity of variances test
            homogeneity = test_homogeneity_variance(docker_data, container_data, alpha=alpha)
            
            # Choose the appropriate test based on normality
            both_normal = (docker_normality['conclusion'] == 'Normal' and 
                          container_normality['conclusion'] == 'Normal')
            
            if both_normal and homogeneity['homogeneous']:
                # Independent samples t-test
                test_stat, test_p = stats.ttest_ind(docker_data, container_data)
                test_used = "Independent t-test"
            elif both_normal and not homogeneity['homogeneous']:
                # Welch's t-test
                test_stat, test_p = stats.ttest_ind(docker_data, container_data, equal_var=False)
                test_used = "Welch's t-test"
            else:
                # Mann-Whitney U test (non-parametric)
                u_stat, u_p = mannwhitneyu(docker_data, container_data, alternative='two-sided')
                test_stat, test_p = u_stat, u_p
                test_used = "Mann-Whitney U test"
            
            # Effect size
            effect_size = calculate_effect_size(docker_data, container_data)
            
            # Statistical power
            power = calculate_statistical_power(
                docker_data,
                container_data,
                alpha=alpha,
                effect_size=effect_size['cohens_d'],
                test_type='two_sample'
            )
            
            results.append({
                'scenario': scenario,
                'docker_n': len(docker_data),
                'container_n': len(container_data),
                'docker_mean': np.mean(docker_data),
                'container_mean': np.mean(container_data),
                'docker_std': np.std(docker_data, ddof=1),
                'container_std': np.std(container_data, ddof=1),
                'docker_median': np.median(docker_data),
                'container_median': np.median(container_data),
                'test_used': test_used,
                'test_statistic': test_stat,
                'p_value': test_p,
                'significant_uncorrected': test_p < alpha,
                'docker_normal': docker_normality['conclusion'],
                'container_normal': container_normality['conclusion'],
                'homogeneous_var': homogeneity['homogeneous'],
                'effect_size': effect_size['cohens_d'],
                'effect_interpretation': effect_size['interpretation'],
                'statistical_power': power['power'],
                'power_interpretation': power['interpretation']
            })
    
    return pd.DataFrame(results)

def apply_multiple_comparison_correction(results_df, method='bonferroni', alpha=0.05):
    """Apply multiple comparison correction"""
    if results_df.empty:
        return results_df
    
    # Extract p-values
    p_values = results_df['p_value'].values
    
    # Apply correction
    if method == 'bonferroni':
        corrected_p = multipletests(p_values, method='bonferroni')[1]
    elif method == 'fdr_bh':
        corrected_p = multipletests(p_values, method='fdr_bh')[1]
    elif method == 'holm':
        corrected_p = multipletests(p_values, method='holm')[1]
    else:
        corrected_p = p_values
    
    # Add corrected columns
    results_df[f'p_value_{method}'] = corrected_p
    results_df[f'significant_{method}'] = corrected_p < alpha
    
    return results_df

def perform_anova_analysis(df, metric_col='value', tool_col='tool', scenario_col='scenario'):
    """Perform analysis of variance (ANOVA)"""
    results = {}
    
    # Prepare data for ANOVA
    groups = []
    group_names = []
    
    for scenario in df[scenario_col].unique():
        scenario_data = df[df[scenario_col] == scenario]
        
        for tool in scenario_data[tool_col].unique():
            tool_data = scenario_data[scenario_data[tool_col] == tool][metric_col].values
            if len(tool_data) > 0:
                groups.append(tool_data)
                group_names.append(f"{scenario}_{tool}")
    
    if len(groups) < 2:
        return {'anova': 'Insufficient groups', 'posthoc': 'N/A'}
    
    # Normality test for each group
    normality_results = []
    for i, group in enumerate(groups):
        norm_test = test_normality_robust(group)
        normality_results.append({
            'group': group_names[i],
            'normal': norm_test['conclusion'] == 'Normal'
        })
    
    # Choose the appropriate test
    all_normal = all(result['normal'] for result in normality_results)
    
    if all_normal:
        # Parametric ANOVA
        try:
            f_stat, f_p = stats.f_oneway(*groups)
            test_used = "One-way ANOVA"
            logger.debug(f"ANOVA executed successfully: F={f_stat:.4f}, p={f_p:.4f}")
        except ValueError as e:
            logger.warning(f"Error in ANOVA test (insufficient data or empty groups): {e}")
            f_stat, f_p = np.nan, np.nan
            test_used = "ANOVA failed"
        except Exception as e:
            logger.error(f"Unexpected error in ANOVA test: {type(e).__name__}: {e}", exc_info=True)
            f_stat, f_p = np.nan, np.nan
            test_used = "ANOVA failed"
    else:
        # Kruskal-Wallis (non-parametric)
        try:
            h_stat, h_p = kruskal(*groups)
            f_stat, h_stat = h_stat, h_stat
            f_p = h_p
            test_used = "Kruskal-Wallis test"
            logger.debug(f"Kruskal-Wallis executed successfully: H={h_stat:.4f}, p={h_p:.4f}")
        except ValueError as e:
            logger.warning(f"Error in Kruskal-Wallis test (insufficient data or empty groups): {e}")
            f_stat, f_p = np.nan, np.nan
            test_used = "Kruskal-Wallis failed"
        except Exception as e:
            logger.error(f"Unexpected error in Kruskal-Wallis test: {type(e).__name__}: {e}", exc_info=True)
            f_stat, f_p = np.nan, np.nan
            test_used = "Kruskal-Wallis failed"
    
    results['anova'] = {
        'test_used': test_used,
        'statistic': f_stat,
        'p_value': f_p,
        'significant': f_p < 0.05 if not np.isnan(f_p) else False,
        'normality_check': normality_results
    }
    
    return results

def save_figure_safe(fig, filepath, dpi=300, bbox_inches='tight'):
    """
    Save a matplotlib figure with robust error handling.
    
    Args:
        fig: Matplotlib figure or None (uses plt.gcf())
        filepath: Full path of the output file
        dpi: Image resolution (default: 300)
        bbox_inches: Bounding box adjustment (default: 'tight')
    
    Returns:
        bool: True if saved successfully, False otherwise
    """
    try:
        if fig is None:
            plt.savefig(filepath, dpi=dpi, bbox_inches=bbox_inches)
        else:
            fig.savefig(filepath, dpi=dpi, bbox_inches=bbox_inches)
        logger.debug(f"Figure saved successfully: {filepath}")
        return True
    except PermissionError as e:
        logger.error(f"No permission to save figure to {filepath}: {e}")
        print(f"⚠️  Error: No permission to save {os.path.basename(filepath)}")
        return False
    except OSError as e:
        logger.error(f"I/O error saving figure to {filepath}: {e}")
        print(f"⚠️  Error saving {os.path.basename(filepath)}: {e}")
        return False
    except Exception as e:
        logger.error(f"Unexpected error saving figure to {filepath}: {type(e).__name__}: {e}", exc_info=True)
        print(f"⚠️  Unexpected error saving {os.path.basename(filepath)}: {e}")
        return False

def create_enhanced_visualizations(data, output_dir):
    """Create enhanced visualizations with statistical analysis"""
    plt.style.use('seaborn-v0_8' if 'seaborn-v0_8' in plt.style.available else 'seaborn')
    
    # Fixed colors for consistency across charts
    # Docker: Blue (#1f77b4 - matplotlib default)
    # Apple container: Orange (#ff7f0e - matplotlib default)
    TOOL_COLORS = {
        'docker': '#1f77b4',      # Blue
        'container': '#ff7f0e'     # Orange
    }
    # Fixed order: docker (blue) first, then container (orange)
    TOOL_HUE_ORDER = ['docker', 'container']
    # Palette as a dictionary (ensures direct and correct mapping)
    TOOL_PALETTE = TOOL_COLORS
    
    # 1. Comparison chart with confidence intervals
    if 'main' in data:
        startup_data = data['main'][data['main']['scenario'].str.contains('startup')]
        if not startup_data.empty:
            plt.figure(figsize=(15, 12))
            
            # Box plot with outliers
            plt.subplot(2, 3, 1)
            sns.boxplot(data=startup_data, x='scenario', y='value', hue='tool', showfliers=True, 
                       palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
            plt.title('Startup Times Distribution (with outliers)')
            plt.xticks(rotation=45)
            plt.ylabel('Time (seconds)')
            
            # Violin plot
            plt.subplot(2, 3, 2)
            sns.violinplot(data=startup_data, x='scenario', y='value', hue='tool', 
                         palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
            plt.title('Startup Times Density Distribution')
            plt.xticks(rotation=45)
            plt.ylabel('Time (seconds)')
            
            # Bar plot with confidence intervals
            plt.subplot(2, 3, 3)
            startup_summary = startup_data.groupby(['tool', 'scenario'])['value'].agg(['mean', 'std', 'count']).reset_index()
            startup_summary['ci'] = 1.96 * startup_summary['std'] / np.sqrt(startup_summary['count'])
            
            x_pos = np.arange(len(startup_summary['scenario'].unique()))
            width = 0.35
            
            docker_means = startup_summary[startup_summary['tool'] == 'docker']['mean']
            container_means = startup_summary[startup_summary['tool'] == 'container']['mean']
            docker_cis = startup_summary[startup_summary['tool'] == 'docker']['ci']
            container_cis = startup_summary[startup_summary['tool'] == 'container']['ci']
            
            plt.bar(x_pos - width/2, docker_means, width, yerr=docker_cis, 
                   label='Docker', alpha=0.8, capsize=5, color=TOOL_COLORS['docker'])
            plt.bar(x_pos + width/2, container_means, width, yerr=container_cis, 
                   label='Apple container', alpha=0.8, capsize=5, color=TOOL_COLORS['container'])
            plt.xlabel('Scenario')
            plt.ylabel('Time (seconds)')
            plt.title('Startup Times with 95% CI')
            plt.xticks(x_pos, startup_summary['scenario'].unique(), rotation=45)
            plt.legend()
            
            # Q-Q plots to check normality
            plt.subplot(2, 3, 4)
            docker_data = startup_data[startup_data['tool'] == 'docker']['value']
            stats.probplot(docker_data, dist="norm", plot=plt)
            plt.title('Q-Q Plot: Docker (Normal Distribution)')
            
            plt.subplot(2, 3, 5)
            container_data = startup_data[startup_data['tool'] == 'container']['value']
            stats.probplot(container_data, dist="norm", plot=plt)
            plt.title('Q-Q Plot: Apple container (Normal Distribution)')
            
            # Histograms
            plt.subplot(2, 3, 6)
            plt.hist(docker_data, alpha=0.7, label='Docker', bins=10, density=True, color=TOOL_COLORS['docker'])
            plt.hist(container_data, alpha=0.7, label='Apple container', bins=10, density=True, color=TOOL_COLORS['container'])
            plt.xlabel('Time (seconds)')
            plt.ylabel('Density')
            plt.title('Distribution Comparison')
            plt.legend()
            
            plt.tight_layout()
            save_figure_safe(None, os.path.join(output_dir, 'enhanced_startup_analysis.png'))
            plt.close()
            
            # New figure with CDFs and Boxen plots
            plt.figure(figsize=(15, 10))
            
            # CDF plots
            plt.subplot(2, 3, 1)
            docker_sorted = np.sort(docker_data)
            container_sorted = np.sort(container_data)
            docker_cdf = np.arange(1, len(docker_sorted) + 1) / len(docker_sorted)
            container_cdf = np.arange(1, len(container_sorted) + 1) / len(container_sorted)
            plt.plot(docker_sorted, docker_cdf, label='Docker', linewidth=2, color=TOOL_COLORS['docker'])
            plt.plot(container_sorted, container_cdf, label='Apple container', linewidth=2, color=TOOL_COLORS['container'])
            plt.xlabel('Time (seconds)')
            plt.ylabel('Cumulative Probability')
            plt.title('CDF: Startup Times')
            plt.legend()
            plt.grid(True, alpha=0.3)
            
            # Boxen plots (more robust statistics than boxplot)
            plt.subplot(2, 3, 2)
            startup_data_plot = startup_data.copy()
            startup_data_plot['tool_scenario'] = startup_data_plot['tool'] + '_' + startup_data_plot['scenario']
            sns.boxenplot(data=startup_data_plot, x='tool_scenario', y='value', hue='tool', 
                         palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
            plt.title('Boxen Plot: Startup Times (Robust Statistics)')
            plt.xticks(rotation=45)
            plt.ylabel('Time (seconds)')
            
            # Comparative box plot (side-by-side)
            plt.subplot(2, 3, 3)
            sns.boxplot(data=startup_data, x='scenario', y='value', hue='tool', showfliers=True, 
                       palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
            plt.title('Box Plot Comparison')
            plt.xticks(rotation=45)
            plt.ylabel('Time (seconds)')
            
            # CDF per tool
            plt.subplot(2, 3, 4)
            for tool in startup_data['tool'].unique():
                tool_data = startup_data[startup_data['tool'] == tool]['value']
                sorted_data = np.sort(tool_data)
                cdf = np.arange(1, len(sorted_data) + 1) / len(sorted_data)
                plt.plot(sorted_data, cdf, label=tool, linewidth=2, alpha=0.8, color=TOOL_COLORS[tool])
            plt.xlabel('Time (seconds)')
            plt.ylabel('Cumulative Probability')
            plt.title('CDF by Tool')
            plt.legend()
            plt.grid(True, alpha=0.3)
            
            # Histograms with KDE
            plt.subplot(2, 3, 5)
            sns.histplot(data=startup_data, x='value', hue='tool', kde=True, alpha=0.6, 
                        palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
            plt.xlabel('Time (seconds)')
            plt.ylabel('Density')
            plt.title('Distribution with KDE')
            
            # Improved violin plot
            plt.subplot(2, 3, 6)
            sns.violinplot(data=startup_data, x='scenario', y='value', hue='tool', inner='quart', 
                         palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
            plt.title('Violin Plot: Distribution Shape')
            plt.xticks(rotation=45)
            plt.ylabel('Time (seconds)')
            
            plt.tight_layout()
            save_figure_safe(None, os.path.join(output_dir, 'cdf_boxen_analysis.png'))
            plt.close()
    
    # 2. Correlation chart and variance analysis
    if 'sysbench' in data and 'main' in data:
        plt.figure(figsize=(16, 10))
        
        # Correlation between metrics
        plt.subplot(2, 3, 1)
        cpu_data = data['sysbench'][data['sysbench']['test'] == 'cpu']
        if not cpu_data.empty:
            correlation_data = cpu_data.pivot_table(values='value', index='threads', columns='tool')
            sns.heatmap(correlation_data.corr(), annot=True, cmap='coolwarm', center=0)
            plt.title('CPU Performance Correlation')
        
        # Visual variance analysis
        plt.subplot(2, 3, 2)
        if 'main' in data:
            all_data = data['main'].copy()
            all_data['group'] = all_data['tool'] + '_' + all_data['scenario']
            sns.boxplot(data=all_data, x='group', y='value')
            plt.title('ANOVA Visualization')
            plt.xticks(rotation=45)
        
        # Residuals vs fitted values
        plt.subplot(2, 3, 3)
        if 'main' in data:
            startup_data = data['main'][data['main']['scenario'].str.contains('startup')]
            if not startup_data.empty:
                # Simulate residual analysis
                means = startup_data.groupby(['tool', 'scenario'])['value'].mean()
                residuals = []
                fitted = []
                for _, row in startup_data.iterrows():
                    group_mean = means[(row['tool'], row['scenario'])]
                    residual = row['value'] - group_mean
                    residuals.append(residual)
                    fitted.append(group_mean)
                
                plt.scatter(fitted, residuals, alpha=0.6)
                plt.axhline(y=0, color='r', linestyle='--')
                plt.xlabel('Fitted Values')
                plt.ylabel('Residuals')
                plt.title('Residuals vs Fitted Values')
        
        # Statistical power
        plt.subplot(2, 3, 4)
        if 'main' in data:
            startup_data = data['main'][data['main']['scenario'].str.contains('startup')]
            if not startup_data.empty:
                scenarios = startup_data['scenario'].unique()
                powers = []
                effect_sizes = []
                
                for scenario in scenarios:
                    scenario_data = startup_data[startup_data['scenario'] == scenario]
                    docker_data = scenario_data[scenario_data['tool'] == 'docker']['value'].values
                    container_data = scenario_data[scenario_data['tool'] == 'container']['value'].values
                    
                    if len(docker_data) > 1 and len(container_data) > 1:
                        effect = calculate_effect_size(docker_data, container_data)
                        power = calculate_statistical_power(docker_data, container_data, effect_size=effect['cohens_d'])
                        powers.append(power['power'])
                        effect_sizes.append(abs(effect['cohens_d']))
                    else:
                        powers.append(np.nan)
                        effect_sizes.append(np.nan)
                
                plt.scatter(effect_sizes, powers, s=100, alpha=0.7)
                plt.axhline(y=0.8, color='r', linestyle='--', label='Power = 0.8')
                plt.xlabel('Effect Size (|Cohen\'s d|)')
                plt.ylabel('Statistical Power')
                plt.title('Statistical Power Analysis')
                plt.legend()
        
        # Effect size distribution
        plt.subplot(2, 3, 5)
        if 'main' in data:
            startup_data = data['main'][data['main']['scenario'].str.contains('startup')]
            if not startup_data.empty:
                effect_sizes = []
                for scenario in scenarios:
                    scenario_data = startup_data[startup_data['scenario'] == scenario]
                    docker_data = scenario_data[scenario_data['tool'] == 'docker']['value'].values
                    container_data = scenario_data[scenario_data['tool'] == 'container']['value'].values
                    
                    if len(docker_data) > 1 and len(container_data) > 1:
                        effect = calculate_effect_size(docker_data, container_data)
                        effect_sizes.append(effect['cohens_d'])
                
                if effect_sizes:
                    plt.hist(effect_sizes, bins=10, alpha=0.7, edgecolor='black')
                    plt.axvline(x=0, color='r', linestyle='--', label='No effect')
                    plt.axvline(x=0.2, color='orange', linestyle='--', label='Small effect')
                    plt.axvline(x=0.5, color='yellow', linestyle='--', label='Medium effect')
                    plt.axvline(x=0.8, color='green', linestyle='--', label='Large effect')
                    plt.xlabel('Effect Size (Cohen\'s d)')
                    plt.ylabel('Frequency')
                    plt.title('Effect Size Distribution')
                    plt.legend()
        
        # Sensitivity analysis
        plt.subplot(2, 3, 6)
        if 'main' in data:
            startup_data = data['main'][data['main']['scenario'].str.contains('startup')]
            if not startup_data.empty:
                # Simulate sensitivity analysis by varying the sample size
                sample_sizes = range(5, 51, 5)
                powers = []
                
                for n in sample_sizes:
                    # Use existing data to simulate
                    docker_data = startup_data[startup_data['tool'] == 'docker']['value'].values
                    container_data = startup_data[startup_data['tool'] == 'container']['value'].values
                    
                    if len(docker_data) > 0 and len(container_data) > 0:
                        effect = calculate_effect_size(docker_data, container_data)
                        power = TTestIndPower().power(
                            effect_size=abs(effect['cohens_d']),
                            nobs1=n,
                            alpha=0.05,
                            ratio=1.0,
                            alternative='two-sided'
                        )
                        powers.append(power)
                    else:
                        powers.append(np.nan)
                
                plt.plot(sample_sizes, powers, 'o-', linewidth=2, markersize=6)
                plt.axhline(y=0.8, color='r', linestyle='--', label='Power = 0.8')
                plt.xlabel('Sample Size')
                plt.ylabel('Statistical Power')
                plt.title('Power Analysis by Sample Size')
                plt.legend()
                plt.grid(True, alpha=0.3)
        
        plt.tight_layout()
        save_figure_safe(None, os.path.join(output_dir, 'statistical_analysis_dashboard.png'))
        plt.close()
    
    # 3. Specific charts for sysbench data (CPU/Memory) when there is no main data
    if 'sysbench' in data and 'main' not in data:
        sysbench_data = data['sysbench']
        if not sysbench_data.empty:
            plt.figure(figsize=(16, 12))
            
            # Box plot comparing Docker vs container per test
            plt.subplot(2, 3, 1)
            if 'test' in sysbench_data.columns and 'threads' in sysbench_data.columns:
                # Create more descriptive labels
                def create_label(row):
                    test_name = row['test'].upper()
                    threads = int(row['threads'])
                    if threads == 1:
                        return f"{test_name} ({threads} thread)"
                    else:
                        return f"{test_name} ({threads} threads)"
                sysbench_data['test_label'] = sysbench_data.apply(create_label, axis=1)
                sns.boxplot(data=sysbench_data, x='test_label', y='value', hue='tool', showfliers=True, 
                           palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
                plt.title('CPU/Memory Performance Distribution')
                plt.xticks(rotation=45)
                plt.ylabel('Events/sec' if 'cpu' in sysbench_data['test'].values[0] else 'Throughput')
            else:
                sns.boxplot(data=sysbench_data, x='test', y='value', hue='tool', showfliers=True, 
                           palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
                plt.title('Performance Distribution')
                plt.xticks(rotation=45)
                plt.ylabel('Value')
            plt.legend()
            
            # Violin plot
            plt.subplot(2, 3, 2)
            if 'test_label' in sysbench_data.columns:
                sns.violinplot(data=sysbench_data, x='test_label', y='value', hue='tool', inner='quart', 
                              palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
                plt.xticks(rotation=45)
            else:
                sns.violinplot(data=sysbench_data, x='test', y='value', hue='tool', inner='quart', 
                              palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
                plt.xticks(rotation=45)
            plt.title('Performance Density Distribution')
            if len(sysbench_data) > 0 and 'cpu' in str(sysbench_data['test'].values[0]):
                plt.ylabel('Events/sec')
            else:
                plt.ylabel('Value')
            plt.legend()
            
            # Bar plot with confidence intervals
            plt.subplot(2, 3, 3)
            if 'test' in sysbench_data.columns:
                group_cols = ['tool', 'test']
                if 'threads' in sysbench_data.columns:
                    group_cols.append('threads')
                sysbench_summary = sysbench_data.groupby(group_cols)['value'].agg(['mean', 'std', 'count']).reset_index()
                sysbench_summary['ci'] = 1.96 * sysbench_summary['std'] / np.sqrt(sysbench_summary['count'])
                
                # Create descriptive labels for the bar chart
                if 'threads' in sysbench_summary.columns:
                    def create_label_bar(row):
                        test_name = row['test'].upper()
                        threads = int(row['threads'])
                        if threads == 1:
                            return f"{test_name} ({threads} thread)"
                        else:
                            return f"{test_name} ({threads} threads)"
                    sysbench_summary['test_label'] = sysbench_summary.apply(create_label_bar, axis=1)
                    
                    # Group by test_label to ensure correct ordering
                    labels = []
                    docker_means = []
                    docker_cis = []
                    container_means = []
                    container_cis = []
                    
                    for test_val in sysbench_summary['test'].unique():
                        for thread_val in sorted(sysbench_summary[sysbench_summary['test'] == test_val]['threads'].unique()):
                            row = sysbench_summary[(sysbench_summary['test'] == test_val) & (sysbench_summary['threads'] == thread_val)]
                            if not row.empty:
                                label = create_label_bar(row.iloc[0])
                                labels.append(label)
                                
                                docker_row = row[row['tool'] == 'docker']
                                container_row = row[row['tool'] == 'container']
                                
                                if not docker_row.empty:
                                    docker_means.append(docker_row['mean'].values[0])
                                    docker_cis.append(docker_row['ci'].values[0])
                                else:
                                    docker_means.append(0)
                                    docker_cis.append(0)
                                
                                if not container_row.empty:
                                    container_means.append(container_row['mean'].values[0])
                                    container_cis.append(container_row['ci'].values[0])
                                else:
                                    container_means.append(0)
                                    container_cis.append(0)
                    
                    if labels:
                        x_pos = np.arange(len(labels))
                        width = 0.35
                        plt.bar(x_pos - width/2, docker_means, width, yerr=docker_cis, 
                               label='Docker', alpha=0.8, capsize=5, color=TOOL_COLORS['docker'])
                        plt.bar(x_pos + width/2, container_means, width, yerr=container_cis, 
                               label='Apple container', alpha=0.8, capsize=5, color=TOOL_COLORS['container'])
                        plt.xticks(x_pos, labels, rotation=45)
                else:
                    x_pos = np.arange(len(sysbench_summary['test'].unique()))
                    width = 0.35
                    docker_data = sysbench_summary[sysbench_summary['tool'] == 'docker']
                    container_data = sysbench_summary[sysbench_summary['tool'] == 'container']
                    plt.bar(x_pos - width/2, docker_data['mean'], width, yerr=docker_data['ci'], 
                           label='Docker', alpha=0.8, capsize=5, color=TOOL_COLORS['docker'])
                    plt.bar(x_pos + width/2, container_data['mean'], width, yerr=container_data['ci'], 
                           label='Apple container', alpha=0.8, capsize=5, color=TOOL_COLORS['container'])
                    plt.xticks(x_pos, sysbench_summary['test'].unique(), rotation=45)
                
                plt.xlabel('Test')
                plt.ylabel('Performance')
                plt.title('Performance with 95% CI')
                plt.legend()
            
            # Q-Q plots to check normality
            docker_data_qq = sysbench_data[sysbench_data['tool'] == 'docker']['value']
            container_data_qq = sysbench_data[sysbench_data['tool'] == 'container']['value']
            
            plt.subplot(2, 3, 4)
            if len(docker_data_qq) > 0:
                stats.probplot(docker_data_qq, dist="norm", plot=plt)
                plt.title('Q-Q Plot: Docker (Normal Distribution)')
            
            plt.subplot(2, 3, 5)
            if len(container_data_qq) > 0:
                stats.probplot(container_data_qq, dist="norm", plot=plt)
                plt.title('Q-Q Plot: Apple container (Normal Distribution)')
            
            # Comparative histograms
            plt.subplot(2, 3, 6)
            if len(docker_data_qq) > 0:
                plt.hist(docker_data_qq, alpha=0.7, label='Docker', bins=10, density=True, color=TOOL_COLORS['docker'])
            if len(container_data_qq) > 0:
                plt.hist(container_data_qq, alpha=0.7, label='Apple container', bins=10, density=True, color=TOOL_COLORS['container'])
            plt.xlabel('Value')
            plt.ylabel('Density')
            plt.title('Distribution Comparison')
            plt.legend()
            
            plt.tight_layout()
            # Use a generic file name for sysbench data
            save_figure_safe(None, os.path.join(output_dir, 'performance_analysis.png'))
            plt.close()
            
            # Statistical dashboard for sysbench
            plt.figure(figsize=(16, 10))
            
            # CDF plots
            plt.subplot(2, 3, 1)
            docker_data_cdf = sysbench_data[sysbench_data['tool'] == 'docker']['value']
            container_data_cdf = sysbench_data[sysbench_data['tool'] == 'container']['value']
            if len(docker_data_cdf) > 0 and len(container_data_cdf) > 0:
                docker_sorted = np.sort(docker_data_cdf)
                container_sorted = np.sort(container_data_cdf)
                docker_cdf = np.arange(1, len(docker_sorted) + 1) / len(docker_sorted)
                container_cdf = np.arange(1, len(container_sorted) + 1) / len(container_sorted)
                plt.plot(docker_sorted, docker_cdf, label='Docker', linewidth=2, color=TOOL_COLORS['docker'])
                plt.plot(container_sorted, container_cdf, label='Apple container', linewidth=2, color=TOOL_COLORS['container'])
                plt.xlabel('Value')
                plt.ylabel('Cumulative Probability')
                plt.title('CDF: Performance Comparison')
                plt.legend()
                plt.grid(True, alpha=0.3)
            
            # Boxen plots
            plt.subplot(2, 3, 2)
            if 'test_label' in sysbench_data.columns:
                sns.boxenplot(data=sysbench_data, x='test_label', y='value', hue='tool', 
                             palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
                plt.xticks(rotation=45)
            else:
                sns.boxenplot(data=sysbench_data, x='test', y='value', hue='tool', 
                             palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
                plt.xticks(rotation=45)
            plt.title('Boxen Plot (Robust Statistics)')
            plt.ylabel('Value')
            plt.legend()
            
            # Statistical power analysis for sysbench
            plt.subplot(2, 3, 3)
            if 'test' in sysbench_data.columns:
                tests = sysbench_data['test'].unique()
                powers = []
                effect_sizes = []
                
                for test_val in tests:
                    test_data = sysbench_data[sysbench_data['test'] == test_val]
                    docker_vals = test_data[test_data['tool'] == 'docker']['value'].values
                    container_vals = test_data[test_data['tool'] == 'container']['value'].values
                    
                    if len(docker_vals) > 1 and len(container_vals) > 1:
                        effect = calculate_effect_size(docker_vals, container_vals)
                        power = calculate_statistical_power(docker_vals, container_vals, effect_size=effect['cohens_d'])
                        powers.append(power['power'])
                        effect_sizes.append(abs(effect['cohens_d']))
                    else:
                        powers.append(np.nan)
                        effect_sizes.append(np.nan)
                
                if powers and not all(np.isnan(powers)):
                    valid_powers = [p for p in powers if not np.isnan(p)]
                    valid_effects = [e for e, p in zip(effect_sizes, powers) if not np.isnan(p)]
                    if valid_powers:
                        plt.scatter(valid_effects, valid_powers, s=100, alpha=0.7)
                        plt.axhline(y=0.8, color='r', linestyle='--', label='Power = 0.8')
                        plt.xlabel('Effect Size (|Cohen\'s d|)')
                        plt.ylabel('Statistical Power')
                        plt.title('Statistical Power Analysis')
                        plt.legend()
            
            plt.tight_layout()
            # Use a generic file name for sysbench data
            plt.savefig(os.path.join(output_dir, 'statistical_dashboard.png'), dpi=300, bbox_inches='tight')
            plt.close()
    
    # 4. Charts for Disk I/O (fio)
    if 'fio' in data:
        fio_data = data['fio']
        if not fio_data.empty:
            # Filter throughput data only
            fio_throughput = fio_data[fio_data['metric'] == 'throughput_kb_per_sec'].copy()
            if not fio_throughput.empty:
                plt.figure(figsize=(16, 12))
                
                # Box plot
                plt.subplot(2, 3, 1)
                sns.boxplot(data=fio_throughput, x='test', y='value', hue='tool', showfliers=True,
                           palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
                plt.title('Disk I/O Throughput Distribution')
                plt.xticks(rotation=45)
                plt.ylabel('Throughput (KB/s)')
                plt.legend()
                
                # Violin plot
                plt.subplot(2, 3, 2)
                sns.violinplot(data=fio_throughput, x='test', y='value', hue='tool', inner='quart',
                             palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
                plt.title('Disk I/O Density Distribution')
                plt.xticks(rotation=45)
                plt.ylabel('Throughput (KB/s)')
                plt.legend()
                
                # Bar plot with CI
                plt.subplot(2, 3, 3)
                fio_summary = fio_throughput.groupby(['tool', 'test'])['value'].agg(['mean', 'std', 'count']).reset_index()
                fio_summary['ci'] = 1.96 * fio_summary['std'] / np.sqrt(fio_summary['count'])
                
                x_pos = np.arange(len(fio_summary['test'].unique()))
                width = 0.35
                docker_means = fio_summary[fio_summary['tool'] == 'docker']['mean']
                container_means = fio_summary[fio_summary['tool'] == 'container']['mean']
                docker_cis = fio_summary[fio_summary['tool'] == 'docker']['ci']
                container_cis = fio_summary[fio_summary['tool'] == 'container']['ci']
                
                plt.bar(x_pos - width/2, docker_means, width, yerr=docker_cis,
                       label='Docker', alpha=0.8, capsize=5, color=TOOL_COLORS['docker'])
                plt.bar(x_pos + width/2, container_means, width, yerr=container_cis,
                       label='Apple container', alpha=0.8, capsize=5, color=TOOL_COLORS['container'])
                plt.xlabel('Test Type')
                plt.ylabel('Throughput (KB/s)')
                plt.title('Disk I/O Performance with 95% CI')
                plt.xticks(x_pos, fio_summary['test'].unique(), rotation=45)
                plt.legend()
                
                # Q-Q plots
                plt.subplot(2, 3, 4)
                docker_data_qq = fio_throughput[fio_throughput['tool'] == 'docker']['value']
                if len(docker_data_qq) > 0:
                    stats.probplot(docker_data_qq, dist="norm", plot=plt)
                    plt.title('Q-Q Plot: Docker')
                
                plt.subplot(2, 3, 5)
                container_data_qq = fio_throughput[fio_throughput['tool'] == 'container']['value']
                if len(container_data_qq) > 0:
                    stats.probplot(container_data_qq, dist="norm", plot=plt)
                    plt.title('Q-Q Plot: Apple container')
                
                # CDF
                plt.subplot(2, 3, 6)
                docker_sorted = np.sort(docker_data_qq)
                container_sorted = np.sort(container_data_qq)
                docker_cdf = np.arange(1, len(docker_sorted) + 1) / len(docker_sorted)
                container_cdf = np.arange(1, len(container_sorted) + 1) / len(container_sorted)
                plt.plot(docker_sorted, docker_cdf, label='Docker', linewidth=2, color=TOOL_COLORS['docker'])
                plt.plot(container_sorted, container_cdf, label='Apple container', linewidth=2, color=TOOL_COLORS['container'])
                plt.xlabel('Throughput (KB/s)')
                plt.ylabel('Cumulative Probability')
                plt.title('CDF: Disk I/O Performance')
                plt.legend()
                plt.grid(True, alpha=0.3)
                
                plt.tight_layout()
                _disk_png = os.path.join(output_dir, 'performance_analysis_disk_fio.png')
                plt.savefig(_disk_png, dpi=300, bbox_inches='tight')
                plt.savefig(os.path.join(output_dir, 'performance_analysis.png'), dpi=300, bbox_inches='tight')
                plt.close()
    
    # 5. Charts for STREAM (Memory Bandwidth)
    if 'stream' in data:
        stream_data = data['stream']
        if not stream_data.empty:
            # Filter bandwidth only
            stream_bandwidth = stream_data[stream_data['metric'] == 'bandwidth_mb_per_sec'].copy()
            if not stream_bandwidth.empty:
                plt.figure(figsize=(16, 12))
                
                # Create descriptive labels if threads are present
                if 'threads' in stream_bandwidth.columns:
                    def create_stream_label(row):
                        test_name = row['test'].upper()
                        threads = int(row['threads'])
                        return f"{test_name} ({threads}t)"
                    stream_bandwidth['test_label'] = stream_bandwidth.apply(create_stream_label, axis=1)
                    x_col = 'test_label'
                else:
                    x_col = 'test'
                
                # Box plot
                plt.subplot(2, 3, 1)
                sns.boxplot(data=stream_bandwidth, x=x_col, y='value', hue='tool', showfliers=True,
                           palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
                plt.title('STREAM Memory Bandwidth Distribution')
                plt.xticks(rotation=45)
                plt.ylabel('Bandwidth (MB/s)')
                plt.legend()
                
                # Violin plot
                plt.subplot(2, 3, 2)
                sns.violinplot(data=stream_bandwidth, x=x_col, y='value', hue='tool', inner='quart',
                             palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
                plt.title('STREAM Density Distribution')
                plt.xticks(rotation=45)
                plt.ylabel('Bandwidth (MB/s)')
                plt.legend()
                
                # Bar plot with CI
                plt.subplot(2, 3, 3)
                group_cols = ['tool', 'test']
                if 'threads' in stream_bandwidth.columns:
                    group_cols.append('threads')
                stream_summary = stream_bandwidth.groupby(group_cols)['value'].agg(['mean', 'std', 'count']).reset_index()
                stream_summary['ci'] = 1.96 * stream_summary['std'] / np.sqrt(stream_summary['count'])
                
                # Create unique labels combining test and threads (if present)
                if 'threads' in stream_summary.columns:
                    stream_summary['label'] = stream_summary['test'].str.upper() + ' (' + stream_summary['threads'].astype(str) + 't)'
                else:
                    stream_summary['label'] = stream_summary['test'].str.upper()
                
                # Get all unique (test, threads) combinations to ensure a consistent order
                # This ensures that even if a tool lacks some scenarios, the arrays have the same size
                if 'threads' in stream_summary.columns:
                    # Create all possible combinations of test and threads
                    all_tests = sorted(stream_summary['test'].unique())
                    all_threads = sorted(stream_summary['threads'].unique())
                    unique_labels = []
                    for test in all_tests:
                        for thread in all_threads:
                            label = f"{test.upper()} ({int(thread)}t)"
                            unique_labels.append(label)
                else:
                    unique_labels = sorted(stream_summary['label'].unique())
                
                x_pos = np.arange(len(unique_labels))
                width = 0.35
                
                # Filter and sort by label to ensure matching
                docker_data = stream_summary[stream_summary['tool'] == 'docker'].sort_values('label')
                container_data = stream_summary[stream_summary['tool'] == 'container'].sort_values('label')
                
                # Ensure both have the same labels in the same order
                docker_means = []
                docker_cis = []
                container_means = []
                container_cis = []
                
                for label in unique_labels:
                    docker_row = docker_data[docker_data['label'] == label]
                    container_row = container_data[container_data['label'] == label]
                    
                    if not docker_row.empty:
                        docker_means.append(docker_row['mean'].iloc[0])
                        docker_cis.append(docker_row['ci'].iloc[0])
                    else:
                        docker_means.append(0)
                        docker_cis.append(0)
                    
                    if not container_row.empty:
                        container_means.append(container_row['mean'].iloc[0])
                        container_cis.append(container_row['ci'].iloc[0])
                    else:
                        container_means.append(0)
                        container_cis.append(0)
                
                docker_means = np.array(docker_means)
                container_means = np.array(container_means)
                docker_cis = np.array(docker_cis)
                container_cis = np.array(container_cis)
                
                # Check that the arrays have the same size before plotting
                if len(docker_means) == len(container_means) == len(x_pos):
                    plt.bar(x_pos - width/2, docker_means, width, yerr=docker_cis,
                           label='Docker', alpha=0.8, capsize=5, color=TOOL_COLORS['docker'])
                    plt.bar(x_pos + width/2, container_means, width, yerr=container_cis,
                           label='Apple container', alpha=0.8, capsize=5, color=TOOL_COLORS['container'])
                    plt.xlabel('Test Type')
                    plt.ylabel('Bandwidth (MB/s)')
                    plt.title('STREAM Performance with 95% CI')
                    plt.xticks(x_pos, unique_labels, rotation=45, ha='right')
                    plt.legend()
                else:
                    logger.warning(f"Shape mismatch in STREAM bar plot: docker_means={len(docker_means)}, container_means={len(container_means)}, x_pos={len(x_pos)}. Skipping bar plot.")
                    plt.text(0.5, 0.5, 'Bar plot skipped due to data shape mismatch', 
                            ha='center', va='center', transform=plt.gca().transAxes)
                    plt.title('STREAM Performance with 95% CI (Error)')
                
                # Q-Q plots
                plt.subplot(2, 3, 4)
                docker_data_qq = stream_bandwidth[stream_bandwidth['tool'] == 'docker']['value']
                if len(docker_data_qq) > 0:
                    stats.probplot(docker_data_qq, dist="norm", plot=plt)
                    plt.title('Q-Q Plot: Docker')
                
                plt.subplot(2, 3, 5)
                container_data_qq = stream_bandwidth[stream_bandwidth['tool'] == 'container']['value']
                if len(container_data_qq) > 0:
                    stats.probplot(container_data_qq, dist="norm", plot=plt)
                    plt.title('Q-Q Plot: Apple container')
                
                # CDF
                plt.subplot(2, 3, 6)
                docker_sorted = np.sort(docker_data_qq)
                container_sorted = np.sort(container_data_qq)
                docker_cdf = np.arange(1, len(docker_sorted) + 1) / len(docker_sorted)
                container_cdf = np.arange(1, len(container_sorted) + 1) / len(container_sorted)
                plt.plot(docker_sorted, docker_cdf, label='Docker', linewidth=2, color=TOOL_COLORS['docker'])
                plt.plot(container_sorted, container_cdf, label='Apple container', linewidth=2, color=TOOL_COLORS['container'])
                plt.xlabel('Bandwidth (MB/s)')
                plt.ylabel('Cumulative Probability')
                plt.title('CDF: STREAM Performance')
                plt.legend()
                plt.grid(True, alpha=0.3)
                
                plt.tight_layout()
                plt.savefig(os.path.join(output_dir, 'performance_analysis.png'), dpi=300, bbox_inches='tight')
                plt.close()
    
    # 6. Charts for Math (PI calculation)
    if 'math' in data:
        math_data = data['math']
        if not math_data.empty:
            # Filter time_seconds only (execution time)
            math_time = math_data[math_data['metric'] == 'time_seconds'].copy()
            if not math_time.empty:
                plt.figure(figsize=(16, 12))
                
                # Create descriptive labels if threads are present
                if 'threads' in math_time.columns:
                    def create_math_label(row):
                        test_name = row['test'].upper()
                        threads = int(row['threads'])
                        return f"{test_name} ({threads}t)"
                    math_time['test_label'] = math_time.apply(create_math_label, axis=1)
                    x_col = 'test_label'
                else:
                    x_col = 'test'
                
                # Box plot
                plt.subplot(2, 3, 1)
                sns.boxplot(data=math_time, x=x_col, y='value', hue='tool', showfliers=True,
                           palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
                plt.title('Math Computation Time Distribution')
                plt.xticks(rotation=45)
                plt.ylabel('Execution Time (seconds)')
                plt.legend()
                
                # Violin plot
                plt.subplot(2, 3, 2)
                sns.violinplot(data=math_time, x=x_col, y='value', hue='tool', inner='quart',
                             palette=TOOL_PALETTE, hue_order=TOOL_HUE_ORDER)
                plt.title('Math Computation Density Distribution')
                plt.xticks(rotation=45)
                plt.ylabel('Execution Time (seconds)')
                plt.legend()
                
                # Bar plot with CI
                plt.subplot(2, 3, 3)
                group_cols = ['tool', 'test']
                if 'threads' in math_time.columns:
                    group_cols.append('threads')
                math_summary = math_time.groupby(group_cols)['value'].agg(['mean', 'std', 'count']).reset_index()
                math_summary['ci'] = 1.96 * math_summary['std'] / np.sqrt(math_summary['count'])
                
                x_pos = np.arange(len(math_summary[group_cols[1]].unique()))
                width = 0.35
                docker_means = math_summary[math_summary['tool'] == 'docker']['mean']
                container_means = math_summary[math_summary['tool'] == 'container']['mean']
                docker_cis = math_summary[math_summary['tool'] == 'docker']['ci']
                container_cis = math_summary[math_summary['tool'] == 'container']['ci']
                
                plt.bar(x_pos - width/2, docker_means, width, yerr=docker_cis,
                       label='Docker', alpha=0.8, capsize=5, color=TOOL_COLORS['docker'])
                plt.bar(x_pos + width/2, container_means, width, yerr=container_cis,
                       label='Apple container', alpha=0.8, capsize=5, color=TOOL_COLORS['container'])
                plt.xlabel('Test Type')
                plt.ylabel('Execution Time (seconds)')
                plt.title('Math Performance with 95% CI')
                plt.xticks(x_pos, math_summary[group_cols[1]].unique(), rotation=45)
                plt.legend()
                
                # Q-Q plots
                plt.subplot(2, 3, 4)
                docker_data_qq = math_time[math_time['tool'] == 'docker']['value']
                if len(docker_data_qq) > 0:
                    stats.probplot(docker_data_qq, dist="norm", plot=plt)
                    plt.title('Q-Q Plot: Docker')
                
                plt.subplot(2, 3, 5)
                container_data_qq = math_time[math_time['tool'] == 'container']['value']
                if len(container_data_qq) > 0:
                    stats.probplot(container_data_qq, dist="norm", plot=plt)
                    plt.title('Q-Q Plot: Apple container')
                
                # CDF
                plt.subplot(2, 3, 6)
                docker_sorted = np.sort(docker_data_qq)
                container_sorted = np.sort(container_data_qq)
                docker_cdf = np.arange(1, len(docker_sorted) + 1) / len(docker_sorted)
                container_cdf = np.arange(1, len(container_sorted) + 1) / len(container_sorted)
                plt.plot(docker_sorted, docker_cdf, label='Docker', linewidth=2, color=TOOL_COLORS['docker'])
                plt.plot(container_sorted, container_cdf, label='Apple container', linewidth=2, color=TOOL_COLORS['container'])
                plt.xlabel('Execution Time (seconds)')
                plt.ylabel('Cumulative Probability')
                plt.title('CDF: Math Performance')
                plt.legend()
                plt.grid(True, alpha=0.3)
                
                plt.tight_layout()
                plt.savefig(os.path.join(output_dir, 'performance_analysis.png'), dpi=300, bbox_inches='tight')
                plt.close()

def generate_experimental_table(data, output_dir, quiet=False, alpha=0.05):
    """
    Generate a complete experimental table consolidating all statistical metrics
    from all benchmarks.
    
    Args:
        data: Dictionary of DataFrames with the data
        output_dir: Output directory
        quiet: If True, reduce output (compact mode)
    
    Returns the consolidated DataFrame and exports it to CSV and LaTeX.
    """
    if not quiet:
        print("\n" + "="*70)
        print("📊 GENERATING COMPLETE EXPERIMENTAL TABLE")
        print("="*70)
    
    all_results = []
    
    # Process each benchmark type
    benchmark_configs = [
        {
            'key': 'main',
            'name': 'Startup',
            'scenario_col': 'scenario',
            'metric_col': 'value',
            'unit': 'seconds',
            'lower_is_better': True
        },
        {
            'key': 'sysbench',
            'name': 'CPU/Memory',
            'scenario_col': 'test',
            'metric_col': 'value',
            'unit': 'events/sec or MB/s',
            'lower_is_better': False
        },
        {
            'key': 'fio',
            'name': 'Disk I/O',
            'scenario_col': 'test',
            'metric_col': 'value',
            'unit': 'KB/s',
            'lower_is_better': False,
            'metric_filter': lambda df: df[df['metric'] == 'throughput_kb_per_sec']
        },
        {
            'key': 'stream',
            'name': 'STREAM',
            'scenario_col': 'test',
            'metric_col': 'value',
            'unit': 'MB/s',
            'lower_is_better': False,
            'metric_filter': lambda df: df[df['metric'] == 'bandwidth_mb_per_sec']
        },
        {
            'key': 'math',
            'name': 'Math',
            'scenario_col': 'test',
            'metric_col': 'value',
            'unit': 'seconds',
            'lower_is_better': True,
            'metric_filter': lambda df: df[df['metric'] == 'time_seconds']
        },
        {
            'key': 'wrk',
            'name': 'HTTP',
            'scenario_col': 'test',
            'metric_col': 'value',
            'unit': 'req/s or ms',
            'lower_is_better': False,
            # Avoid mixing distinct metrics (e.g., req/s vs latency) in the same test.
            # If there are multiple metrics, prioritize req/s as the main metric.
            'metric_filter': lambda df: df[df['metric'] == 'requests_per_sec'] if 'metric' in df.columns and (df['metric'] == 'requests_per_sec').any() else df
        }
    ]
    
    for config in benchmark_configs:
        key = config['key']
        if key not in data or data[key].empty:
            continue
        
        if not quiet:
            print(f"\n📋 Processing: {config['name']}")
        
        # Apply metric filter if specified
        df = data[key].copy()
        if 'metric_filter' in config:
            df = config['metric_filter'](df)
            if df.empty:
                continue

        # For benchmarks with multiple thread configurations, treat (test, threads) as a "scenario".
        # Otherwise, the analysis mixes distributions from different workloads.
        scenario_col = config['scenario_col']
        if 'threads' in df.columns:
            threads_unique = df['threads'].dropna().unique()
            if len(threads_unique) > 1:
                df['scenario_with_threads'] = (
                    df[scenario_col].astype(str).str.lower()
                    + "_"
                    + df['threads'].astype(int).astype(str)
                    + "t"
                )
                scenario_col = 'scenario_with_threads'
        
        # Compute descriptive statistics
        group_cols = ['tool', scenario_col]
        stats_df, ci_df = calculate_enhanced_statistics(
            df,
            metric_col=config['metric_col'],
            group_cols=group_cols,
            alpha=alpha
        )
        
        # Compute statistical tests
        robust_tests = perform_robust_statistical_tests(
            df,
            metric_col=config['metric_col'],
            tool_col='tool',
            scenario_col=scenario_col,
            alpha=alpha
        )
        
        # Apply multiple comparison corrections
        if not robust_tests.empty:
            robust_tests = apply_multiple_comparison_correction(robust_tests, 'bonferroni', alpha=alpha)
            robust_tests = apply_multiple_comparison_correction(robust_tests, 'fdr_bh', alpha=alpha)
        
        # Consolidate results
        # Reset index for easier access
        stats_df_reset = stats_df.reset_index()
        ci_df_reset = ci_df.reset_index()
        
        # Get unique scenarios
        if scenario_col in stats_df_reset.columns:
            scenarios = stats_df_reset[scenario_col].unique()
        else:
            # If there is no scenario column, use the index
            scenarios = stats_df.index.get_level_values(scenario_col).unique() if hasattr(stats_df.index, 'get_level_values') else []
        
        for scenario in scenarios:
            for tool in ['docker', 'container']:
                # Filter by tool and scenario
                stats_filtered = stats_df_reset[
                    (stats_df_reset['tool'] == tool) & 
                    (stats_df_reset[scenario_col] == scenario)
                ]
                ci_filtered = ci_df_reset[
                    (ci_df_reset['tool'] == tool) & 
                    (ci_df_reset[scenario_col] == scenario)
                ]
                
                if stats_filtered.empty:
                    continue
                
                stats_row = stats_filtered.iloc[0]
                ci_row = ci_filtered.iloc[0] if not ci_filtered.empty else pd.Series({'ci_lower': np.nan, 'ci_upper': np.nan})
                
                # Look up statistical test results
                test_row = robust_tests[robust_tests['scenario'] == scenario] if not robust_tests.empty else None
                
                result = {
                    'benchmark': config['name'],
                    'scenario': scenario,
                    'tool': tool,
                    'unit': config['unit'],
                    'n': int(stats_row['count']),
                    'mean': stats_row['mean'],
                    'std': stats_row['std'],
                    'median': stats_row['median'],
                    'q25': stats_row['q25'],
                    'q75': stats_row['q75'],
                    'iqr': stats_row['iqr'],
                    'min': stats_row['min'],
                    'max': stats_row['max'],
                    'p5': stats_row['p5'],
                    'p95': stats_row['p95'],
                    'ci_lower': ci_row['ci_lower'],
                    'ci_upper': ci_row['ci_upper'],
                    'skewness': stats_row['skew'],
                    'kurtosis': stats_row['kurtosis']
                }

                # Defaults: keep columns stable even when no comparison is possible
                # (e.g., only docker or only container in a scenario due to collection failures).
                result['test_used'] = np.nan
                result['p_value'] = np.nan
                result['p_value_bonferroni'] = np.nan
                result['p_value_fdr_bh'] = np.nan
                result['significant'] = False
                result['effect_size'] = np.nan
                result['effect_interpretation'] = 'N/A'
                result['statistical_power'] = np.nan
                result['power_interpretation'] = 'N/A'
                
                # Add statistical test information (docker only, then compare)
                if tool == 'docker' and test_row is not None and not test_row.empty:
                    test = test_row.iloc[0]
                    result['test_used'] = test['test_used']
                    result['p_value'] = test['p_value']
                    result['p_value_bonferroni'] = test.get('p_value_bonferroni', np.nan)
                    result['p_value_fdr_bh'] = test.get('p_value_fdr_bh', np.nan)
                    result['significant'] = test.get('significant_fdr_bh', False)
                    result['effect_size'] = test['effect_size']
                    result['effect_interpretation'] = test['effect_interpretation']
                    result['statistical_power'] = test['statistical_power']
                    result['power_interpretation'] = test['power_interpretation']
                elif tool == 'container':
                    # For container, copy the test information from docker (it is the same)
                    if test_row is not None and not test_row.empty:
                        test = test_row.iloc[0]
                        result['test_used'] = test['test_used']
                        result['p_value'] = test['p_value']
                        result['p_value_bonferroni'] = test.get('p_value_bonferroni', np.nan)
                        result['p_value_fdr_bh'] = test.get('p_value_fdr_bh', np.nan)
                        result['significant'] = test.get('significant_fdr_bh', False)
                        result['effect_size'] = test['effect_size']
                        result['effect_interpretation'] = test['effect_interpretation']
                        result['statistical_power'] = test['statistical_power']
                        result['power_interpretation'] = test['power_interpretation']
                
                all_results.append(result)
    
    # Create consolidated DataFrame
    if not all_results:
        print("⚠️  No data found to generate the experimental table")
        return None
    
    consolidated_df = pd.DataFrame(all_results)
    
    # Sort by benchmark and scenario
    consolidated_df = consolidated_df.sort_values(['benchmark', 'scenario', 'tool'])
    
    # Save CSV
    csv_path = os.path.join(output_dir, 'experimental_table_complete.csv')
    try:
        consolidated_df.to_csv(csv_path, index=False, float_format='%.4f')
        logger.info(f"CSV table saved successfully: {csv_path}")
        if not quiet:
            print(f"\n✅ CSV table saved to: {csv_path}")
    except PermissionError as e:
        logger.error(f"No permission to write CSV file: {e}")
        print(f"⚠️  Error: No permission to save {csv_path}")
    except OSError as e:
        logger.error(f"I/O error saving CSV: {e}")
        print(f"⚠️  Error saving CSV: {e}")
    except Exception as e:
        logger.error(f"Unexpected error saving CSV: {type(e).__name__}: {e}", exc_info=True)
        print(f"⚠️  Unexpected error saving CSV: {e}")
    
    # Generate LaTeX table
    latex_path = os.path.join(output_dir, 'experimental_table_complete.tex')
    try:
        generate_latex_table(consolidated_df, latex_path)
        logger.info(f"LaTeX table saved successfully: {latex_path}")
        if not quiet:
            print(f"✅ LaTeX table saved to: {latex_path}")
    except Exception as e:
        logger.error(f"Error generating LaTeX table: {type(e).__name__}: {e}", exc_info=True)
        print(f"⚠️  Error generating LaTeX table: {e}")
    
    # Generate summary table (main metrics only)
    summary_path = os.path.join(output_dir, 'experimental_table_summary.csv')
    try:
        summary_df = consolidated_df[['benchmark', 'scenario', 'tool', 'n', 'mean', 'std', 
                                      'median', 'iqr', 'ci_lower', 'ci_upper', 'effect_size', 
                                      'p_value_fdr_bh', 'significant', 'statistical_power']].copy()
        summary_df.to_csv(summary_path, index=False, float_format='%.4f')
        logger.info(f"Summary table saved successfully: {summary_path}")
        if not quiet:
            print(f"✅ Summary table saved to: {summary_path}")
    except KeyError as e:
        logger.error(f"Column not found while generating summary table: {e}")
        print(f"⚠️  Error: Column not found while generating summary table: {e}")
    except PermissionError as e:
        logger.error(f"No permission to write summary table: {e}")
        print(f"⚠️  Error: No permission to save {summary_path}")
    except Exception as e:
        logger.error(f"Unexpected error saving summary table: {type(e).__name__}: {e}", exc_info=True)
        print(f"⚠️  Error saving summary table: {e}")
    
    if not quiet:
        print(f"\n📊 Total records in table: {len(consolidated_df)}")
        print(f"📊 Benchmarks included: {consolidated_df['benchmark'].nunique()}")
    
    return consolidated_df

def escape_latex(text):
    """Escape LaTeX special characters"""
    if pd.isna(text):
        return "N/A"
    text = str(text)
    # Escape special characters
    text = text.replace('\\', '\\textbackslash{}')
    text = text.replace('&', '\\&')
    text = text.replace('%', '\\%')
    text = text.replace('$', '\\$')
    text = text.replace('#', '\\#')
    text = text.replace('^', '\\textasciicircum{}')
    text = text.replace('_', '\\_')
    text = text.replace('{', '\\{')
    text = text.replace('}', '\\}')
    text = text.replace('~', '\\textasciitilde{}')
    return text

def generate_latex_table(df, output_path):
    """
    Generate a formatted LaTeX table.
    Creates separate tables per benchmark.
    """
    try:
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write("% Complete Experimental Table - Docker vs Apple container Benchmark\n")
            f.write("% Automatically generated by analyze_results_enhanced.py\n")
            f.write("%\n")
            f.write("% To use in LaTeX, copy the contents of the desired section\n")
            f.write("%\n")
            f.write("\\documentclass{article}\n")
            f.write("\\usepackage{booktabs}\n")
            f.write("\\usepackage{longtable}\n")
            f.write("\\usepackage{multirow}\n")
            f.write("\\usepackage{array}\n")
            f.write("\\begin{document}\n\n")
            
            # Generate a table for each benchmark
            for benchmark in df['benchmark'].unique():
                benchmark_df = df[df['benchmark'] == benchmark]
                
                f.write(f"% ============================================\n")
                f.write(f"% TABLE: {benchmark}\n")
                f.write(f"% ============================================\n\n")
                
                f.write("\\begin{table}[h]\n")
                f.write("\\centering\n")
                f.write("\\small\n")
                f.write("\\caption{Experimental Results: " + benchmark + "}\n")
                f.write("\\label{tab:" + benchmark.lower().replace(' ', '_').replace('/', '_') + "}\n")
                
                # Determine table width based on the number of columns
                num_cols = 10
                f.write("\\begin{tabular}{" + "l" + "c" * (num_cols - 1) + "}\n")
                f.write("\\toprule\n")
                
                # Header
                f.write("Scenario & Tool & N & Mean & SD & Median & IQR & CI 95\\% & Effect Size & p-value (FDR) \\\\\n")
                f.write(" & & & & & & & [lower, upper] & (Cohen's d) & \\\\\n")
                f.write("\\midrule\n")
                
                # Data grouped by scenario
                for scenario in benchmark_df['scenario'].unique():
                    scenario_df = benchmark_df[benchmark_df['scenario'] == scenario]
                    
                    # Escape scenario for LaTeX
                    scenario_escaped = escape_latex(scenario)

                    docker_rows = scenario_df[scenario_df['tool'] == 'docker']
                    container_rows = scenario_df[scenario_df['tool'] == 'container']

                    have_docker = not docker_rows.empty
                    have_container = not container_rows.empty
                    row_count = (1 if have_docker else 0) + (1 if have_container else 0)
                    if row_count == 0:
                        continue

                    # Effect size and p-value are comparison metrics; use the Docker row if it exists, otherwise the Container row.
                    ref_row = docker_rows.iloc[0] if have_docker else container_rows.iloc[0]
                    effect_size = ref_row.get('effect_size', np.nan)
                    p_val = ref_row.get('p_value_fdr_bh', np.nan)
                    if pd.isna(effect_size):
                        effect_str = "N/A"
                    else:
                        effect_str = f"{effect_size:.4f}"
                    if pd.isna(p_val):
                        p_str = "N/A"
                    else:
                        sig = "***" if p_val < 0.001 else "**" if p_val < 0.01 else "*" if p_val < 0.05 else ""
                        p_str = f"{p_val:.4f}{sig}"

                    # Row 1 (Docker if present; otherwise Container)
                    first_tool = 'docker' if have_docker else 'container'
                    first_row = docker_rows.iloc[0] if first_tool == 'docker' else container_rows.iloc[0]
                    first_label = "Docker" if first_tool == 'docker' else "Container"
                    f.write(f"\\multirow{{{row_count}}}{{*}}{{{scenario_escaped}}} & {first_label} & ")
                    f.write(f"{int(first_row['n'])} & ")
                    f.write(f"{first_row['mean']:.4f} & ")
                    f.write(f"{first_row['std']:.4f} & ")
                    f.write(f"{first_row['median']:.4f} & ")
                    f.write(f"{first_row['iqr']:.4f} & ")
                    f.write(f"[{first_row['ci_lower']:.4f}, {first_row['ci_upper']:.4f}] & ")
                    f.write(f"{effect_str} & {p_str} \\\\\n")

                    # Row 2 (if both exist)
                    if have_docker and have_container:
                        second_row = container_rows.iloc[0] if first_tool == 'docker' else docker_rows.iloc[0]
                        second_label = "Container" if first_tool == 'docker' else "Docker"
                        f.write(f" & {second_label} & ")
                        f.write(f"{int(second_row['n'])} & ")
                        f.write(f"{second_row['mean']:.4f} & ")
                        f.write(f"{second_row['std']:.4f} & ")
                        f.write(f"{second_row['median']:.4f} & ")
                        f.write(f"{second_row['iqr']:.4f} & ")
                        f.write(f"[{second_row['ci_lower']:.4f}, {second_row['ci_upper']:.4f}] & ")
                        f.write(" & ")  # Effect size and p-value already in the previous row
                        f.write(" \\\\\n")
                    
                    f.write("\\midrule\n")
                
                f.write("\\bottomrule\n")
                f.write("\\end{tabular}\n")
                f.write("\\begin{tablenotes}\n")
                f.write("\\small\n")
                f.write("\\item N: sample size; SD: standard deviation; IQR: interquartile range; ")
                f.write("CI: confidence interval; Effect Size: effect size (Cohen's d); ")
                f.write("p-value corrected by FDR (Benjamini-Hochberg).\n")
                f.write("\\item Significance: *** p < 0.001, ** p < 0.01, * p < 0.05\n")
                f.write("\\end{tablenotes}\n")
                f.write("\\end{table}\n\n")
            
            f.write("\\end{document}\n")
    except PermissionError as e:
        logger.error(f"No permission to write LaTeX table: {e}")
        raise
    except OSError as e:
        logger.error(f"I/O error writing LaTeX table: {e}")
        raise
    except KeyError as e:
        logger.error(f"Column not found while generating LaTeX table: {e}")
        raise
    except Exception as e:
        logger.error(f"Unexpected error generating LaTeX table: {type(e).__name__}: {e}", exc_info=True)
        raise
    
    # Message removed - not needed in the output
    logger.debug(f"LaTeX table generated with {df['benchmark'].nunique()} benchmarks")

def generate_enhanced_report(data, output_dir, validation_result=None, quiet=False):
    """Generate the robust statistical report
    
    Args:
        data: Dictionary of DataFrames with the data
        output_dir: Output directory
        validation_result: Result of the methodological rigor validation
        quiet: If True, do not print progress messages
    """
    report_path = os.path.join(output_dir, 'enhanced_analysis_report.txt')
    
    try:
        with open(report_path, 'w', encoding='utf-8') as f:
            f.write("=== ROBUST STATISTICAL ANALYSIS REPORT ===\n")
            f.write("BENCHMARK DOCKER VS APPLE CONTAINER\n\n")
            f.write(f"Analysis date: {pd.Timestamp.now()}\n")
            f.write(f"Script version: Enhanced Statistical Analysis v2.0\n\n")
            
            # Methodological Rigor Validation section (informational only)
            if validation_result:
                f.write("=== METHODOLOGICAL RIGOR ASSESSMENT (INFORMATIONAL) ===\n")
                f.write("This section assesses whether the collected data meet methodological rigor standards.\n")
                f.write("The statistical analysis is performed regardless of this result.\n\n")
                
                if validation_result['status'] == 'PASS':
                    f.write("✅ Status: Data meet methodological rigor\n")
                else:
                    f.write("⚠️  Status: Data do not fully meet methodological rigor\n")
                    f.write("   (Analysis performed normally, but results should be interpreted with caution)\n\n")
                
                if len(validation_result['issues']) > 0:
                    f.write("❌ Points of attention:\n")
                    for issue in validation_result['issues']:
                        f.write(f"  - {issue}\n")
                    f.write("\n")
                
                if len(validation_result['warnings']) > 0:
                    f.write("⚠️  Recommendations:\n")
                    for warning in validation_result['warnings']:
                        f.write(f"  - {warning}\n")
                    f.write("\n")
                
                if validation_result['status'] != 'PASS':
                    f.write("NOTE: For full methodological rigor, running with 30 iterations is recommended.\n")
                    f.write("The results presented below are valid, but may have statistical limitations.\n")
                
                f.write("\n")
            
            # Enhanced descriptive statistics
            if 'main' in data:
                f.write("=== ENHANCED DESCRIPTIVE STATISTICS ===\n")
                stats_df, ci_df = calculate_enhanced_statistics(data['main'])
                f.write("Basic Statistics (including Median and IQR):\n")
                f.write(stats_df.to_string())
                f.write("\n\nConfidence Intervals (95%):\n")
                f.write(ci_df.to_string())
                f.write("\n\n")
                
                # Highlighted section with Median and IQR
                f.write("=== ROBUST STATISTICS (Median and IQR) ===\n")
                f.write("Median and IQR are robust statistics that are not affected by outliers.\n")
                f.write("IQR (Interquartile Range) = Q3 - Q1\n\n")
                robust_stats = stats_df[['median', 'q25', 'q75', 'iqr', 'mean', 'std']].copy()
                f.write(robust_stats.to_string())
                f.write("\n\n")
                
                # Robust statistical tests for main (startup)
                f.write("=== ROBUST STATISTICAL ANALYSIS (STARTUP) ===\n")
                robust_tests = perform_robust_statistical_tests(data['main'])
                
                if not robust_tests.empty:
                    # Apply multiple comparison corrections
                    robust_tests = apply_multiple_comparison_correction(robust_tests, 'bonferroni')
                    robust_tests = apply_multiple_comparison_correction(robust_tests, 'fdr_bh')
                    
                    f.write("Statistical Test Results:\n")
                    f.write(robust_tests.to_string(index=False))
                    f.write("\n\n")
                    
                    # Detailed interpretation
                    f.write("=== DETAILED INTERPRETATION ===\n")
                    
                    for _, row in robust_tests.iterrows():
                        f.write(f"\n--- {row['scenario']} ---\n")
                        f.write(f"Test used: {row['test_used']}\n")
                        f.write(f"Sample size: Docker={row['docker_n']}, Apple container={row['container_n']}\n")
                        f.write(f"Normality: Docker={row['docker_normal']}, Apple container={row['container_normal']}\n")
                        f.write(f"Homogeneity of variances: {row['homogeneous_var']}\n")
                        f.write(f"P-value (uncorrected): {row['p_value']:.6f}\n")
                        f.write(f"P-value (Bonferroni): {row['p_value_bonferroni']:.6f}\n")
                        f.write(f"P-value (FDR): {row['p_value_fdr_bh']:.6f}\n")
                        f.write(f"Significant (FDR): {row['significant_fdr_bh']}\n")
                        f.write(f"Effect size (Cohen's d): {row['effect_size']:.4f} ({row['effect_interpretation']})\n")
                        f.write(f"Statistical power: {row['statistical_power']:.4f} ({row['power_interpretation']})\n")
                        
                        if row['significant_fdr_bh']:
                            better_tool = "Docker" if row['docker_mean'] < row['container_mean'] else "Apple container"
                            f.write(f"CONCLUSION: {better_tool} is significantly better (p={row['p_value_fdr_bh']:.6f})\n")
                        else:
                            f.write("CONCLUSION: No significant difference found\n")
                    
                    # Analysis of variance
                    f.write("\n=== ANALYSIS OF VARIANCE (ANOVA) ===\n")
                    anova_results = perform_anova_analysis(data['main'])
                    if 'anova' in anova_results:
                        anova = anova_results['anova']
                        f.write(f"Test used: {anova['test_used']}\n")
                        f.write(f"Statistic: {anova['statistic']:.6f}\n")
                        f.write(f"P-value: {anova['p_value']:.6f}\n")
                        f.write(f"Significant: {anova['significant']}\n")
                        f.write("Normality check per group:\n")
                        for norm_check in anova['normality_check']:
                            f.write(f"  {norm_check['group']}: {norm_check['normal']}\n")
                    
                    # Executive summary
                    f.write("\n=== EXECUTIVE SUMMARY ===\n")
                    significant_tests = robust_tests[robust_tests['significant_fdr_bh']]
                    total_tests = len(robust_tests)
                    
                    f.write(f"Total tests performed: {total_tests}\n")
                    f.write(f"Tests with significant difference (FDR corrected): {len(significant_tests)}\n")
                    f.write(f"Significance rate: {len(significant_tests)/total_tests*100:.1f}%\n\n")
                    
                    # Statistical power analysis
                    low_power_tests = robust_tests[robust_tests['power_interpretation'] == 'Low']
                    f.write(f"Tests with low statistical power: {len(low_power_tests)}\n")
                    if len(low_power_tests) > 0:
                        f.write("WARNING: Some tests have low statistical power. Consider increasing the sample size.\n\n")
                    
                    # Effect size analysis
                    large_effects = robust_tests[robust_tests['effect_interpretation'] == 'Large']
                    medium_effects = robust_tests[robust_tests['effect_interpretation'] == 'Medium']
                    f.write(f"Large effects found: {len(large_effects)}\n")
                    f.write(f"Medium effects found: {len(medium_effects)}\n\n")
                    
                    # Recommendations
                    f.write("=== RECOMMENDATIONS ===\n")
                    if len(low_power_tests) > 0:
                        f.write("1. Increase the sample size to improve statistical power\n")
                    if len(significant_tests) == 0:
                        f.write("2. Investigate whether the lack of significance is due to low statistical power\n")
                    f.write("3. Consider additional analyses for scenarios with large effects\n")
                    f.write("4. Document all experimental settings for replicability\n")
                    f.write("5. Perform cross-validation of the results\n")
            
            # Statistical tests for the new benchmarks (fio, stream, math)
            for benchmark_name, benchmark_key in [('Disk I/O', 'fio'), ('STREAM', 'stream'), ('Math', 'math')]:
                if benchmark_key in data:
                    benchmark_data = data[benchmark_key]
                    if not benchmark_data.empty:
                        # Select the appropriate metric
                        if benchmark_key == 'fio':
                            metric_filter = benchmark_data['metric'] == 'throughput_kb_per_sec'
                            metric_name = 'Throughput (KB/s)'
                        elif benchmark_key == 'stream':
                            metric_filter = benchmark_data['metric'] == 'bandwidth_mb_per_sec'
                            metric_name = 'Bandwidth (MB/s)'
                        elif benchmark_key == 'math':
                            metric_filter = benchmark_data['metric'] == 'time_seconds'
                            metric_name = 'Execution Time (seconds)'
                        else:
                            continue
                        
                        filtered_data = benchmark_data[metric_filter].copy()
                        if not filtered_data.empty:
                            f.write(f"\n=== ROBUST STATISTICAL ANALYSIS ({benchmark_name}) ===\n")
                            # Use 'test' as scenario_col for the new benchmarks
                            robust_tests = perform_robust_statistical_tests(filtered_data, scenario_col='test')
                            
                            if not robust_tests.empty:
                                # Apply multiple comparison corrections
                                robust_tests = apply_multiple_comparison_correction(robust_tests, 'bonferroni')
                                robust_tests = apply_multiple_comparison_correction(robust_tests, 'fdr_bh')
                                
                                f.write(f"Metric: {metric_name}\n")
                                f.write("Statistical Test Results:\n")
                                f.write(robust_tests.to_string(index=False))
                                f.write("\n\n")
                                
                                # Brief interpretation
                                f.write("=== SUMMARY ===\n")
                                significant_tests = robust_tests[robust_tests['significant_fdr_bh']]
                                f.write(f"Tests with significant difference: {len(significant_tests)}/{len(robust_tests)}\n")
                                
                                for _, row in significant_tests.iterrows():
                                    better_tool = "Docker" if row['docker_mean'] < row['container_mean'] else "Apple container"
                                    # For math, lower time is better; for others, higher is better
                                    if benchmark_key == 'math':
                                        better_tool = "Docker" if row['docker_mean'] < row['container_mean'] else "Apple container"
                                    else:
                                        better_tool = "Docker" if row['docker_mean'] > row['container_mean'] else "Apple container"
                                    f.write(f"  {row['scenario']}: {better_tool} is better (p={row['p_value_fdr_bh']:.6f}, d={row['effect_size']:.4f})\n")
                                f.write("\n")
            
            f.write("\n=== LIMITATIONS AND CONSIDERATIONS ===\n")
            f.write("1. Limited sample size may affect the robustness of the results\n")
            f.write("2. Multiple comparisons increase the chance of false positives\n")
            f.write("3. Non-parametric tests may have lower power than parametric tests\n")
            f.write("4. Results are specific to the experimental environment used\n")
            f.write("5. Interpretation of effect sizes should consider the practical context\n")
            
            logger.info(f"Statistical report generated successfully: {report_path}")
            if not quiet:
                print(f"✅ Statistical report saved to: {report_path}")
    except PermissionError as e:
        logger.error(f"No permission to write report: {e}")
        print(f"⚠️  Error: No permission to save report to {report_path}")
    except OSError as e:
        logger.error(f"I/O error writing report: {e}")
        print(f"⚠️  Error saving report: {e}")
    except Exception as e:
        logger.error(f"Unexpected error generating report: {type(e).__name__}: {e}", exc_info=True)
        print(f"⚠️  Unexpected error generating report: {e}")

def main():
    parser = argparse.ArgumentParser(description='Robust statistical analysis of the Docker vs Apple container benchmark')
    parser.add_argument('results_dir', help='Directory containing the benchmark results')
    parser.add_argument('--output', '-o', help='Output directory for charts and reports', default='enhanced_analysis_output')
    parser.add_argument('--alpha', type=float, default=0.05, help='Significance level (default: 0.05)')
    parser.add_argument('--sample-size', action='store_true', help='Include sample size analysis (Raj Jain Ch. 13)')
    parser.add_argument('--precision', type=float, default=5.0, help='Desired precision in %% for the sample size analysis (default: 5.0)')
    parser.add_argument('--quiet', '-q', action='store_true', help='Quiet mode: compact output, no detailed logs')
    parser.add_argument('--verbose', '-v', action='store_true', help='Verbose mode: show all detailed information')
    
    args = parser.parse_args()
    
    # Automatically detect quiet mode when called by a script (environment variable)
    if os.environ.get('ANALYSIS_QUIET', '').lower() in ('1', 'true', 'yes'):
        args.quiet = True
    
    # Quiet and verbose are mutually exclusive
    if args.quiet:
        args.verbose = False
    
    if not os.path.exists(args.results_dir):
        print(f"Error: Directory {args.results_dir} not found")
        sys.exit(1)
    
    # Create output directory
    os.makedirs(args.output, exist_ok=True)
    
    # Configure logging with a file in the output directory
    setup_logging(args.output, quiet=args.quiet)
    
    if not args.quiet:
        print("Loading data...")
    data = load_data(args.results_dir, quiet=args.quiet)
    
    if not data:
        print("Error: No data found for analysis")
        sys.exit(1)
    
    # Validate methodological rigor before analyzing (informational only, does not prevent analysis)
    # Use compact mode if quiet is enabled
    # Use precision and confidence from the arguments (or defaults)
    confidence_level = 1 - args.alpha
    validation_result = validate_methodological_rigor(
        data, 
        min_iterations=30, 
        min_valid=25, 
        compact=args.quiet,
        desired_precision_percent=args.precision,
        confidence_level=confidence_level
    )
    
    if not args.quiet:
        if not validation_result['ready_for_analysis']:
            print("\n⚠️  NOTICE: Data do not fully meet methodological rigor.")
            print("   The analysis will be performed normally, but the results should be interpreted with caution.")
            print("   For full methodological rigor, run again with 30 iterations.\n")
        else:
            print("\n✅ Data meet methodological rigor - the analysis will be performed normally.\n")
    
    if not args.quiet:
        print("Generating enhanced visualizations...")
    create_enhanced_visualizations(data, args.output)
    
    if not args.quiet:
        print("Generating complete experimental table...")
    experimental_table = generate_experimental_table(data, args.output, quiet=args.quiet, alpha=args.alpha)
    
    if not args.quiet:
        print("Generating robust statistical report...")
    generate_enhanced_report(data, args.output, validation_result=validation_result, quiet=args.quiet)
    
    # Sample size analysis (Raj Jain Ch. 13)
    if args.sample_size:
        print("\n" + "="*70)
        print("📊 SAMPLE SIZE ANALYSIS (Raj Jain, Ch. 13)")
        print("="*70)
        try:
            import sys as sys_module
            import os as os_module
            sys_module.path.insert(0, os_module.path.dirname(os_module.path.abspath(__file__)))
            from sample_size_analysis import generate_sample_size_report
            sample_size_df, sample_size_report = generate_sample_size_report(
                args.results_dir,
                output_file=os_module.path.join(args.output, 'sample_size_analysis.txt'),
                confidence_level=1 - args.alpha,
                desired_precision_percent=args.precision
            )
            print(f"✅ Sample size analysis completed!")
            print(f"   Report saved to: {os_module.path.join(args.output, 'sample_size_analysis.txt')}")
            
            # Add summary to the main report
            with open(os_module.path.join(args.output, 'enhanced_analysis_report.txt'), 'a', encoding='utf-8') as f:
                f.write("\n\n" + "="*70 + "\n")
                f.write("SAMPLE SIZE ANALYSIS (Raj Jain, Ch. 13)\n")
                f.write("="*70 + "\n\n")
                insufficient = sample_size_df[~sample_size_df['sufficient']]
                if len(insufficient) > 0:
                    f.write(f"⚠️  {len(insufficient)} scenarios need more replications:\n\n")
                    for _, row in insufficient.iterrows():
                        additional = row['required_n'] - row['current_n']
                        f.write(f"  - {row['scenario']} ({row['tool']}): ")
                        f.write(f"Add {additional} replications ")
                        f.write(f"(current: {row['current_n']}, required: {row['required_n']})\n")
                else:
                    f.write("✅ All scenarios have a sufficient number of replications!\n")
                f.write(f"\nSee full details in: sample_size_analysis.txt\n")
        except ImportError as e:
            logger.warning(f"Module sample_size_analysis not found. Skipping sample size analysis: {e}")
            print("⚠️  Module sample_size_analysis not found. Skipping sample size analysis.")
        except FileNotFoundError as e:
            logger.error(f"Required file for sample size analysis not found: {e}")
            print(f"⚠️  Error: File not found in sample size analysis: {e}")
        except ValueError as e:
            logger.error(f"Validation error in sample size analysis: {e}")
            print(f"⚠️  Validation error in sample size analysis: {e}")
        except Exception as e:
            logger.error(f"Unexpected error in sample size analysis: {type(e).__name__}: {e}", exc_info=True)
            print(f"⚠️  Error in sample size analysis: {e}")
    
    if args.quiet:
        # Compact mode: essential summary only, with formatting similar to Bash
        file_count = 0
        if experimental_table is not None:
            file_count += 3  # CSV, LaTeX, summary
        if 'main' in data:
            file_count += 3  # startup analysis, cdf, dashboard
        elif 'sysbench' in data:
            file_count += 2  # performance, dashboard
        if 'fio' in data or 'stream' in data or 'math' in data:
            file_count += 2  # performance, dashboard
        
        # Count the report file
        file_count += 1  # enhanced_analysis_report.txt
        
        print(f"  ✅ Analysis completed")
        print(f"  📁 Files generated: {file_count} files (CSV, PNG, TXT, LaTeX)")
        
        # Show only important warnings
        if validation_result and not validation_result['ready_for_analysis']:
            issues_count = len(validation_result.get('issues', []))
            warnings_count = len(validation_result.get('warnings', []))
            if issues_count > 0 or warnings_count > 0:
                print(f"  ⚠️  Warning: {issues_count + warnings_count} issue(s) requiring attention (n < 30 in some scenarios)")
                print(f"     Results should be interpreted with caution")
    else:
        # Verbose mode: show everything
        print(f"\nRobust statistical analysis completed! Results saved to: {args.output}")
        print("\nFiles generated:")
        
        # Add information about the experimental table
        if experimental_table is not None:
            print("- experimental_table_complete.csv: Complete experimental table (all metrics)")
            print("- experimental_table_complete.tex: Formatted LaTeX table")
            print("- experimental_table_summary.csv: Summary table (key metrics)")
        
        # Determine which files were generated based on the available data
        if 'main' in data:
            print("- enhanced_startup_analysis.png: Detailed visual startup analysis")
            print("- cdf_boxen_analysis.png: CDF and Boxen plots")
        if 'sysbench' in data and 'main' not in data:
            print("- performance_analysis.png: Detailed visual performance analysis (CPU/Memory)")
            print("- statistical_dashboard.png: Statistical dashboard")
        elif 'main' in data:
            print("- statistical_analysis_dashboard.png: Statistical dashboard")
    
    # New benchmarks
    if 'fio' in data:
        print("- performance_analysis.png: Disk I/O visual analysis (fio)")
    if 'stream' in data:
        print("- performance_analysis.png: STREAM visual analysis (Memory Bandwidth)")
    if 'math' in data:
        print("- performance_analysis.png: Math (PI calculation) visual analysis")
    
    print("- enhanced_analysis_report.txt: Robust statistical report")

if __name__ == "__main__":
    main()
