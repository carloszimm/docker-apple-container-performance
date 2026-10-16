#!/usr/bin/env python3
"""
Sample Size Analysis (Required Number of Replications)
Based on Chapter 13 of Raj Jain: "The Art of Computer Systems Performance Analysis"

This module implements statistical methods to determine the required number
of replications (r) for each test, ensuring adequate precision and confidence.
"""

import numpy as np
import pandas as pd
from scipy import stats
from scipy.stats import t as t_dist
import warnings
warnings.filterwarnings('ignore')


def calculate_required_replications(
    sample_data,
    desired_precision=None,
    desired_precision_percent=None,
    confidence_level=0.95,
    use_t_distribution=True
):
    """
    Computes the required number of replications based on Raj Jain's methodology (Ch. 13).
    
    Method 1: Absolute Precision (E)
    r = (Z_{α/2} × σ / E)²
    
    Method 2: Relative Precision (percentage of the mean)
    r = (Z_{α/2} × CV / (E%))²
    where CV = σ / μ (coefficient of variation)
    
    Parameters:
    -----------
    sample_data : array-like
        Pilot sample data (may be partial)
    desired_precision : float, optional
        Desired absolute precision (E). E.g., if E=2, the mean will be within ±2 units
    desired_precision_percent : float, optional
        Desired relative precision as a percentage (E%). E.g., if E%=5, the mean will be within ±5% of the true mean
    confidence_level : float, default=0.95
        Confidence level (1 - α). Default: 0.95 (95%)
    use_t_distribution : bool, default=True
        If True, uses the t distribution (when σ is estimated from the sample)
        If False, uses the normal Z distribution (when σ is known)
    
    Returns:
    --------
    dict : Dictionary with:
        - 'required_replications': Minimum number of replications required
        - 'current_n': Current number of observations
        - 'sufficient': True if current n >= required n
        - 'method': Method used ('absolute' or 'relative')
        - 'precision': Precision used
        - 'confidence_level': Confidence level
        - 'sample_mean': Sample mean
        - 'sample_std': Sample standard deviation
        - 'sample_cv': Coefficient of variation
        - 'margin_of_error': Current margin of error with n observations
    """
    sample_data = np.array(sample_data)
    sample_data = sample_data[~np.isnan(sample_data)]  # Remove NaNs
    
    if len(sample_data) < 2:
        return {
            'required_replications': np.nan,
            'current_n': len(sample_data),
            'sufficient': False,
            'error': 'Sample too small (n < 2) to estimate variance'
        }
    
    n = len(sample_data)
    mean = np.mean(sample_data)
    std = np.std(sample_data, ddof=1)  # Sample standard deviation (n-1)
    cv = (std / mean * 100) if mean != 0 else np.inf  # Coefficient of variation in %
    
    # Significance level
    alpha = 1 - confidence_level
    
    # Determine which method to use
    if desired_precision is not None:
        method = 'absolute'
        E = desired_precision
    elif desired_precision_percent is not None:
        method = 'relative'
        E_percent = desired_precision_percent
        E = mean * (E_percent / 100)  # Convert percentage to absolute
    else:
        # If no precision is specified, default to 5% relative
        method = 'relative'
        E_percent = 5.0
        E = mean * (E_percent / 100)
    
    # Choose distribution (t or Z)
    if use_t_distribution:
        # Use the t distribution (when σ is estimated from the sample)
        # Initially use n-1 degrees of freedom
        # Then iterate if necessary
        df = n - 1
        critical_value = t_dist.ppf(1 - alpha/2, df)
    else:
        # Use the normal Z distribution (when σ is known)
        critical_value = stats.norm.ppf(1 - alpha/2)
    
    # Compute the required number of replications
    # r = (Z_{α/2} × σ / E)²
    if std == 0:
        # If there is no variability, 1 replication is sufficient
        required_r = 1
    else:
        required_r = ((critical_value * std) / E) ** 2
    
    # Round up (integer)
    required_r = int(np.ceil(required_r))
    
    # If the t distribution was used, may need to iterate (since df depends on n)
    if use_t_distribution and required_r > n:
        # Iterate until convergence
        max_iterations = 10
        for _ in range(max_iterations):
            old_r = required_r
            df = max(1, required_r - 1)  # df >= 1 avoids t_dist.ppf(p, 0) = NaN
            critical_value = t_dist.ppf(1 - alpha/2, df)
            required_r = int(np.ceil(((critical_value * std) / E) ** 2))
            if required_r == old_r:
                break
    
    # Compute the current margin of error with n observations
    if use_t_distribution:
        df_current = n - 1
        critical_current = t_dist.ppf(1 - alpha/2, df_current)
    else:
        critical_current = stats.norm.ppf(1 - alpha/2)
    
    margin_of_error = critical_current * (std / np.sqrt(n))
    
    result = {
        'required_replications': required_r,
        'current_n': n,
        'sufficient': n >= required_r,
        'method': method,
        'precision': E if method == 'absolute' else E_percent,
        'precision_absolute': E,
        'confidence_level': confidence_level,
        'alpha': alpha,
        'sample_mean': mean,
        'sample_std': std,
        'sample_cv': cv,
        'margin_of_error': margin_of_error,
        'margin_of_error_percent': (margin_of_error / mean * 100) if mean != 0 else np.inf,
        'critical_value': critical_value,
        'distribution': 't' if use_t_distribution else 'Z'
    }
    
    return result


