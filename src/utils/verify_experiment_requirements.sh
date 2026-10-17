#!/bin/bash

# =============================================================================
# COMPLETE EXPERIMENT REQUIREMENTS VERIFICATION SCRIPT
# =============================================================================
# RESPONSIBILITY: VALIDATION
# Checks that all requirements are installed and working correctly
# for running the experiments. Returns a success/failure status.
#
# Usage: Before running experiments, to make sure everything is ready
# Output: Validation report with counters (passed/failed/warnings)
#
# Related scripts:
# - show_system_info.sh: Displays summarized information (quick view)
# - collect_system_info.sh: Collects and saves detailed information (documentation)
# =============================================================================

set -euo pipefail

# Load common output functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_output.sh"

# Inherit output style from the parent script if defined
# If OUTPUT_STYLE is not set, use tag as the default for consistency
if [ -z "${OUTPUT_STYLE:-}" ]; then
    enable_tag_output
fi

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

# Function to check and count
check_pass() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
    print_success "$1"
}

check_fail() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    print_error "$1"
}

check_warn() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    WARNINGS=$((WARNINGS + 1))
    print_warning "$1"
}

print_step "Complete Experiment Requirements Verification"
echo ""

# =============================================================================
# 1. DOCKER
# =============================================================================
print_step "1. Docker Verification"
echo ""

if command -v docker &> /dev/null; then
    check_pass "Docker installed: $(docker --version)"
    
    # Check context
    CURRENT_CONTEXT=$(docker context show 2>/dev/null || echo "unknown")
    if [ "$CURRENT_CONTEXT" = "desktop-linux" ]; then
        check_pass "Correct Docker context: ${CURRENT_CONTEXT}"
    else
        check_fail "Incorrect Docker context: ${CURRENT_CONTEXT} (must be 'desktop-linux')"
        print_detail "Run: ./src/utils/check_docker_context.sh to fix"
    fi
    
    # Check whether it is running
    if docker info &> /dev/null; then
        check_pass "Docker is running"
        
        # Docker information
        DOCKER_NAME=$(docker info 2>/dev/null | grep -i "Name:" | head -1 | sed 's/.*Name: *//' || echo "N/A")
        if [[ "$DOCKER_NAME" == *"docker-desktop"* ]] || [[ "$DOCKER_NAME" == *"Docker Desktop"* ]]; then
            print_detail "Docker Desktop confirmed: ${DOCKER_NAME}"
        fi
    else
        check_fail "Docker is not running"
        print_detail "Run: open -a Docker"
    fi
else
    check_fail "Docker not found. Install Docker Desktop."
fi

echo ""

# =============================================================================
# 2. APPLE CONTAINER
# =============================================================================
print_step "2. Apple container Verification"
echo ""

if command -v container &> /dev/null; then
    check_pass "Apple container installed: $(container --version 2>&1 | head -1)"
    
    # Check whether it is running
    if container system status &> /dev/null; then
        check_pass "Apple container is running"
    else
        check_warn "Apple container is not running"
        print_detail "Trying to start..."
        if container system start &> /dev/null; then
            sleep 2
            if container system status &> /dev/null; then
                check_pass "Apple container started successfully"
            else
                check_fail "Failed to start Apple container"
            fi
        else
            check_fail "Failed to start Apple container"
        fi
    fi
else
    check_fail "Apple container not found"
    print_detail "Install Apple container: https://github.com/apple/container/releases"
fi

echo ""

# =============================================================================
# 3. REQUIRED DOCKER IMAGES
# =============================================================================
print_step "3. Docker Images Verification"
echo ""

# Registry images — can be obtained via docker pull
source "${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/config/image_pins.sh"
REGISTRY_IMAGES=("$ALPINE_TAG" "$NGINX_TAG")
# Local images — must be built before the experiment (the sysbench image local/sysbench:1.0.20-alpine3.24
# is built on demand by the CPU and memory scripts; see src/benchmarks/images/sysbench/Dockerfile)
LOCAL_IMAGES=("bench-fio:alpine-3.24")
MISSING_IMAGES=()

