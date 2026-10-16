#!/usr/bin/env bash

# =============================================================================
# STATISTICAL UTILITIES
# =============================================================================
#
# Utility functions related to sample size and statistical parameters
# for the performance experiments.
#
# Based on Raj Jain - The Art of Computer Systems Performance Analysis
# (Chapter 13 - Sample Size, Confidence Intervals, and Tests of Hypotheses).
# =============================================================================

# -----------------------------------------------------------------------------
# calculate_min_sample_size
# -----------------------------------------------------------------------------
# Computes the recommended minimum sample size (n) for a given confidence
# level, using Raj Jain's rule of thumb.
#
# Concept:
#   General formula for sample size:
#     n = (z_{α/2} * σ / E)^2
#   Where:
#     - z_{α/2}: critical value of the normal distribution
#     - σ: population standard deviation (unknown a priori)
#     - E: desired absolute margin of error
#
# Since σ is unknown before the experiment, Jain recommends, in practice:
#   - n >= 30 observations for usual confidence levels (90%, 95%, 99%)
#   - With n >= 30 we can use Student's t distribution with a good approximation
#
# Parameters:
#   $1 - Confidence level in decimal format (e.g., 0.95, 0.90, 0.99)
#        (currently does not change the returned value, but is accepted for
#         future extension, if needed).
#
# Returns:
#   n_min - recommended minimum sample size (integer)
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# get_z_critical
# -----------------------------------------------------------------------------
# Returns the critical value z_{α/2} for a given confidence level.
#
# Reference: Raj Jain, Ch. 13 — critical values for two-sided CI
#   90% CI: z = 1.645  (α=0.10, α/2=0.05)  — Examples 13.7, 13.8, 13.9
#   95% CI: z = 1.960  (α=0.05, α/2=0.025) — Examples 13.9, 13.11, 13.13
#   99% CI: z = 2.576  (α=0.01, α/2=0.005) — Example 13.10
#
# Parameters:
#   $1 - confidence — confidence level in decimal format (e.g., 0.95, 0.99)
#
# Returns:
#   z — critical value (printed to stdout)
# -----------------------------------------------------------------------------
get_z_critical() {
    local confidence=${1:-0.95}
    local z
    if   [ "$(echo "$confidence >= 0.99" | bc -l)" -eq 1 ]; then z=2.576
    elif [ "$(echo "$confidence >= 0.95" | bc -l)" -eq 1 ]; then z=1.96
    elif [ "$(echo "$confidence >= 0.90" | bc -l)" -eq 1 ]; then z=1.645
    else z=1.645
    fi
    echo "$z"
}

calculate_min_sample_size() {
    local confidence=${1:-0.95}

    # Typical z_{α/2} values (commented for reference only):
    # 90%: z = 1.645
    # 95%: z = 1.96
    # 99%: z = 2.576

    # Raj Jain's rule of thumb: minimum of 30 observations
    # to allow reliable use of Student's t distribution.
    local n_min=30

    echo "$n_min"
}

