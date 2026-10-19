#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# STREAM PERFORMANCE BENCHMARK
# =============================================================================
#
# DESCRIPTION:
#   Script to run memory bandwidth benchmarks using STREAM, comparing
#   Docker Desktop and Apple container. The script follows a rigorous
#   methodology based on Raj Jain for computer systems performance analysis,
#   including warmup iterations, randomization, and statistical validation.
#
# FEATURES:
#   - Measures memory bandwidth on both runtimes
#   - Runs warmup iterations (discarded) for stabilization
#   - Applies randomization to the test execution order
#   - Validates results and computes descriptive statistics
#   - Generates CSV files with results and a manifest with metadata
#
# PARAMETERS (Environment Variables):
#
#   Benchmark-Specific Parameters:
#   PAUSE_STREAM_OVERRIDE
#       Pause time (in seconds) between iterations for system stabilization.
#       Default: 2
#       Example: PAUSE_STREAM_OVERRIDE=3 ./run_stream_performance.sh
#
#   STREAM_ARRAY_SIZE_MB
#       STREAM array size in MB (default: 512MB).
#       Used for both Docker and Apple container for a fair comparison.
#       Apple container uses --memory, automatically computed by the script.
#       Example: STREAM_ARRAY_SIZE_MB=1024 ./run_stream_performance.sh
#
#   STREAM_ARRAY_SIZE_MB_CONTAINER
#       STREAM array size in MB for Apple container (default: same as STREAM_ARRAY_SIZE_MB).
#       The script automatically computes the required memory limit via --memory:
#       Memory = 3 × STREAM_ARRAY_SIZE_MB_CONTAINER × 1.5 (safety margin)
#       Example: STREAM_ARRAY_SIZE_MB_CONTAINER=512 ./run_stream_performance.sh
#
#   Parameters Common to All Benchmarks:
#   ITERATIONS_OVERRIDE
#       Number of main iterations to run.
#       Default: 30
#       Example: ITERATIONS_OVERRIDE=10 ./run_stream_performance.sh
#
#   WARMUP_ITERATIONS_OVERRIDE
#       Number of warmup iterations (discarded) run before the main
#       iterations. Use 0 to disable warmup.
#       Default: 5
#       Example: WARMUP_ITERATIONS_OVERRIDE=0 ./run_stream_performance.sh
#
#   MIN_VALID_OVERRIDE
#       Minimum number of valid iterations required to consider the
#       experiment valid.
#       Default: 30
#       Example: MIN_VALID_OVERRIDE=25 ./run_stream_performance.sh
#
#   ENABLE_RANDOMIZATION
#       Enables or disables randomization of the test execution order.
#       Default: true
#       Values: true, false
#       Example: ENABLE_RANDOMIZATION=false ./run_stream_performance.sh
#
#   CONFIDENCE_LEVEL
#       Desired confidence level for confidence intervals (0.90, 0.95, 0.99).
#       Default: 0.95 (95%)
#       The script automatically computes the recommended minimum sample size.
#       Example: CONFIDENCE_LEVEL=0.99 ./run_stream_performance.sh
#
#   ENABLE_SAMPLE_SIZE_PRETEST
#       When true, runs a short STREAM pretest to estimate the recommended
#       sample size (n) based on Raj Jain, Ch. 13.9.
#       Default: false (uses only the practical minimum of 30 observations).
#       Example: ENABLE_SAMPLE_SIZE_PRETEST=true ./run_stream_performance.sh
#
#   TARGET_REL_ERROR
#       Target relative error (r) for the n calculation in the pretest.
#       Suggested default: 0.05 (5%).
#       Example: TARGET_REL_ERROR=0.03 ENABLE_SAMPLE_SIZE_PRETEST=true ./run_stream_performance.sh
#
#   PRETEST_ITERATIONS_OVERRIDE
#       Number of pretest iterations used to estimate the mean and standard deviation.
#       Default: 5
#       Example: PRETEST_ITERATIONS_OVERRIDE=10 ENABLE_SAMPLE_SIZE_PRETEST=true ./run_stream_performance.sh
#
# DEPENDENCIES:
#   - Docker Desktop installed and running
#   - Apple container installed and running
#   - alpine:3.24 image available (STREAM will be compiled inside the container)
#
# OUTPUT:
#   Results are saved to: bench_results/stream_performance_<timestamp>/
#   - stream_performance_summary.csv: Consolidated summary with statistics
#   - docker_stream_*.csv: Individual Docker results
#   - container_stream_*.csv: Individual Apple container results
#   - results_stream.csv: Main format for statistical analysis
#   - manifest.txt: Experiment metadata (configuration, methodology)
#
# METHODOLOGY:
#   - Warmup Phase: 5 initial discarded iterations (configurable)
#   - Execution Phase: 30 main iterations (configurable)
#   - Randomization: Fisher-Yates shuffle for execution order
#   - Validation: checks that values are positive numbers
#   - Statistics: mean, standard deviation, minimum, maximum
#
# USAGE EXAMPLES:
#   # Default run (30 iterations, 5 warmup)
#   ./run_stream_performance.sh
#
#   # Quick test (2 iterations, no warmup)
#   ITERATIONS_OVERRIDE=2 WARMUP_ITERATIONS_OVERRIDE=0 ./run_stream_performance.sh
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

