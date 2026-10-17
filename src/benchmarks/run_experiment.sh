#!/usr/bin/env bash

# =============================================================================
# EXPERIMENT ORCHESTRATOR
# =============================================================================
#
# DESCRIPTION:
#   Orchestrator script for running benchmark experiments comparing
#   Docker Desktop and Apple container. Coordinates the execution of multiple
#   individual benchmarks following a rigorous methodology based on Raj Jain.
#
# FEATURES:
#   - Coordinates execution of individual benchmarks
#   - Validates experimental settings
#   - Ensures methodological consistency
#   - Consolidates results for analysis
#   - Supports running full or individual experiments
#
# PARAMETERS (Environment Variables):
#
#   Parameters Common to All Benchmarks:
#   ITERATIONS_OVERRIDE
#       Number of main iterations per benchmark.
#       Default: 30
#       Example: ITERATIONS_OVERRIDE=10 ./run_experiment.sh
#
#   WARMUP_ITERATIONS_OVERRIDE
#       Number of warmup iterations (discarded).
#       Default: 5
#       Example: WARMUP_ITERATIONS_OVERRIDE=0 ./run_experiment.sh
#
#   MIN_VALID_OVERRIDE
#       Minimum number of valid iterations required.
#       Default: 30
#       Example: MIN_VALID_OVERRIDE=25 ./run_experiment.sh
#
#   CONFIDENCE_LEVEL
#       Desired confidence level (0.90, 0.95, 0.99).
#       Default: 0.95 (95%)
#       Example: CONFIDENCE_LEVEL=0.99 ./run_experiment.sh
#
#   ENABLE_RANDOMIZATION
#       Enables randomization of the runtime execution order.
#       Default: true
#       Values: true, false
#       Example: ENABLE_RANDOMIZATION=false ./run_experiment.sh
#
# DEPENDENCIES:
#   - Docker Desktop installed and running
#   - Apple container installed and running
#   - Individual benchmark scripts in src/benchmarks/
#   - Python 3 with an active virtual environment
#   - Analysis scripts in src/analysis/
#
# OUTPUT:
#   Results saved to: bench_results/<experiment_name>/
#   Each benchmark generates its own directory with detailed results.
#
# METHODOLOGY:
#   Based on Raj Jain - The Art of Computer Systems Performance Analysis:
#   - Warmup iterations for stabilization
#   - Multiple replications (n >= 30 for 95% confidence)
#   - Randomization to reduce bias
#   - Data validation and descriptive statistics
#   - Robust statistical analysis
#
# AUTHOR: Alessandra Pereira
# VERSION: 4.0
# DATE: 2025-11-29
# =============================================================================

set -euo pipefail

# Script directory (src/benchmarks)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# LOGGING (terminal output saved to logs/)
# =============================================================================
# On the first run, re-executes the script with tee to record all output
# in logs/experiment_YYYYMMDD-HHMMSS.log. On exit (option 16 or Ctrl+C),
# tee finalizes the file normally.
if [ -z "${EXPERIMENT_LOG_ACTIVE:-}" ]; then
    PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    LOG_DIR="${PROJECT_ROOT}/logs"
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/experiment_$(date +%Y%m%d-%H%M%S).log"
    export EXPERIMENT_LOG_FILE="$LOG_FILE"
    export EXPERIMENT_LOG_ACTIVE=1
    exec bash -c '"$0" "$@" 2>&1 | tee "$EXPERIMENT_LOG_FILE"' "$0" "$@"
fi

# Load common output functions and statistical utilities
source "${SCRIPT_DIR}/../utils/common_output.sh"
source "${SCRIPT_DIR}/../utils/statistical_utils.sh"

# Enable tag style for benchmarks (default: [SUCCESS], [INFO], etc.)
enable_tag_output
# Export so child scripts inherit the style
export OUTPUT_STYLE="tag"

# =============================================================================
# EXPERIMENTAL SETTINGS
# =============================================================================
# Default values for full experiments (for reference)
# NOTE: These values are for reference/display only. The individual scripts
#       use their own defaults when not passed via environment variables.
DEFAULT_FIO_SIZE_MB=1024
DEFAULT_STREAM_ARRAY_SIZE_MB=1024
# Default PI_DIGITS in run_math_performance.sh is 10,000 (10 thousand)
# For quick validation, 10 digits are used
# Experimental settings (support override via environment)
ITERATIONS=${ITERATIONS_OVERRIDE:-30}  # Minimum for statistical rigor
WARMUP_ITERATIONS=${WARMUP_ITERATIONS_OVERRIDE:-5}  # Warmup iterations (default: 5, can be overridden including 0)
MIN_VALID_ITERATIONS=${MIN_VALID_OVERRIDE:-30} # Minimum valid iterations for analysis (30 main after warmup)
CONFIDENCE_LEVEL=${CONFIDENCE_LEVEL:-0.95}  # Default: 95% (0.95)
ALPHA_LEVEL=0.05       # Significance level

# Compute the recommended minimum sample size for the specified confidence level
MIN_SAMPLE_SIZE_RECOMMENDED=$(calculate_min_sample_size "$CONFIDENCE_LEVEL")

# Check whether the number of iterations meets the recommended minimum
if [ "$ITERATIONS" -lt "$MIN_SAMPLE_SIZE_RECOMMENDED" ]; then
    conf_pct=$(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)
    print_important "Number of iterations (${ITERATIONS}) is below the recommended minimum (${MIN_SAMPLE_SIZE_RECOMMENDED}) for ${conf_pct}% confidence"
    print_detail "The statistical community traditionally uses a sample size of n≥30 to ensure better robustness of the analysis"
fi

# Export variables to child scripts (to allow override)
export WARMUP_ITERATIONS_OVERRIDE=${WARMUP_ITERATIONS_OVERRIDE:-5}
export ITERATIONS_OVERRIDE=${ITERATIONS_OVERRIDE:-30}
export MIN_VALID_OVERRIDE=${MIN_VALID_OVERRIDE:-30}
export CONFIDENCE_LEVEL=${CONFIDENCE_LEVEL:-0.95}
export ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true}
export RANDOMIZATION_SEED=${RANDOMIZATION_SEED:-}

