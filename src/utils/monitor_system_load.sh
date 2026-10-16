#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# MONITOR SYSTEM LOAD
# =============================================================================
# Script to monitor system load (CPU/Memory) before each benchmark
# iteration, mitigating threat T4 (external load interfering with the tests).
#
# Usage:
#   src/utils/monitor_system_load.sh >> "${OUTPUT_DIR}/system_load_log.csv"
#   - exit 0: load within thresholds (OK)
#   - exit 1: load above at least one threshold (HIGH)
#
# Collected metrics:
#   - timestamp (UTC, ISO 8601)
#   - cpu_percent (average per core, 0-100)
#   - mem_percent (RAM used, 0-100)
#   - status (OK | HIGH_CPU | HIGH_MEM | HIGH_CPU_MEM)
#
# Thresholds (can be overridden via environment variables):
#   CPU_THRESHOLD (default: 20.0)
#   MEM_THRESHOLD (default: 80.0)
# =============================================================================

CPU_THRESHOLD=${CPU_THRESHOLD:-20.0}
MEM_THRESHOLD=${MEM_THRESHOLD:-80.0}

# Helper function to get a UTC timestamp (ISO 8601)
get_iso_timestamp_utc() {
    date -u +"%Y-%m-%dT%H:%M:%S%z"
}

# Function to measure average CPU usage per core (%)
get_cpu_usage() {
    # Sum %CPU of all processes
    local total_cpu
    total_cpu=$(ps -A -o %cpu= 2>/dev/null | awk '{s+=$1} END {if (NR>0) printf "%.1f", s; else print "0.0"}')
    
    # Number of logical CPUs
    local cores
    cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
    
    # Normalize to 0-100 per core
    # On macOS, the sum of %cpu can exceed 100 on multi-core systems
    local cpu_per_core
    cpu_per_core=$(echo "$total_cpu / $cores" | bc -l 2>/dev/null | awk '{printf "%.1f", $1}')
    
    echo "$cpu_per_core"
}

# Function to measure memory usage (%)
get_mem_usage() {
    # Use vm_stat to get memory statistics
    local vm_output page_size free_pages active_pages inactive_pages speculative_pages wired_pages
    
    vm_output=$(vm_stat 2>/dev/null || true)
    
    # If vm_stat fails, return 0.0 to avoid breaking
    if [ -z "$vm_output" ]; then
        echo "0.0"
        return 0
    fi
    
    page_size=$(echo "$vm_output" | head -1 | awk '{print $8}' | tr -d '.')
    free_pages=$(echo "$vm_output" | awk '/Pages free/ {gsub("\\.","",$3); print $3}')
    active_pages=$(echo "$vm_output" | awk '/Pages active/ {gsub("\\.","",$3); print $3}')
    inactive_pages=$(echo "$vm_output" | awk '/Pages inactive/ {gsub("\\.","",$3); print $3}')
    speculative_pages=$(echo "$vm_output" | awk '/Pages speculative/ {gsub("\\.","",$3); print $3}')
    wired_pages=$(echo "$vm_output" | awk '/Pages wired down/ {gsub("\\.","",$4); print $4}')
    # Pages occupied by the memory compressor (swap in RAM — Apple Silicon).
    # Omitting these pages underestimated the real memory pressure by ~10 p.p.
    compressed_pages=$(echo "$vm_output" | awk '/Pages occupied by compressor/ {gsub("\\.","",$5); print $5}')
    compressed_pages=${compressed_pages:-0}

    # Total: all physical RAM managed by the kernel
    # Used: active + wired + compressed pages (all occupy real RAM)
    local total_pages used_pages
    total_pages=$((free_pages + active_pages + inactive_pages + speculative_pages + wired_pages + compressed_pages))
    used_pages=$((active_pages + wired_pages + compressed_pages))
    
    if [ "$total_pages" -le 0 ]; then
        echo "0.0"
        return 0
    fi
    
    local mem_pct
    mem_pct=$(echo "$used_pages * 100 / $total_pages" | bc -l 2>/dev/null | awk '{printf "%.1f", $1}')
    
    echo "$mem_pct"
}

main() {
    local timestamp
    timestamp=$(get_iso_timestamp_utc)
    
    local cpu_usage mem_usage
    cpu_usage=$(get_cpu_usage)
    mem_usage=$(get_mem_usage)
    
    # Evaluate thresholds (float comparison via bc)
    local status="OK"
    local cpu_high=0
    local mem_high=0
    
    if [ "$(echo "$cpu_usage > $CPU_THRESHOLD" | bc -l 2>/dev/null)" -eq 1 ]; then
        cpu_high=1
    fi
    
    if [ "$(echo "$mem_usage > $MEM_THRESHOLD" | bc -l 2>/dev/null)" -eq 1 ]; then
        mem_high=1
    fi
    
    if [ "$cpu_high" -eq 1 ] && [ "$mem_high" -eq 1 ]; then
        status="HIGH_CPU_MEM"
    elif [ "$cpu_high" -eq 1 ]; then
        status="HIGH_CPU"
    elif [ "$mem_high" -eq 1 ]; then
        status="HIGH_MEM"
    else
        status="OK"
    fi
    
    # Print CSV line (stdout)
    # Format: timestamp,cpu_percent,mem_percent,status
    echo "${timestamp},${cpu_usage},${mem_usage},${status}"
    
    # Exit code based on status
    if [ "$status" = "OK" ]; then
        exit 0
    else
        exit 1
    fi
}

main "$@"


