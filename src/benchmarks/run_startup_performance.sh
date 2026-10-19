#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# STARTUP PERFORMANCE BENCHMARK
# =============================================================================
#
# DESCRIPTION:
#   Script that runs container startup time benchmarks, comparing Docker
#   Desktop and Apple container. The script follows a rigorous methodology
#   based on Raj Jain for computer systems performance analysis, including
#   warmup iterations, randomization and statistical validation.
#
# FEATURES:
#   - Measures container startup time on both runtimes
#   - Runs warmup iterations (discarded) for stabilization
#   - Randomizes the test execution order
#   - Validates results and computes descriptive statistics
#   - Generates CSV files with results and a manifest with metadata
#
# PARAMETERS (Environment Variables):
#
#   Benchmark-Specific Parameters:
#   PAUSE_STARTUP_OVERRIDE
#       Pause time (in seconds) between iterations for system stabilization.
#       Default: 2
#       Example: PAUSE_STARTUP_OVERRIDE=3 ./run_startup_performance.sh
#
#   Parameters Common to All Benchmarks:
#   ITERATIONS_OVERRIDE
#       Number of main iterations to run.
#       Default: 30
#       Example: ITERATIONS_OVERRIDE=10 ./run_startup_performance.sh
#
#   WARMUP_ITERATIONS_OVERRIDE
#       Number of warmup iterations (discarded) run before the main
#       iterations. Use 0 to disable warmup.
#       Default: 5
#       Example: WARMUP_ITERATIONS_OVERRIDE=0 ./run_startup_performance.sh
#
#   MIN_VALID_OVERRIDE
#       Minimum number of valid iterations required to consider the
#       experiment valid.
#       Default: 30
#       Example: MIN_VALID_OVERRIDE=25 ./run_startup_performance.sh
#
#   ENABLE_RANDOMIZATION
#       Enables or disables randomization of the test execution order.
#       Default: true
#       Values: true, false
#       Example: ENABLE_RANDOMIZATION=false ./run_startup_performance.sh
#
#   CONFIDENCE_LEVEL
#       Desired confidence level for confidence intervals (0.90, 0.95, 0.99).
#       Default: 0.95 (95%)
#       The script automatically computes the recommended minimum sample size.
#       Example: CONFIDENCE_LEVEL=0.99 ./run_startup_performance.sh
#
#   ENABLE_SAMPLE_SIZE_PRETEST
#       When true, runs a short startup pretest to estimate the recommended
#       sample size (n) based on Raj Jain, Ch. 13.9.
#       Default: false (uses only the practical minimum of 30 observations).
#       Example: ENABLE_SAMPLE_SIZE_PRETEST=true ./run_startup_performance.sh
#
#   TARGET_REL_ERROR
#       Target relative error (r) for the computation of n in the pretest.
#       Suggested default: 0.05 (5%).
#       Example: TARGET_REL_ERROR=0.03 ENABLE_SAMPLE_SIZE_PRETEST=true ./run_startup_performance.sh
#
#   PRETEST_ITERATIONS_OVERRIDE
#       Number of pretest iterations used to estimate the mean and standard deviation.
#       Default: 5
#       Example: PRETEST_ITERATIONS_OVERRIDE=10 ENABLE_SAMPLE_SIZE_PRETEST=true ./run_startup_performance.sh
#
# DEPENDENCIES:
#   - Docker Desktop installed and running
#   - Apple container installed and running
#   - alpine:3.24 image available on both runtimes
#
# OUTPUT:
#   Results are saved to: bench_results/startup_performance_<timestamp>/
#   - startup_performance_summary.csv: Consolidated summary with statistics
#   - docker_startup_warm_results.csv: Individual Docker results
#   - container_startup_warm_results.csv: Individual Apple container results
#   - results_main.csv: Main format for statistical analysis
#   - manifest.txt: Experiment metadata (configuration, methodology)
#
# METHODOLOGY:
#   - Warmup Phase: 5 initial discarded iterations (configurable)
#   - Execution Phase: 30 main iterations (configurable)
#   - Randomization: Fisher-Yates shuffle for execution order
#   - Validation: Checks that values are within the expected range (100ms - 30s)
#   - Statistics: Mean, standard deviation, minimum, maximum
#
# USAGE EXAMPLES:
#   # Default run (30 iterations, 5 warmup)
#   ./run_startup_performance.sh
#
#   # Quick test (2 iterations, no warmup)
#   ITERATIONS_OVERRIDE=2 WARMUP_ITERATIONS_OVERRIDE=0 ./run_startup_performance.sh
#
#   # Run without randomization
#   ENABLE_RANDOMIZATION=false ./run_startup_performance.sh
#
#   # Run with 10 warmup iterations
#   WARMUP_ITERATIONS_OVERRIDE=10 ./run_startup_performance.sh
#
#   # Run with a custom pause (3 seconds between iterations)
#   PAUSE_STARTUP_OVERRIDE=3 ./run_startup_performance.sh
#
# AUTHOR:
#   Alessandra Pereira - Docker Desktop vs Apple container performance comparison
#
# VERSION:
#   1.0
#
# DATE:
#   2025-11-28
#
# =============================================================================