# Standardized pauses between iterations (in seconds)
PAUSE_STARTUP=2        # Startup: 1-2s (using 2s)
PAUSE_CPU_MEMORY=2     # CPU/Memory: 2s default
PAUSE_HTTP=4           # HTTP: 3-5s (using 4s as the midpoint)
PAUSE_DISK=3           # Disk I/O: 3s default (disk I/O requires more time)
PAUSE_STREAM=2         # STREAM: 2s default
PAUSE_MATH=2           # Math: 2s default

# Check experimental dependencies
check_dependencies() {
    print_step "Checking dependencies..."
    
    # Check whether python is available
    if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
        print_error "Python not found. Install Python first."
        exit 1
    fi
    
    # Use python3 if available, otherwise python
    local python_cmd="python3"
    if ! command -v python3 >/dev/null 2>&1; then
        python_cmd="python"
    fi
    
    # Check whether pip is available
    if ! command -v pip3 >/dev/null 2>&1 && ! command -v pip >/dev/null 2>&1; then
        print_error "pip not found. Install pip first."
        exit 1
    fi
    
    # Use pip3 if available, otherwise pip
    local pip_cmd="pip3"
    if ! command -v pip3 >/dev/null 2>&1; then
        pip_cmd="pip"
    fi
    
    # Check virtual environment (optional - informational only)
    # The individual benchmark scripts automatically detect the venv
    if [[ -n "${VIRTUAL_ENV:-}" ]]; then
        print_success "Virtual environment detected: $VIRTUAL_ENV"
        print_detail "The benchmark scripts will use this environment for statistical analysis"
    else
        print_info "Virtual environment not detected"
        print_detail "The benchmark scripts will try to automatically detect the project venv"
        print_detail "If needed, activate it manually: source venv/bin/activate"
    fi
    
    # Check Python modules required for statistical analysis
    # Note: This check is optional, since the individual scripts also do it
    local required_deps=("matplotlib" "seaborn" "scipy" "pandas" "numpy" "statsmodels")
    local missing=()
    
    # Try to detect the venv Python first
    local venv_python=""
    local project_root="${SCRIPT_DIR}/../.."
    if [ -f "${project_root}/venv/bin/python" ]; then
        venv_python="${project_root}/venv/bin/python"
    elif [ -f "${project_root}/venv/bin/python3" ]; then
        venv_python="${project_root}/venv/bin/python3"
    fi
    
    # Use venv Python if available, otherwise use the system one
    local check_python="${venv_python:-$python_cmd}"
    
    for dep in "${required_deps[@]}"; do
        if ! $check_python -c "import $dep" 2>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_important "Some Python dependencies may be missing: ${missing[*]}"
        print_detail "The benchmark scripts will check and install them automatically if needed"
        print_detail "Or install manually: ${pip_cmd} install ${missing[*]}"
    else
        print_success "Python dependencies verified"
    fi
    
    print_success "Basic dependencies verified"
}

# Check Docker context (must be local for valid experiments)
# Uses the dedicated script to avoid code duplication
check_docker_context() {
    local check_script="${SCRIPT_DIR}/../utils/check_docker_context.sh"
    
    if [ -f "$check_script" ]; then
        # Run script in automatic mode (changes context if needed)
        if bash "$check_script" --auto; then
            return 0
        else
            exit 1
        fi
    else
        print_critical "Docker context check script not found: $check_script"
        exit 1
    fi
}

# Check Rosetta with methodological rigor
check_rosetta() {
    print_step "Rigorous verification of the experimental environment..."
    
    # Use verification script if available
    local rosetta_script="${SCRIPT_DIR}/../utils/check_rosetta.sh"
    if [[ -f "$rosetta_script" ]]; then
        print_info "Running detailed Rosetta verification..."
        if bash "$rosetta_script"; then
            print_success "System verified - Docker working correctly"
        else
            print_critical "Problem detected with Docker/Rosetta"
            print_info_plain "For methodological rigor, the environment must be controlled"
            print_detail "Run '$rosetta_script' for more details"
            print_detail "Configure Docker Desktop and run again"
            exit 1
        fi
    else
        # Basic check if the script is not available
        if ! command -v arch &>/dev/null; then
            print_warning "Command 'arch' not found — Rosetta check skipped"
        elif arch -x86_64 /usr/bin/true 2>/dev/null; then
            print_important "Rosetta is ACTIVE"
            print_info "Checking whether Docker is using native ARM64..."

            if docker version >/dev/null 2>&1; then
                local docker_arch=$(docker version --format '{{.Server.Arch}}' 2>/dev/null)
                if [[ "$docker_arch" == "arm64" ]]; then
                    print_success "Docker using native ARM64 (ideal for benchmarking)"
                else
                    print_error "Docker using emulation - compromises results"
                    print_info_plain "For methodological rigor, Docker must use native ARM64"
                    exit 1
                fi
            fi
        else
            print_success "Rosetta inactive - ideal environment"
        fi
    fi
}

# Check Apple container
check_apple_container() {
    print_step "Checking Apple container..."
    
    if ! command -v container >/dev/null 2>&1; then
        print_critical "Apple container not found"
        print_detail "Install Apple container for a valid comparison"
        exit 1
    fi
    
    # Check whether the service is running
    if ! container system status >/dev/null 2>&1; then
        print_info "Starting the Apple container service..."
        print_detail "Running: container system start"
        container system start
        sleep 3
    fi
    
    # Functional test with timeout to avoid hanging
    print_info "Testing Apple container functionality (timeout: 30s)..."
    local test_pid=""
    local test_result=""
    
    # Run test in the background with timeout (with standardized resources)
    (container run --rm --cpus="${CONTAINER_STANDARD_CPUS:-12}" --memory="${CONTAINER_STANDARD_MEMORY:-8G}" alpine:3.24 echo "test" >/tmp/container_test.out 2>&1) &
    test_pid=$!
    
    # Wait up to 30 seconds
    local count=0
    while [ $count -lt 30 ]; do
        if ! kill -0 $test_pid 2>/dev/null; then
            # Process finished
            wait $test_pid 2>/dev/null
            test_result=$(cat /tmp/container_test.out 2>/dev/null || echo "")
            rm -f /tmp/container_test.out 2>/dev/null
            break
        fi
        sleep 1
        count=$((count + 1))
    done
    
    # If still running after 30s, kill the process
    if kill -0 $test_pid 2>/dev/null; then
        kill $test_pid 2>/dev/null
        wait $test_pid 2>/dev/null
        rm -f /tmp/container_test.out 2>/dev/null
        test_result="TIMEOUT"
    fi
    
    if [ "$test_result" = "TIMEOUT" ]; then
        print_warning "Apple container did not respond within 30 seconds"
        print_detail "The container may be stuck or the alpine:3.24 image may not be available"
        print_detail "Try: container system stop && container system start"
        print_info "Continuing anyway (may fail during the benchmarks)..."
    elif [ -n "$test_result" ] && echo "$test_result" | grep -q "test"; then
        print_success "Apple container working correctly"
    elif [ -z "$test_result" ]; then
        print_success "Apple container working correctly"
    else
        print_warning "Apple container returned an unexpected result"
        print_detail "Result: ${test_result:0:100}"
        print_info "Continuing anyway..."
    fi
}

