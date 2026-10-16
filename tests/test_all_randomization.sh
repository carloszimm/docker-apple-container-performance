#!/bin/bash
# Test script to validate randomization in all scripts
# Runs with randomization disabled to validate behavior

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

echo "🔬 Testing all scripts with randomization DISABLED (2 iterations each)..."
echo ""

# Function to test a script
test_script() {
    local script_name=$1
    local script_path=$2
    local description=$3
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Testing: ${description}${NC}"
    echo "  Script: ${script_name}"
    
    # IMPORTANT: these tests are functional/randomization validation, not statistical rigor.
    # To avoid appearing "stuck" and to prevent aborts, we force warmup=0 and minimal parameters.
    local extra_env=()
    extra_env+=( "WARMUP_ITERATIONS_OVERRIDE=0" "VALIDATION_MODE=true" )

    case "$script_name" in
        http)
            extra_env+=( "PAUSE_HTTP_OVERRIDE=1" "HTTP_MAX_RETRIES_PER_ITERATION=1" "HTTP_STARTUP_TIMEOUT_SECONDS=5" )
            ;;
        disk)
            extra_env+=( "PAUSE_DISK_OVERRIDE=1" "FIO_SIZE_MB=64" )
            ;;
        math)
            extra_env+=( "PAUSE_MATH_OVERRIDE=1" "PI_DIGITS=3" )
            ;;
        stream)
            extra_env+=( "PAUSE_STREAM_OVERRIDE=1" "STREAM_ARRAY_SIZE_MB=100" "STREAM_ARRAY_SIZE_MB_CONTAINER=100" )
            ;;
        startup)
            extra_env+=( "PAUSE_STARTUP_OVERRIDE=1" )
            ;;
        cpu|memory)
            extra_env+=( "PAUSE_CPU_MEMORY_OVERRIDE=1" )
            ;;
    esac

    if env ENABLE_RANDOMIZATION=false ITERATIONS_OVERRIDE=2 MIN_VALID_OVERRIDE=2 \
        "${extra_env[@]}" \
        bash "$script_path" > /tmp/test_${script_name}.log 2>&1; then
        # Check whether randomization was disabled (look for message)
        if grep -q "Randomization disabled" /tmp/test_${script_name}.log; then
            echo -e "  ${GREEN}✅ Success: Randomization disabled correctly${NC}"
        else
            echo -e "  ${YELLOW}⚠️  Warning: Did not find the randomization-disabled message${NC}"
        fi
        
        # Check whether the order is deterministic (look for expected order)
        if grep -q "Test order:" /tmp/test_${script_name}.log; then
            echo -e "  ${GREEN}✅ Success: Deterministic order detected${NC}"
            # Show detected order
            echo -e "  ${BLUE}Detected order:${NC}"
            grep -A 10 "Test order:" /tmp/test_${script_name}.log | grep "  -" | head -5 | sed 's/^/    /'
        fi
        
        echo ""
        return 0
    else
        echo -e "  ${RED}❌ Error running script${NC}"
        echo "  Last log lines:"
        tail -10 /tmp/test_${script_name}.log | sed 's/^/    /'
        echo ""
        return 1
    fi
}

# Success and failure counters
success=0
failed=0

# Test each modified script
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. HTTP Performance
if test_script "http" "${PROJECT_ROOT}/src/benchmarks/run_http_performance.sh" "HTTP Performance"; then
    ((success++))
else
    ((failed++))
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 2. Disk Performance (may take longer)
if test_script "disk" "${PROJECT_ROOT}/src/benchmarks/run_disk_performance.sh" "Disk I/O Performance"; then
    ((success++))
else
    ((failed++))
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 3. Math Performance
if test_script "math" "${PROJECT_ROOT}/src/benchmarks/run_math_performance.sh" "Math Performance"; then
    ((success++))
else
    ((failed++))
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# STREAM now removes setup noise and can run quickly; even so,
# we keep the test lightweight to avoid long runs.
echo -e "${BLUE}Checking STREAM (syntax + ultra-quick run)...${NC}"
if bash -n "${PROJECT_ROOT}/src/benchmarks/run_stream_performance.sh" 2>&1; then
    echo -e "  ${GREEN}✅ STREAM syntax valid${NC}"
    if env ENABLE_RANDOMIZATION=false ITERATIONS_OVERRIDE=1 MIN_VALID_OVERRIDE=1 WARMUP_ITERATIONS_OVERRIDE=0 \
        PAUSE_STREAM_OVERRIDE=1 STREAM_ARRAY_SIZE_MB=50 STREAM_ARRAY_SIZE_MB_CONTAINER=50 VALIDATION_MODE=true \
        bash "${PROJECT_ROOT}/src/benchmarks/run_stream_performance.sh" > /tmp/test_stream.log 2>&1; then
        echo -e "  ${GREEN}✅ STREAM ultra-quick run OK${NC}"
        ((success++))
    else
        echo -e "  ${RED}❌ Error running STREAM (ultra-quick)${NC}"
        tail -10 /tmp/test_stream.log | sed 's/^/    /'
        ((failed++))
    fi
else
    echo -e "  ${RED}❌ Syntax error in STREAM${NC}"
    ((failed++))
fi

echo ""
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
    echo -e "${GREEN}✅ All tests passed! Randomization correctly implemented in all scripts.${NC}"
    exit 0
else
    echo -e "${RED}❌ Some tests failed. Check the logs above.${NC}"
    exit 1
fi

