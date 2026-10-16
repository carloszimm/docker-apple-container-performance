#!/bin/bash
# Quick test script to validate scripts without randomization
# Runs each test with only 2 iterations for fast validation

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

echo "🔬 Testing scripts without randomization (2 iterations each)..."
echo ""

# Function to test a script
test_script() {
    local script_name=$1
    local script_path=$2
    local description=$3
    
    echo -e "${BLUE}Testing: ${description}${NC}"
    echo "  Script: ${script_name}"
    
    # Functional test: reduce runtime (warmup=0 + minimal pauses)
    local extra_env=()
    extra_env+=( "WARMUP_ITERATIONS_OVERRIDE=0" "VALIDATION_MODE=true" )
    case "$script_name" in
        startup) extra_env+=( "PAUSE_STARTUP_OVERRIDE=1" ) ;;
        cpu|memory) extra_env+=( "PAUSE_CPU_MEMORY_OVERRIDE=1" ) ;;
    esac

    if env ENABLE_RANDOMIZATION=false ITERATIONS_OVERRIDE=2 MIN_VALID_OVERRIDE=2 \
        "${extra_env[@]}" \
        bash "$script_path" > /tmp/test_output_${script_name}.log 2>&1; then
        # Check whether randomization was disabled (look for message)
        if grep -q "Randomization disabled" /tmp/test_output_${script_name}.log; then
            echo -e "  ${GREEN}✅ Success: Randomization disabled correctly${NC}"
        else
            echo -e "  ${YELLOW}⚠️  Warning: Did not find the randomization-disabled message${NC}"
        fi
        
        # Check whether the order is deterministic (look for expected order)
        if grep -q "docker:.*container:" /tmp/test_output_${script_name}.log || grep -q "docker:startup_warm" /tmp/test_output_${script_name}.log; then
            echo -e "  ${GREEN}✅ Success: Deterministic order detected${NC}"
        fi
        
        echo ""
        return 0
    else
        echo -e "  ${RED}❌ Error running script${NC}"
        echo "  Last log lines:"
        tail -5 /tmp/test_output_${script_name}.log | sed 's/^/    /'
        echo ""
        return 1
    fi
}

# Success and failure counters
success=0
failed=0

# Test each script
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Startup Performance
if test_script "startup" "${PROJECT_ROOT}/src/benchmarks/run_startup_performance.sh" "Startup Performance"; then
    ((success++))
else
    ((failed++))
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 2. CPU Performance
if test_script "cpu" "${PROJECT_ROOT}/src/benchmarks/run_cpu_performance.sh" "CPU Performance"; then
    ((success++))
else
    ((failed++))
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 3. Memory Performance
if test_script "memory" "${PROJECT_ROOT}/src/benchmarks/run_memory_performance.sh" "Memory Performance"; then
    ((success++))
else
    ((failed++))
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Test Summary:"
echo -e "  ${GREEN}✅ Successes: ${success}${NC}"
echo -e "  ${RED}❌ Failures: ${failed}${NC}"
echo ""

if [ $failed -eq 0 ]; then
    echo -e "${GREEN}✅ All tests passed! Randomization can be disabled correctly.${NC}"
    exit 0
else
    echo -e "${RED}❌ Some tests failed. Check the logs above.${NC}"
    exit 1
fi

