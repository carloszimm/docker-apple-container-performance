#!/usr/bin/env bash
# Builds a combined dataset from the seven benchmark result folders and runs the statistical
# analysis over all of it at once (multiple-comparison corrections then span every benchmark).
#
# analyze_results_enhanced.py reads ONE directory containing fixed file names
# (results_main.csv, results_sysbench.csv, results_wrk.csv, results_fio.csv, results_stream.csv,
# results_math.csv). Each benchmark folder only holds its own file, and the CPU and memory
# benchmarks both write results_sysbench.csv, so the folders have to be merged first.
#
# Usage:
#   bash src/utils/build_combined_analysis.sh [options]
#
# Options (each folder defaults to the most recent bench_results/<name>_performance_*):
#   --startup DIR --cpu DIR --memory DIR --http DIR --disk DIR --stream DIR --math DIR
#   --output DIR      Directory for the merged input CSVs (default: bench_results/combined)
#   --analysis-output DIR
#                     Directory for the analysis results (default: bench_results/enhanced_analysis)
#   --sample-size     Also run the sample-size analysis (Raj Jain, Ch. 13)
#
# Environment:
#   MIN_VALID  Minimum valid iterations required in every summary row (default: 30)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/common_output.sh"
cd "$REPO_ROOT"

MIN_VALID="${MIN_VALID:-30}"
OUTPUT_DIR="bench_results/combined"
ANALYSIS_DIR="bench_results/enhanced_analysis"
SAMPLE_SIZE=""
# Per-benchmark folders are kept in DIR_<name> variables (macOS ships bash 3.2: no associative arrays)
DIR_startup=""; DIR_cpu=""; DIR_memory=""; DIR_http=""; DIR_disk=""; DIR_stream=""; DIR_math=""

while [ $# -gt 0 ]; do
    case "$1" in
        --startup|--cpu|--memory|--http|--disk|--stream|--math)
            printf -v "DIR_${1#--}" '%s' "${2%/}"; shift 2 ;;
        --output) OUTPUT_DIR="${2%/}"; shift 2 ;;
        --analysis-output) ANALYSIS_DIR="${2%/}"; shift 2 ;;
        --sample-size) SAMPLE_SIZE="--sample-size"; shift ;;
        -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

# benchmark | results file | summary file
BENCHMARKS=(
    "startup|results_main.csv|startup_performance_summary.csv"
    "cpu|results_sysbench.csv|cpu_performance_summary.csv"
    "memory|results_sysbench.csv|memory_performance_summary.csv"
    "http|results_wrk.csv|http_performance_summary.csv"
    "disk|results_fio.csv|disk_performance_summary.csv"
    "stream|results_stream.csv|stream_performance_summary.csv"
    "math|results_math.csv|math_performance_summary.csv"
)

print_step "Selecting and validating benchmark folders"
for entry in "${BENCHMARKS[@]}"; do
    IFS='|' read -r name results summary <<< "$entry"

    dirvar="DIR_${name}"
    if [ -z "${!dirvar}" ]; then
        # Folder names end in a sortable timestamp: the last one is the most recent
        latest="$(ls -d bench_results/${name}_performance_* 2>/dev/null | sort | tail -n 1 || true)"
        if [ -z "$latest" ]; then
            print_error "No bench_results/${name}_performance_* folder found (use --${name} DIR)"
            exit 1
        fi
        printf -v "$dirvar" '%s' "${latest%/}"
    fi
    dir="${!dirvar}"

    for f in "$results" "$summary"; do
        if [ ! -s "$dir/$f" ]; then
            print_error "${name}: missing or empty $dir/$f"
            exit 1
        fi
    done

    # Every row of the summary must reach MIN_VALID valid iterations
    bad=$(awk -F, -v min="$MIN_VALID" '
        NR==1 { for (i=1;i<=NF;i++) if ($i=="valid_iterations") col=i; next }
        col && $col+0 < min { print $0 }' "$dir/$summary")
    if ! head -n 1 "$dir/$summary" | grep -q "valid_iterations"; then
        print_error "${name}: no valid_iterations column in $dir/$summary"
        exit 1
    fi
    if [ -n "$bad" ]; then
        print_error "${name}: fewer than ${MIN_VALID} valid iterations in $dir/$summary:"
        echo "$bad" | sed 's/^/    /'
        exit 1
    fi
    print_success "${name}: $dir"
done

print_step "Building combined dataset in ${OUTPUT_DIR}"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

cp "${DIR_startup}/results_main.csv"  "$OUTPUT_DIR/results_main.csv"
cp "${DIR_http}/results_wrk.csv"      "$OUTPUT_DIR/results_wrk.csv"
cp "${DIR_disk}/results_fio.csv"      "$OUTPUT_DIR/results_fio.csv"
cp "${DIR_stream}/results_stream.csv" "$OUTPUT_DIR/results_stream.csv"
cp "${DIR_math}/results_math.csv"     "$OUTPUT_DIR/results_math.csv"

# CPU and memory both produce results_sysbench.csv: concatenate (header once)
cpu_header="$(head -n 1 "${DIR_cpu}/results_sysbench.csv")"
mem_header="$(head -n 1 "${DIR_memory}/results_sysbench.csv")"
if [ "$cpu_header" != "$mem_header" ]; then
    print_error "CPU and memory results_sysbench.csv have different headers; cannot merge"
    exit 1
fi
{
    echo "$cpu_header"
    tail -n +2 "${DIR_cpu}/results_sysbench.csv"
    tail -n +2 "${DIR_memory}/results_sysbench.csv"
} > "$OUTPUT_DIR/results_sysbench.csv"

# Provenance: which folders went into this analysis
{
    echo "Combined dataset built on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "Repository commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
    for entry in "${BENCHMARKS[@]}"; do
        IFS='|' read -r name _ _ <<< "$entry"
        dirvar="DIR_${name}"
        echo "${name}: ${!dirvar}"
    done
} > "$OUTPUT_DIR/SOURCES.txt"

print_step "Running the statistical analysis"
if [ -x venv/bin/python ] && venv/bin/python -c "import pandas" 2>/dev/null; then
    PY="venv/bin/python"
elif command -v python3 >/dev/null 2>&1 && python3 -c "import pandas" 2>/dev/null; then
    PY="python3"
else
    print_error "Python with pandas not found. Run: bash src/utils/setup_environment.sh"
    exit 1
fi

"$PY" src/analysis/analyze_results_enhanced.py "$OUTPUT_DIR" --output "$ANALYSIS_DIR" ${SAMPLE_SIZE}
cp "$OUTPUT_DIR/SOURCES.txt" "$ANALYSIS_DIR/SOURCES.txt"

print_success "Combined analysis written to ${ANALYSIS_DIR} (input CSVs: ${OUTPUT_DIR}; sources: ${ANALYSIS_DIR}/SOURCES.txt)"
