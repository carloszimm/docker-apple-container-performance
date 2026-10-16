#!/usr/bin/env bash

# =============================================================================
# BENCHMARK UTILITIES
# =============================================================================
#
# Common utility functions for benchmark scripts.
# Centralizes code duplicated across the different benchmark scripts.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/benchmark_utils.sh"
#
# Dependencies:
#   - common_output.sh (must be sourced first)
#   - statistical_utils.sh (for some functions)
# =============================================================================

# -----------------------------------------------------------------------------
# STANDARDIZED RESOURCES (Methodology: Raj Jain - Identical Conditions)
# -----------------------------------------------------------------------------
# To ensure a fair comparison between Docker Desktop and Apple container,
# resources must be standardized. Values are based on the documented
# Docker Desktop settings (Settings → Resources).
# -----------------------------------------------------------------------------
CONTAINER_STANDARD_CPUS=${CONTAINER_STANDARD_CPUS:-12}      # 12 CPUs (same as Docker Desktop)
CONTAINER_STANDARD_MEMORY=${CONTAINER_STANDARD_MEMORY:-8G}   # 8 GB (same as Docker Desktop)

# -----------------------------------------------------------------------------
# run_container_with_standard_resources
# -----------------------------------------------------------------------------
# Runs a container with standardized resources (CPUs and memory).
# Ensures Apple container uses the same resources as Docker Desktop,
# eliminating a confounding variable (threat T21 to internal validity).
#
# Parameters:
#   $1 - Runtime ("docker" or "container")
#   $2 - Container image
#   $3 - Custom memory (optional, format: "8G", "512M", etc.)
#        If not provided, uses CONTAINER_STANDARD_MEMORY
#   $@ - Remaining arguments for container run (flags, command, etc.)
#
# Example:
#   run_container_with_standard_resources "container" "alpine:3.19" "echo test"
#   run_container_with_standard_resources "container" "alpine:3.19" "2G" "sh -c 'echo test'"
#
# Notes:
#   - Docker Desktop already has globally limited resources (Settings → Resources)
#   - Apple container needs explicit per-container limits
#   - Custom memory is useful for specific benchmarks (e.g., STREAM)
# -----------------------------------------------------------------------------
run_container_with_standard_resources() {
    local runtime=$1
    local image=$2
    shift 2
    
    if [ "$runtime" = "docker" ]; then
        # Docker Desktop already has globally limited resources
        # No need to pass --cpus or --memory (already configured in Settings)
        docker run --rm "$image" "$@"
    elif [ "$runtime" = "container" ]; then
        # Apple container needs explicit limits
        # Check whether the first argument is custom memory (format: number followed by G/M)
        local memory_flag="--memory=${CONTAINER_STANDARD_MEMORY}"
        if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+[GM]?i?B?$ ]]; then
            memory_flag="--memory=$1"
            shift  # Remove first argument (memory)
        fi
        container run --rm --cpus="${CONTAINER_STANDARD_CPUS}" ${memory_flag} "$image" "$@"
    else
        echo "Error: invalid runtime: $runtime" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# check_dependencies
