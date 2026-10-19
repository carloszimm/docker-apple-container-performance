# Methodology notes

This document describes how the experiment is set up so that it can be replicated. The exact
versions used in a given run are recorded automatically under `docs/system_info/` by
`src/utils/collect_system_info.sh`.

## Runtimes under test

| Runtime | Version requirement |
|---------|--------------------|
| Docker Desktop | Any recent release; the exact version is recorded in `docs/system_info/` |
| Apple container | 1.5.0, enforced by `src/utils/setup_environment.sh` |

Results are only comparable across runs that use the same runtime versions, so the setup script
fails if the installed Apple container version differs from the expected one.

## Workload images

Both runtimes run the same `linux/arm64` images on the same host.

- **Base images are pinned by digest.** `config/image_pins.sh` is the single source of truth for
  the `alpine:3.24` and `nginx:1.30.6` digests. `setup_environment.sh` pulls each image by digest
  and tags it locally with the name the benchmark scripts use, and
  `verify_experiment_requirements.sh` fails if a tag does not match its pinned digest. Tags alone
  can move (patch releases and base-image rebuilds are published under the same tag), so the
  digest is what fixes the image contents.
- **Benchmark images are built from the repository.** `src/benchmarks/images/` contains the
  Dockerfiles for the fio, STREAM, and sysbench images, all built `FROM` the pinned Alpine digest.
  The toolchain is installed at build time so that no package installation occurs inside the
  measurement loops.
- **Package versions.** The Alpine package versions used by the images are listed in
  `docs/image_packages.md`.
- **STREAM source is vendored.** `src/benchmarks/images/stream/stream.c` (STREAM v5.10, from
  jeffhammond/STREAM commit `4dbce1d0fdb7410e8f21b48f3381bc0a1341967f`; checksum in
  `stream.c.sha256`) is copied into the image at build time. The benchmark never downloads source
  code, so the toolchain image needs neither `wget` nor CA certificates, and runs do not depend on
  network access or on a remote file staying unchanged.

## Image transfer to Apple container

Images are built or pulled with Docker and then transferred to Apple container with
`docker save --platform linux/arm64 | container image load`.

- Only the `linux/arm64` variant is exported. Docker Desktop's containerd image store writes
  multi-platform archives that `container image load` cannot read (it fails with a
  `missingContent` error), and the other platforms are never run on this host anyway.
- As a consequence, the digest Apple container reports for an image is that of the single arm64
  manifest, not of the multi-platform index that Docker reports. The digests therefore differ by
  construction even though the image content (layers) is the same.
- Transfers happen during setup and image preparation, outside every measured interval.

## Resource limits

Every benchmark applies identical limits on both runtimes: 12 CPUs and 8 GB of memory.

## Python analysis environment

The Python dependencies are listed in `requirements.txt`, and the exact resolved versions used for
the analysis are committed in `requirements.lock`.

## Math benchmark

The "Math (π)" benchmark computes π with `bc` (installed inside the container at run time), not with
a dedicated benchmark suite. Its result files are named `*_pi_*.csv`.