# Load common output functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utils/common_output.sh"
# Load statistical utilities (minimum sample size, Raj Jain)
source "${SCRIPT_DIR}/../utils/statistical_utils.sh"
# Load benchmark utilities (centralized functions)
source "${SCRIPT_DIR}/../utils/benchmark_utils.sh"

# Enable emoji style for benchmarks
enable_emoji_output

# Settings (support override via environment)
# Parameter validation using validation functions (Phase 3)
ITERATIONS=$(validate_positive_integer "${ITERATIONS_OVERRIDE:-}" 30 "ITERATIONS_OVERRIDE")
MIN_VALID_ITERATIONS=$(validate_positive_integer "${MIN_VALID_OVERRIDE:-}" 30 "MIN_VALID_OVERRIDE")
# WARMUP_ITERATIONS can be 0 (to disable), so validate manually
if [ -n "${WARMUP_ITERATIONS_OVERRIDE:-}" ]; then
    if [[ "${WARMUP_ITERATIONS_OVERRIDE}" =~ ^[0-9]+$ ]] && [ "${WARMUP_ITERATIONS_OVERRIDE}" -ge 0 ]; then
        WARMUP_ITERATIONS="${WARMUP_ITERATIONS_OVERRIDE}"
    else
        print_warning "⚠️  Invalid value for WARMUP_ITERATIONS_OVERRIDE: '${WARMUP_ITERATIONS_OVERRIDE}'. Using default: 5"
        WARMUP_ITERATIONS=5
    fi
else
    WARMUP_ITERATIONS=5
fi
PAUSE_STARTUP=$(validate_positive_integer "${PAUSE_STARTUP_OVERRIDE:-}" 2 "PAUSE_STARTUP_OVERRIDE")

# Significance and confidence level
ALPHA_LEVEL=0.05
CONFIDENCE_LEVEL=$(validate_float_in_range "${CONFIDENCE_LEVEL:-}" 0.95 0.01 0.99 "CONFIDENCE_LEVEL")

# Compute the recommended minimum sample size for the specified confidence level
MIN_SAMPLE_SIZE_RECOMMENDED=$(calculate_min_sample_size "$CONFIDENCE_LEVEL")

# Check whether the number of iterations meets the recommended minimum
check_sample_size "$ITERATIONS" "$CONFIDENCE_LEVEL"

