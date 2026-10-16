#!/bin/bash

# =============================================================================
# QUICK SYSTEM INFORMATION DISPLAY SCRIPT
# =============================================================================
# Displays summarized system information quickly and readably
# Usage: For quick viewing (e.g., menu option 11)
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

print_step "System Information"
echo ""

# =============================================================================
# BASIC SYSTEM INFORMATION
# =============================================================================
print_info "Operating System:"
echo "  System: $(uname -s) $(uname -r)"
echo "  Architecture: $(uname -m)"
echo "  macOS: $(sw_vers -productVersion)"
echo "  Build: $(sw_vers -buildVersion)"
echo ""

# =============================================================================
# HARDWARE
# =============================================================================
print_info "Hardware:"
CPU_BRAND=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "N/A")
CPU_PHYSICAL=$(sysctl -n hw.physicalcpu 2>/dev/null || echo "N/A")
CPU_LOGICAL=$(sysctl -n hw.logicalcpu 2>/dev/null || echo "N/A")
MEMORY_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
MEMORY_GB=$((MEMORY_BYTES / 1073741824))
DISK_AVAILABLE=$(df -h / | tail -1 | awk '{print $4}')
DISK_TOTAL=$(df -h / | tail -1 | awk '{print $2}')

echo "  CPU: ${CPU_BRAND}"
echo "  Physical Cores: ${CPU_PHYSICAL}"
echo "  Logical Cores: ${CPU_LOGICAL}"
echo "  RAM: ${MEMORY_GB} GB"
echo "  Disk: ${DISK_AVAILABLE} available of ${DISK_TOTAL} total"
echo ""

# =============================================================================
# DOCKER
# =============================================================================
print_info "Docker:"
if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version 2>/dev/null || echo "N/A")
    echo "  Version: ${DOCKER_VERSION}"
    
    CURRENT_CONTEXT=$(docker context show 2>/dev/null || echo "unknown")
    echo "  Context: ${CURRENT_CONTEXT}"
    
    if docker info &> /dev/null; then
        DOCKER_NAME=$(docker info 2>/dev/null | grep -i "Name:" | head -1 | sed 's/.*Name: *//' || echo "N/A")
        DOCKER_CPUS=$(docker info 2>/dev/null | grep -i "CPUs:" | head -1 | sed 's/.*CPUs: *//' || echo "N/A")
        DOCKER_MEM=$(docker info 2>/dev/null | grep -i "Total Memory:" | head -1 | sed 's/.*Total Memory: *//' || echo "N/A")
        echo "  Status: Running"
        echo "  Name: ${DOCKER_NAME}"
        echo "  Allocated CPUs: ${DOCKER_CPUS}"
        echo "  Allocated Memory: ${DOCKER_MEM}"
    else
        echo "  Status: Not running"
    fi
else
    echo "  Docker not found"
fi
echo ""

# =============================================================================
# APPLE CONTAINER
# =============================================================================
print_info "Apple container:"
if command -v container &> /dev/null; then
    CONTAINER_VERSION=$(container --version 2>&1 | head -1 || echo "N/A")
    echo "  Version: ${CONTAINER_VERSION}"
    
    if container system status &> /dev/null; then
        echo "  Status: Running"
    else
        echo "  Status: Not running"
    fi
else
    echo "  Apple container not found"
fi
echo ""

# =============================================================================
# PYTHON
# =============================================================================
print_info "Python:"
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version 2>&1 || echo "N/A")
    echo "  Version: ${PYTHON_VERSION}"
    echo "  Path: $(which python3)"
else
    echo "  Python3 not found"
fi

# Virtual environment
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VENV_DIR="${PROJECT_ROOT}/venv"
if [ -d "$VENV_DIR" ]; then
    echo "  Virtual Environment: Exists at ${VENV_DIR}"
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        echo "  Status: Active (${VIRTUAL_ENV})"
    else
        echo "  Status: Not active"
    fi
else
    echo "  Virtual Environment: Not found"
fi
echo ""

# =============================================================================
# BENCHMARK TOOLS
# =============================================================================
print_info "Benchmark Tools:"
TOOLS=("sysbench" "wrk" "fio" "jq" "bc")
for tool in "${TOOLS[@]}"; do
    if command -v "$tool" &> /dev/null; then
        echo "  ${tool}: installed"
    else
        echo "  ${tool}: not found"
    fi
done
echo ""

# =============================================================================
# DOCKER IMAGES
# =============================================================================
print_info "Essential Docker Images:"
REQUIRED_IMAGES=("alpine:3.19" "nginx:stable")
for image in "${REQUIRED_IMAGES[@]}"; do
    # Check whether Docker is running before trying to check images
    if docker info &> /dev/null; then
        if docker image inspect "$image" &> /dev/null; then
            echo "  ${image}: available"
        else
            echo "  ${image}: not found"
        fi
    else
        print_warning "Cannot check images (Docker is not running)"
        break
    fi
done
echo ""

# =============================================================================
# QUICK SUMMARY
# =============================================================================
print_separator
print_info "Quick Summary:"

# Count status
READY_COUNT=0
ISSUES=()

if command -v docker &> /dev/null && docker info &> /dev/null; then
    READY_COUNT=$((READY_COUNT + 1))
else
    ISSUES+=("Docker")
fi

if command -v container &> /dev/null && container system status &> /dev/null; then
    READY_COUNT=$((READY_COUNT + 1))
else
    ISSUES+=("Apple container")
fi

if [ -d "$VENV_DIR" ]; then
    READY_COUNT=$((READY_COUNT + 1))
else
    ISSUES+=("Python Virtual Environment")
fi

if [ ${#ISSUES[@]} -eq 0 ]; then
    print_success "System ready for experiments"
else
    print_warning "Attention required:"
    for issue in "${ISSUES[@]}"; do
        print_detail "${issue}"
    done
fi

echo ""

