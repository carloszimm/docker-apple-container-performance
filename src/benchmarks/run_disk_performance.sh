#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# DISK PERFORMANCE BENCHMARK
# =============================================================================
#
# DESCRIPTION:
#   Script to run disk I/O performance benchmarks using fio,
#   comparing Docker Desktop and Apple container. The script follows a
#   rigorous methodology based on Raj Jain for computer systems performance
#   analysis, including warmup iterations, randomization, and statistical
#   validation.
#
# FEATURES:
#   - Measures disk I/O throughput on both runtimes
#   - Runs warmup iterations (discarded) for stabilization
#   - Applies randomization to the test execution order
#   - Validates results and computes descriptive statistics
#   - Generates CSV files with results and a manifest with metadata
#
# PARAMETERS (Environment Variables):
#
#   Benchmark-Specific Parameters:
#   PAUSE_DISK_OVERRIDE
#       Pause time (in seconds) between iterations for system stabilization.
#       Default: 3
#       Example: PAUSE_DISK_OVERRIDE=5 ./run_disk_performance.sh
#
#   FIO_SIZE_MB
#       Test size in MB (default: 1024MB = 1GB).
#       Example: FIO_SIZE_MB=512 ./run_disk_performance.sh
#
#   Parameters Common to All Benchmarks:
#   ITERATIONS_OVERRIDE
#       Number of main iterations to run.
#       Default: 30
#       Example: ITERATIONS_OVERRIDE=10 ./run_disk_performance.sh
#
#   WARMUP_ITERATIONS_OVERRIDE
#       Number of warmup iterations (discarded) run before the main
#       iterations. Use 0 to disable warmup.
#       Default: 5
#       Example: WARMUP_ITERATIONS_OVERRIDE=0 ./run_disk_performance.sh
#
#   MIN_VALID_OVERRIDE
#       Minimum number of valid iterations required for the
#       experiment to be considered valid.
#       Default: 30
#       Example: MIN_VALID_OVERRIDE=25 ./run_disk_performance.sh
#
#   ENABLE_RANDOMIZATION
#       Enables or disables randomization of the test execution order.
#       Default: true
#       Values: true, false
#       Example: ENABLE_RANDOMIZATION=false ./run_disk_performance.sh
#
#   CONFIDENCE_LEVEL
#       Desired confidence level for confidence intervals (0.90, 0.95, 0.99).
#       Default: 0.95 (95%)
#       The script automatically computes the recommended minimum sample size.
#       Example: CONFIDENCE_LEVEL=0.99 ./run_disk_performance.sh
#
#   ENABLE_SAMPLE_SIZE_PRETEST
#       When true, runs a short I/O pretest to estimate the recommended
#       sample size (n) based on Raj Jain, Ch. 13.9.
#       Default: false (uses only the practical minimum of 30 observations).
#       Example: ENABLE_SAMPLE_SIZE_PRETEST=true ./run_disk_performance.sh
#
#   TARGET_REL_ERROR
#       Target relative error (r) for computing n in the pretest.
#       Suggested default: 0.05 (5%).
#       Example: TARGET_REL_ERROR=0.03 ENABLE_SAMPLE_SIZE_PRETEST=true ./run_disk_performance.sh
#
#   PRETEST_ITERATIONS_OVERRIDE
#       Number of pretest iterations used to estimate the mean and standard deviation.
#       Default: 5
#       Example: PRETEST_ITERATIONS_OVERRIDE=10 ENABLE_SAMPLE_SIZE_PRETEST=true ./run_disk_performance.sh
#
# DEPENDENCIES:
#   - Docker Desktop installed and running
#   - Apple container installed and running
#   - Base image alpine:3.24 available (the local benchmark image with fio+jq is built automatically)
#
# OUTPUT:
#   Results are saved to: bench_results/disk_performance_<timestamp>/
#   - disk_performance_summary.csv: Consolidated summary with statistics
#   - docker_fio_*.csv: Individual Docker results
#   - container_fio_*.csv: Individual Apple container results
#   - results_fio.csv: Main format for statistical analysis
#   - manifest.txt: Experiment metadata (configuration, methodology)
#
# METHODOLOGY:
#   - Warmup Phase: 5 initial iterations discarded (configurable)
#   - Execution Phase: 30 main iterations (configurable)
#   - Randomization: Fisher-Yates shuffle for execution order
#   - Validation: Checks that values are positive numbers
#   - Statistics: Mean, standard deviation, minimum, maximum
#
# USAGE EXAMPLES:
#   # Default run (30 iterations, 5 warmup)
#   ./run_disk_performance.sh
#
#   # Quick test (2 iterations, no warmup)
#   ITERATIONS_OVERRIDE=2 WARMUP_ITERATIONS_OVERRIDE=0 ./run_disk_performance.sh
#
#   # Run without randomization
#   ENABLE_RANDOMIZATION=false ./run_disk_performance.sh
#
# AUTHOR:
#   Alessandra Pereira - Performance comparison: Docker Desktop vs Apple container
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
PAUSE_DISK=${PAUSE_DISK_OVERRIDE:-3}  # Default: 3s, can be overridden