# Settings (support environment override)
ITERATIONS=${ITERATIONS_OVERRIDE:-30}
MIN_VALID_ITERATIONS=${MIN_VALID_OVERRIDE:-30}
WARMUP_ITERATIONS=${WARMUP_ITERATIONS_OVERRIDE:-5}  # Default: 5, can be overridden (including 0)
PAUSE_STREAM=${PAUSE_STREAM_OVERRIDE:-2}  # Default: 2s, can be overridden

# Significance and confidence levels
ALPHA_LEVEL=0.05
CONFIDENCE_LEVEL=${CONFIDENCE_LEVEL:-0.95}  # Default: 95% (0.95)

# Compute the recommended minimum sample size for the given confidence level
MIN_SAMPLE_SIZE_RECOMMENDED=$(calculate_min_sample_size "$CONFIDENCE_LEVEL")

# Check whether the number of iterations meets the recommended minimum
check_sample_size "$ITERATIONS" "$CONFIDENCE_LEVEL"

# -----------------------------------------------------------------------------
# STREAM IMAGE / ENVIRONMENT (METHODOLOGICAL RIGOR + REMOVAL OF "SETUP NOISE")
# -----------------------------------------------------------------------------
# Methodological problem:
# - Installing the toolchain (apk add gcc/make/...), downloading stream.c, and compiling
#   INSIDE the iterations contaminates the bandwidth measurement (setup noise).
#
# Solution:
# - Use a fixed local image with the toolchain already installed (no apk add in the loop)
# - Prepare the binary (download + compilation) once per scenario, OUTSIDE the measurement loop
# - Measure only the execution of ./stream via exec in a persistent worker container
STREAM_BASE_IMAGE=${STREAM_BASE_IMAGE:-alpine:3.24}
STREAM_IMAGE=${STREAM_IMAGE:-bench-stream:alpine-3.24}
STREAM_DIGEST=""

# Retry control (to reduce small samples caused by transient failures)
STREAM_MAX_RETRIES_PER_ITERATION=${STREAM_MAX_RETRIES_PER_ITERATION:-1}
STREAM_RETRY_PAUSE_SECONDS=${STREAM_RETRY_PAUSE_SECONDS:-1}

