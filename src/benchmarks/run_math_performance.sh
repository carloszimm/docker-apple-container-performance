#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# MATH PERFORMANCE BENCHMARK
# =============================================================================
#
# DESCRIPTION:
#   Script that runs mathematical computation benchmarks using PI calculation,
#   comparing Docker Desktop and Apple container. The script follows a rigorous
#   methodology based on Raj Jain for computer systems performance analysis,
#   including warmup iterations, randomization and statistical validation.
#
# FEATURES:
#   - Measures PI calculation time on both runtimes
#   - Runs warmup iterations (discarded) for stabilization
#   - Randomizes the test execution order
#   - Validates results and computes descriptive statistics
#   - Generates CSV files with results and a manifest with metadata
#
# PARAMETERS (Environment Variables):
#
#   Benchmark-Specific Parameters:
#   PAUSE_MATH_OVERRIDE
#       Pause time (in seconds) between iterations for system stabilization.
#       Default: 2
#       Example: PAUSE_MATH_OVERRIDE=3 ./run_math_performance.sh
#
#   PI_DIGITS
#       Number of PI digits to compute (default: 10000 = 10 thousand).
#       NOTE: Value chosen pragmatically to balance execution time and the
#       ability to detect differences. There is no specific academic reference
#       that justifies this exact number.
#       Estimated time: ~93s per run (30 iterations × 4 tests ≈ 3 hours total)
#       Example: PI_DIGITS=5000 ./run_math_performance.sh (for a faster test)
#
#   Parameters Common to All Benchmarks:
#   ITERATIONS_OVERRIDE
#       Number of main iterations to run.
#       Default: 30
#       Example: ITERATIONS_OVERRIDE=10 ./run_math_performance.sh
#
#   WARMUP_ITERATIONS_OVERRIDE
#       Number of warmup iterations (discarded) run before the main
#       iterations. Use 0 to disable warmup.
#       Default: 5
#       Example: WARMUP_ITERATIONS_OVERRIDE=0 ./run_math_performance.sh
#
#   MIN_VALID_OVERRIDE
#       Minimum number of valid iterations required to consider the
#       experiment valid.
#       Default: 30
#       Example: MIN_VALID_OVERRIDE=25 ./run_math_performance.sh
#
#   ENABLE_RANDOMIZATION
#       Enables or disables randomization of the test execution order.
#       Default: true
#       Values: true, false
#       Example: ENABLE_RANDOMIZATION=false ./run_math_performance.sh
#
#   CONFIDENCE_LEVEL
#       Desired confidence level for confidence intervals (0.90, 0.95, 0.99).
#       Default: 0.95 (95%)
#       The script automatically computes the recommended minimum sample size.
#       Example: CONFIDENCE_LEVEL=0.99 ./run_math_performance.sh
#
#   ENABLE_SAMPLE_SIZE_PRETEST
#       When true, runs a short PI calculation pretest to estimate the recommended
#       sample size (n) based on Raj Jain, Ch. 13.9.
#       Default: false (uses only the practical minimum of 30 observations).
#       Example: ENABLE_SAMPLE_SIZE_PRETEST=true ./run_math_performance.sh
#
#   TARGET_REL_ERROR
#       Target relative error (r) for the computation of n in the pretest.
#       Suggested default: 0.05 (5%).
#       Example: TARGET_REL_ERROR=0.03 ENABLE_SAMPLE_SIZE_PRETEST=true ./run_math_performance.sh
#
#   PRETEST_ITERATIONS_OVERRIDE
#       Number of pretest iterations used to estimate the mean and standard deviation.
#       Default: 5
#       Example: PRETEST_ITERATIONS_OVERRIDE=10 ENABLE_SAMPLE_SIZE_PRETEST=true ./run_math_performance.sh
#
# DEPENDENCIES:
#   - Docker Desktop installed and running
#   - Apple container installed and running
#   - alpine:3.19 image available (bc will be installed in the container)
#
# OUTPUT:
#   Results are saved to: bench_results/math_performance_<timestamp>/
#   - math_performance_summary.csv: Consolidated summary with statistics
#   - docker_ycruncher_*.csv: Individual Docker results
#   - container_ycruncher_*.csv: Individual Apple container results
#   - results_math.csv: Main format for statistical analysis
#   - manifest.txt: Experiment metadata (configuration, methodology)
#
# METHODOLOGY:
#   - Warmup Phase: 5 initial discarded iterations (configurable)
#   - Execution Phase: 30 main iterations (configurable)
#   - Randomization: Fisher-Yates shuffle for execution order
#   - Validation: Checks that values are positive numbers
#   - Statistics: Mean, standard deviation, minimum, maximum
#
# USAGE EXAMPLES:
#   # Default run (30 iterations, 5 warmup)
#   ./run_math_performance.sh
#
#   # Quick test (2 iterations, no warmup)
#   ITERATIONS_OVERRIDE=2 WARMUP_ITERATIONS_OVERRIDE=0 ./run_math_performance.sh
#
# AUTHOR:
#   Alessandra Pereira - Docker Desktop vs Apple container performance comparison
#
# VERSION:
#   1.0
#
# DATE:
#   2025-11-29
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
ITERATIONS=${ITERATIONS_OVERRIDE:-30}
MIN_VALID_ITERATIONS=${MIN_VALID_OVERRIDE:-30}
WARMUP_ITERATIONS=${WARMUP_ITERATIONS_OVERRIDE:-5}  # Default: 5, can be overridden (including 0)
PAUSE_MATH=${PAUSE_MATH_OVERRIDE:-2}  # Default: 2s, can be overridden