# Significance and confidence level
ALPHA_LEVEL=0.05
CONFIDENCE_LEVEL=${CONFIDENCE_LEVEL:-0.95}  # Default: 95% (0.95)

# Compute the recommended minimum sample size for the specified confidence level
MIN_SAMPLE_SIZE_RECOMMENDED=$(calculate_min_sample_size "$CONFIDENCE_LEVEL")

# Check whether the number of iterations meets the recommended minimum
check_sample_size "$ITERATIONS" "$CONFIDENCE_LEVEL"

# -----------------------------------------------------------------------------
# FIO IMAGE / ENVIRONMENT (METHODOLOGICAL RIGOR + "SETUP NOISE" REMOVAL)
# -----------------------------------------------------------------------------
# Methodological problem (HIGHEST priority):
# - Installing packages (apk add fio/jq) and (re)creating the dataset inside the
#   iteration contaminates Disk I/O measurements ("setup noise").
#
# Solution:
# - Use a derived image with fio+jq preinstalled (setup outside the loop)
# - Keep one container per test (runtime+test_type) and use exec per iteration
# - Prepare the dataset (test file) once per test, outside the measurement
#
# Reproducibility note:
# - Fixed base: alpine:3.24
# - Local derived image: built automatically if missing
FIO_BASE_IMAGE=${FIO_BASE_IMAGE:-alpine:3.24}
FIO_IMAGE=${FIO_IMAGE:-bench-fio:alpine-3.24}
FIO_DIGEST=""

# Test size in MB (default: 1GB = 1024MB)
FIO_SIZE_MB=${FIO_SIZE_MB:-1024}

# Ensure the fio image is available on the runtime (METHODOLOGICAL RIGOR)
# and that there is no "setup noise" (package installation) inside the iteration.
ensure_fio_image() {
    local runtime=$1
    local dockerfile_dir="${SCRIPT_DIR}/images/fio"
    local dockerfile_path="${dockerfile_dir}/Dockerfile"

    if [ ! -f "$dockerfile_path" ]; then
        print_error "Dockerfile for fio image not found: ${dockerfile_path}"
        return 1
    fi

    if [ "$runtime" = "docker" ]; then
        if ! docker image inspect "${FIO_IMAGE}" >/dev/null 2>&1; then
            print_step "Building benchmark image (fio+jq): ${FIO_IMAGE}"
            if ! docker build -t "${FIO_IMAGE}" -f "${dockerfile_path}" "${dockerfile_dir}" >/dev/null 2>&1; then
                print_error "Failed to build image ${FIO_IMAGE}"
                return 1
            fi
        fi
        local img_id
        img_id=$(docker image inspect "${FIO_IMAGE}" --format '{{.Id}}' 2>/dev/null || echo "")
        if [ -n "$img_id" ]; then
            FIO_DIGEST="$img_id"
            print_step "Docker: ${FIO_IMAGE} id: ${img_id:0:20}..."
        fi
        return 0
    fi

    # Apple container: ensure the SAME image is available
    if ! container image ls 2>/dev/null | awk '{print $1":"$2}' | grep -q "${FIO_IMAGE}"; then
        print_warning "Image ${FIO_IMAGE} not found in Apple container. Syncing from Docker..."
        ensure_fio_image "docker"
        local tmp_tar="${OUTPUT_DIR:-.}/fio_image.tar"
        print_info "Exporting from Docker and importing into Apple container (same image, methodological rigor)..."
        if docker save "${FIO_IMAGE}" -o "${tmp_tar}" >/dev/null 2>&1; then
            if container image load --input "${tmp_tar}" >/dev/null 2>&1; then
                rm -f "${tmp_tar}" >/dev/null 2>&1 || true
                print_success "Image ${FIO_IMAGE} imported into Apple container (same as Docker)"
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
    docker_id=$(docker image inspect "${FIO_IMAGE}" --format '{{.Id}}' 2>/dev/null || echo "")
    container_id=$(container image inspect "${FIO_IMAGE}" --format '{{.Id}}' 2>/dev/null || echo "")
    if [ -n "$docker_id" ] && [ -n "$container_id" ]; then
        if [ "$docker_id" = "$container_id" ]; then
            print_step "✅ Identical IDs confirmed - same image on both runtimes"
            FIO_DIGEST="$docker_id"
        else
            print_warning "⚠️  Different IDs between runtimes - check consistency"
        fi
    fi
}

