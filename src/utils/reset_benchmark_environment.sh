#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# RESET BENCHMARK ENVIRONMENT
# =============================================================================
# Purpose:
#   "Reset" the execution environment to start a new round of benchmarks,
#   reducing the chance of failures caused by:
#   - leftover containers (Docker / Apple container)
#   - stuck port mappings (e.g., 8080)
#
# Important:
#   This script may stop/remove ALL containers of Docker Desktop and of
#   Apple container on the host. Use with care if you are running other
#   services in containers outside the experiment.
#
# Usage:
#   bash src/utils/reset_benchmark_environment.sh
#
# Flags:
#   --force   Do not ask for confirmation
#   --prune   (Docker) Runs docker system prune -af (removes unused caches/artifacts)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common_output.sh"

enable_tag_output

FORCE=false
PRUNE=false

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --prune) PRUNE=true ;;
    -h|--help)
      echo "Usage: bash src/utils/reset_benchmark_environment.sh [--force] [--prune]"
      exit 0
      ;;
    *)
      print_warning "Unknown argument ignored: ${arg}"
      ;;
  esac
done

print_step "Benchmark environment reset (Docker + Apple container)"
print_important "Warning: this may stop/remove containers that are not part of the experiment."

if [ "$FORCE" != "true" ]; then
  echo ""
  read -r -p "Do you want to continue? (y/N): " reply
  if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
    print_info "Reset cancelled."
    exit 0
  fi
fi

echo ""
print_step "1) Docker Desktop: stop and remove containers"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  running="$(docker ps -q 2>/dev/null || true)"
  if [ -n "$running" ]; then
    print_info "Stopping running containers (Docker)..."
    docker stop $running >/dev/null 2>&1 || true
  else
    print_info "No running containers (Docker)."
  fi

  all_containers="$(docker ps -aq 2>/dev/null || true)"
  if [ -n "$all_containers" ]; then
    print_info "Removing containers (Docker)..."
    docker rm -f $all_containers >/dev/null 2>&1 || true
  else
    print_info "No containers to remove (Docker)."
  fi

  if [ "$PRUNE" = "true" ]; then
    print_warning "Running docker system prune -af (removes unused caches/artifacts)..."
    docker system prune -af >/dev/null 2>&1 || true
  fi

  print_success "Docker: reset complete."
else
  print_warning "Docker is not available/running — skipping Docker reset."
fi

echo ""
print_step "2) Apple container: stop and remove containers"

if command -v container >/dev/null 2>&1; then
  # Note: in some environments the `container ps` subcommand may not be available.
  # We use the --all options, which are supported.
  set +e
  container stop --all >/dev/null 2>&1
  container delete --all --force >/dev/null 2>&1
  set -e
  print_success "Apple container: reset complete."
else
  print_warning "Apple container CLI not found — skipping Apple container reset."
fi

echo ""
print_step "3) Quick HTTP port check (informational)"

if command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
    print_warning "Port 8080 is still in use by a process:"
    lsof -nP -iTCP:8080 -sTCP:LISTEN || true
    print_detail "If necessary, terminate the process above or use HTTP_PORT_STRATEGY=auto (default)."
  else
    print_success "Port 8080 is free."
  fi
else
  print_info "lsof not available — skipping port check."
fi

echo ""
print_success "Environment ready to start a new round of benchmarks."

