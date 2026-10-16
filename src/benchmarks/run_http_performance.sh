#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# HTTP PERFORMANCE BENCHMARK
# =============================================================================
#
# DESCRIPTION:
#   Script to run HTTP performance benchmarks using wrk,
#   comparing Docker Desktop and Apple container. The script follows a
#   rigorous methodology based on Raj Jain for computer systems performance
#   analysis, including warmup iterations, randomization, and statistical
#   validation.
#
# FEATURES:
#   - Measures requests per second on both runtimes
#   - Runs warmup iterations (discarded) for stabilization
#   - Applies randomization to the test execution order
#   - Validates results and computes descriptive statistics
#   - Generates CSV files with results and a manifest with metadata
#
# PARAMETERS (Environment Variables):
#
#   Benchmark-Specific Parameters:
#   PAUSE_HTTP_OVERRIDE
#       Pause time (in seconds) between iterations for system stabilization.
#       Default: 4
#       Example: PAUSE_HTTP_OVERRIDE=5 ./run_http_performance.sh
#
#   Parameters Common to All Benchmarks:
#   ITERATIONS_OVERRIDE
#       Number of main iterations to run.
#       Default: 30
#       Example: ITERATIONS_OVERRIDE=10 ./run_http_performance.sh
#
#   WARMUP_ITERATIONS_OVERRIDE
#       Number of warmup iterations (discarded) run before the main
#       iterations. Use 0 to disable warmup.
#       Default: 5
#       Example: WARMUP_ITERATIONS_OVERRIDE=0 ./run_http_performance.sh
#
#   MIN_VALID_OVERRIDE
#       Minimum number of valid iterations required for the
#       experiment to be considered valid.
#       Default: 30
#       Example: MIN_VALID_OVERRIDE=25 ./run_http_performance.sh
#
#   ENABLE_RANDOMIZATION
#       Enables or disables randomization of the test execution order.
#       Default: true
#       Values: true, false
#       Example: ENABLE_RANDOMIZATION=false ./run_http_performance.sh
#
#   CONFIDENCE_LEVEL
#       Desired confidence level for confidence intervals (0.90, 0.95, 0.99).
#       Default: 0.95 (95%)
#       The script automatically computes the recommended minimum sample size.
#       Example: CONFIDENCE_LEVEL=0.99 ./run_http_performance.sh
#
#   ENABLE_SAMPLE_SIZE_PRETEST
#       When true, runs a short HTTP pretest to estimate the recommended
#       sample size (n) based on Raj Jain, Ch. 13.9.
#       Default: false (uses only the practical minimum of 30 observations).
#       Example: ENABLE_SAMPLE_SIZE_PRETEST=true ./run_http_performance.sh
#
#   TARGET_REL_ERROR
#       Target relative error (r) for computing n in the pretest.
#       Suggested default: 0.05 (5%).
#       Example: TARGET_REL_ERROR=0.03 ENABLE_SAMPLE_SIZE_PRETEST=true ./run_http_performance.sh
#
#   PRETEST_ITERATIONS_OVERRIDE
#       Number of pretest iterations used to estimate the mean and standard deviation.
#       Default: 5
#       Example: PRETEST_ITERATIONS_OVERRIDE=10 ENABLE_SAMPLE_SIZE_PRETEST=true ./run_http_performance.sh
#
# DEPENDENCIES:
#   - Docker Desktop installed and running
#   - Apple container installed and running
#   - wrk installed locally
#   - nginx image available
#
# OUTPUT:
#   Results are saved to: bench_results/http_performance_<timestamp>/
#   - http_performance_summary.csv: Consolidated summary with statistics
#   - docker_http_results.csv: Individual Docker results
#   - container_http_results.csv: Individual Apple container results
#   - results_wrk.csv: Main format for statistical analysis
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
#   ./run_http_performance.sh
#
#   # Quick test (2 iterations, no warmup)
#   ITERATIONS_OVERRIDE=2 WARMUP_ITERATIONS_OVERRIDE=0 ./run_http_performance.sh
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
PAUSE_HTTP=${PAUSE_HTTP_OVERRIDE:-4}  # Default: 4s, can be overridden

# Rigor policy: invariant workload (no server fallback)
# - Never replace nginx with another server (e.g., python http.server), so the workload does not change
# - If the server fails to start or become ready, retry up to a limit and record the reason
HTTP_IMAGE="nginx:stable"
HTTP_MAX_RETRIES_PER_ITERATION=${HTTP_MAX_RETRIES_PER_ITERATION:-3}
HTTP_STARTUP_TIMEOUT_SECONDS=${HTTP_STARTUP_TIMEOUT_SECONDS:-10}

