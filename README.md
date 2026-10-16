# Docker Desktop or Apple's container? An Empirical Performance Comparison of Container Runtimes on Apple Silicon

Replication package for a performance experiment comparing **Docker Desktop** and **Apple container** (Apple's native container runtime for macOS) on Apple Silicon (M2 Pro).

The methodology follows Raj Jain's framework (*The Art of Computer Systems Performance Analysis*, chs. 3 and 13): 30 iterations + 5 warmup iterations per benchmark, 95% confidence level, ±5% margin of error, and randomized execution order to eliminate systematic bias.

## Hardware and environment

| Item | Specification |
|------|--------------|
| Machine | MacBook Pro M2 Pro |
| Cores | 12 (8 performance + 4 efficiency) |
| RAM | 16 GB |
| OS | macOS (native ARM64) |
| Runtimes | Docker Desktop · Apple container 1.5.0 |

Exact versions of every component are recorded under `docs/system_info/` by `src/utils/collect_system_info.sh` each time the experiment is run.

## Prerequisites

- Docker Desktop and Apple container installed and running
- Python 3 (for statistical analysis)
- Tools via Homebrew: `sysbench`, `wrk`, `fio`, `jq`, `bc`

## Setup

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

Check that the environment is ready before running:

```bash
bash src/utils/verify_experiment_requirements.sh
```

## Running the benchmarks

### Full experiment (recommended)

```bash
bash src/benchmarks/run_experiment.sh
```

The script shows an interactive menu, validates the environment, runs the benchmarks sequentially, and consolidates the results. Terminal output is automatically saved to `logs/`.

### Individual scripts

Each script produces its own results and automatic analysis:

```bash
bash src/benchmarks/run_startup_performance.sh
bash src/benchmarks/run_cpu_performance.sh
bash src/benchmarks/run_memory_performance.sh
bash src/benchmarks/run_http_performance.sh
bash src/benchmarks/run_disk_performance.sh
bash src/benchmarks/run_stream_performance.sh
bash src/benchmarks/run_math_performance.sh
```

**HTTP benchmark:** uses `nginx:stable` on both runtimes (no fallback). Invalid iterations are recorded in `http_server_failures.csv`. The port strategy is `auto` by default (avoids "port in use" conflicts); configure it via `HTTP_PORT`, `HTTP_PORT_STRATEGY`, and `HTTP_PORT_MAX_TRIES`.

**Disk I/O benchmark:** prepares the dataset and starts the container outside the measurement loop. Each iteration measures only `fio` via `exec`, removing setup noise. It uses the local image `bench-fio:alpine-3.19`, built automatically from `src/benchmarks/images/fio/Dockerfile`.

## Analyzing the results

Results are written to `bench_results/<benchmark>_<timestamp>/`. To generate the full statistical analysis:

```bash
python src/analysis/analyze_results_enhanced.py \
  bench_results/<benchmark_dir> \
  --output bench_results/<benchmark_dir>/enhanced_analysis
```

To include the sample-size analysis (Jain, ch. 13):

```bash
python src/analysis/analyze_results_enhanced.py \
  bench_results/<benchmark_dir> \
  --output bench_results/<benchmark_dir>/enhanced_analysis \
  --sample-size
```

The analysis produces CSV and LaTeX tables, comparison plots, a statistical dashboard, normality tests, Mann-Whitney U tests, ANOVA, and multiple-comparison corrections.

## Benchmarks

| # | Benchmark | Tool | Metric |
|---|-----------|------|--------|
| 1 | Startup | native timing | ms (startup time) |
| 2 | CPU | sysbench | ops/s (1 and 2 threads) |
| 3 | Memory | sysbench | MB/s (1 and 2 threads) |
| 4 | HTTP | nginx + wrk | req/s (4 threads, 100 connections) |
| 5 | Disk I/O | fio | KB/s (sequential/random read/write) |
| 6 | STREAM | STREAM benchmark | MB/s (Copy, Scale, Add, Triad — 1 and 2 threads) |
| 7 | Math (π) | bc | digits/s (10,000 digits — 1 and 2 processes) |

All benchmarks apply identical resource limits to both runtimes: 12 CPUs and 8 GB of memory.

## Project structure

```
docker-apple-container-performance/
├── src/
│   ├── benchmarks/          # Benchmark scripts (one per type) + orchestrator
│   │   └── images/          # Dockerfiles for custom images (fio, STREAM)
│   ├── analysis/            # analyze_results_enhanced.py · sample_size_analysis.py
│   └── utils/               # Shared functions, verification, system info collection
├── config/
│   └── experiment_config.yaml   # Protocol parameters (audit trail; not read at runtime)
├── docs/
│   └── system_info/         # Hardware, software, and configuration snapshots (generated)
├── tests/                   # Validation scripts and Python unit tests
├── bench_results/           # Benchmark output (CSV, analysis, plots; generated)
├── requirements.txt         # Python dependencies
└── pyproject.toml           # Project metadata
```

## Tests

```bash
# Validates syntax and presence of ENABLE_RANDOMIZATION (~1 s)
bash tests/test_randomization_syntax.sh

# Functional test without randomization, 2 iterations (~2–5 min)
bash tests/test_no_randomization.sh

# Full functional test, all 7 benchmarks (~5–15 min)
bash tests/test_all_randomization.sh

# Python unit tests
source venv/bin/activate
pytest tests/test_benchmark.py
```

## Results

Results of the experiment are generated by running the steps above; they are not yet included in this repository.

## Authors

Alessandra Pereira and TODO: add remaining authors