# Estimate recommended sample size via pretest (Raj Jain 13.9)
estimate_sample_size_startup_pretest() {
    local pretest_iterations=${PRETEST_ITERATIONS_OVERRIDE:-5}
    local rel_error=${TARGET_REL_ERROR:-0.05}
    local runtime="docker"
    local scenario="startup_warm"

    print_info "Sample size pretest (Raj Jain 13.9):"
    print_info "  Runtime: ${runtime}, Scenario: ${scenario}"
    print_info "  Pretest iterations: ${pretest_iterations}"
    local rel_error_pct
    rel_error_pct=$(echo "$rel_error * 100" | bc -l | cut -d'.' -f1)
    print_info "  Target relative error: ${rel_error_pct}%"

    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "/tmp/startup_pretest_$$.tmp")

    for i in $(seq 1 $pretest_iterations); do
        print_info "  Pretest ${i}/${pretest_iterations}..."

        local start_time end_time duration_seconds duration_ms
        start_time=$(date +%s.%N)

        # Run a simple container (same operation as the startup_warm scenario)
        docker run --rm alpine:3.24 echo "test" > /dev/null 2>&1

        end_time=$(date +%s.%N)
        duration_seconds=$(echo "$end_time - $start_time" | bc -l)
        duration_ms=$(echo "$duration_seconds * 1000" | bc -l | cut -d'.' -f1)

        # Basic validation (reasonable time between 100ms and 30s)
        if [ "$duration_ms" -ge 100 ] && [ "$duration_ms" -le 30000 ] 2>/dev/null; then
            echo "$duration_ms" >> "$tmp_file"
            print_success "  ✓ ${duration_ms}ms (valid for pretest)"
        else
            print_warning "  ⚠️  ${duration_ms}ms (invalid for pretest - outside expected range)"
        fi

        sleep "$PAUSE_STARTUP"
    done

    # Compute mean and standard deviation from the pretest
    if [ ! -s "$tmp_file" ]; then
        print_warning "⚠️  Pretest did not generate enough valid data to estimate sample size"
        rm -f "$tmp_file" 2>/dev/null || true
        return
    fi

    local stats
    stats=$(awk '{
        x[NR]=$1; sum+=$1
    } END {
        if (NR > 0) {
            mean = sum/NR
            for (i=1; i<=NR; i++) {
                sumsq += (x[i]-mean)*(x[i]-mean)
            }
            std = (NR>1) ? sqrt(sumsq/(NR-1)) : 0
            printf "%.6f %.6f\n", mean, std
        }
    }' "$tmp_file")

    rm -f "$tmp_file" 2>/dev/null || true

    local mean std
    mean=$(echo "$stats" | awk '{print $1}')
    std=$(echo "$stats" | awk '{print $2}')

    if [ -z "$mean" ] || [ -z "$std" ]; then
        print_warning "⚠️  Could not compute mean/standard deviation in the pretest"
        return
    fi

    print_info "  Mean (pretest): ${mean}ms"
    print_info "  Standard deviation (pretest): ${std}ms"
    
    # Compute CV for context
    local cv
    cv=$(echo "scale=2; ($std / $mean) * 100" | bc -l)
    print_info "  Coefficient of variation (CV): ${cv}%"

    # Compute n using Jain's formula 13.9 (before the floor)
    local z
    z=$(get_z_critical "$CONFIDENCE_LEVEL")
    
    local E n_calculado n_ceil
    E=$(echo "$rel_error * $mean" | bc -l)
    n_calculado=$(echo "scale=6; ($z * $std / $E)^2" | bc -l)
    n_ceil=$(printf '%s\n' "$n_calculado" | awk '{ if ($1 <= 0) print 1; else if ($1 == int($1)) print int($1); else print int($1)+1 }')
    
    # Get final n (with a floor of 30)
    local n_rec
    n_rec=$(calculate_required_sample_size "$mean" "$std" "$rel_error" "$CONFIDENCE_LEVEL")

    local conf_pct_display
    conf_pct_display=$(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)
    
    print_step "Sample size estimate (Raj Jain 13.9):"
    echo ""
    print_info "  Formula calculation:"
    print_info "    z_{{α/2}} = ${z} (${conf_pct_display}% confidence)"
    print_info "    E = r × X̄ = ${rel_error} × ${mean} = ${E} ms"
    print_info "    n = (z × s / E)² = (${z} × ${std} / ${E})²"
    print_info "    n = ${n_calculado}"
    print_info "    n (rounded up) = ${n_ceil} observations"
    echo ""
    
    if [ "$n_ceil" -lt 30 ]; then
        print_info "  Applying the minimum floor (Raj Jain):"
        print_info "    n_final = max(${n_ceil}, 30) = ${n_rec} observations"
        print_info "    → Rationale: Raj Jain recommends a minimum of 30 observations to"
        print_info "      ensure statistical robustness and reliable use of Student's t distribution"
    else
        print_info "  Final result:"
        print_info "    n_final = ${n_rec} observations (no minimum floor needed)"
    fi
    echo ""

    if [ "$ITERATIONS" -lt "$n_rec" ]; then
        local conf_pct
        conf_pct=$(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)
        print_warning "  ⚠️  Current iterations (${ITERATIONS}) below the recommendation (${n_rec}) for ${conf_pct}% confidence and relative error ${rel_error_pct}%"
        print_info "      → Consider increasing ITERATIONS_OVERRIDE to at least ${n_rec} for formal runs"
    else
        print_success "  ✓ Current iterations (${ITERATIONS}) ≥ recommended (${n_rec}) for the configured pretest"
    fi
}