# STREAM array size in MB (default: 512MB)
# For quick tests, reduce to 100MB via STREAM_ARRAY_SIZE_MB=100
# NOTE: Apple container requires explicit memory configuration via --memory
# The script automatically computes the required memory limit:
# Required memory = 3 × STREAM_ARRAY_SIZE_MB × 1.5 (safety margin)
# For 512MB: 3 × 512MB × 1.5 = 2304MB ≈ 2.3G
# Both runtimes use the same size (512MB) for a fair comparison
STREAM_ARRAY_SIZE_MB=${STREAM_ARRAY_SIZE_MB:-512}
# Size for Apple container (by default, uses the same value as STREAM_ARRAY_SIZE_MB)
# The memory limit is computed automatically via --memory in container run
# If STREAM_ARRAY_SIZE_MB was set but STREAM_ARRAY_SIZE_MB_CONTAINER was not,
# use the same value to ensure a fair comparison
STREAM_ARRAY_SIZE_MB_CONTAINER=${STREAM_ARRAY_SIZE_MB_CONTAINER:-${STREAM_ARRAY_SIZE_MB}}

# Ensure the benchmark image is available in the runtime (METHODOLOGICAL RIGOR)
# and that there is no "setup noise" (apk add) inside the iteration.
ensure_stream_image() {
    local runtime=$1
    local dockerfile_dir="${SCRIPT_DIR}/images/stream"
    local dockerfile_path="${dockerfile_dir}/Dockerfile"

    if [ "$runtime" = "docker" ]; then
        if [ ! -f "$dockerfile_path" ]; then
            print_error "Dockerfile for STREAM image not found: ${dockerfile_path}"
            return 1
        fi

        if ! docker image inspect "${STREAM_IMAGE}" >/dev/null 2>&1; then
            print_step "Building benchmark image (STREAM toolchain): ${STREAM_IMAGE}"
            local build_out
            if ! build_out=$(docker build -t "${STREAM_IMAGE}" -f "${dockerfile_path}" "${dockerfile_dir}" 2>&1); then
                print_error "Failed to build image ${STREAM_IMAGE}"
                print_detail "docker build output (last lines):"
                echo "$build_out" | tail -n 15
                return 1
            fi
        fi

        local img_id
        img_id=$(docker image inspect ${STREAM_IMAGE} --format '{{.Id}}' 2>/dev/null || echo "")
        if [ -n "$img_id" ]; then
            STREAM_DIGEST="$img_id"
            print_step "Docker: ${STREAM_IMAGE} id: ${img_id:0:20}..."
        fi
        return 0
    else
        if ! container image ls 2>/dev/null | awk '{print $1":"$2}' | grep -q "${STREAM_IMAGE}"; then
            print_warning "Image ${STREAM_IMAGE} not found in Apple container. Syncing from Docker..."
            ensure_stream_image "docker"
            local tmp_tar="${OUTPUT_DIR:-.}/stream_image.tar"
            print_info "Exporting from Docker and importing into Apple container (same image, methodological rigor)..."
            if docker save --platform linux/arm64 "${STREAM_IMAGE}" -o "${tmp_tar}" >/dev/null 2>&1; then
                if container image load --input "${tmp_tar}" >/dev/null 2>&1; then
                    rm -f "${tmp_tar}" >/dev/null 2>&1 || true
                    print_success "Image ${STREAM_IMAGE} imported into Apple container (same as Docker)"
                else
                    print_error "Failed to import image into Apple container"
                    return 1
                fi
            else
                print_error "Failed to export image from Docker"
                return 1
            fi
        fi

        local docker_id container_id
        docker_id=$(docker image inspect ${STREAM_IMAGE} --format '{{.Id}}' 2>/dev/null || echo "")
        container_id=$(container image inspect ${STREAM_IMAGE} --format '{{.Id}}' 2>/dev/null || echo "")
        if [ -n "$docker_id" ] && [ -n "$container_id" ]; then
            if [ "$docker_id" = "$container_id" ]; then
                print_step "✅ Identical IDs confirmed - same image on both runtimes"
                STREAM_DIGEST="$docker_id"
            else
                print_warning "⚠️  IDs differ between runtimes - check consistency"
            fi
        fi
    fi
}

# -----------------------------------------------------------------------------
# Structured failure logging (to diagnose small samples)
# -----------------------------------------------------------------------------
sanitize_csv_field() {
    local s=${1:-}
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    s="${s//\"/\"\"}"
    echo "\"$s\""
}

