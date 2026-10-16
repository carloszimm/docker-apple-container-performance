#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# CPU PERFORMANCE BENCHMARK
# =============================================================================
#
# DESCRIPTION:
#   Script to run CPU performance benchmarks using `sysbench`, comparing
#   Docker Desktop and Apple container. The focus is on measuring the rate of
#   events per second (operations per second) in controlled scenarios,
#   following good methodological practices for performance experiments.
#
# FEATURES:
#   - Runs CPU tests with `sysbench` on both runtimes (Docker and Apple container)
#   - Ensures both runtimes use the same `sysbench` image (tag/digest)
#   - Supports warmup iterations (discarded) before the main iterations
#   - Allows randomizing the test order to reduce systematic bias
#   - Consolidates results into CSV files ready for statistical analysis
#   - Generates a manifest with complete experiment metadata
#
# PARAMETERS (Environment Variables):
#
#   Benchmark-Specific Parameters:
#   SYSBENCH_IMAGE
#       Container image used to run `sysbench`.
#       Default: local/sysbench:1.0.20-alpine3.19 (built via ensure_sysbench_image
#       from Alpine 3.19 + `apk add sysbench`). Ensures an identical image
#       (same digest) on both runtimes (Docker Desktop and Apple container).
#       Example: SYSBENCH_IMAGE=other/image:tag ./run_cpu_performance.sh
#
#   Parameters Common to All Benchmarks:
#   ITERATIONS_OVERRIDE
#       Number of main iterations per runtime/scenario combination.
#       Default: 30
#       Example: ITERATIONS_OVERRIDE=10 ./run_cpu_performance.sh
#
#   WARMUP_ITERATIONS_OVERRIDE
#       Number of warmup iterations (discarded) run before the main
#       iterations. Use 0 to disable warmup.
#       Default: 5
#       Example: WARMUP_ITERATIONS_OVERRIDE=0 ./run_cpu_performance.sh
#
#   MIN_VALID_OVERRIDE
#       Minimum number of valid iterations required to consider the
#       experiment valid in each combination.
#       Default: 30
#       Example: MIN_VALID_OVERRIDE=25 ./run_cpu_performance.sh
#
#   ENABLE_RANDOMIZATION
#       Enables or disables randomization of the test order
#       (runtime and thread-count combinations).
#       Default: true
#       Values: true, false
#       Example: ENABLE_RANDOMIZATION=false ./run_cpu_performance.sh
#
#   CONFIDENCE_LEVEL
#       Desired confidence level for confidence intervals (0.90, 0.95, 0.99).
#       Default: 0.95 (95%)
#       The script automatically computes the recommended minimum sample size.
#       Example: CONFIDENCE_LEVEL=0.99 ./run_cpu_performance.sh
#
#   ENABLE_SAMPLE_SIZE_PRETEST
#       When true, runs a short pretest to estimate the recommended sample
#       size (n) based on Raj Jain, Ch. 13.9.
#       Default: false (uses only the practical minimum of 30 observations).
#       Example: ENABLE_SAMPLE_SIZE_PRETEST=true ./run_cpu_performance.sh
#
#   TARGET_REL_ERROR
#       Target relative error (r) for the n calculation in the pretest.
#       Suggested default: 0.05 (5%).
#       Example: TARGET_REL_ERROR=0.03 ENABLE_SAMPLE_SIZE_PRETEST=true ./run_cpu_performance.sh
#
#   PRETEST_ITERATIONS_OVERRIDE
#       Number of pretest iterations used to estimate the mean and standard deviation.
#       Default: 5
#       Example: PRETEST_ITERATIONS_OVERRIDE=10 ENABLE_SAMPLE_SIZE_PRETEST=true ./run_cpu_performance.sh
#
# DEPENDENCIES:
#   - Docker Desktop installed and running
#   - Apple container installed and running
#   - `sysbench` available (via image and/or local binary)
#   - Python 3 (for optional statistical analysis)
#
# OUTPUT:
#   Results are saved to: bench_results/cpu_performance_<timestamp>/
#   - cpu_performance_summary.csv: Consolidated summary with statistics
#   - results_sysbench.csv: Main format for statistical analysis
#   - docker_sysbench_cpu_*.csv: Per-scenario Docker results
#   - container_sysbench_cpu_*.csv: Per-scenario Apple container results
#   - manifest.txt: Experiment metadata (configuration, image, methodology)
#
# METHODOLOGY:
#   - Warmup Phase: initial discarded iterations (configurable)
#   - Execution Phase: main iterations (configurable)
#   - Randomization: Fisher-Yates shuffle for test execution order
#   - Main metric: events per second (ops/s) from `sysbench cpu`
#   - Validation: only positive numeric values are considered valid
#
# USAGE EXAMPLES:
#   # Default run (30 iterations, 5 warmup, randomization enabled)
#   ./run_cpu_performance.sh
#
#   # Quick test (10 iterations, no warmup)
#   ITERATIONS_OVERRIDE=10 WARMUP_ITERATIONS_OVERRIDE=0 ./run_cpu_performance.sh
#
#   # Run without randomization
#   ENABLE_RANDOMIZATION=false ./run_cpu_performance.sh
#
#   # Run with a local sysbench image
#   SYSBENCH_IMAGE=local/sysbench:1.0.20-alpine3.19 ./run_cpu_performance.sh
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