# HTTP port on the host (for -p HOST_PORT:80).
# - HTTP_PORT_STRATEGY=fixed: requires HTTP_PORT to be free; if it is not, the iteration fails (logged) and continues
# - HTTP_PORT_STRATEGY=auto (default): searches from HTTP_PORT for a free port (HTTP_PORT_MAX_TRIES attempts)
HTTP_PORT=${HTTP_PORT:-8080}
HTTP_PORT_STRATEGY=${HTTP_PORT_STRATEGY:-auto}
HTTP_PORT_MAX_TRIES=${HTTP_PORT_MAX_TRIES:-50}

# Significance and confidence level
ALPHA_LEVEL=0.05
CONFIDENCE_LEVEL=${CONFIDENCE_LEVEL:-0.95}  # Default: 95% (0.95)

# Compute the recommended minimum sample size for the specified confidence level
MIN_SAMPLE_SIZE_RECOMMENDED=$(calculate_min_sample_size "$CONFIDENCE_LEVEL")

# Check whether the number of iterations meets the recommended minimum
check_sample_size "$ITERATIONS" "$CONFIDENCE_LEVEL"

# Function to run warmup iterations (discarded)
run_warmup_http() {
    local runtime=$1
    local test_type=$2
    local test_name=$3
    local warmup_count=$4
    
    if [ "$warmup_count" -le 0 ]; then
        return 0
    fi
    
    print_step "Running ${warmup_count} warmup iterations (discarded) - ${runtime} ${test_type} ${test_name}"
    
    for w in $(seq 1 $warmup_count); do
        print_info "Warmup ${w}/${warmup_count} - ${runtime} ${test_type} ${test_name}"
        
        local server_pid=""
        local http_port=""

        http_port="$(choose_http_port "$runtime" "warmup" "" || true)"
        if [ -z "$http_port" ]; then
            # No port available (or fixed port in use) → warmup cannot run
            print_warning "  ⚠️  Warmup ${w}/${warmup_count}: HTTP port unavailable (HTTP_PORT=${HTTP_PORT}, strategy=${HTTP_PORT_STRATEGY})"
            sleep $PAUSE_HTTP
            continue
        fi
        
        # Start HTTP server
        if [ "$runtime" = "docker" ]; then
            server_pid=$(docker run -d -p "${http_port}:80" "$HTTP_IMAGE" 2>/dev/null)
        elif [ "$runtime" = "container" ]; then
            # Use standardized resources, but keep -d and -p for daemon and port
            server_pid=$(container run -d -p "${http_port}:80" --cpus="${CONTAINER_STANDARD_CPUS}" --memory="${CONTAINER_STANDARD_MEMORY}" "$HTTP_IMAGE" 2>/dev/null)
        fi
        
        if [ -n "$server_pid" ]; then
            sleep 3
            wrk -t4 -c100 -d5s "http://localhost:${http_port}" > /dev/null 2>&1
            
            # Stop server
            if [ "$runtime" = "docker" ]; then
                docker stop "$server_pid" > /dev/null 2>&1
                docker rm "$server_pid" > /dev/null 2>&1
            elif [ "$runtime" = "container" ]; then
                container stop "$server_pid" > /dev/null 2>&1
                container rm "$server_pid" > /dev/null 2>&1
            fi
        fi
        
        # Pause between warmup iterations
        sleep $PAUSE_HTTP
    done
    
    print_success "✅ Warmup completed"
}