# -----------------------------------------------------------------------------
# Checks required and optional system dependencies.
#
# Parameters:
#   $@ - List of optional dependencies to check
#        Examples: "sysbench", "wrk", "fio"
#
# Returns:
#   0 if all required dependencies are available
#   1 if a required dependency is missing (and exits)
#
# Required dependencies (always checked):
#   - docker
#   - container (Apple container)
#   - python3
#
# Optional dependencies (checked if provided as arguments):
#   - Any additional command passed as a parameter
# -----------------------------------------------------------------------------
check_dependencies() {
    local optional_deps=("$@")
    
    print_step "Checking dependencies..."
    
    # Check Docker (required)
    if ! command -v docker &> /dev/null; then
        print_error "Docker not found"
        exit 1
    else
        if docker info &> /dev/null; then
            print_success "Docker Desktop: Running"
            check_docker_resources
        else
            print_warning "Docker Desktop: Installed but not running"
            print_info "Run: open -a Docker"
            exit 1
        fi
    fi
    
    # Check Apple container (required)
    if ! command -v container &> /dev/null; then
        print_error "Apple container not found"
        exit 1
    fi
    
    # Check Python3 (required)
    if ! command -v python3 &> /dev/null; then
        print_warning "Python3 not found (required for statistical analysis)"
        # Does not exit, since some benchmarks can work without statistical analysis
    fi
    
    # Check optional dependencies (if provided)
    local optional_count=${#optional_deps[@]}
    if [ "$optional_count" -gt 0 ]; then
        for dep in "${optional_deps[@]}"; do
            if ! command -v "$dep" &> /dev/null; then
                print_warning "${dep} not found"
                case "$dep" in
                    sysbench)
                        print_info "Install with: brew install sysbench"
                        ;;
                    wrk)
                        print_info "Install with: brew install wrk"
                        ;;
                    fio)
                        print_info "Install with: brew install fio"
                        ;;
                esac
                # Optional dependencies do not cause an exit
            else
                print_success "${dep}: Found"
            fi
        done
    fi
    
    print_success "All dependencies found"
}

# -----------------------------------------------------------------------------
# check_rosetta
# -----------------------------------------------------------------------------
# Checks whether Rosetta is active (required for x86_64 emulation on ARM64).
#
# Returns:
#   Always 0 (only reports the status)
# -----------------------------------------------------------------------------
check_rosetta() {
    print_step "Checking Rosetta..."
    
    if [[ $(uname -m) == "arm64" ]]; then
        if ! pgrep -q oahd; then
            print_warning "Rosetta is not running"
            print_info "Run: softwareupdate --install-rosetta"
        else
            print_success "Rosetta is active"
        fi
    else
        print_info "x86_64 system - Rosetta not required"
    fi
}

# -----------------------------------------------------------------------------
# check_apple_container
# -----------------------------------------------------------------------------
# Checks whether Apple container is running and, optionally, tries to start it.
#
# Parameters:
#   $1 - "auto_start" (optional): If provided, tries to start it automatically
#                                 If not provided, only checks and exits on error
#
# Returns:
#   0 if Apple container is running
#   1 if it is not running and could not be started (and exits)
# -----------------------------------------------------------------------------
check_apple_container() {
    local auto_start=${1:-}
    
    print_step "Checking Apple container..."
    
    if ! container system status &> /dev/null; then
        print_warning "Apple container is not running"
        
        if [ "$auto_start" = "auto_start" ]; then
            print_info "Trying to start automatically..."
            if container system start &> /dev/null; then
                sleep 2
                if container system status &> /dev/null; then
                    print_success "Apple container: Started automatically"
                    return 0
                else
                    print_error "Failed to start Apple container"
                    print_info "Run manually: container system start"
                    exit 1
                fi
            else
                print_error "Failed to start Apple container automatically"
                print_info "Run manually: container system start"
                exit 1
            fi
        else
            print_info "Run: container system start"
            exit 1
        fi
    else
        print_success "Apple container is active"
        print_info "Apple container — CPUs: ${CONTAINER_STANDARD_CPUS} (per run, via --cpus) | RAM: ${CONTAINER_STANDARD_MEMORY} (per run, via --memory)"
    fi
}

