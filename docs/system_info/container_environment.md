# Internal Container Environment

## Important Note

The benchmarks are executed **INSIDE** the containers. This document describes the internal environment where the benchmarks run.

## Alpine Linux (Base Image)

### Docker Container

```bash
NAME="Alpine Linux"
ID=alpine
VERSION_ID=3.24.2
PRETTY_NAME="Alpine Linux v3.24"
HOME_URL="https://alpinelinux.org/"
BUG_REPORT_URL="https://gitlab.alpinelinux.org/alpine/aports/-/issues"

Linux 5393f2695c85 7.0.14-linuxkit #1 SMP PREEMPT Sun Sep 20 16:14:09 UTC 2026 aarch64 Linux
```

### Apple container

```bash
NAME="Alpine Linux"
ID=alpine
VERSION_ID=3.24.2
PRETTY_NAME="Alpine Linux v3.24"
HOME_URL="https://alpinelinux.org/"
BUG_REPORT_URL="https://gitlab.alpinelinux.org/alpine/aports/-/issues"

Linux bd4689b8-e9bb-4812-b2c0-9eec73085888 6.18.35 #1 SMP Mon Jun 15 12:55:27 UTC 2026 aarch64 Linux
```

## Benchmark Tools in the Containers

### sysbench

**Note:** sysbench is installed dynamically inside alpine:3.24 during benchmark execution.

**Docker (installed dynamically):**
  - sysbench 1.0.20

**Apple container (installed dynamically):**
  - sysbench 1.0.20

### Nginx

**Docker:**
  - /docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
  - /docker-entrypoint.sh: Looking for shell scripts in /docker-entrypoint.d/
  - /docker-entrypoint.sh: Launching /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh
  - 10-listen-on-ipv6-by-default.sh: info: Getting the checksum of /etc/nginx/conf.d/default.conf
  - 10-listen-on-ipv6-by-default.sh: info: Enabled listen on IPv6 in /etc/nginx/conf.d/default.conf
  - /docker-entrypoint.sh: Sourcing /docker-entrypoint.d/15-local-resolvers.envsh
  - /docker-entrypoint.sh: Launching /docker-entrypoint.d/20-envsubst-on-templates.sh
  - /docker-entrypoint.sh: Launching /docker-entrypoint.d/30-tune-worker-processes.sh
  - /docker-entrypoint.sh: Configuration complete; ready for start up
  - nginx version: nginx/1.30.6

**Apple container:**
  - [0/6] [0s]
  - [1/6] Fetching image [0s]
  - [2/6] Unpacking image [0s]
  - [3/6] Fetching kernel [0s]
  - [4/6] Fetching init image [0s]
  - [5/6] Unpacking init image [0s]
  - [6/6] Starting container [0s]
  - [6/6] Starting container [0s]
  - /docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
  - /docker-entrypoint.sh: Looking for shell scripts in /docker-entrypoint.d/
  - /docker-entrypoint.sh: Launching /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh
  - 10-listen-on-ipv6-by-default.sh: info: Getting the checksum of /etc/nginx/conf.d/default.conf
  - 10-listen-on-ipv6-by-default.sh: info: Enabled listen on IPv6 in /etc/nginx/conf.d/default.conf
  - /docker-entrypoint.sh: Sourcing /docker-entrypoint.d/15-local-resolvers.envsh
  - /docker-entrypoint.sh: Launching /docker-entrypoint.d/20-envsubst-on-templates.sh
  - /docker-entrypoint.sh: Launching /docker-entrypoint.d/30-tune-worker-processes.sh
  - /docker-entrypoint.sh: Configuration complete; ready for start up
  - nginx version: nginx/1.30.6