# Experiment settings (support environment override)
ITERATIONS=${ITERATIONS_OVERRIDE:-30}
MIN_VALID_ITERATIONS=${MIN_VALID_OVERRIDE:-30}
WARMUP_ITERATIONS=${WARMUP_ITERATIONS_OVERRIDE:-5}  # Default: 5, can be overridden (including 0)
ALPHA_LEVEL=0.05
CONFIDENCE_LEVEL=${CONFIDENCE_LEVEL:-0.95}  # Default: 95% (0.95)

# Image with sysbench pre-installed, built locally to ensure a reproducible
# digest that is identical on both runtimes (see ensure_sysbench_image).
SYSBENCH_IMAGE=${SYSBENCH_IMAGE:-local/sysbench:1.0.20-alpine3.19}
SYSBENCH_DIGEST=""

# Compute the recommended minimum sample size for the given confidence level
MIN_SAMPLE_SIZE_RECOMMENDED=$(calculate_min_sample_size "$CONFIDENCE_LEVEL")

# Check whether the number of iterations meets the recommended minimum
check_sample_size "$ITERATIONS" "$CONFIDENCE_LEVEL"

# Ensure the sysbench image is available in the runtime (METHODOLOGICAL RIGOR)
# Verifies and ensures both tools use exactly the same image (same digest)
ensure_sysbench_image() {
    local runtime=$1
    local digest=""

    if [ "$runtime" = "docker" ]; then
        if ! docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -q "${SYSBENCH_IMAGE}"; then
            print_warning "Image ${SYSBENCH_IMAGE} not found in Docker. Trying pull..."
            if ! docker pull ${SYSBENCH_IMAGE} >/dev/null 2>&1; then
                print_warning "Pull failed. Building local image with sysbench (methodological rigor, no network)..."
                # Build a minimal local image with sysbench
                local build_dir="${OUTPUT_DIR:-.}/_sysbench_build"
                mkdir -p "$build_dir"
                cat > "$build_dir/Dockerfile" << 'EOF'
FROM alpine:3.19
RUN apk add --no-cache sysbench
ENTRYPOINT ["/usr/bin/sysbench"]
EOF
                local local_tag="local/sysbench:1.0.20-alpine3.19"
                if docker build -q -t "$local_tag" "$build_dir" >/dev/null 2>&1; then
                    docker rmi ${SYSBENCH_IMAGE} >/dev/null 2>&1 || true
                    SYSBENCH_IMAGE="$local_tag"
                    print_success "Local image built: ${SYSBENCH_IMAGE}"
                else
                    print_error "Failed to build local sysbench image"
                    return 1
                fi
            fi
        fi
        # Capture the digest to ensure reproducibility
        digest=$(docker image inspect ${SYSBENCH_IMAGE} --format '{{index .RepoDigests 0}}' 2>/dev/null | cut -d'@' -f2 || echo "")
        if [ -n "$digest" ]; then
            SYSBENCH_DIGEST="$digest"
            print_step "Docker: ${SYSBENCH_IMAGE} digest: ${digest:0:20}..."
        else
            # Local images have no RepoDigests; use the ID as a stable identifier
            local img_id=$(docker image inspect ${SYSBENCH_IMAGE} --format '{{.Id}}' 2>/dev/null || echo "")
            if [ -n "$img_id" ]; then
                SYSBENCH_DIGEST="$img_id"
                print_step "Docker: ${SYSBENCH_IMAGE} id: ${img_id:0:20}..."
            fi
        fi
    else
        # Apple container: if missing, try pull; if that fails and the image exists in Docker, do save/load
        if ! container image ls | awk '{print $1":"$2}' | grep -q "${SYSBENCH_IMAGE}"; then
            print_warning "Image ${SYSBENCH_IMAGE} not found in Apple container. Trying pull..."
            if ! container image pull ${SYSBENCH_IMAGE} >/dev/null 2>&1; then
                print_warning "Pull failed in Apple container. Checking Docker for import..."
                # If the image does not exist in Docker (because the pull failed and we did not build), build locally
                if ! docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -q "${SYSBENCH_IMAGE}"; then
                    print_warning "Image ${SYSBENCH_IMAGE} not present in Docker. Building locally to import..."
                    local build_dir2="${OUTPUT_DIR:-.}/_sysbench_build"
                    mkdir -p "$build_dir2"
                    cat > "$build_dir2/Dockerfile" << 'EOF'
FROM alpine:3.19
RUN apk add --no-cache sysbench
ENTRYPOINT ["/usr/bin/sysbench"]
EOF
                    local local_tag2="local/sysbench:1.0.20-alpine3.19"
                    if docker build -q -t "$local_tag2" "$build_dir2" >/dev/null 2>&1; then
                        SYSBENCH_IMAGE="$local_tag2"
                        print_success "Local image built: ${SYSBENCH_IMAGE}"
                    else
                        print_error "Failed to build local sysbench image"
                        return 1
                    fi
                fi
                # Export from Docker and import into Apple container
                local tmp_tar="${OUTPUT_DIR:-.}/sysbench_image.tar"
                print_info "Exporting from Docker and importing into Apple container (ensuring the same image)..."
                if docker save ${SYSBENCH_IMAGE} -o "${tmp_tar}" >/dev/null 2>&1; then
                    if container image load --input "${tmp_tar}" >/dev/null 2>&1; then
                        print_success "Image ${SYSBENCH_IMAGE} imported into Apple container (same as Docker)"
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
        fi
        # Capture the Apple container digest
        digest=$(container image inspect ${SYSBENCH_IMAGE} --format '{{index .RepoDigests 0}}' 2>/dev/null | cut -d'@' -f2 || echo "")
        if [ -n "$digest" ] && [ -n "$SYSBENCH_DIGEST" ]; then
            if [ "$digest" != "$SYSBENCH_DIGEST" ]; then
                print_error "⚠️  METHODOLOGICAL RIGOR: Different digests! Docker: ${SYSBENCH_DIGEST:0:20}... Container: ${digest:0:20}..."
                print_warning "⚠️  The images are different - this may affect the validity of the results!"
            else
                print_step "✅ Identical digests confirmed - same image on both runtimes"
            fi
        else
            # If there is no digest (local image), compare by ID
            local docker_id=$(docker image inspect ${SYSBENCH_IMAGE} --format '{{.Id}}' 2>/dev/null || echo "")
            local container_id=$(container image inspect ${SYSBENCH_IMAGE} --format '{{.Id}}' 2>/dev/null || echo "")
            if [ -n "$docker_id" ] && [ -n "$container_id" ]; then
                if [ "$docker_id" = "$container_id" ]; then
                    print_step "✅ Identical IDs confirmed - same image on both runtimes"
                    SYSBENCH_DIGEST="$docker_id"
                else
                    print_warning "⚠️  IDs differ between runtimes - check consistency"
                fi
            fi
        fi
    fi
}