# -----------------------------------------------------------------------------
# check_docker_resources
# -----------------------------------------------------------------------------
# Reads the actual CPU and memory settings of Docker Desktop via `docker info`
# and compares them with the values expected by the experiment
# (CONTAINER_STANDARD_CPUS and CONTAINER_STANDARD_MEMORY). Emits a warning if
# there is a significant mismatch.
#
# Methodological context:
#   The Docker Desktop × Apple container comparison requires symmetric conditions.
#   Apple container receives explicit limits via --cpus/--memory on each run.
#   Docker Desktop depends on manual configuration in Settings → Resources.
#   This function ensures that this configuration is recorded and validated
#   programmatically on every execution, rather than implicitly assumed.
#
# Returns:
#   Always 0 (the warning does not interrupt the experiment; the decision is up to the researcher)
# -----------------------------------------------------------------------------
check_docker_resources() {
    local expected_cpus=${CONTAINER_STANDARD_CPUS:-12}
    local expected_mem=${CONTAINER_STANDARD_MEMORY:-8G}

    # Read actual Docker Desktop values
    local actual_cpus actual_mem_bytes
    actual_cpus=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo "?")
    actual_mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo "0")

    # Convert expected_mem (e.g., "8G", "4G") to bytes
    local expected_mem_bytes=0
    local mem_num mem_unit
    mem_num=$(echo "$expected_mem" | sed 's/[GgMm].*//')
    mem_unit=$(echo "$expected_mem" | sed 's/[0-9]*//' | tr '[:lower:]' '[:upper:]')
    case "$mem_unit" in
        G) expected_mem_bytes=$((mem_num * 1024 * 1024 * 1024)) ;;
        M) expected_mem_bytes=$((mem_num * 1024 * 1024)) ;;
    esac

    # Format actual memory in GB for display
    local actual_mem_gb="?"
    if [ "$actual_mem_bytes" -gt 0 ] 2>/dev/null; then
        actual_mem_gb=$(echo "scale=1; $actual_mem_bytes / 1073741824" | bc -l)
    fi

    # Check CPUs (exact comparison)
    local cpu_ok=true
    if [ "$actual_cpus" != "?" ] && [ "$actual_cpus" != "$expected_cpus" ]; then
        cpu_ok=false
    fi

    # Check memory with a 10% tolerance (Docker reserves ~1-2% for overhead)
    local mem_ok=true
    if [ "$expected_mem_bytes" -gt 0 ] && [ "$actual_mem_bytes" -gt 0 ] 2>/dev/null; then
        local diff threshold
        diff=$(echo "$actual_mem_bytes - $expected_mem_bytes" | bc -l | awk '{if($1<0) print -$1; else print $1}')
        threshold=$(echo "$expected_mem_bytes * 0.10" | bc -l)
        if [ "$(echo "$diff > $threshold" | bc -l)" -eq 1 ]; then
            mem_ok=false
        fi
    fi

    # Always log — even without a mismatch (environment traceability)
    print_info "Docker Desktop — CPUs: ${actual_cpus} (expected: ${expected_cpus}) | RAM: ${actual_mem_gb}GB (expected: ${expected_mem})"

    # Warn if there is a mismatch
    if [ "$cpu_ok" = false ] || [ "$mem_ok" = false ]; then
        print_warning "Docker Desktop resources differ from the values expected by the experiment"
        [ "$cpu_ok" = false ] && print_info "  CPUs: configured=${actual_cpus}, expected=${expected_cpus}"
        [ "$mem_ok" = false ] && print_info "  RAM:  configured=${actual_mem_gb}GB, expected=${expected_mem}"
        print_warning "Adjust in Docker Desktop → Settings → Resources before proceeding"
    else
        print_success "Docker Desktop resources verified: ${actual_cpus} CPUs, ${actual_mem_gb}GB RAM"
    fi
}

# -----------------------------------------------------------------------------
# setup_output_directory
# -----------------------------------------------------------------------------
# Creates and configures the output directory for benchmark results.
#
# Parameters:
#   $1 - Benchmark name (e.g., "startup_performance", "cpu_performance")
#
# Global variables set:
#   EXPERIMENT_NAME - Experiment name with timestamp
#   OUTPUT_DIR - Full path of the output directory
#
# Returns:
#   Always 0
# -----------------------------------------------------------------------------
setup_output_directory() {
    local benchmark_name=$1
    
    if [ -z "$benchmark_name" ]; then
        print_error "Benchmark name not provided to setup_output_directory"
        exit 1
    fi
    
    EXPERIMENT_NAME="${benchmark_name}_$(date +%Y%m%d-%H%M%S)"
    OUTPUT_DIR="bench_results/${EXPERIMENT_NAME}"
    mkdir -p "${OUTPUT_DIR}"
    
    print_info "Output directory: ${OUTPUT_DIR}"
}