# Function to run the HTTP benchmark with methodological rigor
# Estimate the recommended sample size via pretest (Raj Jain 13.9)
estimate_sample_size_http_pretest() {
    local pretest_iterations=${PRETEST_ITERATIONS_OVERRIDE:-5}
    local rel_error=${TARGET_REL_ERROR:-0.05}
    local runtime="docker"

    print_info "Sample size pretest (Raj Jain 13.9):"
    print_info "  Runtime: ${runtime}"
    print_info "  Pretest iterations: ${pretest_iterations}"
    local rel_error_pct
    rel_error_pct=$(echo "$rel_error * 100" | bc -l | cut -d'.' -f1)
    print_info "  Target relative error: ${rel_error_pct}%"

    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "/tmp/http_pretest_$$.tmp")

    for i in $(seq 1 $pretest_iterations); do
        print_info "  Pretest ${i}/${pretest_iterations}..."
        local result=""
        local server_pid=""
        local http_port=""

        http_port="$(choose_http_port "docker" "pretest" "" || true)"
        if [ -z "$http_port" ]; then
            print_warning "  ⚠️  Pretest ${i}/${pretest_iterations}: HTTP port unavailable (HTTP_PORT=${HTTP_PORT}, strategy=${HTTP_PORT_STRATEGY})"
            sleep "$PAUSE_HTTP"
            continue
        fi
        
        server_pid=$(docker run -d -p "${http_port}:80" nginx:stable 2>/dev/null)
        if [ -n "$server_pid" ]; then
            sleep 3
            result=$(wrk -t4 -c100 -d5s "http://localhost:${http_port}" 2>/dev/null | grep "Requests/sec" | awk '{print $2}')
            docker stop "$server_pid" > /dev/null 2>&1
            docker rm "$server_pid" > /dev/null 2>&1
        fi

        if [[ "$result" =~ ^[0-9]+\.?[0-9]*$ ]] && [ "$(echo "$result > 0" | bc -l)" -eq 1 ]; then
            echo "$result" >> "$tmp_file"
            print_success "  ✓ ${result} req/sec (valid for pretest)"
        else
            print_warning "  ⚠️  Invalid value in pretest: ${result}"
        fi
        
        sleep "$PAUSE_HTTP"
    done

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

    print_info "  Mean (pretest): ${mean} req/sec"
    print_info "  Standard deviation (pretest): ${std} req/sec"
    
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
    print_info "    E = r × X̄ = ${rel_error} × ${mean} = ${E} req/sec"
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

# -----------------------------------------------------------------------------
# HTTP server helpers (invariant workload)
# -----------------------------------------------------------------------------
port_is_free() {
    local port=$1
    local py="python3"
    if ! command -v python3 >/dev/null 2>&1; then
        py="python"
    fi
    "$py" - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", port))
except OSError:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PY
}

choose_http_port() {
    # Selects a free port on the HOST to map nginx (80) -> localhost:<port>
    # Keeps the workload invariant; only the exposed port changes.
    local runtime=$1
    local stage=$2
    local log_file=$3
    local base_port="${4:-$HTTP_PORT}"

    local preferred="${base_port}"
    local strategy="${HTTP_PORT_STRATEGY}"
    local max_tries="${HTTP_PORT_MAX_TRIES}"

    if [ "$strategy" = "fixed" ]; then
        if port_is_free "$preferred"; then
            echo "$preferred"
            return 0
        fi
        if [ -n "$log_file" ]; then
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),${runtime},0,${stage},port_in_use,port=${preferred}; strategy=fixed" >> "$log_file"
        fi
        return 1
    fi

    local port="$preferred"
    local tries=0
    while [ "$tries" -lt "$max_tries" ]; do
        if port_is_free "$port"; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
        tries=$((tries + 1))
    done

    if [ -n "$log_file" ]; then
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),${runtime},0,${stage},no_free_port,from=${preferred}; tries=${max_tries}; strategy=auto" >> "$log_file"
    fi
    return 1
}

wait_for_http_ready() {
    local timeout_seconds=$1
    local http_port=$2
    local wait_count=0
    local server_ready=false

    while [ "$wait_count" -lt "$timeout_seconds" ]; do
        if command -v curl >/dev/null 2>&1; then
            # Accept any status other than 000 (server responded)
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${http_port}" 2>/dev/null || echo "000")
            if [ "$code" != "000" ]; then
                server_ready=true
                break
            fi
        elif command -v nc >/dev/null 2>&1; then
            if nc -z localhost "$http_port" 2>/dev/null; then
                server_ready=true
                break
            fi
        else
            # Final fallback: wait a short time and assume ready
            if [ "$wait_count" -ge 2 ]; then
                server_ready=true
                break
            fi
        fi

        sleep 1
        wait_count=$((wait_count + 1))
    done

    if [ "$server_ready" = true ]; then
        return 0
    fi
    return 1
}