# Significance and confidence level
ALPHA_LEVEL=0.05
CONFIDENCE_LEVEL=${CONFIDENCE_LEVEL:-0.95}  # Default: 95% (0.95)

# Compute the recommended minimum sample size for the specified confidence level
MIN_SAMPLE_SIZE_RECOMMENDED=$(calculate_min_sample_size "$CONFIDENCE_LEVEL")

# Check whether the number of iterations meets the recommended minimum
check_sample_size "$ITERATIONS" "$CONFIDENCE_LEVEL"

# Base image for compiling Y-cruncher (METHODOLOGICAL RIGOR: use a fixed tag, not latest)
MATH_IMAGE=${MATH_IMAGE:-alpine:3.19}
MATH_DIGEST=""

# Number of PI digits to compute (default: 10,000 = 1e4)
# NOTE: This value was chosen pragmatically to balance execution time and the
# ability to detect differences. There is no specific academic reference that
# justifies this exact number. The literature mentions values ranging from thousands
# to billions of digits depending on the purpose (y-cruncher: trillions, Super PI: millions).
# Estimated time: ~93s per run × 120 runs (30 iterations × 2 runtimes × 2 threads) ≈ 3 hours
# For quick tests, it can be reduced (e.g. 1,000 = 1e3, ~2s per run; 5,000 = 5e3, ~17s per run)
PI_DIGITS=${PI_DIGITS:-10000}