# -----------------------------------------------------------------------------
# run_warmup_iterations
# -----------------------------------------------------------------------------
# Runs warmup iterations (discarded) to stabilize the system.
#
# Parameters:
#   $1 - Runtime to use ("docker" or "container")
#   $2 - Test type (e.g. "startup_warm")
#   $3 - Number of warmup iterations
#
# Returns:
#   0 on success
#   1 on error
#
# Note: Warmup iterations are discarded and do not count toward the results.
#       This helps stabilize the system before the actual measurements.
# -----------------------------------------------------------------------------
run_warmup_iterations() {
    local runtime=$1
    local test_type=$2
    local warmup_count=$3
    
    if [ "$warmup_count" -le 0 ]; then
        return 0
    fi
    
    print_info "  Running ${warmup_count} warmup iterations (discarded)..."
    
    for w in $(seq 1 $warmup_count); do
        if [ "$runtime" = "docker" ]; then
            if [ "$test_type" = "startup_warm" ]; then
                docker run --rm alpine:3.24 echo "test" > /dev/null 2>&1
            fi
        elif [ "$runtime" = "container" ]; then
            if [ "$test_type" = "startup_warm" ]; then
                run_container_with_standard_resources "container" "alpine:3.24" "echo" "test" > /dev/null 2>&1
            fi
        fi
        
        # Pause between warmup iterations
        sleep $PAUSE_STARTUP
    done
    
    print_success "  ✓ Warmup completed"
}