# -----------------------------------------------------------------------------
# calculate_required_sample_size
# -----------------------------------------------------------------------------
# Computes the sample size required to reach a relative precision r
# (e.g., 5%) with a specified confidence level, using the formula
# presented by Jain for the mean.
#
# Formula (for the mean):
#   n = (z_{α/2} * s / (r * \bar{X}))^2
#   where:
#     - z_{α/2}: critical value (normal) for the desired confidence level
#     - s: sample standard deviation
#     - r: allowed relative error (e.g., 0.05 for 5%)
#     - \bar{X}: sample mean
#
# Parameters:
#   $1 - mean          (sample mean)
#   $2 - std           (sample standard deviation)
#   $3 - rel_error     (desired relative error, e.g., 0.05 = 5%)
#   $4 - confidence    (confidence level, e.g., 0.95)
#
# Returns:
#   n_recommended - recommended sample size (integer, already rounded
#                   up and with a minimum floor of 30 observations)
# -----------------------------------------------------------------------------
calculate_required_sample_size() {
    local mean=$1
    local std=$2
    local rel_error=${3:-0.05}
    local confidence=${4:-0.95}

    # If mean or standard deviation are invalid, return the minimum floor
    if [ -z "$mean" ] || [ -z "$std" ] || [ "$(echo "$mean <= 0" | bc -l)" -eq 1 ] || [ "$(echo "$std < 0" | bc -l)" -eq 1 ]; then
        echo "30"
        return
    fi

    # Map confidence level to z_{α/2}
    # Reference: Raj Jain, Ch. 13 — critical values for two-sided CI
    #   90% CI: z = 1.645  (α=0.10, α/2=0.05)  — Examples 13.7, 13.8, 13.9
    #   95% CI: z = 1.960  (α=0.05, α/2=0.025) — Examples 13.9, 13.11, 13.13
    #   99% CI: z = 2.576  (α=0.01, α/2=0.005) — Example 13.10
    local z
    if [ "$(echo "$confidence >= 0.99" | bc -l)" -eq 1 ]; then
        z=2.576
    elif [ "$(echo "$confidence >= 0.95" | bc -l)" -eq 1 ]; then
        z=1.96
    elif [ "$(echo "$confidence >= 0.90" | bc -l)" -eq 1 ]; then
        z=1.645
    else
        # Confidence too low or not explicitly supported: use 1.645 (≈ 90%)
        z=1.645
    fi

    # Allowed absolute error: E = r * mean
    local E
    E=$(echo "$rel_error * $mean" | bc -l)

    # Avoid division by zero or a very small E
    if [ "$(echo "$E <= 0" | bc -l)" -eq 1 ]; then
        echo "30"
        return
    fi

    # n = (z * s / E)^2
    local n
    n=$(echo "scale=6; ($z * $std / $E)^2" | bc -l)

    # Round up (ceil)
    local n_int
    n_int=$(printf '%s\n' "$n" | awk '{ if ($1 <= 0) print 1; else if ($1 == int($1)) print int($1); else print int($1)+1 }')

    # Apply minimum floor of 30 observations
    if [ "$n_int" -lt 30 ]; then
        n_int=30
    fi

    echo "$n_int"
}

# -----------------------------------------------------------------------------
# compute_stats_welford
# -----------------------------------------------------------------------------
# Computes descriptive statistics (mean, sample standard deviation, min, max)
# of a numeric column of a CSV, using Welford's online algorithm for the
# standard deviation.
#
# Welford's algorithm (1962):
#   Incrementally accumulates the sum of squared deviations, avoiding the
#   subtraction of large terms that causes catastrophic cancellation in the
#   classic computational formula (sumsq/n - mean²).
#
#   Per iteration:
#     count++
#     delta  = x - M          (deviation from the mean before the update)
#     M     += delta / count   (updated running mean)
#     M2    += delta * (x - M) (M already updated; accumulates Σ(xi - mean)²)
#
#   At the end: s = sqrt(M2 / (n-1))    ← Bessel's correction (divisor n-1)
#
# References:
#   Welford, B.P. (1962). Technometrics, 4(3), 419-420.
#   Knuth, D.E. (1997). TAOCP Vol. 2, 3rd ed., §4.2.2, eq. (15-16).
#   Chan, T.F. et al. (1983). The American Statistician, 37(3), 242-247.
#
# Usage:
#   tail -n +2 file.csv | compute_stats_welford [COLUMN] [FORMAT]
#
# Parameters:
#   COLUMN   — index of the column to process (default: 2)
#   FORMAT   — printf format string for the output (default: "%d,%d,%.2f,%.2f,%.2f,%.2f")
#              fields in order: iterations, valid_iterations, mean, std, min, max
#
# Output (stdout):
#   "iterations,valid_iterations,mean,std,min,max" formatted according to FORMAT
#   When there is no data: "0,0,0,0,0,0"
#
# Note: produces the sample standard deviation (ddof=1), consistent with np.std(ddof=1).
# -----------------------------------------------------------------------------
compute_stats_welford() {
    local col=${1:-2}
    local fmt=${2:-"%d,%d,%.2f,%.2f,%.2f,%.2f"}
    awk -F',' -v col="$col" -v fmt="$fmt" '{
        count++; delta=$col-M; M+=delta/count; M2+=delta*($col-M); sum+=$col
        if (min=="" || $col<min) min=$col
        if (max=="" || $col>max) max=$col
    } END {
        if (count>0) {
            mean=sum/count
            std=(count > 1) ? sqrt(M2/(count-1)) : 0
            printf fmt"\n", count, count, mean, std, min, max
        } else {
            printf "0,0,0,0,0,0\n"
        }
    }'
}