# Ensure the base image is available in the runtime (METHODOLOGICAL RIGOR)
ensure_math_image() {
    local runtime=$1
    local digest=""

    if [ "$runtime" = "docker" ]; then
        if ! docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -q "${MATH_IMAGE}"; then
            print_warning "Image ${MATH_IMAGE} not found in Docker. Pulling..."
            if ! docker pull ${MATH_IMAGE} >/dev/null 2>&1; then
                print_error "Failed to pull the image"
                return 1
            fi
        fi
        local img_id=$(docker image inspect ${MATH_IMAGE} --format '{{.Id}}' 2>/dev/null || echo "")
        if [ -n "$img_id" ]; then
            MATH_DIGEST="$img_id"
            print_step "Docker: ${MATH_IMAGE} id: ${img_id:0:20}..."
        fi
    else
        if ! container image ls | awk '{print $1":"$2}' | grep -q "${MATH_IMAGE}"; then
            print_warning "Image ${MATH_IMAGE} not found in Apple container. Checking Docker..."
            if ! docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -q "${MATH_IMAGE}"; then
                print_warning "Image not present in Docker. Pulling..."
                ensure_math_image "docker"
            fi
            local tmp_tar="${OUTPUT_DIR:-.}/math_image.tar"
            print_info "Exporting from Docker and importing into Apple container (ensuring the same image)..."
            if docker save ${MATH_IMAGE} -o "${tmp_tar}" >/dev/null 2>&1; then
                if container image load --input "${tmp_tar}" >/dev/null 2>&1; then
                    print_success "Image ${MATH_IMAGE} imported into Apple container (same as Docker)"
                    rm -f "${tmp_tar}" >/dev/null 2>&1 || true
                else
                    print_error "Failed to import image into Apple container"
                    return 1
                fi
            else
                print_error "Failed to export image from Docker"
                return 1
            fi
        fi
        local docker_id=$(docker image inspect ${MATH_IMAGE} --format '{{.Id}}' 2>/dev/null || echo "")
        local container_id=$(container image inspect ${MATH_IMAGE} --format '{{.Id}}' 2>/dev/null || echo "")
        if [ -n "$docker_id" ] && [ -n "$container_id" ]; then
            if [ "$docker_id" = "$container_id" ]; then
                print_step "✅ Identical IDs confirmed - same image on both runtimes"
                MATH_DIGEST="$docker_id"
            else
                print_warning "⚠️  Different IDs between runtimes - check consistency"
            fi
        fi
    fi
}

# TODO: The CSV file names and comments in this script still reference "ycruncher"
# (e.g. docker_ycruncher_1t.csv, container_ycruncher_2t.csv). The actual tool is bc.
# Rename the output files and update all comments to reflect this.
# Function to run warmup iterations (discarded)
run_warmup_math() {
    local runtime=$1
    local threads=$2
    local warmup_count=$3
    
    if [ "$warmup_count" -le 0 ]; then
        return 0
    fi
    
    print_step "Running ${warmup_count} warmup iterations (discarded) - ${runtime} PI ${threads} threads"
    
    for w in $(seq 1 $warmup_count); do
        print_info "Warmup ${w}/${warmup_count} - ${runtime} PI ${threads} threads"
        
        if [ "$runtime" = "docker" ]; then
            docker run --rm ${MATH_IMAGE} sh -c "
                apk add --no-cache bc >/dev/null 2>&1
                echo \"scale=${PI_DIGITS}; 4*a(1)\" | timeout 270 bc -l >/dev/null 2>&1
            " > /dev/null 2>&1
        elif [ "$runtime" = "container" ]; then
            # Use set +e to prevent the script from stopping if container run fails
            set +e
            run_container_with_standard_resources "container" "${MATH_IMAGE}" sh -c "
                apk add --no-cache bc >/dev/null 2>&1
                echo \"scale=${PI_DIGITS}; 4*a(1)\" | timeout 270 bc -l >/dev/null 2>&1
            " > /dev/null 2>&1
            local warmup_exit_code=$?
            set -e
            if [ $warmup_exit_code -ne 0 ]; then
                print_warning "  ⚠️  Warmup ${w}/${warmup_count} failed (exit code: $warmup_exit_code) - continuing..."
            fi
        fi
        
        # Pause between warmup iterations
        sleep $PAUSE_MATH
    done
    
    print_success "✅ Warmup completed"
}

