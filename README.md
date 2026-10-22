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
bash src/utils/setup_environment.sh
```

This installs the Homebrew tools (including Apple container if it is not already installed), requires Apple container to be exactly version 1.5.0, creates `venv/`, installs `requirements.txt`, and writes the exact resolved Python package versions to `requirements.lock`. If Homebrew installs a different version than 1.5.0, install that version from the [1.5.0 release](https://github.com/apple/container/releases/tag/1.5.0) instead. Before the first run, start the container system once with `container system start`.

The base images are pinned by digest in `config/image_pins.sh` (`alpine:3.24`, `nginx:1.30.6`); `setup_environment.sh` pulls them by digest and `verify_experiment_requirements.sh` checks the digests. The benchmark images are built from `src/benchmarks/images/` (fio, STREAM, sysbench). The STREAM source (`stream.c`, v5.10) is vendored in the repository, so no network access is needed at run time. Image digests are recorded in `docs/system_info/image_digests.md`.

Check that the environment is ready before running:

```bash
bash src/utils/verify_experiment_requirements.sh
```

Setup choices that affect replicability (pinned images, vendored STREAM source, image transfer) are described in [`docs/methodology_notes.md`](docs/methodology_notes.md).

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

**HTTP benchmark:** uses `nginx:1.30.6` on both runtimes (no fallback). Invalid iterations are recorded in `http_server_failures.csv`. The port strategy is `auto` by default (avoids "port in use" conflicts); configure it via `HTTP_PORT`, `HTTP_PORT_STRATEGY`, and `HTTP_PORT_MAX_TRIES`.

**Disk I/O benchmark:** prepares the dataset and starts the container outside the measurement loop. Each iteration measures only `fio` via `exec`, removing setup noise. It uses the local image `bench-fio:alpine-3.24`, built automatically from `src/benchmarks/images/fio/Dockerfile`.

## Analyzing the results

Results are written to `bench_results/<benchmark>_<timestamp>/`.

**Per-benchmark analysis (automatic).** Every benchmark script runs the statistical analysis when it finishes and writes it to `bench_results/<benchmark>_<timestamp>/enhanced_analysis/`: CSV and LaTeX tables, comparison plots, a statistical dashboard, normality tests, Mann-Whitney U tests, ANOVA, and multiple-comparison corrections. You do not need to run anything for this. To re-generate it manually (for example after changing the analysis, or to add the sample-size analysis of Jain, ch. 13):

```bash
python src/analysis/analyze_results_enhanced.py \
  bench_results/<benchmark_dir> \
  --output bench_results/<benchmark_dir>/enhanced_analysis \
  --sample-size        # optional
```

**Combined analysis (one extra step after the full experiment).** The analysis script reads a single directory with fixed file names, so the seven benchmark folders have to be merged first (CPU and memory both write `results_sysbench.csv`). This script does it and then analyzes all benchmarks in one run, producing a single set of tables, plots and one report (multiple-comparison corrections are applied within each benchmark, as in the per-benchmark analyses):

```bash
bash src/utils/build_combined_analysis.sh                 # uses the most recent folder of each benchmark
bash src/utils/build_combined_analysis.sh --sample-size   # also the sample-size analysis
bash src/utils/build_combined_analysis.sh --http bench_results/http_performance_<timestamp> ...   # pick folders explicitly
```

It refuses to run if any folder has fewer than 30 valid iterations in its summary (`MIN_VALID` to change). The merged input CSVs go to `bench_results/combined/`, and the analysis (tables, plots, reports) to `bench_results/enhanced_analysis/`, together with `SOURCES.txt`, which lists the source folders and the repository commit. Use `--output` and `--analysis-output` to change these locations.

## Benchmarks

| # | Benchmark | Tool | Metric |
|---|-----------|------|--------|
| 1 | Startup | native timing | ms (startup time) |
| 2 | CPU | sysbench | ops/s (1 and 2 threads) |
| 3 | Memory | sysbench | MB/s (1 and 2 threads) |
| 4 | HTTP | nginx + wrk | req/s (4 threads, 100 connections) |
| 5 | Disk I/O | fio | KB/s (sequential/random read/write) |
| 6 | STREAM | STREAM benchmark | MB/s (Copy, Scale, Add, Triad — 1 and 2 threads) |
| 7 | Math (π) | bc | aggregate digits/s (10,000 digits per process — 1 and 2 parallel processes) |

All benchmarks apply identical resource limits to both runtimes: 12 CPUs and 8 GB of memory.

## Project structure

```
docker-apple-container-performance/
├── src/
│   ├── benchmarks/          # Benchmark scripts (one per type) + orchestrator
│   │   └── images/          # Dockerfiles for custom images (fio, STREAM + vendored stream.c, sysbench)
│   ├── analysis/            # analyze_results_enhanced.py · sample_size_analysis.py
│   └── utils/               # Shared functions, verification, system info collection
├── config/
│   └── experiment_config.yaml   # Protocol parameters (audit trail; not read at runtime)
├── docs/
│   └── system_info/         # Hardware, software, and configuration snapshots (generated)
├── tests/                   # Validation scripts and Python unit tests
├── bench_results/           # Benchmark output (CSV, analysis, plots; generated); combined/ holds the merged inputs and enhanced_analysis/ the combined analysis
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

## Results (2026-10-20/21)

Run with n = 30 valid iterations per benchmark (Apple container 1.5.0, Docker Desktop 4.95.0). Summary of findings; full statistics are in `bench_results/enhanced_analysis/`. A first full round (2026-10-19/20, kept in `bench_results/round1/`) is a replication: 38 of the 40 runtime × scenario means agree within 2.1% between the two rounds.

| Benchmark | Winner | Difference |
|-----------|--------|------------|
| Startup | Docker | ~5.2× faster (~148 ms vs ~765 ms) |
| CPU | Apple container | marginal (+0.2–0.4%) |
| Memory | Apple container | +0.5% (1 thread), +8.1% (2 threads, high variance in Docker) |
| HTTP | Apple container | +25.0% req/s (62,310 vs 49,843) |
| Disk I/O | Docker | 36–232% faster (higher variance in Apple container) |
| STREAM | Docker | +1.8–5.0% (1 thread); Triad +1.9%, other operations equivalent (2 threads) |
| Math (π) | Apple container | marginal (0.4% faster) |

## Authors

Alessandra Pereira, Carlos Zimmerle, and Kiev Gama.