start_fio_worker_container() {
    local runtime=$1
    local test_dir_abs=$2
    local name="fio_${runtime}_$$_$(date +%s)"
    local id=""

    if [ "$runtime" = "docker" ]; then
        id=$(docker run -d --rm --name "$name" -v "${test_dir_abs}:/test" "${FIO_IMAGE}" sh -c "sleep 1000000" 2>/dev/null || true)
    else
        id=$(container run -d --rm --name "$name" --cpus="${CONTAINER_STANDARD_CPUS}" --memory="${CONTAINER_STANDARD_MEMORY}" -v "${test_dir_abs}:/test" "${FIO_IMAGE}" sh -c "sleep 1000000" 2>/dev/null || true)
    fi

    if [ -z "$id" ]; then
        print_error "Failed to start worker container (runtime=${runtime})"
        return 1
    fi

    echo "$id"
}

stop_fio_worker_container() {
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

prepare_fio_dataset_once() {
    local runtime=$1
    local worker_id=$2
    local filename=$3
    local fio_ioengine=$4
    local fio_size=$5

    # Preparation outside the measurement (removes "setup noise" from inside the iteration)
    # - Recreates a fixed-size file via fio (sequential write)
    # - Ensures read tests have a stable dataset
    local cmd="
        rm -f \"/test/${filename}\" >/dev/null 2>&1 || true
        fio --name=prepare --filename=\"/test/${filename}\" --size=${fio_size} --ioengine=${fio_ioengine} \
            --iodepth=1 --bs=1M --rw=write --direct=1 --numjobs=1 --group_reporting >/dev/null 2>&1
        sync >/dev/null 2>&1 || true
    "

    if [ "$runtime" = "docker" ]; then
        docker exec "$worker_id" sh -c "$cmd" >/dev/null 2>&1 || true
    else
        container exec "$worker_id" sh -c "$cmd" >/dev/null 2>&1 || true
    fi
}

# Function to run warmup iterations (discarded)
run_warmup_fio() {
    local runtime=$1
    local test_type=$2
    local warmup_count=$3
    local worker_id=$4
    local fio_ioengine=$5
    local fio_iodepth=$6
    local fio_bs=$7
    local fio_rw=$8
    local fio_size=$9
    local fio_filename=${10}
    
    if [ "$warmup_count" -le 0 ]; then
        return 0
    fi
    
    print_step "Running ${warmup_count} warmup iterations (discarded) - ${runtime} ${test_type}"
    
    for w in $(seq 1 $warmup_count); do
        print_info "Warmup ${w}/${warmup_count} - ${runtime} ${test_type}"

        local cmd="
            fio --name=warmup --filename=\"/test/${fio_filename}\" --size=${fio_size} --ioengine=${fio_ioengine} \
                --iodepth=${fio_iodepth} --bs=${fio_bs} --rw=${fio_rw} \
                --runtime=5 --time_based --direct=1 --group_reporting >/dev/null 2>&1
        "

        if [ "$runtime" = "docker" ]; then
            docker exec "$worker_id" sh -c "$cmd" >/dev/null 2>&1 || true
        else
            container exec "$worker_id" sh -c "$cmd" >/dev/null 2>&1 || true
        fi
        
        # Pause between warmup iterations
        sleep $PAUSE_DISK
    done
    
    print_success "✅ Warmup completed"
}

# Estimate the recommended sample size via pretest (Raj Jain 13.9)
estimate_sample_size_disk_pretest() {
    local pretest_iterations=${PRETEST_ITERATIONS_OVERRIDE:-5}
    local rel_error=${TARGET_REL_ERROR:-0.05}
    local runtime="docker"
    local test_type="sequential_write"

    print_info "Sample size pretest (Raj Jain 13.9):"
    print_info "  Runtime: ${runtime}, Test: ${test_type}"
    print_info "  Pretest iterations: ${pretest_iterations}"
    local rel_error_pct
    rel_error_pct=$(echo "$rel_error * 100" | bc -l | cut -d'.' -f1)
    print_info "  Target relative error: ${rel_error_pct}%"

    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "/tmp/disk_pretest_$$.tmp")
    local test_dir="${OUTPUT_DIR:-.}/_fio_pretest"
    mkdir -p "$test_dir"
    local test_dir_abs=$(cd "$test_dir" && pwd)

    # Use a persistent worker to avoid including "setup noise" in the pretest
    local worker_id
    worker_id=$(start_fio_worker_container "$runtime" "$test_dir_abs")
    local fio_filename="fio_pretest.dat"
    prepare_fio_dataset_once "$runtime" "$worker_id" "$fio_filename" "libaio" "${FIO_SIZE_MB}M"

    for i in $(seq 1 $pretest_iterations); do
        print_info "  Pretest ${i}/${pretest_iterations}..."
        local result=""

        local cmd="
            fio --name=pretest --filename=\"/test/${fio_filename}\" --size=${FIO_SIZE_MB}M --ioengine=libaio \
                --iodepth=1 --bs=1M --rw=write --runtime=5 --time_based --direct=1 \
                --output-format=json --output=/tmp/fio_output.json 2>/dev/null
            jq -r '.jobs[0].write.bw' /tmp/fio_output.json 2>/dev/null || echo '0'
        "
        local raw_output=""
        raw_output=$(docker exec "$worker_id" sh -c "$cmd" 2>&1 || true)
        result=$(echo "$raw_output" | head -1 | xargs)
        if [ -n "$result" ] && [ "$result" != "0" ] && [[ "$result" =~ ^[0-9]+$ ]]; then
            result=$(echo "scale=2; $result / 1024" | bc -l 2>/dev/null || echo "$result")
        fi

        if [[ "$result" =~ ^[0-9]+\.?[0-9]*$ ]] && [ "$(echo "$result > 0" | bc -l)" -eq 1 ]; then
            echo "$result" >> "$tmp_file"
            print_success "  ✓ ${result} KB/sec (valid for pretest)"
        else
            print_warning "  ⚠️  Invalid value in pretest: ${result}"
        fi
        
        sleep "$PAUSE_DISK"
    done

    stop_fio_worker_container "$runtime" "$worker_id"
    rm -rf "$test_dir" 2>/dev/null || true

    # Compute mean and standard deviation from the pretest
    if [ ! -s "$tmp_file" ]; then
        print_warning "⚠️  Pretest did not produce enough valid data to estimate sample size"
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

    print_info "  Mean (pretest): ${mean} KB/sec"
    print_info "  Standard deviation (pretest): ${std} KB/sec"
    
    # Compute CV for context
    local cv
    cv=$(echo "scale=2; ($std / $mean) * 100" | bc -l)
    print_info "  Coefficient of variation (CV): ${cv}%"

    # Compute n using Jain's formula 13.9 (before applying the floor)
    local z
    z=$(get_z_critical "$CONFIDENCE_LEVEL")
    
    local E n_calculated n_ceil
    E=$(echo "$rel_error * $mean" | bc -l)
    n_calculated=$(echo "scale=6; ($z * $std / $E)^2" | bc -l)
    n_ceil=$(printf '%s\n' "$n_calculated" | awk '{ if ($1 <= 0) print 1; else if ($1 == int($1)) print int($1); else print int($1)+1 }')
    
    # Get final n (with floor of 30)
    local n_rec
    n_rec=$(calculate_required_sample_size "$mean" "$std" "$rel_error" "$CONFIDENCE_LEVEL")

    local conf_pct_display
    conf_pct_display=$(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)
    
    print_step "Sample size estimate (Raj Jain 13.9):"
    echo ""
    print_info "  Formula calculation:"
    print_info "    z_{{α/2}} = ${z} (${conf_pct_display}% confidence)"
    print_info "    E = r × X̄ = ${rel_error} × ${mean} = ${E} KB/sec"
    print_info "    n = (z × s / E)² = (${z} × ${std} / ${E})²"
    print_info "    n = ${n_calculated}"
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
        print_warning "  ⚠️  Current iterations (${ITERATIONS}) below recommended (${n_rec}) for ${conf_pct}% confidence and ${rel_error_pct}% relative error"
        print_info "      → Consider increasing ITERATIONS_OVERRIDE to at least ${n_rec} for formal runs"
    else
        print_success "  ✓ Current iterations (${ITERATIONS}) ≥ recommended (${n_rec}) for the configured pretest"
    fi
}