# Function to consolidate results with methodological rigor
consolidate_results() {
    print_step "Consolidating results for statistical analysis..."
    
    # Consolidate main results
    cat > "${OUTPUT_DIR}/results_main.csv" << EOF
timestamp,platform,tool,scenario,metric,value,unit,notes
EOF
    
    for file in "${OUTPUT_DIR}"/*_startup_warm_results.csv "${OUTPUT_DIR}"/*_pull_results.csv; do
        if [ -f "$file" ] && [ -s "$file" ] && [ $(wc -l < "$file") -gt 1 ]; then
            local tool=$(basename "$file" | cut -d'_' -f1)
            local scenario=$(basename "$file" | cut -d'_' -f2)
            
            # Skip header and process each line
            tail -n +2 "$file" | while IFS=',' read -r iteration timestamp value unit notes; do
                echo "${timestamp},macOS,${tool},${scenario},mean,${value},${unit},${notes}" >> "${OUTPUT_DIR}/results_main.csv"
            done
        fi
    done
    
    # Consolidate sysbench results
    cat > "${OUTPUT_DIR}/results_sysbench.csv" << EOF
timestamp,platform,tool,test,threads,metric,value,unit,notes
EOF
    
    for file in "${OUTPUT_DIR}"/*_sysbench_*.csv; do
        if [ -f "$file" ] && [ -s "$file" ] && [ $(wc -l < "$file") -gt 1 ]; then
            local tool=$(basename "$file" | cut -d'_' -f1)
            local test_type=$(basename "$file" | cut -d'_' -f3)
            local threads=$(basename "$file" | cut -d'_' -f4 | cut -d'.' -f1)
            
            # Skip header and process each line
            tail -n +2 "$file" | while IFS=',' read -r iteration timestamp test threads metric value unit notes; do
                echo "${timestamp},macOS,${tool},${test_type},${threads},${metric},${value},${unit},${notes}" >> "${OUTPUT_DIR}/results_sysbench.csv"
            done
        fi
    done
    
    # Consolidate HTTP results
    cat > "${OUTPUT_DIR}/results_wrk.csv" << EOF
timestamp,platform,tool,url,metric,value,unit,notes
EOF
    
    for file in "${OUTPUT_DIR}"/*_http_results.csv; do
        if [ -f "$file" ] && [ -s "$file" ] && [ $(wc -l < "$file") -gt 1 ]; then
            local tool=$(basename "$file" | cut -d'_' -f1)
            
            # Skip header and process each line
            tail -n +2 "$file" | while IFS=',' read -r iteration timestamp url metric value unit notes; do
                echo "${timestamp},macOS,${tool},${url},${metric},${value},${unit},${notes}" >> "${OUTPUT_DIR}/results_wrk.csv"
            done
        fi
    done
    
    print_success "Results consolidated for statistical analysis"
}

# Function to capture image digests
get_image_digest() {
    local tool=$1
    local image=$2
    local digest="N/A"
    
    if [ "$tool" = "docker" ]; then
        digest=$(docker image inspect "$image" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "N/A")
    else
        digest=$(container image inspect "$image" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "N/A")
    fi
    
    echo "$digest"
}

# Function to generate experimental manifest
generate_manifest() {
    # Capture actual versions
    local docker_ver=$(docker --version 2>/dev/null || echo "N/A")
    local container_ver=$(container --version 2>/dev/null || echo "N/A")
    local python_ver=$(python3 --version 2>/dev/null || python --version 2>/dev/null || echo "N/A")
    local sysbench_ver=$(sysbench --version 2>/dev/null | head -1 || echo "N/A")
    local wrk_ver=$(wrk --version 2>/dev/null || echo "N/A")
    
    # Capture image digests
    local nginx_digest_docker=$(get_image_digest "docker" "nginx:1.30.6")
    local nginx_digest_container=$(get_image_digest "container" "nginx:1.30.6")
    local alpine_digest_docker=$(get_image_digest "docker" "alpine:3.24")
    local alpine_digest_container=$(get_image_digest "container" "alpine:3.24")
    
    # Capture hardware information
    local cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "N/A")
    local mem_total=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.2f GB", $1/1024/1024/1024}' || echo "N/A")
    local disk_info=$(df -h / | tail -1 | awk '{print $2 " total, " $4 " available"}' || echo "N/A")
    
    local conf_pct=$(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)
    
    cat > "${OUTPUT_DIR}/manifest.txt" << EOF
=== EXPERIMENT MANIFEST ===
Name: ${EXPERIMENT_NAME}
Date: $(date)
Version: Experiment Orchestrator v4.0
Platform: macOS $(sw_vers -productVersion)
Architecture: $(uname -m)
Kernel: $(uname -r)

=== HARDWARE ===
CPU: ${cpu_model}
Total Memory: ${mem_total}
Disk: ${disk_info}

=== SOFTWARE - VERSIONS ===
Docker: ${docker_ver}
Apple container: ${container_ver}
Python: ${python_ver}
sysbench: ${sysbench_ver}
wrk: ${wrk_ver}

=== IMAGES USED ===
nginx:1.30.6 (Docker):
  Digest: ${nginx_digest_docker}
nginx:1.30.6 (Apple container):
  Digest: ${nginx_digest_container}
alpine:3.24 (Docker):
  Digest: ${alpine_digest_docker}
alpine:3.24 (Apple container):
  Digest: ${alpine_digest_container}

=== STATISTICAL SETTINGS ===
Iterations per scenario: ${ITERATIONS}
Warmup iterations: ${WARMUP_ITERATIONS}
Minimum valid iterations: ${MIN_VALID_ITERATIONS}
Confidence level: ${conf_pct}% (${CONFIDENCE_LEVEL})
Recommended minimum size (Raj Jain, Ch. 13): ${MIN_SAMPLE_SIZE_RECOMMENDED}
Significance level (α): ${ALPHA_LEVEL}
Randomization: ${ENABLE_RANDOMIZATION:-true}

=== STATISTICAL METHODOLOGY ===
Multiple-comparison corrections: Bonferroni, FDR
Statistical tests: Student's t, Welch, Mann-Whitney U
Power analysis: Yes
Effect size: Cohen's d
Confidence intervals: ${conf_pct}%

=== EXPERIMENTAL OBJECTIVE ===
Run a Docker Desktop vs Apple container benchmark with methodological
rigor suitable for academic publication, ensuring:
- Sample size adequate for statistical power
- Appropriate statistical tests
- Corrections for multiple comparisons
- Effect size analysis
- Confidence intervals
- Full data transparency
- Randomization to reduce bias

=== METHODOLOGY ===
- Multiple iterations per scenario (${ITERATIONS})
- Warmup iterations for stabilization (${WARMUP_ITERATIONS})
- Randomization of the runtime execution order
- Robust statistical tests
- Corrections for multiple comparisons
- Statistical power analysis
- Confidence intervals
- Complete documentation

=== GENERATED FILES ===
- results_main.csv: Main results (startup, pull)
- results_sysbench.csv: CPU/Memory results
- results_wrk.csv: HTTP results
- *_results.csv: Individual results per tool/scenario
- enhanced_analysis_report.txt: Robust statistical report
- enhanced_startup_analysis.png: Detailed visual analysis
- statistical_analysis_dashboard.png: Statistical dashboard

=== METHODOLOGICAL STANDARDS ===
- Methodological rigor suitable for academic publication
- Scientific validation with multiple-comparison corrections
- Full transparency of data and methods
- Replicability for other researchers
- Baseado em Raj Jain - The Art of Computer Systems Performance Analysis
EOF
}

# Function to run robust statistical analysis
run_statistical_analysis() {
    # Build paths relative to the script directory
    local analysis_script="${SCRIPT_DIR}/../analysis/analyze_results_enhanced.py"
    local project_root="${SCRIPT_DIR}/../.."
    local analysis_script_from_root="${project_root}/src/analysis/analyze_results_enhanced.py"
    
    # Detect Python: prefer venv, then python3, then python
    local python_cmd=""
    local venv_python="${project_root}/venv/bin/python"
    local venv_python3="${project_root}/venv/bin/python3"
    
    if [ -f "$venv_python" ]; then
        python_cmd="$venv_python"
    elif [ -f "$venv_python3" ]; then
        python_cmd="$venv_python3"
    elif command -v python3 &> /dev/null; then
        python_cmd="python3"
    elif command -v python &> /dev/null; then
        python_cmd="python"
    else
        print_warning "Python not found. Activate the venv or install Python."
        print_detail "To activate the venv: source ${project_root}/venv/bin/activate"
        return 1
    fi
    
    # Try different possible paths for the analysis script
    # Use quiet mode for compact output
    local script_found=false
    local script_path=""
    
    if [ -f "$analysis_script" ]; then
        script_found=true
        script_path="$analysis_script"
    elif [ -f "$analysis_script_from_root" ]; then
        script_found=true
        script_path="$analysis_script_from_root"
    elif [ -f "src/analysis/analyze_results_enhanced.py" ]; then
        script_found=true
        script_path="src/analysis/analyze_results_enhanced.py"
    fi
    
    if [ "$script_found" = true ]; then
        # Run in quiet mode (compact output)
        print_step "Running statistical analysis..."
        ANALYSIS_QUIET=1 $python_cmd "$script_path" "${OUTPUT_DIR}" --output "${OUTPUT_DIR}/enhanced_analysis" --quiet 2>&1
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            # Success - the Python script already prints a message in quiet mode
            :
        else
            print_warning "Error running statistical analysis"
            print_detail "Check that the venv is active and the dependencies are installed"
        fi
    else
        print_warning "Robust analysis script not found"
        print_detail "Run manually:"
        print_detail "${python_cmd:-python} src/analysis/analyze_results_enhanced.py ${OUTPUT_DIR} --output ${OUTPUT_DIR}/enhanced_analysis"
    fi
}

# Function to display the experiment configuration
print_experiment_config() {
    local conf_pct=$(echo "$CONFIDENCE_LEVEL * 100" | bc -l | cut -d'.' -f1)
    
    echo ""
    print_step "Experiment configuration:"
    print_info "Name: ${EXPERIMENT_NAME}"
    print_info "Iterations: ${ITERATIONS}"
    print_info "Warmup iterations: ${WARMUP_ITERATIONS}"
    print_info "Minimum valid: ${MIN_VALID_ITERATIONS}"
    print_info "Confidence level: ${conf_pct}%"
    print_info "Recommended minimum size (Raj Jain): ${MIN_SAMPLE_SIZE_RECOMMENDED}"
    print_info "Significance level (α): ${ALPHA_LEVEL}"
    print_info "Randomization: ${ENABLE_RANDOMIZATION:-true}"
    echo ""
}

# Function to display the validation test configuration
# Receives the validation constants as parameters
print_validation_config() {
    local val_iterations=$1
    local val_warmup=$2
    local val_fio_size=$3
    local val_stream_size=$4
    local val_pi_digits=$5
    local val_pause=$6
    
    echo ""
    print_step "Validation test configuration:"
    print_info "Iterations: ${val_iterations} (per combination)"
    print_info "Warmup: ${val_warmup}$([ "${val_warmup}" -eq 0 ] && echo " (disabled)" || echo " iterations")"
    print_info "Disk: FIO_SIZE_MB=${val_fio_size} (default: ${DEFAULT_FIO_SIZE_MB}MB)"
    print_info "STREAM: STREAM_ARRAY_SIZE_MB=${val_stream_size} (default: ${DEFAULT_STREAM_ARRAY_SIZE_MB}MB)"
    print_info "Math: PI_DIGITS=${val_pi_digits} (default in full experiments: 10,000)"
    print_info "Pauses reduced to the minimum ${val_pause}s"
    print_important "Note: Statistical analysis was run, but results should be interpreted with caution (n=${val_iterations} < 30)"
    echo ""
}

# Main menu with methodological rigor
show_menu() {
    echo ""
    print_step "=== EXPERIMENT MENU ==="
    echo ""
    echo "📊 FULL EXPERIMENTS:"
    echo "  1. 🔬 Full Experiment - ALL benchmarks (${ITERATIONS} iterations, warmup: ${WARMUP_ITERATIONS})"
    echo "     └─ Startup, CPU, Memory, HTTP, Disk I/O, STREAM, Math"
    echo ""
    echo "🔬 INDIVIDUAL BENCHMARKS:"
    echo "  2. 🚀 Startup Performance (${ITERATIONS} iterations, warmup: ${WARMUP_ITERATIONS})"
    echo "  3. 💻 CPU Performance (${ITERATIONS} iterations, 1-2 threads, warmup: ${WARMUP_ITERATIONS})"
    echo "  4. 🧠 Memory Performance (${ITERATIONS} iterations, 1-2 threads, warmup: ${WARMUP_ITERATIONS})"
    echo "  5. 🌐 HTTP Performance (${ITERATIONS} iterations, warmup: ${WARMUP_ITERATIONS})"
    echo "  6. 💾 Disk I/O Performance (${ITERATIONS} iterations, warmup: ${WARMUP_ITERATIONS})"
    echo "  7. 📊 STREAM Memory Bandwidth (${ITERATIONS} iterations, warmup: ${WARMUP_ITERATIONS})"
    echo "  8. 🧮 Math Computation Performance (${ITERATIONS} iterations, warmup: ${WARMUP_ITERATIONS})"
    echo ""
    echo "🛠️  UTILITIES:"
    echo "  9. 📊 Re-analyze Existing Results"
    echo "  10. 🧪 Quick Validation Test (2 iterations + statistical analysis)"
    echo ""
    echo "📋 SYSTEM INFORMATION:"
    echo "  11. ✅ Full Requirements Check"
    echo "      └─ Checks that everything is ready to run experiments (~5s)"
    echo ""
    echo "  12. 📋 System Information (Quick Summary)"
    echo "      └─ Shows summarized information in the terminal (~2s)"
    echo ""
    echo "  13. 📚 Collect System Information (Full Documentation)"
    echo "      └─ Saves detailed information in markdown (~30s)"
    echo "      ⚠️  Leaves docker_configuration.md incomplete (use option 14 afterwards)"
    echo ""
    echo "  14. 🐳 Document Docker Desktop Resources"
    echo "      └─ Completes docker_configuration.md with CPUs, Memory, etc. (interactive)"
    echo "      💡 Recommended after running option 13"
    echo ""
    echo "  15. 🧹 Environment Reset (stop/remove containers; prepare a new round)"
    echo "      └─ Docker: stop/rm containers; Apple container: stop/delete --all"
    echo "      ⚠️  May affect containers outside the experiment"
    echo ""
    echo "  16. ❌ Exit"
    echo ""
    echo ""
    print_info "💡 Tip: For methodological rigor, option 1 (Full Experiment) is recommended"
    echo ""
    print_info "📖 About options 11-14 (recommended order):"
    print_detail "• Option 11: Full validation (check that everything is ready)"
    print_detail "• Option 12: Quick view (debug/quick check - optional)"
    print_detail "• Option 13: Full documentation in markdown"
    print_detail "  └─ ⚠️  Leaves docker_configuration.md incomplete - run option 14 afterwards"
    print_detail "• Option 14: Completes docker_configuration.md with Docker Desktop resources"
    print_detail "  └─ 💡 Recommended after running option 13"
    echo ""
}

# Function to display the verification summary
print_verification_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_step "✅ Checks Completed - System Ready"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    local all_ok=true
    
    # Check dependencies
    if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
        print_success "Python available"
    else
        print_error "Python not found"
        all_ok=false
    fi
    
    # Check Docker
    if docker info &> /dev/null; then
        local docker_context=$(docker context show 2>/dev/null || echo "unknown")
        local docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo "N/A")
        if [ "$docker_context" = "desktop-linux" ]; then
            print_success "Docker: running (v${docker_version}, context: ${docker_context})"
        else
            print_warning "Docker: running (v${docker_version}, context: ${docker_context})"
            print_detail "Recommended: context 'desktop-linux'"
        fi
    else
        print_error "Docker is not running"
        all_ok=false
    fi
    
    # Check Apple container
    if command -v container >/dev/null 2>&1; then
        local container_version=$(container --version 2>&1 | head -1 | grep -oE 'version [0-9.]+' | cut -d' ' -f2 || echo "N/A")
        if container system status >/dev/null 2>&1; then
            print_success "Apple container: running (v${container_version})"
        else
            print_warning "Apple container: installed (v${container_version}) but not running"
            print_detail "Run: container system start"
        fi
    else
        print_error "Apple container not found"
        all_ok=false
    fi
    
    echo ""
    if [ "$all_ok" = true ]; then
        print_success "All prerequisites are ready to run experiments"
    else
        print_warning "Some prerequisites need attention before running experiments"
    fi
    echo ""
}

# Main function
main() {
    # Improved visual header
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                        ║"
    echo "║          🔬 DOCKER DESKTOP VS APPLE CONTAINER EXPERIMENT              ║"
    echo "║          Experiment Orchestrator v4.0                                 ║"
    echo "║                                                                        ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Mark experiment start (to compute the time window at the end)
    local experiment_start_ts
    experiment_start_ts=$(date +%s)
    
    # Initial checks (order matters: Docker context first)
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_step "Checking System Prerequisites"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    echo "📦 1. DEPENDENCIES"
    echo "──────────────────────────────────────────────────────────────────────────"
    check_dependencies
    echo ""
    
    echo "🐳 2. DOCKER"
    echo "──────────────────────────────────────────────────────────────────────────"
    check_docker_context
    echo ""
    
    echo "🔬 3. EXPERIMENTAL ENVIRONMENT (Rosetta/ARM64)"
    echo "──────────────────────────────────────────────────────────────────────────"
    check_rosetta
    echo ""
    
    echo "🍎 4. APPLE CONTAINER"
    echo "──────────────────────────────────────────────────────────────────────────"
    check_apple_container
    echo ""
    
    # Show final summary before the menu
    print_verification_summary
    
    # Interactive menu
    while true; do
        show_menu
        read -p "Choose an option (1-16): " choice
        
        case $choice in
            1)
                # Set up full experiment (option 1 only)
                EXPERIMENT_NAME="experiment_$(date +%Y%m%d-%H%M%S)"
                OUTPUT_DIR="bench_results/${EXPERIMENT_NAME}"
                
                print_step "Running full experiment with methodological rigor..."
                print_experiment_config
                mkdir -p "${OUTPUT_DIR}"
                # Record status per benchmark (so the others are not lost on an isolated failure)
                local status_file="${OUTPUT_DIR}/experiment_status.txt"
                {
                    echo "=== FULL EXPERIMENT STATUS ==="
                    echo "Date: $(date)"
                    echo "Directory: ${OUTPUT_DIR}"
                    echo "Note: each benchmark generates its own directory in bench_results/"
                    echo ""
                } > "$status_file"
                
                # METHODOLOGICAL RIGOR: Use individual scripts that implement randomization
                # This ensures the test order within each benchmark is randomized
                
                # Startup Performance
                print_progress 0 7
                print_benchmark_header 1 7 "STARTUP PERFORMANCE"
                if PAUSE_STARTUP_OVERRIDE=$PAUSE_STARTUP \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_startup_performance.sh"; then
                    echo "$(date) - STARTUP: OK" >> "$status_file"
                else
                    print_warning "Startup Performance failed. Continuing experiment..."
                    echo "$(date) - STARTUP: FAIL" >> "$status_file"
                fi

                # CPU Performance
                print_progress 1 7
                print_benchmark_header 2 7 "CPU PERFORMANCE"
                if PAUSE_CPU_MEMORY_OVERRIDE=$PAUSE_CPU_MEMORY \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_cpu_performance.sh"; then
                    echo "$(date) - CPU: OK" >> "$status_file"
                else
                    print_warning "CPU Performance failed. Continuing experiment..."
                    echo "$(date) - CPU: FAIL" >> "$status_file"
                fi

                # Memory Performance
                print_progress 2 7
                print_benchmark_header 3 7 "MEMORY PERFORMANCE"
                if PAUSE_CPU_MEMORY_OVERRIDE=$PAUSE_CPU_MEMORY \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_memory_performance.sh"; then
                    echo "$(date) - MEMORY: OK" >> "$status_file"
                else
                    print_warning "Memory Performance failed. Continuing experiment..."
                    echo "$(date) - MEMORY: FAIL" >> "$status_file"
                fi

                # HTTP Performance
                print_progress 3 7
                print_benchmark_header 4 7 "HTTP PERFORMANCE"
                if PAUSE_HTTP_OVERRIDE=$PAUSE_HTTP \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_http_performance.sh"; then
                    echo "$(date) - HTTP: OK" >> "$status_file"
                else
                    # SCIENTIFIC SCREENING: do not replace the workload; if it failed, record it and continue with the other benchmarks
                    print_warning "HTTP Performance failed (invariant workload; no fallback)."
                    print_info "It is recommended to re-run only HTTP later (new run) to obtain valid data."
                    echo "$(date) - HTTP: FAIL (no fallback; rerun recommended)" >> "$status_file"
                fi

                # Disk I/O Performance
                print_progress 4 7
                print_benchmark_header 5 7 "DISK I/O PERFORMANCE"
                if PAUSE_DISK_OVERRIDE=$PAUSE_DISK \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_disk_performance.sh"; then
                    echo "$(date) - DISK: OK" >> "$status_file"
                else
                    print_warning "Disk I/O Performance failed. Continuing experiment..."
                    echo "$(date) - DISK: FAIL" >> "$status_file"
                fi

                # STREAM Memory Bandwidth
                print_progress 5 7
                print_benchmark_header 6 7 "STREAM MEMORY BANDWIDTH"
                if PAUSE_STREAM_OVERRIDE=$PAUSE_STREAM \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_stream_performance.sh"; then
                    echo "$(date) - STREAM: OK" >> "$status_file"
                else
                    print_warning "STREAM Memory Bandwidth failed. Continuing experiment..."
                    echo "$(date) - STREAM: FAIL" >> "$status_file"
                fi

                # Math Computation
                print_progress 6 7
                print_benchmark_header 7 7 "MATH COMPUTATION PERFORMANCE"
                if PAUSE_MATH_OVERRIDE=$PAUSE_MATH \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_math_performance.sh"; then
                    echo "$(date) - MATH: OK" >> "$status_file"
                else
                    print_warning "Math Computation Performance failed. Continuing experiment..."
                    echo "$(date) - MATH: FAIL" >> "$status_file"
                fi
                
                print_progress 7 7
                print_separator
                print_success "Full experiment completed!"
                print_step "All benchmarks were run: Startup, CPU, Memory, HTTP, Disk I/O, STREAM, Math"
                print_step "Each benchmark was run with randomization enabled (internal test order)"
                print_step "Results saved in individual directories inside bench_results/"
                print_info "Status summary saved to: ${status_file}"
                break
                ;;
            2)
                print_step "Running Startup Performance with methodological rigor..."
                # The individual script creates its own directory; no need to create experiment_*

                # Use the individual script, which implements randomization and warmup
                if PAUSE_STARTUP_OVERRIDE=$PAUSE_STARTUP \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_startup_performance.sh"; then
                    print_success "Startup Performance completed with methodological rigor!"
                else
                    print_warning "Startup Performance failed."
                fi
                break
                ;;
            3)
                print_step "Running CPU Performance with methodological rigor..."
                # The individual script creates its own directory; no need to create experiment_*

                # Use the individual script, which implements randomization and warmup
                if PAUSE_CPU_MEMORY_OVERRIDE=$PAUSE_CPU_MEMORY \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_cpu_performance.sh"; then
                    print_success "CPU Performance completed with methodological rigor!"
                else
                    print_warning "CPU Performance failed."
                fi
                break
                ;;
            4)
                print_step "Running Memory Performance with methodological rigor..."
                # The individual script creates its own directory; no need to create experiment_*

                # Use the individual script, which implements randomization and warmup
                if PAUSE_CPU_MEMORY_OVERRIDE=$PAUSE_CPU_MEMORY \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_memory_performance.sh"; then
                    print_success "Memory Performance completed with methodological rigor!"
                else
                    print_warning "Memory Performance failed."
                fi
                break
                ;;
            5)
                print_step "Running HTTP Performance with methodological rigor..."
                # The individual script creates its own directory; no need to create experiment_*

                # Use the individual script, which implements randomization and warmup
                if PAUSE_HTTP_OVERRIDE=$PAUSE_HTTP \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_http_performance.sh"; then
                    print_success "HTTP Performance completed with methodological rigor!"
                else
                    print_warning "HTTP Performance failed."
                fi
                break
                ;;
            6)
                print_step "Running Disk I/O Performance with methodological rigor..."
                # The individual script creates its own directory; no need to create experiment_*

                # Use the individual script, which implements randomization and warmup
                if PAUSE_DISK_OVERRIDE=$PAUSE_DISK \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_disk_performance.sh"; then
                    print_success "Disk I/O Performance completed with methodological rigor!"
                else
                    print_warning "Disk I/O Performance failed."
                fi
                break
                ;;
            7)
                print_step "Running STREAM Memory Bandwidth with methodological rigor..."
                # The individual script creates its own directory; no need to create experiment_*

                # Use the individual script, which implements randomization and warmup
                if PAUSE_STREAM_OVERRIDE=$PAUSE_STREAM \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_stream_performance.sh"; then
                    print_success "STREAM Memory Bandwidth completed with methodological rigor!"
                else
                    print_warning "STREAM Memory Bandwidth failed."
                fi
                break
                ;;
            8)
                print_step "Running Math Computation Performance with methodological rigor..."
                # The individual script creates its own directory; no need to create experiment_*

                # Use the individual script, which implements randomization and warmup
                if PAUSE_MATH_OVERRIDE=$PAUSE_MATH \
                    ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                    bash "$(dirname "$0")/run_math_performance.sh"; then
                    print_success "Math Computation Performance completed with methodological rigor!"
                else
                    print_warning "Math Computation Performance failed."
                fi
                break
                ;;
            9)
                print_step "Re-analyzing existing results..."
                read -p "Enter the results directory: " results_dir
                if [ -d "$results_dir" ]; then
                    OUTPUT_DIR="$results_dir"
                    run_statistical_analysis
                else
                    print_error "Directory not found: $results_dir"
                fi
                ;;
            10)
                # Settings for the Quick Validation Test
                # Reduced values for fast validation runs
                local VALIDATION_ITERATIONS=2
                local VALIDATION_WARMUP=0
                local VALIDATION_FIO_SIZE_MB=10
                local VALIDATION_STREAM_ARRAY_SIZE_MB=10
                local VALIDATION_PI_DIGITS=10
                local VALIDATION_PAUSE_SECONDS=2
                
                print_step "Running Quick Validation Test (${VALIDATION_ITERATIONS} iterations per benchmark)..."
                print_validation_config \
                    "$VALIDATION_ITERATIONS" \
                    "$VALIDATION_WARMUP" \
                    "$VALIDATION_FIO_SIZE_MB" \
                    "$VALIDATION_STREAM_ARRAY_SIZE_MB" \
                    "$VALIDATION_PI_DIGITS" \
                    "$VALIDATION_PAUSE_SECONDS"
                # The individual scripts create their own directories; no need to create experiment_*
                
                # Startup Performance
                print_progress 0 7
                print_benchmark_header 1 7 "STARTUP PERFORMANCE" "validation"
                ITERATIONS_OVERRIDE=$VALIDATION_ITERATIONS \
                WARMUP_ITERATIONS_OVERRIDE=$VALIDATION_WARMUP \
                MIN_VALID_OVERRIDE=$VALIDATION_ITERATIONS \
                PAUSE_STARTUP_OVERRIDE=$VALIDATION_PAUSE_SECONDS \
                ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                VALIDATION_MODE=true \
                bash "$(dirname "$0")/run_startup_performance.sh" || print_warning "Startup Performance: validation error"
                
                # CPU Performance
                print_progress 1 7
                print_benchmark_header 2 7 "CPU PERFORMANCE" "validation"
                ITERATIONS_OVERRIDE=$VALIDATION_ITERATIONS \
                WARMUP_ITERATIONS_OVERRIDE=$VALIDATION_WARMUP \
                MIN_VALID_OVERRIDE=$VALIDATION_ITERATIONS \
                PAUSE_CPU_MEMORY_OVERRIDE=$VALIDATION_PAUSE_SECONDS \
                ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                VALIDATION_MODE=true \
                bash "$(dirname "$0")/run_cpu_performance.sh" || print_warning "CPU Performance: validation error"
                
                # Memory Performance
                print_progress 2 7
                print_benchmark_header 3 7 "MEMORY PERFORMANCE" "validation"
                ITERATIONS_OVERRIDE=$VALIDATION_ITERATIONS \
                WARMUP_ITERATIONS_OVERRIDE=$VALIDATION_WARMUP \
                MIN_VALID_OVERRIDE=$VALIDATION_ITERATIONS \
                PAUSE_CPU_MEMORY_OVERRIDE=$VALIDATION_PAUSE_SECONDS \
                ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                VALIDATION_MODE=true \
                bash "$(dirname "$0")/run_memory_performance.sh" || print_warning "Memory Performance: validation error"
                
                # HTTP Performance
                print_progress 3 7
                print_benchmark_header 4 7 "HTTP PERFORMANCE" "validation"
                ITERATIONS_OVERRIDE=$VALIDATION_ITERATIONS \
                WARMUP_ITERATIONS_OVERRIDE=$VALIDATION_WARMUP \
                MIN_VALID_OVERRIDE=$VALIDATION_ITERATIONS \
                PAUSE_HTTP_OVERRIDE=$VALIDATION_PAUSE_SECONDS \
                ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                VALIDATION_MODE=true \
                bash "$(dirname "$0")/run_http_performance.sh" || print_warning "HTTP Performance: validation error"
                
                # Disk I/O Performance
                print_progress 4 7
                print_benchmark_header 5 7 "DISK I/O PERFORMANCE" "validation"
                ITERATIONS_OVERRIDE=$VALIDATION_ITERATIONS \
                WARMUP_ITERATIONS_OVERRIDE=$VALIDATION_WARMUP \
                MIN_VALID_OVERRIDE=$VALIDATION_ITERATIONS \
                FIO_SIZE_MB=$VALIDATION_FIO_SIZE_MB \
                PAUSE_DISK_OVERRIDE=$VALIDATION_PAUSE_SECONDS \
                ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                VALIDATION_MODE=true \
                bash "$(dirname "$0")/run_disk_performance.sh" || print_warning "Disk I/O Performance: validation error"
                
                # STREAM Memory Bandwidth
                print_progress 5 7
                print_benchmark_header 6 7 "STREAM MEMORY BANDWIDTH" "validation"
                ITERATIONS_OVERRIDE=$VALIDATION_ITERATIONS \
                WARMUP_ITERATIONS_OVERRIDE=$VALIDATION_WARMUP \
                MIN_VALID_OVERRIDE=$VALIDATION_ITERATIONS \
                STREAM_ARRAY_SIZE_MB=$VALIDATION_STREAM_ARRAY_SIZE_MB \
                PAUSE_STREAM_OVERRIDE=$VALIDATION_PAUSE_SECONDS \
                ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                VALIDATION_MODE=true \
                bash "$(dirname "$0")/run_stream_performance.sh" || print_warning "STREAM Memory Bandwidth: validation error"
                
                # Math Computation Performance
                print_progress 6 7
                print_benchmark_header 7 7 "MATH COMPUTATION PERFORMANCE" "validation"
                ITERATIONS_OVERRIDE=$VALIDATION_ITERATIONS \
                WARMUP_ITERATIONS_OVERRIDE=$VALIDATION_WARMUP \
                MIN_VALID_OVERRIDE=$VALIDATION_ITERATIONS \
                PI_DIGITS=$VALIDATION_PI_DIGITS \
                PAUSE_MATH_OVERRIDE=$VALIDATION_PAUSE_SECONDS \
                ENABLE_RANDOMIZATION=${ENABLE_RANDOMIZATION:-true} \
                VALIDATION_MODE=true \
                bash "$(dirname "$0")/run_math_performance.sh" || print_warning "Math Computation Performance: validation error"
                
                print_progress 7 7
                print_separator
                print_success "Validation test completed!"
                print_info "All 7 benchmarks were validated with minimal parameters"
                print_info "Results saved in individual directories inside bench_results/"
                break
                ;;
            11)
                # Run full requirements check
                bash "${SCRIPT_DIR}/../utils/verify_experiment_requirements.sh"
                ;;
            12)
                # Use the dedicated script to show system information
                bash "${SCRIPT_DIR}/../utils/show_system_info.sh"
                ;;
            13)
                # Collect system information (full documentation)
                print_step "Collecting detailed system information..."
                print_info "This may take a few seconds..."
                print_detail "Files will be saved to: docs/system_info/"
                echo ""
                if bash "${SCRIPT_DIR}/../utils/collect_system_info.sh"; then
                    print_success "System information collected successfully!"
                    print_detail "Files saved to: docs/system_info/"
                    print_info "💡 Tip: Run option 14 to complete the Docker Desktop documentation"
                else
                    print_warning "There was a problem collecting system information"
                    print_detail "Check that Docker and Apple container are running"
                fi
                ;;
            14)
                # Document Docker Desktop resources
                print_step "Documenting Docker Desktop Resources..."
                print_info "This script will collect information about:"
                print_detail "• Allocated CPUs"
                print_detail "• Allocated memory (GB)"
                print_detail "• Allocated disk (GB)"
                print_detail "• Virtual Machine Manager (VMM)"
                print_detail "• Rosetta (enabled/disabled)"
                print_detail "• Containerd (enabled/disabled)"
                echo ""
                if bash "${SCRIPT_DIR}/../utils/document_docker_resources.sh"; then
                    print_success "Docker Desktop resources documented successfully!"
                    print_detail "File updated: docs/system_info/docker_configuration.md"
                else
                    print_warning "There was a problem documenting the resources"
                fi
                ;;
            15)
                # Reset the environment for a new round (containers/port)
                bash "${SCRIPT_DIR}/../utils/reset_benchmark_environment.sh"
                ;;
            16)
                print_step "Exiting..."
                exit 0
                ;;
            *)
                print_error "Invalid option. Choose 1-16."
                ;;
        esac
    done
    
    print_step "=== EXPERIMENT COMPLETED ==="
    
    # List directories created by the individual benchmarks
    # Each benchmark creates its own directory inside bench_results/
    print_step "Results saved in individual directories:"
    echo ""
    
    # Compute the time window based on the actual experiment duration
    local experiment_end_ts
    experiment_end_ts=$(date +%s)
    
    local elapsed_seconds=$((experiment_end_ts - experiment_start_ts))
    # Convert to minutes, rounding up so nothing is missed
    local elapsed_minutes=$(( (elapsed_seconds + 59) / 60 ))
    
    # Add a safety margin (e.g. +10 minutes) to cover timing variations
    local safety_margin_minutes=10
    local WINDOW_MINUTES=$((elapsed_minutes + safety_margin_minutes))
    
    # Ensure a window of at least 10 minutes for very fast runs
    if [ "$WINDOW_MINUTES" -lt 10 ]; then
        WINDOW_MINUTES=10
    fi
    
    # Look for directories with today's timestamp pattern within the computed window
    local today
    today=$(date +%Y%m%d)
    local recent_dirs
    recent_dirs=$(find bench_results -maxdepth 1 -type d -name "*_${today}*" -mmin -${WINDOW_MINUTES} 2>/dev/null | sort -r)
    
    if [ -n "$recent_dirs" ]; then
        local count=0
        for dir in $recent_dirs; do
            count=$((count + 1))
            local dir_name=$(basename "$dir")
            # Check that the directory is not empty (has at least 1 file besides . and ..)
            local file_count=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
            if [ "$file_count" -gt 0 ]; then
                print_info "  ${count}. ${dir_name} (${file_count} file(s))"
            else
                print_info "  ${count}. ${dir_name} (empty)"
            fi
        done
        echo ""
        print_info "Total: ${count} benchmark directory(ies) found"
    else
        print_warning "No benchmark directory found recently"
        print_detail "Check manually: ls -la bench_results/"
    fi
    
    echo ""
    print_step "For robust statistical analysis of a specific benchmark:"
    print_info "python src/analysis/analyze_results_enhanced.py <benchmark_directory> --output <benchmark_directory>/enhanced_analysis"
    echo ""
    print_info "Example:"
    print_info "python src/analysis/analyze_results_enhanced.py bench_results/startup_performance_20251130-004540 --output bench_results/startup_performance_20251130-004540/enhanced_analysis"
}

# Run main function
main "$@"