# -----------------------------------------------------------------------------
# get_iso_timestamp
# -----------------------------------------------------------------------------
# Generates an ISO 8601 timestamp in UTC.
#
# Returns:
#   Timestamp in the format: YYYY-MM-DDTHH:MM:SS-0300
#
# Note:
#   The timezone is fixed at -0300 (Brazil). For a dynamic timezone, use:
#   date -u +"%Y-%m-%dT%H:%M:%S%z"
# -----------------------------------------------------------------------------
get_iso_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%S%z"
}

# -----------------------------------------------------------------------------
# check_sample_size
# -----------------------------------------------------------------------------
# Checks whether the number of iterations meets the recommended minimum for the
# specified confidence level (based on Raj Jain, Ch. 13).
#
# Parameters:
#   $1 - Number of iterations
#   $2 - Confidence level (e.g., 0.95 for 95%)
#
# Returns:
#   Always 0 (only emits a warning if necessary)
#
# Dependencies:
#   - statistical_utils.sh (calculate_min_sample_size)
# -----------------------------------------------------------------------------
check_sample_size() {
    local iterations=$1
    local confidence_level=${2:-0.95}
    
    if [ -z "$iterations" ] || ! [[ "$iterations" =~ ^[0-9]+$ ]]; then
        print_warning "Invalid number of iterations: ${iterations}"
        return 1
    fi
    
    # Check whether statistical_utils.sh is loaded
    if ! command -v calculate_min_sample_size &> /dev/null; then
        print_warning "calculate_min_sample_size not found. Source statistical_utils.sh"
        return 1
    fi
    
    local min_recommended=$(calculate_min_sample_size "$confidence_level")
    
    if [ "$iterations" -lt "$min_recommended" ]; then
        local conf_pct=$(echo "$confidence_level * 100" | bc -l | cut -d'.' -f1)
        print_warning "Number of iterations (${iterations}) is lower than the recommended minimum (${min_recommended}) for ${conf_pct}% confidence (Raj Jain, Ch. 13)"
    fi
}