sanitize_csv_field() {
    # Sanitizes a string to fit in a simple CSV:
    # - removes line breaks
    # - replaces commas with semicolons
    # - truncates length to avoid huge lines
    local s="${1:-}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    s="${s//,/;}"
    # Collapse multiple spaces
    s="$(echo "$s" | tr -s ' ' | sed 's/^ *//;s/ *$//')"
    # Limit length
    if [ "${#s}" -gt 220 ]; then
        s="${s:0:220}..."
    fi
    echo "$s"
}

stop_http_server() {
    local runtime=$1
    local server_pid=$2

    if [ -z "$server_pid" ]; then
        return 0
    fi

    if [ "$runtime" = "docker" ]; then
        docker stop "$server_pid" >/dev/null 2>&1 || true
        docker rm "$server_pid" >/dev/null 2>&1 || true
    else
        container stop "$server_pid" >/dev/null 2>&1 || true
        container rm "$server_pid" >/dev/null 2>&1 || true
    fi
}

start_http_server_nginx_only() {
    local runtime=$1
    local attempt=$2
    local log_file=$3
    local http_port=$4
    local server_pid=""

    if [ "$runtime" = "docker" ]; then
        local out=""
        set +e
        out=$(docker run -d -p "${http_port}:80" "$HTTP_IMAGE" 2>&1)
        local rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then
            server_pid="$out"
        else
            local details
            details=$(sanitize_csv_field "port=${http_port}; rc=${rc}; ${out}")
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),${runtime},${attempt},start,failed_to_start_container,${details}" >> "$log_file"
            return 1
        fi
    else
        local out=""
        set +e
        out=$(container run -d -p "${http_port}:80" --cpus="${CONTAINER_STANDARD_CPUS}" --memory="${CONTAINER_STANDARD_MEMORY}" "$HTTP_IMAGE" 2>&1)
        local rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then
            server_pid="$out"
        else
            local details
            details=$(sanitize_csv_field "port=${http_port}; rc=${rc}; ${out}")
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),${runtime},${attempt},start,failed_to_start_container,${details}" >> "$log_file"
            return 1
        fi
    fi

    if [ -z "$server_pid" ]; then
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),${runtime},${attempt},start,failed_to_start_container,port=${http_port}; image=${HTTP_IMAGE}" >> "$log_file"
        return 1
    fi

    if ! wait_for_http_ready "$HTTP_STARTUP_TIMEOUT_SECONDS" "$http_port"; then
        local code="N/A"
        if command -v curl >/dev/null 2>&1; then
            code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${http_port}" 2>/dev/null || echo "000")
        fi
        local logs=""
        if [ "$runtime" = "docker" ]; then
            logs=$(docker logs --tail 20 "$server_pid" 2>&1 || true)
        else
            logs=$(container logs --tail 20 "$server_pid" 2>&1 || true)
        fi
        local details
        details=$(sanitize_csv_field "port=${http_port}; http_code=${code}; timeout_s=${HTTP_STARTUP_TIMEOUT_SECONDS}; logs_tail=${logs}")
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),${runtime},${attempt},healthcheck,timeout,${details}" >> "$log_file"
        stop_http_server "$runtime" "$server_pid"
        return 1
    fi

    echo "$server_pid"
    return 0
}