# -----------------------------------------------------------------------------
# run_benchmark
# -----------------------------------------------------------------------------
# Runs the main startup benchmark for a specific runtime.
#
# Parameters:
#   $1 - Runtime to use ("docker" or "container")
#   $2 - Test type (e.g. "startup_warm")
#   $3 - Number of main iterations
#
# Returns:
#   0 on success
#   1 on error
#
# Generates:
#   - CSV file with results: <runtime>_<test_type>_results.csv
#   - Basic statistics (mean, standard deviation, min, max)
#
# Note: Automatically validates results (time between 100ms and 30s).
#       Only valid iterations are counted.
# -----------------------------------------------------------------------------
run_benchmark() {
    local runtime=$1
    local test_type=$2
    local iterations=$3
    
    print_info "  Runtime: ${runtime}"
    print_info "  Scenario: ${test_type}"
    print_info "  Iterations: ${iterations}"
    echo ""
    
    # Warmup iterations (per Raj Jain)
    # WARMUP_ITERATIONS can be overridden via environment variable (default: 5)
    # If WARMUP_ITERATIONS=0, warmup is skipped
    if [ "$WARMUP_ITERATIONS" -gt 0 ]; then
        run_warmup_iterations "$runtime" "$test_type" $WARMUP_ITERATIONS
        echo ""
    else
        print_info "  ℹ Warmup disabled (WARMUP_ITERATIONS=${WARMUP_ITERATIONS})"
        echo ""
    fi
    
    local output_file="${OUTPUT_DIR}/${runtime}_${test_type}_results.csv"
    local valid_count=0
    local total_count=0
    local high_load_count=0
    
    # CSV header
    echo "iteration,time_ms" > "$output_file"
    
    print_info "  Running main iterations..."
    for i in $(seq 1 $iterations); do
        # Monitor system load before the iteration (threat T4 mitigation - documentation only)
        if ! "${SCRIPT_DIR}/../utils/monitor_system_load.sh" >> "${OUTPUT_DIR}/system_load_log.csv" 2>/dev/null; then
            print_warning "  ⚠️  System load above thresholds at iteration ${i}/${iterations} (documented, but continuing)"
            high_load_count=$((high_load_count + 1))
        fi
        
        local start_time=$(date +%s.%N)
        
        if [ "$runtime" = "docker" ]; then
            if [ "$test_type" = "startup_warm" ]; then
                docker run --rm alpine:3.24 echo "test" > /dev/null 2>&1
            fi
        elif [ "$runtime" = "container" ]; then
            if [ "$test_type" = "startup_warm" ]; then
                run_container_with_standard_resources "container" "alpine:3.24" "echo" "test" > /dev/null 2>&1
            fi
        fi
        
        local end_time=$(date +%s.%N)
        # Compute duration in seconds and convert to milliseconds
        local duration_seconds=$(echo "$end_time - $start_time" | bc -l)
        local duration=$(echo "$duration_seconds * 1000" | bc -l | cut -d'.' -f1)
        
        # Basic validation (reasonable time between 100ms and 30s)
        if [ "$duration" -ge 100 ] && [ "$duration" -le 30000 ] 2>/dev/null; then
            echo "${i},${duration}" >> "$output_file"
            valid_count=$((valid_count + 1))
            # Show progress every 5 iterations or on the last 3
            if [ $((i % 5)) -eq 0 ] || [ $i -gt $((iterations - 3)) ]; then
                print_info "    [${i}/${iterations}] ${duration}ms ✓"
            fi
        else
            print_warning "    [${i}/${iterations}] ${duration}ms ✗ (invalid - outside expected range)"
        fi
        
        total_count=$((total_count + 1))
        
        # Pause between iterations (standardized per experimental design)
        sleep $PAUSE_STARTUP
    done
    
    echo ""
    print_info "  Result: ${valid_count}/${total_count} valid iterations (high-load iterations documented: ${high_load_count})"
    
    if [ $valid_count -lt $MIN_VALID_ITERATIONS ]; then
        print_warning "  ⚠ Insufficient valid iterations (${valid_count}/${MIN_VALID_ITERATIONS} minimum)"
        # In validation mode, do not exit with an error (few iterations are expected)
        if [ "${VALIDATION_MODE:-false}" != "true" ]; then
            return 1
        fi
    fi
    
    print_success "  ✓ Benchmark completed successfully"
    return 0
}