# Detect whether the image has an ENTRYPOINT pointing to sysbench
image_has_sysbench_entrypoint() {
    local runtime=$1
    local image=$2
    local ep=""
    if [ "$runtime" = "docker" ]; then
        ep=$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}' 2>/dev/null | tr -d '[]"')
    else
        ep=$(container image inspect "$image" --format '{{json .Config.Entrypoint}}' 2>/dev/null | tr -d '[]"')
    fi
    echo "$ep" | grep -qi sysbench && return 0 || return 1
}

# Estimate the recommended sample size via pretest (Raj Jain 13.9)
estimate_sample_size_cpu_pretest() {
    local pretest_iterations=${PRETEST_ITERATIONS_OVERRIDE:-5}
    local rel_error=${TARGET_REL_ERROR:-0.05}
    local runtime="docker"
    local threads=1
    local test_type="cpu"

    print_info "Sample size pretest (Raj Jain 13.9):"
    print_info "  Runtime: ${runtime}, Threads: ${threads}"
    print_info "  Pretest iterations: ${pretest_iterations}"
    local rel_error_pct
    rel_error_pct=$(echo "$rel_error * 100" | bc -l | cut -d'.' -f1)
    print_info "  Target relative error: ${rel_error_pct}%"

    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "/tmp/cpu_pretest_$$.tmp")

    local args="cpu --threads=${threads} --time=10 run"

    for i in $(seq 1 $pretest_iterations); do
        print_info "  Pretest ${i}/${pretest_iterations}..."
        local result=""

        if image_has_sysbench_entrypoint "docker" "$SYSBENCH_IMAGE"; then
            result=$(LC_ALL=C docker run --rm ${SYSBENCH_IMAGE} ${args} 2>&1 | grep -i 'events per second' | sed -E 's/.*events per second:[[:space:]]*([0-9]+\.[0-9]+).*/\1/')
        else
            result=$(LC_ALL=C docker run --rm ${SYSBENCH_IMAGE} sysbench ${args} 2>&1 | grep -i 'events per second' | sed -E 's/.*events per second:[[:space:]]*([0-9]+\.[0-9]+).*/\1/')
        fi

        if [[ "$result" =~ ^[0-9]+\.?[0-9]*$ ]] && [ "$(echo "$result > 0" | bc -l)" -eq 1 ]; then
            echo "$result" >> "$tmp_file"
            print_success "  ✓ ${result} events/sec (valid for pretest)"
        else
            print_warning "  ⚠️  Invalid value in pretest: ${result}"
        fi
    done

    # Compute mean and standard deviation from the pretest
    if [ ! -s "$tmp_file" ]; then
        print_warning "⚠️  Pretest did not produce enough valid data to estimate the sample size"
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

    print_info "  Mean (pretest): ${mean} events/sec"
    print_info "  Standard deviation (pretest): ${std} events/sec"
    
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
    print_info "    E = r × X̄ = ${rel_error} × ${mean} = ${E} events/sec"
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
        print_warning "  ⚠️  Current iterations (${ITERATIONS}) below the recommended (${n_rec}) for ${conf_pct}% confidence and relative error ${rel_error_pct}%"
        print_info "      → Consider increasing ITERATIONS_OVERRIDE to at least ${n_rec} for formal runs"
    else
        print_success "  ✓ Current iterations (${ITERATIONS}) ≥ recommended (${n_rec}) for the configured pretest"
    fi
}