# -----------------------------------------------------------------------------
# randomize_array
# -----------------------------------------------------------------------------
# Randomizes the order of the elements of an array using a Fisher-Yates shuffle.
#
# ⚠️ CRITICAL (Methodological rigor):
# - Implementations via `sort -R` do not guarantee uniformity and do not support a seed.
# - `shuf` may not exist on macOS.
# - For reproducibility, this project supports an optional seed via:
#   - RANDOMIZATION_SEED=<int>
#   - RANDOMIZATION_CONTEXT=<string> (optional, to derive a seed per benchmark)
#
# Parameters:
#   $@ - Array elements to be randomized
#
# Returns:
#   Randomized array (via echo, must be captured with $())
#
# Example:
#   arr=($(randomize_array "docker" "container"))
#   # Returns: ("container" "docker") or ("docker" "container")
# -----------------------------------------------------------------------------
randomize_array() {
    local array=("$@")
    
    if [ ${#array[@]} -eq 0 ]; then
        echo ""
        return 0
    fi

    # Optional seed for reproducibility
    # - If RANDOMIZATION_SEED is set, derive the seed per context to prevent
    #   multiple calls from producing the same permutation.
    # - We use a per-process global counter so that successive calls yield
    #   different permutations, yet remain deterministic when the seed is fixed.
    local base_seed="${RANDOMIZATION_SEED:-}"
    local ctx="${RANDOMIZATION_CONTEXT:-randomize_array}"
    if [ -z "${__RANDOMIZATION_CALL_INDEX:-}" ]; then
        __RANDOMIZATION_CALL_INDEX=0
    fi
    __RANDOMIZATION_CALL_INDEX=$((__RANDOMIZATION_CALL_INDEX + 1))
    local old_random=""

    if [ -n "$base_seed" ]; then
        # Derive a deterministic seed (0..32767) from (base_seed + context)
        # using cksum (available on macOS).
        local derived
        derived=$(printf '%s' "${base_seed}:${ctx}:${__RANDOMIZATION_CALL_INDEX}" | cksum | awk '{print $1}' 2>/dev/null || echo "")
        if [[ "$derived" =~ ^[0-9]+$ ]]; then
            old_random=$RANDOM
            RANDOM=$((derived % 32768))
        fi
    fi

    # Fisher-Yates shuffle (uniform)
    local i j tmp
    for ((i=${#array[@]}-1; i>0; i--)); do
        j=$((RANDOM % (i+1)))
        tmp=${array[i]}
        array[i]=${array[j]}
        array[j]=$tmp
    done

    # Restore bash RNG (avoid affecting external calls)
    if [ -n "$base_seed" ] && [ -n "$old_random" ]; then
        RANDOM=$old_random
    fi

    printf '%s\n' "${array[@]}"
}

# -----------------------------------------------------------------------------
# run_statistical_analysis
# -----------------------------------------------------------------------------
# Runs robust statistical analysis using the Python analysis script.
#
# Parameters:
#   $1 - Output directory (OUTPUT_DIR) containing the results
#
# Returns:
#   0 if the analysis ran successfully
#   1 if there was an error or the script was not found
#
# Dependencies:
#   - Python 3 (venv preferred)
#   - analyze_results_enhanced.py in src/analysis/
# -----------------------------------------------------------------------------
run_statistical_analysis() {
    local output_dir=$1
    
    if [ -z "$output_dir" ]; then
        print_error "Output directory not provided to run_statistical_analysis"
        return 1
    fi
    
    # Build paths relative to the script directory
    # Assuming benchmark_utils.sh is in src/utils/
    local utils_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local script_dir="$(cd "$utils_dir/.." && pwd)"
    local project_root="$(cd "$script_dir/.." && pwd)"
    
    local analysis_script="${script_dir}/analysis/analyze_results_enhanced.py"
    local analysis_script_from_root="${project_root}/src/analysis/analyze_results_enhanced.py"
    
    # Detect Python: prefer venv, then python3, then python
    local python_cmd=""
    local venv_python="${project_root}/venv/bin/python"
    local venv_python3="${project_root}/venv/bin/python3"
    
    # Check whether the venv Python exists (may be a symlink or a file)
    if [ -x "$venv_python" ] && "$venv_python" -c "import pandas" 2>/dev/null; then
        python_cmd="$venv_python"
    elif [ -x "$venv_python3" ] && "$venv_python3" -c "import pandas" 2>/dev/null; then
        python_cmd="$venv_python3"
    elif command -v python3 &> /dev/null && python3 -c "import pandas" 2>/dev/null; then
        python_cmd="python3"
    elif command -v python &> /dev/null && python -c "import pandas" 2>/dev/null; then
        python_cmd="python"
    else
        print_warning "Python with pandas not found."
        print_info "Install the dependencies: cd ${project_root} && source venv/bin/activate && pip install -r requirements.txt"
        print_info "Or activate the venv: source ${project_root}/venv/bin/activate"
        return 1
    fi
    
    # Try different possible paths for the analysis script
    local script_found=false
    local script_path=""
    
    for path in "$analysis_script" "$analysis_script_from_root" \
                "src/analysis/analyze_results_enhanced.py" \
                "analyze_results_enhanced.py"; do
        if [ -f "$path" ]; then
            script_found=true
            script_path="$path"
            break
        fi
    done
    
    if [ "$script_found" = false ]; then
        print_warning "Robust analysis script not found"
        print_info "Searched in:"
        print_info "  • ${analysis_script}"
        print_info "  • ${analysis_script_from_root}"
        print_info "  • src/analysis/analyze_results_enhanced.py (relative to the current directory)"
        print_info "  • analyze_results_enhanced.py (relative to the current directory)"
        print_info ""
        print_info "Run manually:"
        print_info "  ${python_cmd} <path_to_script> ${output_dir} --output ${output_dir}/enhanced_analysis"
        return 1
    fi
    
    # Run analysis in quiet mode (compact output)
    # Use an environment variable to pass quiet mode to Python
    ANALYSIS_QUIET=1 $python_cmd "$script_path" "${output_dir}" --output "${output_dir}/enhanced_analysis" --quiet 2>&1
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        # Do not print a success message here - the Python script already prints it in quiet mode
        return 0
    else
        print_warning "Error running statistical analysis"
        print_info "Check that the venv is active and the dependencies are installed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# require_command
# -----------------------------------------------------------------------------
# Helper function to check whether a command exists and exit if it does not.
#
# Parameters:
#   $1 - Command name
#   $2 - Error message (optional)
#
# Returns:
#   0 if the command exists
#   1 if it does not exist (and exits)
# -----------------------------------------------------------------------------
require_command() {
    local cmd=$1
    local error_msg=${2:-"Command ${cmd} not found"}
    
    if ! command -v "$cmd" &> /dev/null; then
        print_error "$error_msg"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# check_optional_command
# -----------------------------------------------------------------------------
# Helper function to check whether an optional command exists.
#
# Parameters:
#   $1 - Command name
#
# Returns:
#   0 if the command exists
#   1 if it does not exist (does not exit)
# -----------------------------------------------------------------------------
check_optional_command() {
    local cmd=$1
    
    if command -v "$cmd" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# PHASE 3: PARAMETER VALIDATION SYSTEM
# =============================================================================

# -----------------------------------------------------------------------------
# validate_positive_integer
# -----------------------------------------------------------------------------
# Validates that a value is a positive integer.
#
# Parameters:
#   $1 - Value to validate
#   $2 - Default value (if invalid)
#   $3 - Parameter name (for error messages)
#
# Returns:
#   Prints the validated (or default) value and returns 0
#   Returns 1 if the value cannot be validated
# -----------------------------------------------------------------------------
validate_positive_integer() {
    local value=$1
    local default=$2
    local param_name=${3:-"parameter"}
    
    # If empty, use default
    if [ -z "$value" ]; then
        echo "$default"
        return 0
    fi
    
    # Check whether it is a positive integer
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then
        echo "$value"
        return 0
    else
        print_warning "⚠️  Invalid value for ${param_name}: '${value}'. Using default: ${default}" >&2
        echo "$default"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# validate_float_in_range
# -----------------------------------------------------------------------------
# Validates that a value is a float within a range.
#
# Parameters:
#   $1 - Value to validate
#   $2 - Default value (if invalid)
#   $3 - Minimum value (inclusive)
#   $4 - Maximum value (inclusive)
#   $5 - Parameter name (for error messages)
#
# Returns:
#   Prints the validated (or default) value and returns 0
#   Returns 1 if the value cannot be validated
# -----------------------------------------------------------------------------
validate_float_in_range() {
    local value=$1
    local default=$2
    local min=$3
    local max=$4
    local param_name=${5:-"parameter"}
    
    # If empty, use default
    if [ -z "$value" ]; then
        echo "$default"
        return 0
    fi
    
    # Check whether it is a number (integer or float)
    if [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]] || [[ "$value" =~ ^\.[0-9]+$ ]]; then
        # Check whether it is within the range
        local is_valid
        is_valid=$(echo "$value >= $min && $value <= $max" | bc -l 2>/dev/null || echo "0")
        if [ "$is_valid" = "1" ]; then
            echo "$value"
            return 0
        else
            print_warning "⚠️  Value out of range for ${param_name}: '${value}' (must be between ${min} and ${max}). Using default: ${default}" >&2
            echo "$default"
            return 1
        fi
    else
        print_warning "⚠️  Invalid value for ${param_name}: '${value}' (must be a number). Using default: ${default}" >&2
        echo "$default"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# validate_boolean
# -----------------------------------------------------------------------------
# Validates that a value is a boolean (true/false).
#
# Parameters:
#   $1 - Value to validate
#   $2 - Default value (if invalid)
#   $3 - Parameter name (for error messages)
#
# Returns:
#   Prints the validated (or default) value and returns 0
#   Returns 1 if the value cannot be validated
# -----------------------------------------------------------------------------
validate_boolean() {
    local value=$1
    local default=$2
    local param_name=${3:-"parameter"}
    
    # If empty, use default
    if [ -z "$value" ]; then
        echo "$default"
        return 0
    fi
    
    # Convert to lowercase
    local value_lower
    value_lower=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    
    # Check whether it is true or false
    if [ "$value_lower" = "true" ] || [ "$value_lower" = "false" ]; then
        echo "$value_lower"
        return 0
    else
        print_warning "⚠️  Invalid value for ${param_name}: '${value}' (must be 'true' or 'false'). Using default: ${default}" >&2
        echo "$default"
        return 1
    fi
}

# =============================================================================
# PHASE 3: STRUCTURED LOGGING SYSTEM
# =============================================================================

# Logging level (DEBUG, INFO, WARNING, ERROR)
# Controlled via the LOG_LEVEL environment variable, default INFO
LOG_LEVEL=${LOG_LEVEL:-INFO}

# Helper function to check whether a log level should be displayed
_should_log() {
    local level=$1
    
    case "$LOG_LEVEL" in
        DEBUG)
            return 0  # DEBUG shows everything
            ;;
        INFO)
            case "$level" in
                DEBUG) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        WARNING)
            case "$level" in
                DEBUG|INFO) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        ERROR)
            [ "$level" = "ERROR" ] && return 0 || return 1
            ;;
        *)
            return 0  # Default: show everything
            ;;
    esac
}

# -----------------------------------------------------------------------------
# log_debug
# -----------------------------------------------------------------------------
# Logs a debug message (only if LOG_LEVEL=DEBUG).
#
# Parameters:
#   $1 - Message to log
#   $@ - Additional arguments (optional)
# -----------------------------------------------------------------------------
log_debug() {
    if _should_log "DEBUG"; then
        echo -e "${CYAN}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
    fi
}

# -----------------------------------------------------------------------------
# log_info
# -----------------------------------------------------------------------------
# Logs an informational message.
#
# Parameters:
#   $1 - Message to log
#   $@ - Additional arguments (optional)
# -----------------------------------------------------------------------------
log_info() {
    if _should_log "INFO"; then
        echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
    fi
}

# -----------------------------------------------------------------------------
# log_warning
# -----------------------------------------------------------------------------
# Logs a warning message.
#
# Parameters:
#   $1 - Message to log
#   $@ - Additional arguments (optional)
# -----------------------------------------------------------------------------
log_warning() {
    if _should_log "WARNING"; then
        echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
    fi
}

# -----------------------------------------------------------------------------
# log_error
# -----------------------------------------------------------------------------
# Logs an error message.
#
# Parameters:
#   $1 - Message to log
#   $@ - Additional arguments (optional)
# -----------------------------------------------------------------------------
log_error() {
    if _should_log "ERROR"; then
        echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
    fi
}

# -----------------------------------------------------------------------------
# log_to_file
# -----------------------------------------------------------------------------
# Logs a message to a log file.
#
# Parameters:
#   $1 - Log file
#   $2 - Log level (DEBUG, INFO, WARNING, ERROR)
#   $3 - Message
#   $@ - Additional arguments (optional)
# -----------------------------------------------------------------------------
log_to_file() {
    local log_file=$1
    local level=$2
    shift 2
    local message="$*"
    
    # Create the log directory if it does not exist
    local log_dir
    log_dir=$(dirname "$log_file")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
    fi
    
    # Write to the file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$log_file"
}