def calculate_required_replications_for_comparison(
    data1,
    data2,
    desired_effect_size=None,
    desired_precision=None,
    power=0.8,
    alpha=0.05,
    test_type='two_sample'
):
    """
    Computes the required number of replications for a comparison between two groups.
    
    Based on power analysis to detect a specific effect size.
    
    Parameters:
    -----------
    data1, data2 : array-like
        Data for the two samples
    desired_effect_size : float, optional
        Desired effect size (Cohen's d). If None, uses the observed difference
    desired_precision : float, optional
        Minimum detectable difference (in absolute units)
    power : float, default=0.8
        Desired statistical power (1 - β)
    alpha : float, default=0.05
        Significance level
    test_type : str, default='two_sample'
        Test type ('two_sample' or 'paired')
    
    Returns:
    --------
    dict : Dictionary with the required number of replications per group
    """
    from statsmodels.stats.power import TTestIndPower, TTestPower
    
    data1 = np.array(data1)
    data2 = np.array(data2)
    data1 = data1[~np.isnan(data1)]
    data2 = data2[~np.isnan(data2)]
    
    if len(data1) < 2 or len(data2) < 2:
        return {
            'required_n_per_group': np.nan,
            'error': 'Samples too small to estimate parameters'
        }
    
    mean1 = np.mean(data1)
    mean2 = np.mean(data2)
    std1 = np.std(data1, ddof=1)
    std2 = np.std(data2, ddof=1)
    
    # Compute the effect size
    if desired_effect_size is None:
        # Use the observed Cohen's d
        pooled_std = np.sqrt(((len(data1) - 1) * std1**2 + (len(data2) - 1) * std2**2) / 
                            (len(data1) + len(data2) - 2))
        if pooled_std == 0:
            return {'required_n_per_group': np.nan, 'error': 'Zero variance'}
        effect_size = abs(mean1 - mean2) / pooled_std
    else:
        effect_size = abs(desired_effect_size)
    
    # If absolute precision is specified, convert to effect size
    if desired_precision is not None:
        pooled_std = np.sqrt(((len(data1) - 1) * std1**2 + (len(data2) - 1) * std2**2) / 
                            (len(data1) + len(data2) - 2))
        if pooled_std > 0:
            effect_size = desired_precision / pooled_std
    
    # Compute the required sample size
    if test_type == 'two_sample':
        required_n = TTestIndPower().solve_power(
            effect_size=effect_size,
            power=power,
            alpha=alpha,
            nobs1=None,
            ratio=1.0,  # Same size for both groups
            alternative='two-sided'
        )
    else:  # paired
        required_n = TTestPower().solve_power(
            effect_size=effect_size,
            power=power,
            alpha=alpha,
            nobs=None,
            alternative='two-sided'
        )
    
    required_n = int(np.ceil(required_n))
    
    return {
        'required_n_per_group': required_n,
        'total_required_n': required_n * 2 if test_type == 'two_sample' else required_n,
        'effect_size': effect_size,
        'power': power,
        'alpha': alpha,
        'current_n1': len(data1),
        'current_n2': len(data2),
        'sufficient': min(len(data1), len(data2)) >= required_n
    }