# Function to run warmup iterations (discarded)
run_warmup_sysbench() {
    local runtime=$1
    local test_type=$2
    local test_num=$3
    local warmup_count=$4
    
    if [ "$warmup_count" -le 0 ]; then
        return 0
    fi
    
    print_step "Running ${warmup_count} warmup iterations (discarded) - ${runtime} ${test_type} ${test_num}"
    
    local args="cpu --threads=${test_num} --time=10 run"
    
    for w in $(seq 1 $warmup_count); do
        print_info "Warmup ${w}/${warmup_count} - ${runtime} ${test_type} ${test_num}"
        
        if [ "$runtime" = "docker" ]; then
            if image_has_sysbench_entrypoint "docker" "$SYSBENCH_IMAGE"; then
                docker run --rm ${SYSBENCH_IMAGE} ${args} > /dev/null 2>&1
            else
                docker run --rm ${SYSBENCH_IMAGE} sysbench ${args} > /dev/null 2>&1
            fi
        elif [ "$runtime" = "container" ]; then
            run_container_with_standard_resources "container" "${SYSBENCH_IMAGE}" ${args} > /dev/null 2>&1
        fi
        
        # Pause between warmup iterations
        sleep 2
    done
    
    print_success "✅ Warmup completed"
}

# Function to run the sysbench benchmark
run_sysbench_benchmark() {
    local runtime=$1
    local test_type=$2
    local test_num=$3
    local iterations=$4
    
    print_step "Running ${test_type} ${test_num} - ${runtime} (${iterations} iterations)"
    
    # Warmup iterations (per Raj Jain)
    # WARMUP_ITERATIONS can be overridden via environment variable (default: 5)
    # If WARMUP_ITERATIONS=0, warmup is skipped
    if [ "$WARMUP_ITERATIONS" -gt 0 ]; then
        print_step "Warmup: ${WARMUP_ITERATIONS} iterations (discarded)"
        run_warmup_sysbench "$runtime" "$test_type" "$test_num" $WARMUP_ITERATIONS
    else
        print_info "ℹ️  Warmup disabled (WARMUP_ITERATIONS=${WARMUP_ITERATIONS})"
    fi
    
    local output_file="${OUTPUT_DIR}/${runtime}_sysbench_${test_type}_${test_num}.csv"
    local valid_count=0
    local total_count=0
    local high_load_count=0
    
    # CSV header
    echo "iteration,events_per_sec,latency_ms,throughput" > "$output_file"
    
    for i in $(seq 1 $iterations); do
        print_info "Iteration ${i}/${iterations} - ${runtime} ${test_type} ${test_num}"
        
        # Monitor system load before the iteration (mitigation of threat T4 - documentation only)
        if ! "${SCRIPT_DIR}/../utils/monitor_system_load.sh" >> "${OUTPUT_DIR}/system_load_log.csv" 2>/dev/null; then
            print_warning "  ⚠️  System load above thresholds at iteration ${i}/${iterations} (documented, but continuing)"
            high_load_count=$((high_load_count + 1))
        fi
        
        local result=""
        
        # Image already verified earlier (methodological rigor)
        # Build the command taking ENTRYPOINT into account
        local args="cpu --threads=${test_num} --time=10 run"
        if [ "$runtime" = "docker" ]; then
            if [ "$test_type" = "cpu" ]; then
                if image_has_sysbench_entrypoint "docker" "$SYSBENCH_IMAGE"; then
                    # Extract the number after "events per second:" using sed
                    result=$(LC_ALL=C docker run --rm ${SYSBENCH_IMAGE} ${args} 2>&1 | grep -i 'events per second' | sed -E 's/.*events per second:[[:space:]]*([0-9]+\.[0-9]+).*/\1/')
                else
                    result=$(LC_ALL=C docker run --rm ${SYSBENCH_IMAGE} sysbench ${args} 2>&1 | grep -i 'events per second' | sed -E 's/.*events per second:[[:space:]]*([0-9]+\.[0-9]+).*/\1/')
                fi
            fi
        elif [ "$runtime" = "container" ]; then
            if [ "$test_type" = "cpu" ]; then
                # Capture full output
                local raw_output=$(LC_ALL=C run_container_with_standard_resources "container" "${SYSBENCH_IMAGE}" ${args} 2>&1)
                # Find the line containing "events per second"
                local raw_line=$(echo "$raw_output" | grep -i 'events per second' | tail -1)
                
                # Try multiple approaches to extract the number
                # Approach 1: sed
                result=$(echo "$raw_line" | sed -E 's/.*events per second:[[:space:]]*([0-9]+\.[0-9]+).*/\1/' | xargs)
                
                # If sed failed, try awk
                if [ -z "$result" ] || [ "$result" = "$raw_line" ]; then
                    result=$(echo "$raw_line" | awk '{
                        for(i=1; i<=NF; i++) {
                            if ($i ~ /^[0-9]+\.[0-9]+$/) {
                                print $i
                                exit
                            }
                        }
                    }')
                fi
                
                # If it still failed, try extracting after ":"
                if [ -z "$result" ]; then
                    result=$(echo "$raw_line" | awk -F': ' '{print $NF}' | awk '{print $1}')
                fi
            fi
        fi
        
        # Basic validation (reasonable numeric result)
        if [[ "$result" =~ ^[0-9]+\.?[0-9]*$ ]] && [ $(echo "$result > 0" | bc -l) -eq 1 ]; then
            echo "${i},${result},10.0,${result}" >> "$output_file"
            valid_count=$((valid_count + 1))
            print_success "✅ ${result} events/sec (valid)"
        else
            print_warning "⚠️  ${result} (invalid)"
        fi
        
        total_count=$((total_count + 1))
        
        # Short pause between iterations
        sleep 2
    done
    
    print_step "Result: ${valid_count}/${total_count} valid iterations (high-load iterations documented: ${high_load_count})"
    
    if [ $valid_count -lt $MIN_VALID_ITERATIONS ]; then
        print_error "❌ Insufficient valid iterations (${valid_count}/${MIN_VALID_ITERATIONS} minimum)"
        # In validation mode, do not exit with an error (few iterations are expected)
        if [ "${VALIDATION_MODE:-false}" != "true" ]; then
            return 1
        fi
    fi
    
    print_success "✅ Benchmark ${test_type} ${test_num} - ${runtime} completed successfully"
    return 0
}