for image in "${REGISTRY_IMAGES[@]}"; do
    if docker image inspect "$image" &> /dev/null; then
        check_pass "Docker image available: ${image}"
        # The tag must point at the pinned image (config/image_pins.sh)
        case "$image" in
            "$ALPINE_TAG") pinned="$ALPINE_DIGEST" ;;
            "$NGINX_TAG") pinned="$NGINX_DIGEST" ;;
            *) pinned="" ;;
        esac
        if [ -n "$pinned" ]; then
            if docker image inspect "$image" --format '{{join .RepoDigests " "}}' 2>/dev/null | grep -q "$pinned"; then
                check_pass "Digest matches pin: ${image}"
            else
                check_fail "Digest of ${image} does not match the pinned ${pinned}"
                print_detail "  Run: bash src/utils/setup_environment.sh"
            fi
        fi
    else
        check_fail "Docker image missing: ${image}"
        MISSING_IMAGES+=("$image")
    fi
done

if [ ${#MISSING_IMAGES[@]} -gt 0 ]; then
    print_detail "To download missing images:"
    for img in "${MISSING_IMAGES[@]}"; do
        print_detail "  (bash src/utils/setup_environment.sh pulls the pinned images)"
    done
fi

for image in "${LOCAL_IMAGES[@]}"; do
    if docker image inspect "$image" &> /dev/null; then
        check_pass "Docker image available: ${image}"
    else
        check_fail "Docker image missing (local build): ${image}"
        print_detail "  docker build -t ${image} src/benchmarks/images/fio/"
    fi
done

echo ""

# =============================================================================
# 4. REQUIRED APPLE CONTAINER IMAGES
# =============================================================================
print_step "4. Apple container Images Verification"
echo ""

for image in "${REGISTRY_IMAGES[@]}"; do
    if container image inspect "$image" &> /dev/null; then
        check_pass "Apple container image available: ${image}"
    else
        check_warn "Apple container image missing: ${image}"
        print_detail "Run: ./src/utils/import_images_to_apple_container.sh"
    fi
done

for image in "${LOCAL_IMAGES[@]}"; do
    if container image inspect "$image" &> /dev/null; then
        check_pass "Apple container image available: ${image}"
    else
        check_warn "Apple container image missing (local build): ${image}"
        print_detail "  docker build -t ${image} src/benchmarks/images/fio/"
        print_detail "  Run: ./src/utils/import_images_to_apple_container.sh"
    fi
done

echo ""

# =============================================================================
# 5. SYSTEM TOOLS
# =============================================================================
print_step "5. System Tools Verification"
echo ""

REQUIRED_TOOLS=("python3" "pip3" "sysbench" "wrk" "fio" "jq" "bc")
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "$tool" &> /dev/null; then
        VERSION=""
        case "$tool" in
            python3)
                VERSION=$(python3 --version 2>&1)
                ;;
            pip3)
                VERSION=$(pip3 --version 2>&1 | head -1)
                ;;
            sysbench)
                VERSION=$(sysbench --version 2>&1 | head -1)
                ;;
            wrk)
                VERSION=$(wrk --version 2>&1 | grep -i "wrk" | head -1 || echo "installed")
                ;;
            fio)
                VERSION=$(fio --version 2>&1 | head -1)
                ;;
            jq)
                VERSION=$(jq --version 2>&1)
                ;;
            bc)
                VERSION=$(bc --version 2>&1 | head -1)
                ;;
        esac
        check_pass "${tool} installed: ${VERSION}"
    else
        check_fail "${tool} not found"
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    print_detail "To install missing tools:"
    print_detail "  brew install ${MISSING_TOOLS[*]}"
fi

echo ""

# =============================================================================
# 6. PYTHON VIRTUAL ENVIRONMENT
# =============================================================================
print_step "6. Python Virtual Environment Verification"
echo ""

PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VENV_DIR="${PROJECT_ROOT}/venv"