def analyze_sample_size_requirements(
    results_dir,
    confidence_level=0.95,
    desired_precision_percent=5.0,
    power=0.8,
    alpha=0.05
):
    """
    Analyzes the sample size requirements for all benchmarks.
    
    Parameters:
    -----------
    results_dir : str
        Directory containing the CSV results
    confidence_level : float
        Desired confidence level
    desired_precision_percent : float
        Desired relative precision (%)
    power : float
        Desired statistical power for comparisons
    alpha : float
        Significance level
    
    Returns:
    --------
    pd.DataFrame : Table with sample size requirements per scenario
    """
    import os
    
    results = []
    
    # Load data
    csv_files = {
        'main': 'results_main.csv',
        'sysbench': 'results_sysbench.csv',
        'wrk': 'results_wrk.csv',
        'fio': 'results_fio.csv',
        'stream': 'results_stream.csv',
        'math': 'results_math.csv'
    }
    
    for key, filename in csv_files.items():
        filepath = os.path.join(results_dir, filename)
        if not os.path.exists(filepath):
            continue
        
        df = pd.read_csv(filepath)
        
        # Determine grouping columns
        if 'tool' in df.columns and 'scenario' in df.columns:
            group_cols = ['tool', 'scenario']
            if 'metric' in df.columns:
                group_cols.append('metric')
            metric_col = 'value' if 'value' in df.columns else df.select_dtypes(include=[np.number]).columns[0]
        elif 'tool' in df.columns and 'test' in df.columns:
            group_cols = ['tool', 'test']
            if 'threads' in df.columns:
                group_cols.append('threads')
            if 'metric' in df.columns:
                group_cols.append('metric')
            metric_col = 'value' if 'value' in df.columns else df.select_dtypes(include=[np.number]).columns[0]
        else:
            continue
        
        # Analyze each group
        for group_name, group_df in df.groupby(group_cols):
            values = pd.to_numeric(group_df[metric_col], errors='coerce')
            values = values.dropna().values
            
            if len(values) < 2:
                continue
            
            # Compute requirements
            sample_size_result = calculate_required_replications(
                values,
                desired_precision_percent=desired_precision_percent,
                confidence_level=confidence_level,
                use_t_distribution=True
            )
            
            if isinstance(group_name, tuple):
                tool = group_name[0]
                # Build the scenario label from all elements besides 'tool'
                # (test/scenario, threads if present, metric if present)
                scenario = '/'.join(str(v) for v in group_name[1:])
            else:
                tool = group_name
                scenario = "N/A"

            results.append({
                'benchmark': key,
                'tool': tool,
                'scenario': scenario,
                'current_n': sample_size_result['current_n'],
                'required_n': sample_size_result['required_replications'],
                'sufficient': sample_size_result['sufficient'],
                'mean': sample_size_result['sample_mean'],
                'std': sample_size_result['sample_std'],
                'cv': sample_size_result['sample_cv'],
                'margin_of_error': sample_size_result['margin_of_error'],
                'margin_of_error_percent': sample_size_result['margin_of_error_percent'],
                'precision_percent': desired_precision_percent
            })
    
    return pd.DataFrame(results)