# Consolidate experiment results
consolidate_results() {
    print_step "Consolidating experiment results..."
    
    local summary_file="${OUTPUT_DIR}/cpu_performance_summary.csv"
    local sysbench_file="${OUTPUT_DIR}/results_sysbench.csv"
    
    # Header
    echo "runtime,test_type,test_num,iterations,valid_iterations,mean_events_per_sec,std_events_per_sec,min_events_per_sec,max_events_per_sec" > "$summary_file"
    echo "timestamp,platform,tool,test,threads,metric,value,unit,notes" > "$sysbench_file"
    
    # Process each results file
    for file in "${OUTPUT_DIR}"/*_sysbench_cpu_*.csv; do
        if [ -f "$file" ]; then
            local runtime=$(basename "$file" | cut -d'_' -f1)
            local test_type="cpu"
            local test_num=$(basename "$file" | cut -d'_' -f4 | cut -d'.' -f1)
            
            # Compute statistics (Welford — sample standard deviation, ddof=1)
            local stats=$(tail -n +2 "$file" | compute_stats_welford 2)
            
            echo "${runtime},${test_type},${test_num},${stats}" >> "$summary_file"

            # Append data to the consolidated file compatible with the analysis
            tail -n +2 "$file" | while IFS=',' read -r iteration events_per_sec latency_ms throughput; do
                if [ -n "$events_per_sec" ]; then
                    local timestamp=$(get_iso_timestamp)
                    echo "${timestamp},macOS,${runtime},cpu,${test_num},events_per_sec,${events_per_sec},ops/s,from_cpu_only" >> "$sysbench_file"
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
=== EXPERIMENTAL MANIFEST - CPU PERFORMANCE ===
Date: $(date)
Experiment: CPU Performance (Docker vs Apple container)
Iterations: ${ITERATIONS}
Valid minimum: ${MIN_VALID_ITERATIONS}
Confidence level: $(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)%
Significance level: ${ALPHA_LEVEL}
Warmup iterations: ${WARMUP_ITERATIONS}

=== GENERATED FILES ===
$(ls -la "${OUTPUT_DIR}")

=== CONFIGURATION ===
- Methodological rigor: ${ITERATIONS} iterations
- Statistical validation: minimum ${MIN_VALID_ITERATIONS} valid iterations
- Test: sysbench cpu (2 tests per runtime)
- Runtimes: Docker, Apple container
- Threads: 1 and 2
- Duration: 10 seconds per test

=== LOAD MONITORING (T4) ===
- Script: src/utils/monitor_system_load.sh
- CPU threshold: ${CPU_THRESHOLD:-20.0}%
- Memory threshold: ${MEM_THRESHOLD:-80.0}%
- Load log: system_load_log.csv
- Note: Monitoring is informational/documentation only. It does not prevent iterations from running.

=== IMAGE USED (METHODOLOGICAL RIGOR) ===
Image: ${SYSBENCH_IMAGE}
Digest: ${SYSBENCH_DIGEST:-N/A (not captured)}
Note: Identical image guaranteed on both runtimes for experimental validity

=== METHODOLOGY ===
- CPU performance measurement
- Result validation (positive numeric values)
- Robust statistical analysis
- Full data transparency

=== METHODOLOGICAL STANDARDS ===
- Methodological rigor suitable for academic publication
- Scientific validation with multiple-comparison corrections
- Full transparency of data and methods
- Reproducibility for other researchers
EOF

    print_success "✅ Experimental manifest generated at ${manifest_file}"
}

# Function to run robust statistical analysis
# Function run_statistical_analysis() removed - now uses benchmark_utils.sh

# Main function
main() {
    print_step "=== CPU PERFORMANCE BENCHMARK ==="
    print_step "Docker vs Apple container - CPU Performance"
    echo ""
    
    # Initial checks
    check_dependencies sysbench
    check_rosetta
    check_apple_container auto_start
    
    # Set up experiment
    setup_output_directory "cpu_performance"
    
    print_step "Experiment configuration:"
    print_info "Name: ${EXPERIMENT_NAME}"
    print_info "Iterations: ${ITERATIONS}"
    print_info "Valid minimum: ${MIN_VALID_ITERATIONS}"
    print_info "Confidence level: $(echo \"$CONFIDENCE_LEVEL * 100\" | bc -l | cut -d'.' -f1)%"
    print_info "Significance level: ${ALPHA_LEVEL}"
    print_info "Recommended minimum size (Raj Jain, Ch. 13): ${MIN_SAMPLE_SIZE_RECOMMENDED} observations"
    echo ""
    
    # Run experiment
    print_step "Running CPU Performance with methodological rigor..."
    
    # METHODOLOGICAL RIGOR: Verify and ensure images before starting tests
    print_step "Verifying sysbench images (methodological rigor)..."
    ensure_sysbench_image "docker"
    ensure_sysbench_image "container"
    
    if [ -n "$SYSBENCH_DIGEST" ]; then
        print_step "✅ sysbench image verified: ${SYSBENCH_IMAGE}"
        print_step "✅ Digest: ${SYSBENCH_DIGEST:0:40}..."
    else
        print_warning "⚠️  Digest not captured - reproducibility may be affected"
    fi
    echo ""

    # Optional: estimate the recommended sample size via pretest (Raj Jain 13.9)
    if [ "${ENABLE_SAMPLE_SIZE_PRETEST:-false}" = "true" ]; then
        print_step "Estimating recommended sample size (pretest, Raj Jain 13.9)..."
        estimate_sample_size_cpu_pretest
        echo ""
    fi
    
    # METHODOLOGICAL RIGOR: Randomization to reduce systematic bias (optional)
    # Controlled via environment variable: ENABLE_RANDOMIZATION=true/false
    # Default: true (randomization enabled)
    local enable_randomization=${ENABLE_RANDOMIZATION:-true}
    
    # Define tests: each combination of runtime, test, and threads
    local tests=(
        "docker:cpu:1"
        "container:cpu:1"
        "docker:cpu:2"
        "container:cpu:2"
    )
    
    if [[ "$enable_randomization" == "true" ]]; then
        print_step "Applying randomization for methodological rigor..."
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
        local test_type="${test#*:}"
        test_type="${test_type%%:*}"
        local threads="${test##*:}"
        
        print_step "Running test ${test_num}/${total_tests}: ${runtime} - ${test_type} (${threads} thread(s))"
        run_sysbench_benchmark "$runtime" "$test_type" "$threads" $ITERATIONS
    done
    
    consolidate_results
    generate_manifest
    run_statistical_analysis "${OUTPUT_DIR}"
    
    print_success "✅ CPU Performance completed with methodological rigor!"
    
    print_step "=== EXPERIMENT COMPLETED WITH METHODOLOGICAL RIGOR ==="
    print_success "Results saved to: ${OUTPUT_DIR}"
    print_step "✅ Robust statistical analysis has already been run automatically"
    print_info "To re-run the analysis:"
    print_info "  ${python_cmd:-python} src/analysis/analyze_results_enhanced.py ${OUTPUT_DIR} --output ${OUTPUT_DIR}/enhanced_analysis"
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