if [ -d "$VENV_DIR" ]; then
    check_pass "Virtual environment exists: ${VENV_DIR}"
    
    # Check Python dependencies
    if [ -f "${VENV_DIR}/bin/python" ] || [ -f "${VENV_DIR}/bin/python3" ]; then
        PYTHON_CMD="${VENV_DIR}/bin/python3"
        [ -f "${VENV_DIR}/bin/python" ] && PYTHON_CMD="${VENV_DIR}/bin/python"
        
        PYTHON_VERSION=$($PYTHON_CMD --version 2>&1)
        print_detail "venv Python: ${PYTHON_VERSION}"
        
        # Check main dependencies
        REQUIRED_PYTHON_PACKAGES=("pandas" "numpy" "matplotlib" "seaborn" "scipy" "statsmodels")
        MISSING_PACKAGES=()
        
        for package in "${REQUIRED_PYTHON_PACKAGES[@]}"; do
            if $PYTHON_CMD -c "import $package" 2>/dev/null; then
                check_pass "Python package installed: ${package}"
            else
                check_fail "Python package missing: ${package}"
                MISSING_PACKAGES+=("$package")
            fi
        done
        
        if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
            print_detail "To install missing packages:"
            print_detail "  source venv/bin/activate"
            print_detail "  pip install ${MISSING_PACKAGES[*]}"
        fi
    else
        check_fail "Python not found in the virtual environment"
    fi
else
    check_warn "Virtual environment not found"
    print_detail "To create: python3 -m venv venv"
    print_detail "To install dependencies: pip install -r requirements.txt"
fi

echo ""

# =============================================================================
# 7. DIRECTORY STRUCTURE
# =============================================================================
print_step "7. Directory Structure Verification"
echo ""

REQUIRED_DIRS=(
    "src/benchmarks"
    "src/analysis"
    "src/utils"
    "config"
    "docs"
    "bench_results"
)

for dir in "${REQUIRED_DIRS[@]}"; do
    FULL_PATH="${PROJECT_ROOT}/${dir}"
    if [ -d "$FULL_PATH" ]; then
        check_pass "Directory exists: ${dir}"
    else
        check_fail "Directory missing: ${dir}"
    fi
done

echo ""

# =============================================================================
# 8. BENCHMARK SCRIPTS
# =============================================================================
print_step "8. Benchmark Scripts Verification"
echo ""

BENCHMARK_SCRIPTS=(
    "run_startup_performance.sh"
    "run_cpu_performance.sh"
    "run_memory_performance.sh"
    "run_http_performance.sh"
    "run_disk_performance.sh"
    "run_stream_performance.sh"
    "run_math_performance.sh"
    "run_experiment.sh"
)

BENCHMARK_DIR="${PROJECT_ROOT}/src/benchmarks"
MISSING_SCRIPTS=()

for script in "${BENCHMARK_SCRIPTS[@]}"; do
    if [ -f "${BENCHMARK_DIR}/${script}" ] && [ -x "${BENCHMARK_DIR}/${script}" ]; then
        check_pass "Script exists and is executable: ${script}"
    elif [ -f "${BENCHMARK_DIR}/${script}" ]; then
        check_warn "Script exists but is not executable: ${script}"
        print_detail "Execute: chmod +x ${BENCHMARK_DIR}/${script}"
    else
        check_fail "Script missing: ${script}"
        MISSING_SCRIPTS+=("$script")
    fi
done

echo ""

# =============================================================================
# 9. DISK SPACE
# =============================================================================
print_step "9. Disk Space Verification"
echo ""

AVAILABLE_SPACE_GB=$(df -g / | tail -1 | awk '{print $4}')

if [ "$AVAILABLE_SPACE_GB" -ge 50 ]; then
    check_pass "Sufficient disk space: ${AVAILABLE_SPACE_GB}GB available"
else
    check_warn "Disk space may be insufficient: ${AVAILABLE_SPACE_GB}GB available"
    print_detail "Recommended: at least 50GB free"
fi

echo ""

# =============================================================================
# FINAL SUMMARY
# =============================================================================
print_separator
print_step "Verification Summary"
echo ""

print_info "Total checks: ${TOTAL_CHECKS}"
print_success "Checks passed: ${PASSED_CHECKS}"
if [ $FAILED_CHECKS -gt 0 ]; then
    print_error "Checks failed: ${FAILED_CHECKS}"
fi
if [ $WARNINGS -gt 0 ]; then
    print_warning "Warnings: ${WARNINGS}"
fi

echo ""

if [ $FAILED_CHECKS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    print_success "✅ All requirements are met!"
    print_info "The environment is ready to run the experiments."
    exit 0
elif [ $FAILED_CHECKS -eq 0 ]; then
    print_warning "⚠️  Some warnings were found, but the environment is functional."
    print_info "It is recommended to fix the warnings before running full experiments."
    exit 0
else
    print_critical "❌ Some critical requirements are missing!"
    print_info "Fix the problems above before running the experiments."
    exit 1
fi

