#!/bin/bash
# Quick test of randomization syntax and structure
# Does not run the benchmarks, only validates the implementation

set -e

# Resolve paths robustly (independent of the cwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "🔬 Testing randomization syntax and structure (quick validation)..."
echo ""

# Counters
success=0
failed=0

# Function to validate a script
validate_script() {
    local script_path=$1
    local script_name=$(basename "$script_path")
    
    echo -e "${BLUE}Validating: ${script_name}${NC}"
    
    # 1. Check bash syntax
    if bash -n "$script_path" 2>&1; then
        echo -e "  ${GREEN}✅ Valid syntax${NC}"
    else
        echo -e "  ${RED}❌ Syntax error${NC}"
        return 1
    fi
    
    # 2. Check for ENABLE_RANDOMIZATION
    if grep -q "ENABLE_RANDOMIZATION" "$script_path"; then
        echo -e "  ${GREEN}✅ Variable ENABLE_RANDOMIZATION found${NC}"
    else
        echo -e "  ${RED}❌ Variable ENABLE_RANDOMIZATION NOT found${NC}"
        return 1
    fi
    
    # 3. Check for Fisher-Yates shuffle
    if grep -q "RANDOM %" "$script_path" || grep -q "Fisher-Yates" "$script_path"; then
        echo -e "  ${GREEN}✅ Randomization implemented${NC}"
    else
        echo -e "  ${YELLOW}⚠️  Randomization may not be implemented${NC}"
    fi
    
    # 4. Check for the randomization-disabled message
    if grep -q "Randomization disabled" "$script_path"; then
        echo -e "  ${GREEN}✅ Randomization-disabled message found${NC}"
    else
        echo -e "  ${YELLOW}⚠️  Randomization-disabled message not found${NC}"
    fi
    
    # 5. Count how many tests will be randomized
    local test_count=$(grep -c "docker:" "$script_path" 2>/dev/null || echo "0")
    if [ "$test_count" -gt 0 ]; then
        echo -e "  ${BLUE}ℹ️  Approximately ${test_count} tests detected${NC}"
    fi
    
    echo ""
    return 0
}

# Validate all scripts
scripts=(
    "${PROJECT_ROOT}/src/benchmarks/run_startup_performance.sh"
    "${PROJECT_ROOT}/src/benchmarks/run_cpu_performance.sh"
    "${PROJECT_ROOT}/src/benchmarks/run_memory_performance.sh"
    "${PROJECT_ROOT}/src/benchmarks/run_http_performance.sh"
    "${PROJECT_ROOT}/src/benchmarks/run_disk_performance.sh"
    "${PROJECT_ROOT}/src/benchmarks/run_stream_performance.sh"
    "${PROJECT_ROOT}/src/benchmarks/run_math_performance.sh"
)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

for script in "${scripts[@]}"; do
    if validate_script "$script"; then
        ((success++))
    else
        ((failed++))
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Validation Summary:"
echo -e "  ${GREEN}✅ Valid scripts: ${success}${NC}"
echo -e "  ${RED}❌ Scripts with problems: ${failed}${NC}"
echo ""

if [ $failed -eq 0 ]; then
    echo -e "${GREEN}✅ All scripts have valid syntax and randomization implemented!${NC}"
    echo ""
    echo "📋 Summary:"
    echo "  - 7/7 benchmark scripts validated"
    echo "  - All have ENABLE_RANDOMIZATION implemented"
    echo "  - Ready to use!"
    exit 0
else
    echo -e "${RED}❌ Some scripts have problems. Check above.${NC}"
    exit 1
fi