def generate_sample_size_report(results_dir, output_file=None, **kwargs):
    """
    Generates a complete sample size analysis report.
    
    Parameters:
    -----------
    results_dir : str
        Directory with results
    output_file : str, optional
        Output file. If None, prints to the screen
    **kwargs : dict
        Parameters for analyze_sample_size_requirements
    """
    df = analyze_sample_size_requirements(results_dir, **kwargs)
    
    if df.empty:
        report = "No data found for sample size analysis.\n"
    else:
        report = "=" * 80 + "\n"
        report += "SAMPLE SIZE ANALYSIS (REQUIRED NUMBER OF REPLICATIONS)\n"
        report += "Based on Raj Jain, Ch. 13: The Art of Computer Systems Performance Analysis\n"
        report += "=" * 80 + "\n\n"
        
        report += f"Analysis Parameters:\n"
        report += f"  - Confidence Level: {kwargs.get('confidence_level', 0.95)*100:.1f}%\n"
        report += f"  - Desired Precision: ±{kwargs.get('desired_precision_percent', 5.0):.1f}% of the mean\n"
        report += f"  - Distribution: t (when σ is estimated from the sample)\n\n"
        
        report += "=" * 80 + "\n"
        report += "SUMMARY BY SCENARIO\n"
        report += "=" * 80 + "\n\n"
        
        # Summary by scenario
        for scenario in df['scenario'].unique():
            scenario_df = df[df['scenario'] == scenario]
            report += f"\n{scenario}:\n"
            report += "-" * 80 + "\n"
            
            for _, row in scenario_df.iterrows():
                status = "✅" if row['sufficient'] else "⚠️"
                report += f"  {status} {row['tool']:12s}: "
                report += f"n={row['current_n']:2d} | "
                report += f"Required={row['required_n']:2d} | "
                report += f"CV={row['cv']:5.2f}% | "
                report += f"Current error=±{row['margin_of_error_percent']:.2f}%\n"
        
        report += "\n" + "=" * 80 + "\n"
        report += "RECOMMENDATIONS\n"
        report += "=" * 80 + "\n\n"
        
        insufficient = df[~df['sufficient']]
        if len(insufficient) > 0:
            report += f"⚠️  {len(insufficient)} scenarios need more replications:\n\n"
            for _, row in insufficient.iterrows():
                additional = row['required_n'] - row['current_n']
                report += f"  - {row['scenario']} ({row['tool']}): "
                report += f"Add {additional} replications "
                report += f"(current: {row['current_n']}, required: {row['required_n']})\n"
        else:
            report += "✅ All scenarios have a sufficient number of replications!\n"
        
        report += "\n" + "=" * 80 + "\n"
        report += "STATISTICAL DETAILS\n"
        report += "=" * 80 + "\n\n"
        report += df.to_string(index=False)
        report += "\n\n"
        
        report += "=" * 80 + "\n"
        report += "METHODOLOGICAL NOTES\n"
        report += "=" * 80 + "\n\n"
        report += "1. The number of replications is computed using the formula:\n"
        report += "   r = (t_{α/2} × s / E)²\n"
        report += "   where:\n"
        report += "   - t_{α/2} is the critical value of the t distribution\n"
        report += "   - s is the sample standard deviation\n"
        report += "   - E is the desired precision (in absolute units)\n\n"
        report += "2. The relative precision (E%) is converted to absolute: E = μ × (E% / 100)\n\n"
        report += "3. The t distribution is used because the standard deviation is estimated from the sample.\n\n"
        report += "4. The computation is iterative when needed for convergence.\n\n"
    
    if output_file:
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(report)
        print(f"Report saved to: {output_file}")
    else:
        print(report)
    
    return df, report


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Sample size analysis (required number of replications)'
    )
    parser.add_argument('results_dir', help='Directory containing CSV results')
    parser.add_argument('--output', '-o', help='Output file', default=None)
    parser.add_argument('--confidence', type=float, default=0.95, help='Confidence level (default: 0.95)')
    parser.add_argument('--precision', type=float, default=5.0, help='Desired precision in % (default: 5.0)')
    
    args = parser.parse_args()
    
    generate_sample_size_report(
        args.results_dir,
        output_file=args.output,
        confidence_level=args.confidence,
        desired_precision_percent=args.precision
    )