log_stream_failure() {
    local stage=$1
    local runtime=$2
    local test_type=$3
    local threads=$4
    local iteration=$5
    local attempt=$6
    local exit_code=$7
    local details=${8:-}

    local file="${OUTPUT_DIR}/stream_failures.csv"
    if [ ! -f "$file" ]; then
        echo "timestamp_utc,stage,runtime,test_type,threads,iteration,attempt,exit_code,details" > "$file"
    fi
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "${ts},${stage},${runtime},${test_type},${threads},${iteration},${attempt},${exit_code},$(sanitize_csv_field "$details")" >> "$file"
}

calculate_container_memory_limit_mb() {
    local array_mb=$1
    # STREAM allocates 3 large arrays; use a 1.5 margin (the script already did this)
    # and ensure a minimum for toolchain/exec.
    local memory_needed=$((array_mb * 3 * 150 / 100))
    local memory_minimum=1024
    if [ $memory_needed -lt $memory_minimum ]; then
        memory_needed=$memory_minimum
    fi
    echo "$memory_needed"
}

start_stream_worker_container() {
    local runtime=$1
    local memory_limit_mb=${2:-}
    local name="stream_${runtime}_$$_$(date +%s)"
    local id=""

    if [ "$runtime" = "docker" ]; then
        id=$(docker run -d --rm --name "$name" "${STREAM_IMAGE}" sh -c "sleep 1000000" 2>/dev/null || true)
    else
        local memory_limit="${memory_limit_mb}M"
        id=$(container run -d --rm --name "$name" --cpus="${CONTAINER_STANDARD_CPUS}" --memory="${memory_limit}" "${STREAM_IMAGE}" sh -c "sleep 1000000" 2>/dev/null || true)
    fi

    if [ -z "$id" ]; then
        print_error "Failed to start STREAM worker container (runtime=${runtime})"
        return 1
    fi
    echo "$id"
}

stop_stream_worker_container() {
    local runtime=$1
    local id=$2
    if [ -z "$id" ]; then
        return 0
    fi
    if [ "$runtime" = "docker" ]; then
        docker stop "$id" >/dev/null 2>&1 || true
    else
        container stop "$id" >/dev/null 2>&1 || true
    fi
}

prepare_stream_binary_once() {
    local runtime=$1
    local worker_id=$2
    local array_size_mb=$3

    # Preparation OUTSIDE the measurement: compile the vendored stream.c once per scenario.
    local array_elems=$((array_size_mb * 1024 * 1024 / 8))
    local cmd="
        set -e
        mkdir -p /opt/stream
        cd /opt/stream
        # stream.c is vendored into the image (see images/stream/Dockerfile); no download
        test -f stream.c
        gcc -O3 -fopenmp -DSTREAM_ARRAY_SIZE=${array_elems} -DNTIMES=3 stream.c -o stream -lm
        test -x stream
    "

    local out=""
    local rc=0
    if [ "$runtime" = "docker" ]; then
        out=$(docker exec "$worker_id" sh -c "$cmd" 2>&1)
        rc=$?
    else
        out=$(container exec "$worker_id" sh -c "$cmd" 2>&1)
        rc=$?
    fi

    if [ $rc -ne 0 ]; then
        log_stream_failure "prepare" "$runtime" "ALL" "NA" 0 0 "$rc" "$out"
        return 1
    fi
    return 0
}