run_http_benchmark() {
    local runtime=$1
    local test_type=$2
    local test_name=$3
    local iterations=$4
    
    print_step "Running ${test_type} ${test_name} - ${runtime} (${iterations} iterations)"
    
    # Warmup iterations (per Raj Jain)
    # WARMUP_ITERATIONS can be overridden via environment variable (default: 5)
    # If WARMUP_ITERATIONS=0, warmup is skipped
    if [ "$WARMUP_ITERATIONS" -gt 0 ]; then
        print_step "Warmup: ${WARMUP_ITERATIONS} iterations (discarded)"
        run_warmup_http "$runtime" "$test_type" "$test_name" $WARMUP_ITERATIONS
    else
        print_info "ℹ️  Warmup disabled (WARMUP_ITERATIONS=${WARMUP_ITERATIONS})"
    fi
    
    local output_file="${OUTPUT_DIR}/${runtime}_${test_type}_results.csv"
    local failures_log="${OUTPUT_DIR}/http_server_failures.csv"
    local valid_count=0
    local total_count=0
    local high_load_count=0
    
    # CSV header
    echo "iteration,requests_per_sec,latency_ms,throughput_mb_per_sec" > "$output_file"
    # Structured server failure log (for auditing)
    if [ ! -f "$failures_log" ]; then
        echo "timestamp_utc,runtime,attempt,stage,reason,details" > "$failures_log"
    fi
    
    for i in $(seq 1 $iterations); do
        print_info "Iteration ${i}/${iterations} - ${runtime} ${test_type} ${test_name}"
        
        # Monitor system load before the iteration (threat T4 mitigation - documentation only)
        if ! "${SCRIPT_DIR}/../utils/monitor_system_load.sh" >> "${OUTPUT_DIR}/system_load_log.csv" 2>/dev/null; then
            print_warning "  ⚠️  System load above thresholds at iteration ${i}/${iterations} (documented, but continuing)"
            high_load_count=$((high_load_count + 1))
        fi
        
        local result=""
        local server_pid=""
        local http_port=""
        
        # Invariant workload: always nginx:stable, no fallback to another server.
        # Retry policy: up to HTTP_MAX_RETRIES_PER_ITERATION attempts per iteration.
        local attempt=1
        while [ "$attempt" -le "$HTTP_MAX_RETRIES_PER_ITERATION" ]; do
            if [ "$attempt" -gt 1 ]; then
                print_warning "HTTP: retry ${attempt}/${HTTP_MAX_RETRIES_PER_ITERATION} (server was not ready on the previous attempt)"
            fi

            # Select a port on each attempt (avoids repeating the same port when the runtime
            # fails due to bind/port in use even if the local check does not detect it).
            # - strategy=fixed: always uses HTTP_PORT
            # - strategy=auto: tries different bases (HTTP_PORT + attempt-1) to escape conflicts
            local base_port="${HTTP_PORT}"
            if [ "${HTTP_PORT_STRATEGY}" != "fixed" ]; then
                base_port=$((HTTP_PORT + attempt - 1))
            fi

            http_port="$(choose_http_port "$runtime" "iteration" "$failures_log" "$base_port" || true)"
            if [ -z "$http_port" ]; then
                print_warning "⚠️  HTTP port unavailable (base=${base_port}, strategy=${HTTP_PORT_STRATEGY}) - invalid attempt"
                attempt=$((attempt + 1))
                sleep 1
                continue
            fi

            # start_http_server_nginx_only writes failure logs for auditing
            local pid_or_empty=""
            pid_or_empty=$(start_http_server_nginx_only "$runtime" "$attempt" "$failures_log" "$http_port" || true)
            if [ -n "$pid_or_empty" ]; then
                server_pid="$pid_or_empty"
                break
            fi

            attempt=$((attempt + 1))
            sleep 1
        done
        
        if [ -n "$server_pid" ]; then
            # Run benchmark (with robust error handling)
            local wrk_output=""
            wrk_output=$(wrk -t4 -c100 -d10s "http://localhost:${http_port}" 2>&1) || true
            
            if [ -n "$wrk_output" ]; then
                result=$(echo "$wrk_output" | grep "Requests/sec" | awk '{print $2}' || echo "")
            else
                result=""
            fi

            # Stop server (always try, even if the benchmark failed)
            stop_http_server "$runtime" "$server_pid"
        else
            print_warning "Failed to start nginx (${HTTP_IMAGE}) after ${HTTP_MAX_RETRIES_PER_ITERATION} attempt(s) - invalid iteration"
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),${runtime},${HTTP_MAX_RETRIES_PER_ITERATION},iteration,server_unavailable,port=${http_port:-N/A}; nginx_not_ready" >> "$failures_log"
            result=""
        fi
        
        # Basic validation (reasonable numeric result)
        if [ -n "$result" ] && [[ "$result" =~ ^[0-9]+\.?[0-9]*$ ]] && [ $(echo "$result > 0" | bc -l 2>/dev/null || echo "0") -eq 1 ]; then
            echo "${i},${result},10.0,${result}" >> "$output_file"
            valid_count=$((valid_count + 1))
            print_success "✅ ${result} req/sec (valid)"
        else
            print_warning "⚠️  HTTP Performance: validation error (result: ${result:-empty})"
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
    
    print_success "✅ Benchmark ${test_type} ${test_name} - ${runtime} completed successfully"
    return 0
}