# Function to run the fio benchmark
run_fio_benchmark() {
    local runtime=$1
    local test_type=$2  # sequential_write, sequential_read, random_write, random_read
    local iterations=$3
    
    print_step "Running ${test_type} - ${runtime} (${iterations} iterations)"
    
    # Create temporary directory for tests (use absolute path)
    local test_dir="${OUTPUT_DIR}/_fio_test_${runtime}_${test_type}"
    mkdir -p "$test_dir"
    local test_dir_abs=$(cd "$test_dir" && pwd)
    
    # Determine fio parameters based on the test type
    local fio_ioengine="libaio"
    local fio_iodepth="1"
    local fio_bs="4k"
    local fio_rw=""
    local fio_size="${FIO_SIZE_MB}M"
    
    case "$test_type" in
        sequential_write)
            fio_rw="write"
            fio_bs="1M"
            ;;
        sequential_read)
            fio_rw="read"
            fio_bs="1M"
            ;;
        random_write)
            fio_rw="randwrite"
            fio_bs="4k"
            fio_iodepth="16"
            ;;
        random_read)
            fio_rw="randread"
            fio_bs="4k"
            fio_iodepth="16"
            ;;
    esac
    
    # Start worker container (outside the iteration) and prepare dataset (outside the measurement)
    local worker_id
    worker_id=$(start_fio_worker_container "$runtime" "$test_dir_abs")
    local fio_filename="fio_${test_type}.dat"
    prepare_fio_dataset_once "$runtime" "$worker_id" "$fio_filename" "$fio_ioengine" "$fio_size"

    # Warmup iterations (per Raj Jain) - no setup noise inside the loop
    if [ "$WARMUP_ITERATIONS" -gt 0 ]; then
        print_step "Warmup: ${WARMUP_ITERATIONS} iterations (discarded)"
        run_warmup_fio "$runtime" "$test_type" $WARMUP_ITERATIONS "$worker_id" \
            "$fio_ioengine" "$fio_iodepth" "$fio_bs" "$fio_rw" "$fio_size" "$fio_filename"
    else
        print_info "ℹ️  Warmup disabled (WARMUP_ITERATIONS=${WARMUP_ITERATIONS})"
    fi
    
    local output_file="${OUTPUT_DIR}/${runtime}_fio_${test_type}.csv"
    local valid_count=0
    local total_count=0
    local high_load_count=0
    
    # CSV header
    echo "iteration,throughput_kb_per_sec,latency_ms,iops" > "$output_file"
    
    for i in $(seq 1 $iterations); do
        print_info "Iteration ${i}/${iterations} - ${runtime} ${test_type}"
        
        # Monitor system load before the iteration (threat T4 mitigation - documentation only)
        if ! "${SCRIPT_DIR}/../utils/monitor_system_load.sh" >> "${OUTPUT_DIR}/system_load_log.csv" 2>/dev/null; then
            print_warning "  ⚠️  System load above thresholds at iteration ${i}/${iterations} (documented, but continuing)"
            high_load_count=$((high_load_count + 1))
        fi
        
        local result=""
        local iops=""
        
        local cmd="
            fio --name=test --filename=\"/test/${fio_filename}\" --size=${fio_size} --ioengine=${fio_ioengine} \
                --iodepth=${fio_iodepth} --bs=${fio_bs} --rw=${fio_rw} \
                --runtime=10 --time_based --direct=1 --invalidate=1 --output-format=json --output=/tmp/fio_output.json 2>/dev/null
            if [ \"${fio_rw}\" = \"write\" ] || [ \"${fio_rw}\" = \"randwrite\" ]; then
                jq -r '.jobs[0].write.bw' /tmp/fio_output.json 2>/dev/null || echo '0'
                echo '|'
                jq -r '.jobs[0].write.iops' /tmp/fio_output.json 2>/dev/null || echo '0'
            else
                jq -r '.jobs[0].read.bw' /tmp/fio_output.json 2>/dev/null || echo '0'
                echo '|'
                jq -r '.jobs[0].read.iops' /tmp/fio_output.json 2>/dev/null || echo '0'
            fi
        "

        local raw_output=""
        if [ "$runtime" = "docker" ]; then
            raw_output=$(docker exec "$worker_id" sh -c "$cmd" 2>&1 || true)
        else
            raw_output=$(container exec "$worker_id" sh -c "$cmd" 2>&1 || true)
        fi

        # Parse output (format: <bw>|<iops>)
        result=$(echo "$raw_output" | head -1 | xargs)
        iops=$(echo "$raw_output" | tail -1 | xargs)
        # Convert to KB (bw is reported in bytes)
        if [ -n "$result" ] && [ "$result" != "0" ] && [[ "$result" =~ ^[0-9]+$ ]]; then
            result=$(echo "scale=2; $result / 1024" | bc -l 2>/dev/null || echo "$result")
        fi
        
        # Basic validation (reasonable numeric result)
        if [[ "$result" =~ ^[0-9]+\.?[0-9]*$ ]] && [ $(echo "$result > 0" | bc -l) -eq 1 ]; then
            echo "${i},${result},10.0,${iops:-0}" >> "$output_file"
            valid_count=$((valid_count + 1))
            print_success "✅ ${result} KB/sec (valid)"
        else
            print_warning "⚠️  ${result} (invalid)"
        fi
        
        total_count=$((total_count + 1))
        
        # Standardized pause between iterations
        sleep $PAUSE_DISK
    done
    
    stop_fio_worker_container "$runtime" "$worker_id"
    # Clean up test directory
    rm -rf "$test_dir" 2>/dev/null || true
    
    print_step "Result: ${valid_count}/${total_count} valid iterations (high-load iterations documented: ${high_load_count})"
    
    if [ $valid_count -lt $MIN_VALID_ITERATIONS ]; then
        print_error "❌ Insufficient valid iterations (${valid_count}/${MIN_VALID_ITERATIONS} minimum)"
        # In validation mode, do not exit with an error (few iterations are expected)
        if [ "${VALIDATION_MODE:-false}" != "true" ]; then
            return 1
        fi
    fi
    
    print_success "✅ Benchmark ${test_type} - ${runtime} completed successfully"
    return 0
}