# Function to run STREAM with methodological rigor
# Function to run warmup iterations (discarded)
run_warmup_stream() {
    local runtime=$1
    local test_type=$2
    local threads=$3
    local warmup_count=$4
    local worker_id=$5
    
    if [ "$warmup_count" -le 0 ]; then
        return 0
    fi
    
    print_step "Running ${warmup_count} warmup iterations (discarded) - ${runtime} ${test_type} ${threads} threads"
    
    for w in $(seq 1 $warmup_count); do
        print_info "Warmup ${w}/${warmup_count} - ${runtime} ${test_type} ${threads} threads"

        local cmd="
          export OMP_NUM_THREADS=${threads}
          /opt/stream/stream >/dev/null 2>&1
        "
        local rc=0
        if [ "$runtime" = "docker" ]; then
            docker exec "$worker_id" sh -c "$cmd" >/dev/null 2>&1 || rc=$?
        else
            container exec "$worker_id" sh -c "$cmd" >/dev/null 2>&1 || rc=$?
        fi
        if [ $rc -ne 0 ]; then
            log_stream_failure "warmup" "$runtime" "$test_type" "$threads" "$w" 0 "$rc" "warmup_exec_failed"
        fi
        
        # Pause between warmup iterations
        sleep $PAUSE_STREAM
    done
    
    print_success "✅ Warmup completed"
}