# Consolidate results
# -----------------------------------------------------------------------------
# consolidate_results
# -----------------------------------------------------------------------------
# Consolidates results from all runtimes into a single CSV file.
#
# Generates:
#   - startup_performance_summary.csv: Consolidated summary with statistics
#
# Note: Computes descriptive statistics (mean, standard deviation, min, max)
#       for each combination of runtime and scenario.
# -----------------------------------------------------------------------------
consolidate_results() {
    local summary_file="${OUTPUT_DIR}/startup_performance_summary.csv"
    
    # Header
    echo "runtime,test_type,iterations,valid_iterations,mean_ms,std_ms,min_ms,max_ms" > "$summary_file"
    
    # Process each results file
    for file in "${OUTPUT_DIR}"/*_startup_warm_results.csv; do
        if [ -f "$file" ]; then
            local runtime=$(basename "$file" | cut -d'_' -f1)
            local test_type="startup_warm"
            
            # Compute statistics (Welford — sample standard deviation, ddof=1)
            local stats=$(tail -n +2 "$file" | compute_stats_welford 2 "%d,%d,%.2f,%.2f,%d,%d")
            
            echo "${runtime},${test_type},${stats}" >> "$summary_file"
        fi
    done

    # Generate consolidated file compatible with the enhanced analysis
    local main_file="${OUTPUT_DIR}/results_main.csv"
    echo "timestamp,platform,tool,scenario,metric,value,unit,notes" > "$main_file"
    for file in "${OUTPUT_DIR}"/*_startup_warm_results.csv; do
        if [ -f "$file" ]; then
            local tool=$(basename "$file" | cut -d'_' -f1)
            local scenario="startup_warm"
            # Raw CSVs are in ms; results_main.csv consolidates in seconds
            # (compatible with analyze_results_enhanced.py, which assumes unit="seconds"
            # for startup). Reports show values in ms (more readable scale).
            tail -n +2 "$file" | while IFS=',' read -r iteration time_ms; do
                if [ -n "$time_ms" ]; then
                    local timestamp=$(get_iso_timestamp)
                    local value_sec=$(echo "scale=6; $time_ms/1000" | bc -l)
                    echo "${timestamp},macOS,${tool},${scenario},startup_time,${value_sec},s,from_startup_only" >> "$main_file"
                fi
            done
        fi
    done
    
    print_success "  ✓ Results consolidated: $(basename "$summary_file")"
}

# Generate experimental manifest
# -----------------------------------------------------------------------------
# generate_manifest
# -----------------------------------------------------------------------------
# Generates the manifest.txt file with experiment metadata.
#
# Includes:
#   - System information (hardware, software)
#   - Experimental settings (iterations, warmup, confidence)
#   - Methodology used
#   - List of generated files
#
# Note: The manifest is essential for scientific reproducibility.
# -----------------------------------------------------------------------------
generate_manifest() {
    local manifest_file="${OUTPUT_DIR}/manifest.txt"
    
    cat > "$manifest_file" << EOF
=== EXPERIMENT MANIFEST - STARTUP PERFORMANCE ===
Date: $(date)
Experiment: Startup Performance (Docker Desktop vs Apple container)
Iterations: ${ITERATIONS}
Minimum valid: ${MIN_VALID_ITERATIONS}
Confidence level: $(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)%
Significance level: ${ALPHA_LEVEL}
Warmup iterations: ${WARMUP_ITERATIONS}
Pause between iterations: ${PAUSE_STARTUP}s

=== GENERATED FILES ===
$(ls -la "${OUTPUT_DIR}")

=== CONFIGURATION ===
- Methodological rigor: ${ITERATIONS} iterations
- Statistical validation: Minimum ${MIN_VALID_ITERATIONS} valid iterations
- Test: startup_warm (container already cached)
- Runtimes: Docker Desktop, Apple container

=== LOAD MONITORING (T4) ===
- Script: src/utils/monitor_system_load.sh
- CPU threshold: ${CPU_THRESHOLD:-20.0}%
- Memory threshold: ${MEM_THRESHOLD:-80.0}%
- Load log: system_load_log.csv
- Note: Monitoring is informational/documentation only. It does not prevent iterations from running.

=== METHODOLOGY ===
- Measurement of container startup time
- Result validation (100ms - 30s)
- Robust statistical analysis
- Full data transparency

=== METHODOLOGICAL STANDARDS ===
- Methodological rigor suitable for academic publication
- Scientific validation with multiple-comparison corrections
- Full transparency of data and methods
- Replicability for other researchers
- Innovative contribution
EOF
    
    print_success "  ✓ Experimental manifest generated: $(basename "$manifest_file")"
}

# Function run_statistical_analysis() removed - now uses benchmark_utils.sh

# Main function
main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║  🔬 STARTUP PERFORMANCE BENCHMARK                                      ║"
    echo "║  Docker Desktop vs Apple container - Startup Times                     ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Initial checks
    print_step "📋 Checking System Prerequisites"
    echo ""
    check_dependencies
    check_rosetta
    check_apple_container auto_start
    init_container_safety
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Set up experiment
    setup_output_directory "startup_performance"
    
    print_step "⚙️  Experiment Configuration"
    echo ""
    print_info "  Name: ${EXPERIMENT_NAME}"
    print_info "  Iterations: ${ITERATIONS}"
    print_info "  Minimum valid: ${MIN_VALID_ITERATIONS}"
    print_info "  Confidence level: $(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)%"
    print_info "  Significance level: ${ALPHA_LEVEL}"
    print_info "  Recommended minimum size (Raj Jain, Ch. 13): ${MIN_SAMPLE_SIZE_RECOMMENDED} observations"
    if [ "$WARMUP_ITERATIONS" -gt 0 ]; then
        print_info "  Warmup iterations: ${WARMUP_ITERATIONS} (discarded)"
    else
        print_info "  Warmup iterations: Disabled"
    fi
    print_info "  Pause between iterations: ${PAUSE_STARTUP}s"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Optional: estimate recommended sample size via pretest (Raj Jain 13.9)
    if [ "${ENABLE_SAMPLE_SIZE_PRETEST:-false}" = "true" ]; then
        print_step "Estimating recommended sample size (pretest, Raj Jain 13.9)..."
        echo ""
        estimate_sample_size_startup_pretest
        echo ""
    fi
    
    # Run experiment
    print_step "🚀 Running Benchmark"
    echo ""
    # Randomization to reduce systematic bias (optional)
    # Controlled via environment variable: ENABLE_RANDOMIZATION=true/false
    # Default: true (randomization enabled)
    local enable_randomization=${ENABLE_RANDOMIZATION:-true}
    
    # Define tests: each combination of runtime and scenario
    local tests=(
        "docker:startup_warm"
        "container:startup_warm"
    )
    
    if [[ "$enable_randomization" == "true" ]]; then
        print_info "  Applying randomization (Fisher-Yates shuffle) for methodological rigor..."
        tests=($(randomize_array "${tests[@]}"))
        print_info "  Randomized test order:"
        for test in "${tests[@]}"; do
            print_info "    • $test"
        done
    else
        print_info "  Randomization disabled - using deterministic order"
        print_info "  Test order:"
        for test in "${tests[@]}"; do
            print_info "    • $test"
        done
    fi
    echo ""
    
    # Run tests in order (randomized or deterministic)
    local total_tests=${#tests[@]}
    local test_num=0
    for test in "${tests[@]}"; do
        test_num=$((test_num + 1))
        local runtime="${test%%:*}"
        local scenario="${test#*:}"
        
        print_step "[${test_num}/${total_tests}] Running: ${runtime} - ${scenario}"
        echo ""
        run_benchmark "$runtime" "$scenario" $ITERATIONS
        echo ""
    done
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    print_step "📊 Consolidating Results"
    echo ""
    consolidate_results
    echo ""
    
    print_step "📝 Generating Experimental Manifest"
    echo ""
    generate_manifest
    echo ""
    
    print_step "🔬 Running Statistical Analysis"
    echo ""
    run_statistical_analysis "${OUTPUT_DIR}"
    echo ""
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║  ✅ EXPERIMENT COMPLETED SUCCESSFULLY                                  ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo ""
    print_success "  Results saved to: ${OUTPUT_DIR}"
    echo ""
    print_info "  📁 Generated files:"
    print_info "     • startup_performance_summary.csv"
    print_info "     • docker_startup_warm_results.csv"
    print_info "     • container_startup_warm_results.csv"
    print_info "     • results_main.csv"
    print_info "     • manifest.txt"
    if [ -d "${OUTPUT_DIR}/enhanced_analysis" ]; then
        print_info "     • enhanced_analysis/ (statistical analysis)"
    fi
    echo ""
    print_info "  📖 To re-run the analysis:"
    print_info "     python src/analysis/analyze_results_enhanced.py ${OUTPUT_DIR} --output ${OUTPUT_DIR}/enhanced_analysis"
    echo ""
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