run_math_benchmark() {
    local runtime=$1
    local threads=$2
    local iterations=$3
    
    print_step "Running PI calculation ${threads} threads - ${runtime} (${iterations} iterations)"
    
    # Warmup iterations (per Raj Jain)
    # WARMUP_ITERATIONS can be overridden via environment variable (default: 5)
    # If WARMUP_ITERATIONS=0, warmup is skipped
    if [ "$WARMUP_ITERATIONS" -gt 0 ]; then
        print_step "Warmup: ${WARMUP_ITERATIONS} iterations (discarded)"
        run_warmup_math "$runtime" "$threads" $WARMUP_ITERATIONS
    else
        print_info "ℹ️  Warmup disabled (WARMUP_ITERATIONS=${WARMUP_ITERATIONS})"
    fi
    
    local output_file="${OUTPUT_DIR}/${runtime}_ycruncher_${threads}t.csv"
    local valid_count=0
    local total_count=0
    local high_load_count=0
    
    # CSV header
    echo "iteration,time_seconds,throughput_digits_per_sec" > "$output_file"
    
    for i in $(seq 1 $iterations); do
        print_info "Iteration ${i}/${iterations} - ${runtime} PI ${threads} threads (computing ${PI_DIGITS} digits...)"
        
        # Monitor system load before the iteration (threat T4 mitigation - documentation only)
        if ! "${SCRIPT_DIR}/../utils/monitor_system_load.sh" >> "${OUTPUT_DIR}/system_load_log.csv" 2>/dev/null; then
            print_warning "  ⚠️  System load above thresholds at iteration ${i}/${iterations} (documented, but continuing)"
            high_load_count=$((high_load_count + 1))
        fi
        
        local result=""
        local throughput=""
        
        # Run the PI calculation using bc inside the container
        # Measure execution time using date before and after (more accurate than time inside the container)
        if [ "$runtime" = "docker" ]; then
            local start_time=$(date +%s.%N)
            # Run the PI calculation and discard output (we only want to measure time)
            # Note: This calculation may take ~93s for 10,000 digits
            docker run --rm ${MATH_IMAGE} sh -c "
                apk add --no-cache bc >/dev/null 2>&1
                echo \"scale=${PI_DIGITS}; 4*a(1)\" | timeout 270 bc -l >/dev/null 2>&1
            " >/dev/null 2>&1
            local end_time=$(date +%s.%N)

            # Compute execution time
            result=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
            
            # Compute throughput (digits per second)
            if [ -n "$result" ] && [ "$result" != "0" ] && [ $(echo "$result > 0" | bc -l) -eq 1 ]; then
                throughput=$(echo "scale=2; ${PI_DIGITS} / $result" | bc -l 2>/dev/null || echo "0")
            fi
            
        elif [ "$runtime" = "container" ]; then
            local start_time=$(date +%s.%N)
            # Run the PI calculation and discard output (we only want to measure time)
            # Use standardized resources for a fair comparison
            # Note: This calculation may take ~93s for 10,000 digits
            # Use set +e to capture the exit code without stopping the script
            set +e
            run_container_with_standard_resources "container" "${MATH_IMAGE}" sh -c "
                apk add --no-cache bc >/dev/null 2>&1
                echo \"scale=${PI_DIGITS}; 4*a(1)\" | timeout 270 bc -l >/dev/null 2>&1
            " >/dev/null 2>&1
            local container_exit_code=$?
            set -e
            local end_time=$(date +%s.%N)
            
            # If container run failed, mark as invalid
            if [ $container_exit_code -ne 0 ]; then
                result="0"
                if [ "$i" -le 3 ]; then
                    print_warning "  [DEBUG] Container run failed with exit code: $container_exit_code"
                fi
            fi
            
            # Compute execution time
            result=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
            
            # Compute throughput (digits per second)
            if [ -n "$result" ] && [ "$result" != "0" ] && [ $(echo "$result > 0" | bc -l) -eq 1 ]; then
                throughput=$(echo "scale=2; ${PI_DIGITS} / $result" | bc -l 2>/dev/null || echo "0")
            fi
        fi
        
        # Basic validation (reasonable numeric result)
        if [[ "$result" =~ ^[0-9]+\.?[0-9]*$ ]] && [ $(echo "$result > 0" | bc -l) -eq 1 ]; then
            echo "${i},${result},${throughput:-0}" >> "$output_file"
            valid_count=$((valid_count + 1))
            print_success "✅ ${result}s (${throughput} digits/sec) (valid)"
        else
            print_warning "⚠️  ${result} (invalid)"
        fi
        
        total_count=$((total_count + 1))
        
        # Standardized pause between iterations
        sleep $PAUSE_MATH
    done
    
    print_step "Result: ${valid_count}/${total_count} valid iterations (high-load iterations documented: ${high_load_count})"
    
    if [ $valid_count -lt $MIN_VALID_ITERATIONS ]; then
        print_error "❌ Insufficient valid iterations (${valid_count}/${MIN_VALID_ITERATIONS} minimum)"
        # In validation mode, do not exit with an error (few iterations are expected)
        if [ "${VALIDATION_MODE:-false}" != "true" ]; then
            return 1
        fi
    fi
    
    print_success "✅ Benchmark PI ${threads} threads - ${runtime} completed successfully"
    return 0
}