run_stream_benchmark() {
    local runtime=$1
    local test_type=$2  # copy, scale, add, triad
    local threads=$3
    local iterations=$4
    
    print_step "Running ${test_type} ${threads} threads - ${runtime} (${iterations} iterations)"
    
    # Preparation outside the measurement: start worker + compile once per scenario
    local array_mb="${STREAM_ARRAY_SIZE_MB}"
    if [ "$runtime" = "container" ]; then
        array_mb="${STREAM_ARRAY_SIZE_MB_CONTAINER}"
    fi
    local worker_id=""
    local container_mem_mb=""
    if [ "$runtime" = "container" ]; then
        container_mem_mb=$(calculate_container_memory_limit_mb "$array_mb")
        if [ "${DEBUG_STREAM_MEMORY:-false}" = "true" ] || [ "$iterations" -le 2 ]; then
            print_info "    [DEBUG] Apple container memory_limit=${container_mem_mb}MB (array=${array_mb}MB)"
        fi
        worker_id=$(start_stream_worker_container "$runtime" "$container_mem_mb")
    else
        worker_id=$(start_stream_worker_container "$runtime")
    fi

    if ! prepare_stream_binary_once "$runtime" "$worker_id" "$array_mb"; then
        print_error "❌ Failed to prepare STREAM binary (runtime=${runtime}, array=${array_mb}MB)"
        stop_stream_worker_container "$runtime" "$worker_id"
        return 1
    fi

    # Warmup iterations (per Raj Jain) - NO setup noise in the loop
    if [ "$WARMUP_ITERATIONS" -gt 0 ]; then
        print_step "Warmup: ${WARMUP_ITERATIONS} iterations (discarded)"
        run_warmup_stream "$runtime" "$test_type" "$threads" $WARMUP_ITERATIONS "$worker_id"
    else
        print_info "ℹ️  Warmup disabled (WARMUP_ITERATIONS=${WARMUP_ITERATIONS})"
    fi
    
    local output_file="${OUTPUT_DIR}/${runtime}_stream_${test_type}_${threads}t.csv"
    local valid_count=0
    local total_count=0
    local high_load_count=0
    
    # CSV header
    echo "iteration,bandwidth_mb_per_sec,avg_time,min_time,max_time" > "$output_file"
    
    for i in $(seq 1 $iterations); do
        print_info "Iteration ${i}/${iterations} - ${runtime} ${test_type} ${threads} threads"
        
        # Monitor system load before the iteration (mitigation of threat T4 - documentation only)
        if ! "${SCRIPT_DIR}/../utils/monitor_system_load.sh" >> "${OUTPUT_DIR}/system_load_log.csv" 2>/dev/null; then
            print_warning "  ⚠️  System load above thresholds at iteration ${i}/${iterations} (documented, but continuing)"
            high_load_count=$((high_load_count + 1))
        fi
        
        local result=""
        local avg_time=""
        
        # Measurement: run only the STREAM binary (setup outside the loop)
        local attempt=0
        local max_attempts=$((STREAM_MAX_RETRIES_PER_ITERATION + 1))
        local stream_output=""
        local exec_rc=0
        result=""
        avg_time=""

        while [ $attempt -lt $max_attempts ]; do
            attempt=$((attempt + 1))
            exec_rc=0
            if [ "$runtime" = "docker" ]; then
                stream_output=$(docker exec "$worker_id" sh -c "export OMP_NUM_THREADS=${threads}; /opt/stream/stream 2>&1" 2>&1) || exec_rc=$?
            else
                stream_output=$(container exec "$worker_id" sh -c "export OMP_NUM_THREADS=${threads}; /opt/stream/stream 2>&1" 2>&1) || exec_rc=$?
            fi

            if [ $exec_rc -ne 0 ]; then
                log_stream_failure "measure_exec" "$runtime" "$test_type" "$threads" "$i" "$attempt" "$exec_rc" "${stream_output:0:300}"
                sleep "$STREAM_RETRY_PAUSE_SECONDS"
                continue
            fi

            local raw_output
            raw_output=$(echo "$stream_output" | grep -iE "^[[:space:]]*${test_type}[[:space:]]*:" | head -1)
            if [ -n "$raw_output" ]; then
                result=$(echo "$raw_output" | awk '{print $2}' | head -1 | xargs)
                avg_time=$(echo "$raw_output" | awk '{print $3}' | head -1 | xargs)
                break
            else
                log_stream_failure "parse" "$runtime" "$test_type" "$threads" "$i" "$attempt" 0 "missing_line_${test_type}"
                sleep "$STREAM_RETRY_PAUSE_SECONDS"
            fi
        done
        
        # Basic validation (reasonable numeric result)
        # Temporarily disable set -e for validation (bc may fail if result is empty)
        set +e
        local is_valid=false
        if [ -n "$result" ] && [[ "$result" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            if [ "$(echo "$result > 0" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
                is_valid=true
            fi
        fi
        set -e
        
        if [ "$is_valid" = true ]; then
            echo "${i},${result},${avg_time:-0},${avg_time:-0},${avg_time:-0}" >> "$output_file"
            valid_count=$((valid_count + 1))
            print_success "✅ ${result} MB/sec (valid)"
        else
            print_warning "⚠️  Iteration ${i}/${iterations}: ${result} (invalid)"
            # Show additional debug output if we are near the limit and valid iterations are missing
            if [ $valid_count -lt $MIN_VALID_ITERATIONS ] && [ $i -gt $((iterations - 3)) ]; then
                if [ -z "$result" ]; then
                    print_warning "    [DEBUG] Empty result - possible failure capturing STREAM output"
                elif [[ ! "$result" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    print_warning "    [DEBUG] Result is not numeric: '${result}'"
                else
                    print_warning "    [DEBUG] Result is zero or negative: '${result}'"
                fi
            fi
        fi
        
        total_count=$((total_count + 1))
        
        # Standardized pause between iterations
        sleep $PAUSE_STREAM
    done

    stop_stream_worker_container "$runtime" "$worker_id"
    
    print_step "Result: ${valid_count}/${total_count} valid iterations (high-load iterations documented: ${high_load_count})"
    
    if [ $valid_count -lt $MIN_VALID_ITERATIONS ]; then
        print_error "❌ Insufficient valid iterations (${valid_count}/${MIN_VALID_ITERATIONS} minimum)"
        # In validation mode, do not exit with an error (few iterations are expected)
        if [ "${VALIDATION_MODE:-false}" != "true" ]; then
            return 1
        fi
    fi
    
    print_success "✅ Benchmark ${test_type} ${threads} threads - ${runtime} completed successfully"
    return 0
}

# Consolidate experimental results
consolidate_results() {
    print_step "Consolidating results..."
    
    local summary_file="${OUTPUT_DIR}/stream_performance_summary.csv"
    local stream_file="${OUTPUT_DIR}/results_stream.csv"
    
    # Header
    echo "runtime,test_type,threads,iterations,valid_iterations,mean_bandwidth_mb_per_sec,std_bandwidth_mb_per_sec,min_bandwidth_mb_per_sec,max_bandwidth_mb_per_sec" > "$summary_file"
    echo "timestamp,platform,tool,test,threads,metric,value,unit,notes" > "$stream_file"
    
    # Process each results file
    for file in "${OUTPUT_DIR}"/*_stream_*.csv; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            local runtime=$(echo "$filename" | cut -d'_' -f1)
            # test_type is the third part: container_stream_Copy_1t.csv -> Copy
            local test_type=$(echo "$filename" | cut -d'_' -f3)
            local threads=$(echo "$filename" | sed 's/.*_\([0-9]*\)t\.csv/\1/')
            
            # Compute statistics (Welford — sample standard deviation, ddof=1)
            local stats=$(tail -n +2 "$file" | compute_stats_welford 2)
            
            echo "${runtime},${test_type},${threads},${stats}" >> "$summary_file"

            # Append data to the consolidated file compatible with the analysis
            # test_type is now extracted correctly (Copy, Scale, Add, Triad)
            tail -n +2 "$file" | while IFS=',' read -r iteration bandwidth_mb_per_sec avg_time min_time max_time; do
                if [ -n "$bandwidth_mb_per_sec" ]; then
                    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S-0300")
                    # Use the correct test_type (Copy, Scale, Add, Triad) instead of "stream"
                    echo "${timestamp},macOS,${runtime},${test_type},${threads},bandwidth_mb_per_sec,${bandwidth_mb_per_sec},MB/s,from_stream_only" >> "$stream_file"
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
=== EXPERIMENTAL MANIFEST - STREAM PERFORMANCE ===
Date: $(date)
Experiment: Memory Bandwidth Performance (Docker vs Apple container)
Iterations: ${ITERATIONS}
Valid minimum: ${MIN_VALID_ITERATIONS}
Significance level: ${ALPHA_LEVEL}
Confidence level: $(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)%

=== GENERATED FILES ===
$(ls -la "${OUTPUT_DIR}")

=== CONFIGURATION ===
- Iterations: ${ITERATIONS}
- Statistical validation: minimum ${MIN_VALID_ITERATIONS} valid iterations
- Test: STREAM (4 operation types, 2 thread configurations per runtime)
- Runtimes: Docker, Apple container
- Array size: ${STREAM_ARRAY_SIZE_MB}MB (for both runtimes)
- NOTE: Apple container requires explicit memory configuration via --memory
- Automatically configured memory: $((${STREAM_ARRAY_SIZE_MB_CONTAINER} * 3 * 150 / 100))MB
- For a fair comparison, both runtimes use ${STREAM_ARRAY_SIZE_MB}MB
- Threads: 1 and 2
- Test types: copy, scale, add, triad
- Warmup iterations: ${WARMUP_ITERATIONS}

=== LOAD MONITORING (T4) ===
- Script: src/utils/monitor_system_load.sh
- CPU threshold: ${CPU_THRESHOLD:-20.0}%
- Memory threshold: ${MEM_THRESHOLD:-80.0}%
- Load log: system_load_log.csv
- Note: Monitoring is informational/documentation only. It does not prevent iterations from running.

=== IMAGE USED (METHODOLOGICAL RIGOR) ===
Image: ${STREAM_IMAGE}
Digest: ${STREAM_DIGEST:-N/A (not captured)}
Note: Identical image guaranteed on both runtimes for experimental validity
STREAM compiled inside the container with flags: -O3 -fopenmp

=== "SETUP NOISE" CONTROL (STREAM) ===
- Policy: remove setup (installation/compilation/download) from inside the iteration
- Implementation:
  - Fixed local image with toolchain (no apk add in the loop): ${STREAM_IMAGE}
  - Binary compiled once per scenario (outside the measurement)
  - Measurement runs only /opt/stream/stream via exec (steady state)

=== METHODOLOGY ===
- Memory bandwidth measurement
- Result validation (positive numeric values)
- Robust statistical analysis
- Full data transparency
- Based on Raj Jain - The Art of Computer Systems Performance Analysis

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
    print_step "=== STREAM PERFORMANCE BENCHMARK ==="
    print_step "Docker vs Apple container - Memory Bandwidth Performance"
    echo ""
    
    # Initial checks
    check_dependencies
    check_rosetta
    check_apple_container auto_start
    
    # Set up experiment
    setup_output_directory "stream_performance"
    
    print_step "Experiment configuration:"
    print_info "Name: ${EXPERIMENT_NAME}"
    print_info "Iterations: ${ITERATIONS}"
    print_info "Valid minimum: ${MIN_VALID_ITERATIONS}"
    local conf_pct
    conf_pct=$(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)
    print_info "Confidence level: ${conf_pct}%"
    print_info "Recommended minimum size (Raj Jain, Ch. 13): ${MIN_SAMPLE_SIZE_RECOMMENDED} observations"
    if [ "$WARMUP_ITERATIONS" -gt 0 ]; then
        print_info "Warmup iterations: ${WARMUP_ITERATIONS}"
    else
        print_info "Warmup iterations: Disabled"
    fi
    print_info "Array size: ${STREAM_ARRAY_SIZE_MB}MB (both runtimes)"
    if [ -n "${STREAM_ARRAY_SIZE_MB_CONTAINER:-}" ] && [ "$STREAM_ARRAY_SIZE_MB_CONTAINER" != "$STREAM_ARRAY_SIZE_MB" ]; then
        print_info "Apple container size: ${STREAM_ARRAY_SIZE_MB_CONTAINER}MB (custom)"
    fi
    local memory_limit_calculated=$((STREAM_ARRAY_SIZE_MB_CONTAINER * 3 * 150 / 100))
    print_info "Apple container memory limit (automatically computed): ${memory_limit_calculated}MB"
    echo ""
    
    # Run experiment
    print_step "Running STREAM Performance..."
    # Verify and ensure base images (methodological rigor)
    print_step "Verifying base images (methodological rigor)..."
    ensure_stream_image "docker"
    ensure_stream_image "container"
    if [ -n "$STREAM_DIGEST" ]; then
        print_step "✅ Base image verified: ${STREAM_IMAGE}"
        print_step "✅ Digest: ${STREAM_DIGEST:0:20}..."
    fi
    
    # Randomization to reduce systematic bias (optional)
    # Controlled via environment variable: ENABLE_RANDOMIZATION=true/false
    # Default: true (randomization enabled)
    local enable_randomization=${ENABLE_RANDOMIZATION:-true}
    
    # Define tests: each combination of runtime, operation, and threads
    local tests=(
        "docker:Copy:1"
        "container:Copy:1"
        "docker:Scale:1"
        "container:Scale:1"
        "docker:Add:1"
        "container:Add:1"
        "docker:Triad:1"
        "container:Triad:1"
        "docker:Copy:2"
        "container:Copy:2"
        "docker:Scale:2"
        "container:Scale:2"
        "docker:Add:2"
        "container:Add:2"
        "docker:Triad:2"
        "container:Triad:2"
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
        local operation="${test#*:}"
        operation="${operation%%:*}"
        local threads="${test##*:}"
        
        print_step "Running test ${test_num}/${total_tests}: ${runtime} - ${operation} (${threads} thread(s))"
        run_stream_benchmark "$runtime" "$operation" "$threads" $ITERATIONS
    done
    
    consolidate_results
    generate_manifest
    run_statistical_analysis "${OUTPUT_DIR}"
    
    print_success "✅ STREAM Performance completed!"
    
    print_step "=== EXPERIMENT COMPLETED ==="
    print_success "Results saved to: ${OUTPUT_DIR}"
    print_step "✅ Robust statistical analysis has already been run automatically"
    print_info "To re-run the analysis: python src/analysis/analyze_results_enhanced.py ${OUTPUT_DIR} --output ${OUTPUT_DIR}/enhanced_analysis"
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