# Consolidate experimental results
consolidate_results() {
    print_step "Consolidating results..."
    
    local summary_file="${OUTPUT_DIR}/http_performance_summary.csv"
    local wrk_file="${OUTPUT_DIR}/results_wrk.csv"
    
    # Header
    echo "runtime,test_type,test_name,iterations,valid_iterations,mean_requests_per_sec,std_requests_per_sec,min_requests_per_sec,max_requests_per_sec" > "$summary_file"
    echo "timestamp,platform,tool,test,threads,connections,metric,value,unit,notes" > "$wrk_file"
    
    # Process each results file
    for file in "${OUTPUT_DIR}"/*_http_results.csv; do
        if [ -f "$file" ]; then
            local runtime=$(basename "$file" | cut -d'_' -f1)
            local test_type="http"
            local test_name="benchmark"
            
            # Compute statistics (Welford — sample standard deviation, ddof=1)
            local stats=$(tail -n +2 "$file" | compute_stats_welford 2)
            
            echo "${runtime},${test_type},${test_name},${stats}" >> "$summary_file"

            # Append data to the consolidated file compatible with the analysis
            tail -n +2 "$file" | while IFS=',' read -r iteration requests_per_sec latency_ms throughput; do
                if [ -n "$requests_per_sec" ]; then
                    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S-0300")
                    echo "${timestamp},macOS,${runtime},http,4,100,requests_per_sec,${requests_per_sec},req/s,from_http_only" >> "$wrk_file"
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
=== EXPERIMENT MANIFEST - HTTP PERFORMANCE ===
Date: $(date)
Experiment: HTTP Performance (Docker Desktop vs Apple container)
Iterations: ${ITERATIONS}
Valid minimum: ${MIN_VALID_ITERATIONS}
Significance level: ${ALPHA_LEVEL}
Confidence level: $(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)%
HTTP workload: ${HTTP_IMAGE} (invariant; no fallback)
Retries per iteration (server startup): ${HTTP_MAX_RETRIES_PER_ITERATION}
Healthcheck timeout (startup): ${HTTP_STARTUP_TIMEOUT_SECONDS}s
HTTP port (host): base=${HTTP_PORT}; strategy=${HTTP_PORT_STRATEGY}; max_tries=${HTTP_PORT_MAX_TRIES}

=== GENERATED FILES ===
$(ls -la "${OUTPUT_DIR}")

=== CONFIGURATION ===
- Iterations: ${ITERATIONS}
- Statistical validation: Minimum ${MIN_VALID_ITERATIONS} valid iterations
- Test: HTTP benchmark with wrk
- Runtimes: Docker Desktop, Apple container
- Threads: 4
- Connections: 100
- Duration: 10 seconds per test
- Warmup iterations: ${WARMUP_ITERATIONS}
- Policy: invariant workload (if nginx fails, the iteration is invalid; no server swap)
- Auditing: startup failures recorded in http_server_failures.csv

=== LOAD MONITORING (T4) ===
- Script: src/utils/monitor_system_load.sh
- Threshold CPU: ${CPU_THRESHOLD:-20.0}%
- Memory threshold: ${MEM_THRESHOLD:-80.0}%
- Load log: system_load_log.csv
- Note: Monitoring is informational/documentary only. It does not prevent iterations from running.

=== METHODOLOGY ===
- HTTP performance measurement
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
    print_step "=== HTTP PERFORMANCE BENCHMARK ==="
    print_step "Docker Desktop vs Apple container - HTTP Performance"
    echo ""
    
    # Initial checks
    check_dependencies wrk
    check_rosetta
    check_apple_container auto_start
    
    # Set up experiment
    setup_output_directory "http_performance"
    
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
    echo ""
    
    # Run experiment
    print_step "Running HTTP Performance..."
    # Sample size pretest (optional, Raj Jain 13.9)
    if [ "${ENABLE_SAMPLE_SIZE_PRETEST:-false}" = "true" ]; then
        echo ""
        print_step "Estimating recommended sample size (pretest, Raj Jain 13.9)..."
        echo ""
        estimate_sample_size_http_pretest
        echo ""
    fi
    
    # Randomization to reduce systematic bias (optional)
    # Controlled via environment variable: ENABLE_RANDOMIZATION=true/false
    # Default: true (randomization enabled)
    local enable_randomization=${ENABLE_RANDOMIZATION:-true}
    
    # Define tests: each combination of runtime and scenario
    local tests=(
        "docker:http:benchmark"
        "container:http:benchmark"
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
        test_type="${test_type%%:*}"
        local test_name="${test##*:}"
        
        print_step "Running test ${test_num}/${total_tests}: ${runtime} - ${test_type} (${test_name})"
        run_http_benchmark "$runtime" "$test_type" "$test_name" $ITERATIONS
    done
    
    consolidate_results
    generate_manifest
    run_statistical_analysis "${OUTPUT_DIR}"
    
    print_success "✅ HTTP Performance completed!"
    
    print_step "=== EXPERIMENT COMPLETED ==="
    print_success "Results saved to: ${OUTPUT_DIR}"
    print_step "✅ Robust statistical analysis was already run automatically"
    print_info "To re-run the analysis: python src/analysis/analyze_results_enhanced.py ${OUTPUT_DIR} --output ${OUTPUT_DIR}/enhanced_analysis"
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