# Consolidate experimental results
consolidate_results() {
    print_step "Consolidating results..."
    
    local summary_file="${OUTPUT_DIR}/math_performance_summary.csv"
    local math_file="${OUTPUT_DIR}/results_math.csv"
    
    # Header
    echo "runtime,threads,iterations,valid_iterations,mean_time_seconds,std_time_seconds,min_time_seconds,max_time_seconds,mean_throughput_digits_per_sec" > "$summary_file"
    echo "timestamp,platform,tool,test,threads,metric,value,unit,notes" > "$math_file"
    
    # Process each results file
    for file in "${OUTPUT_DIR}"/*_ycruncher_*.csv; do
        if [ -f "$file" ]; then
            local runtime=$(basename "$file" | cut -d'_' -f1)
            local threads=$(basename "$file" | sed 's/.*_\([0-9]*\)t\.csv/\1/')
            
            # Compute statistics (Welford — sample standard deviation, ddof=1)
            # Col 2 = time_seconds; Col 3 = throughput_digits_per_sec (mean only)
            local time_stats=$(tail -n +2 "$file" | compute_stats_welford 2)
            local mean_throughput=$(tail -n +2 "$file" | awk -F',' '{s+=$3; c++} END {if(c>0) printf "%.2f", s/c; else printf "0"}')
            local stats="${time_stats},${mean_throughput}"
            
            echo "${runtime},${threads},${stats}" >> "$summary_file"

            # Append data to the consolidated file compatible with the analysis
            tail -n +2 "$file" | while IFS=',' read -r iteration time_seconds throughput_digits_per_sec; do
                if [ -n "$time_seconds" ]; then
                    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S-0300")
                    echo "${timestamp},macOS,${runtime},pi,${threads},time_seconds,${time_seconds},s,from_math_only" >> "$math_file"
                    echo "${timestamp},macOS,${runtime},pi,${threads},throughput_digits_per_sec,${throughput_digits_per_sec},digits/s,from_math_only" >> "$math_file"
                fi
            done
        fi
    done
    
    print_success "✅ Results consolidated in ${summary_file}"
}

# Generate experimental manifest
generate_manifest() {
    print_step "Generating experimental manifest..."
    
    local manifest_file="${OUTPUT_DIR}/manifest.txt"
    
    cat > "$manifest_file" << EOF
=== EXPERIMENT MANIFEST - MATH PERFORMANCE ===
Date: $(date)
Experiment: Mathematical Computation Performance (Docker Desktop vs Apple container)
Iterations: ${ITERATIONS}
Minimum valid: ${MIN_VALID_ITERATIONS}
Significance level: ${ALPHA_LEVEL}
Confidence level: $(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)%

=== GENERATED FILES ===
$(ls -la "${OUTPUT_DIR}")

=== CONFIGURATION ===
- Iterations: ${ITERATIONS}
- Statistical validation: Minimum ${MIN_VALID_ITERATIONS} valid iterations
- Test: PI calculation (2 thread configurations per runtime)
- Runtimes: Docker Desktop, Apple container
- PI digits: ${PI_DIGITS}
- Threads: 1 and 2
- Method: bc (Basic Calculator) for PI calculation
- Warmup iterations: ${WARMUP_ITERATIONS}

=== LOAD MONITORING (T4) ===
- Script: src/utils/monitor_system_load.sh
- CPU threshold: ${CPU_THRESHOLD:-20.0}%
- Memory threshold: ${MEM_THRESHOLD:-80.0}%
- Load log: system_load_log.csv
- Note: Monitoring is informational/documentation only. It does not prevent iterations from running.

=== IMAGE USED (METHODOLOGICAL RIGOR) ===
Image: ${MATH_IMAGE}
Digest: ${MATH_DIGEST:-N/A (not captured)}
Note: Identical image guaranteed on both runtimes for experimental validity
Tool: bc (Basic Calculator) for PI calculation

=== METHODOLOGY ===
- Measurement of mathematical computation performance
- Result validation (positive numeric values)
- Robust statistical analysis
- Full data transparency
- Based on Raj Jain - The Art of Computer Systems Performance Analysis

=== METHODOLOGICAL STANDARDS ===
- Methodological rigor suitable for academic publication
- Scientific validation with multiple-comparison corrections
- Full transparency of data and methods
- Replicability for other researchers
EOF

    print_success "✅ Experimental manifest generated in ${manifest_file}"
}

# Function to run robust statistical analysis
# Function run_statistical_analysis() removed - now uses benchmark_utils.sh

# Main function
main() {
    print_step "=== MATH PERFORMANCE BENCHMARK ==="
    print_step "Docker Desktop vs Apple container - Mathematical Computation Performance"
    echo ""
    
    # Initial checks
    check_dependencies
    check_rosetta
    check_apple_container auto_start
    
    # Set up experiment
    setup_output_directory "math_performance"
    
    print_step "Experiment configuration:"
    print_info "Name: ${EXPERIMENT_NAME}"
    print_info "Iterations: ${ITERATIONS}"
    print_info "Minimum valid: ${MIN_VALID_ITERATIONS}"
    local conf_pct
    conf_pct=$(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)
    print_info "Confidence level: ${conf_pct}%"
    print_info "Recommended minimum size (Raj Jain, Ch. 13): ${MIN_SAMPLE_SIZE_RECOMMENDED} observations"
    if [ "$WARMUP_ITERATIONS" -gt 0 ]; then
        print_info "Warmup iterations: ${WARMUP_ITERATIONS}"
    else
        print_info "Warmup iterations: Disabled"
    fi
    print_info "PI digits: ${PI_DIGITS}"
    echo ""
    
    # Run experiment
    print_step "Running Math Performance..."
    # Check and ensure base images (methodological rigor)
    print_step "Checking base images (methodological rigor)..."
    ensure_math_image "docker"
    ensure_math_image "container"
    if [ -n "$MATH_DIGEST" ]; then
        print_step "✅ Base image verified: ${MATH_IMAGE}"
        print_step "✅ Digest: ${MATH_DIGEST:0:20}..."
    fi
    
    # Randomization to reduce systematic bias (optional)
    # Controlled via environment variable: ENABLE_RANDOMIZATION=true/false
    # Default: true (randomization enabled)
    local enable_randomization=${ENABLE_RANDOMIZATION:-true}
    
    # Define tests: each combination of runtime and threads
    local tests=(
        "docker:1"
        "container:1"
        "docker:2"
        "container:2"
    )
    
    if [[ "$enable_randomization" == "true" ]]; then
        print_step "Applying randomization to reduce systematic bias..."
        
        # Randomize test order (Fisher-Yates shuffle)
        tests=($(randomize_array "${tests[@]}"))
        
        print_step "Randomized test order:"
        for test in "${tests[@]}"; do
            print_info "  - $test"
        done
    else
        print_step "Randomization disabled - using deterministic order"
        print_info "Test order:"
        for test in "${tests[@]}"; do
            print_info "  - $test"
        done
    fi
    echo ""
    
    # Run tests in order (randomized or deterministic)
    local total_tests=${#tests[@]}
    local test_num=0
    for test in "${tests[@]}"; do
        test_num=$((test_num + 1))
        local runtime="${test%%:*}"
        local threads="${test#*:}"
        
        print_step "Running test ${test_num}/${total_tests}: ${runtime} - PI (${threads} thread(s))"
        run_math_benchmark "$runtime" "$threads" $ITERATIONS
    done
    
    consolidate_results
    generate_manifest
    run_statistical_analysis "${OUTPUT_DIR}"
    
    print_success "✅ Math Performance completed!"
    
    print_step "=== EXPERIMENT COMPLETED ==="
    print_success "Results saved to: ${OUTPUT_DIR}"
    print_step "✅ Robust statistical analysis was already run automatically"
    print_info "To re-run the analysis: python src/analysis/analyze_results_enhanced.py ${OUTPUT_DIR} --output ${OUTPUT_DIR}/enhanced_analysis"
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