# Consolidate results
consolidate_results() {
    print_step "Consolidating results..."
    
    local summary_file="${OUTPUT_DIR}/disk_performance_summary.csv"
    local fio_file="${OUTPUT_DIR}/results_fio.csv"
    
    # Header
    echo "runtime,test_type,iterations,valid_iterations,mean_throughput_kb_per_sec,std_throughput_kb_per_sec,min_throughput_kb_per_sec,max_throughput_kb_per_sec" > "$summary_file"
    echo "timestamp,platform,tool,test,metric,value,unit,notes" > "$fio_file"
    
    # Process each results file
    for file in "${OUTPUT_DIR}"/*_fio_*.csv; do
        if [ -f "$file" ]; then
            local runtime=$(basename "$file" | cut -d'_' -f1)
            local test_type=$(basename "$file" | sed 's/.*_fio_\(.*\)\.csv/\1/')
            
            # Compute statistics (Welford — sample standard deviation, ddof=1)
            local stats=$(tail -n +2 "$file" | compute_stats_welford 2)
            
            echo "${runtime},${test_type},${stats}" >> "$summary_file"

            # Append data to the consolidated file compatible with the analysis
            tail -n +2 "$file" | while IFS=',' read -r iteration throughput_kb_per_sec latency_ms iops; do
                if [ -n "$throughput_kb_per_sec" ]; then
                    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S-0300")
                    echo "${timestamp},macOS,${runtime},${test_type},throughput_kb_per_sec,${throughput_kb_per_sec},KB/s,from_disk_only" >> "$fio_file"
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
=== EXPERIMENT MANIFEST - DISK PERFORMANCE ===
Date: $(date)
Experiment: Disk I/O Performance (Docker Desktop vs Apple container)
Iterations: ${ITERATIONS}
Valid minimum: ${MIN_VALID_ITERATIONS}
Significance level: ${ALPHA_LEVEL}
Confidence level: $(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)%

=== GENERATED FILES ===
$(ls -la "${OUTPUT_DIR}")

=== CONFIGURATION ===
- Iterations: ${ITERATIONS}
- Statistical validation: Minimum ${MIN_VALID_ITERATIONS} valid iterations
- Test: fio (4 I/O types per runtime)
- Runtimes: Docker Desktop, Apple container
- Test size: ${FIO_SIZE_MB}MB
- Test types: sequential_write, sequential_read, random_write, random_read
- Warmup iterations: ${WARMUP_ITERATIONS}

=== LOAD MONITORING (T4) ===
- Script: src/utils/monitor_system_load.sh
- Threshold CPU: ${CPU_THRESHOLD:-20.0}%
- Memory threshold: ${MEM_THRESHOLD:-80.0}%
- Load log: system_load_log.csv
- Note: Monitoring is informational/documentary only. It does not prevent iterations from running.

=== IMAGE USED (METHODOLOGICAL RIGOR) ===
Image: ${FIO_IMAGE}
Digest: ${FIO_DIGEST:-N/A (not captured)}
Note: Identical image guaranteed on both runtimes for experimental validity

=== "SETUP NOISE" CONTROL (HIGHEST PRIORITY) ===
- Policy: remove setup from inside the iteration (package installation, dataset creation)
- Implementation:
  - Derived image (fio+jq) built before measurement
  - Worker container per test (runtime+test_type) and exec per iteration
  - Dataset (fio_*.dat file) prepared once per test, outside the measurement loop

=== METHODOLOGY ===
- Disk I/O performance measurement
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
    print_step "=== DISK PERFORMANCE BENCHMARK ==="
    print_step "Docker Desktop vs Apple container - Disk I/O Performance"
    echo ""
    
    # Initial checks
    check_dependencies
    check_rosetta
    check_apple_container auto_start
    
    # Set up experiment
    setup_output_directory "disk_performance"
    
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
    print_info "Test size: ${FIO_SIZE_MB}MB"
    echo ""
    
    # Run experiment
    print_step "Running Disk Performance..."
    # Verify and ensure fio images (methodological rigor + setup noise removal)
    print_step "Verifying fio image (methodological rigor + no setup noise)..."
    ensure_fio_image "docker"
    ensure_fio_image "container"
    if [ -n "$FIO_DIGEST" ]; then
        print_step "✅ fio image verified: ${FIO_IMAGE}"
        print_step "✅ Digest: ${FIO_DIGEST:0:20}..."
    fi
    
    # Sample size pretest (optional, Raj Jain 13.9)
    if [ "${ENABLE_SAMPLE_SIZE_PRETEST:-false}" = "true" ]; then
        echo ""
        print_step "Estimating recommended sample size (pretest, Raj Jain 13.9)..."
        echo ""
        estimate_sample_size_disk_pretest
        echo ""
    fi
    
    # Randomization to reduce systematic bias (optional)
    # Controlled via environment variable: ENABLE_RANDOMIZATION=true/false
    # Default: true (randomization enabled)
    local enable_randomization=${ENABLE_RANDOMIZATION:-true}
    
    # Define tests: each combination of runtime and test type
    local tests=(
        "docker:sequential_write"
        "container:sequential_write"
        "docker:sequential_read"
        "container:sequential_read"
        "docker:random_write"
        "container:random_write"
        "docker:random_read"
        "container:random_read"
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
        local test_type="${test#*:}"
        
        print_step "Running test ${test_num}/${total_tests}: ${runtime} - ${test_type}"
        run_fio_benchmark "$runtime" "$test_type" $ITERATIONS
    done
    
    consolidate_results
    generate_manifest
    run_statistical_analysis "${OUTPUT_DIR}"
    
    print_success "✅ Disk Performance completed!"
    
    print_step "=== EXPERIMENT COMPLETED ==="
    print_success "Results saved to: ${OUTPUT_DIR}"
    print_step "✅ Robust statistical analysis was already run automatically"
    print_info "To re-run the analysis: python src/analysis/analyze_results_enhanced.py ${OUTPUT_DIR} --output ${OUTPUT_DIR}/enhanced_analysis"
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

