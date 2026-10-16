#!/usr/bin/env bash
# Prepares the host for the experiment:
#   1. Installs the Homebrew benchmark tools (sysbench, wrk, fio, jq)
#   2. Checks the Apple container CLI version (EXPECTED_CONTAINER_VERSION)
#   3. Creates ./venv and installs requirements.txt
#   4. Records the exact resolved Python package versions in requirements.lock
#
# Usage: bash src/utils/setup_environment.sh
set -euo pipefail

missing=0

EXPECTED_CONTAINER_VERSION="1.5.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

echo "==> Homebrew tools"
if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew not found: https://brew.sh" >&2
    exit 1
fi
# bc is provided by macOS (/usr/bin/bc); the Homebrew bc is keg-only and not needed
brew install sysbench wrk fio jq

echo "==> Docker Desktop"
if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop/" >&2
    missing=1
else
    docker --version
fi

echo "==> Apple container (expected ${EXPECTED_CONTAINER_VERSION})"
if ! command -v container >/dev/null 2>&1; then
    echo "container CLI not found. Install release ${EXPECTED_CONTAINER_VERSION} from" >&2
    echo "  https://github.com/apple/container/releases/tag/${EXPECTED_CONTAINER_VERSION}" >&2
    missing=1
else
    installed="$(container --version)"
    echo "$installed"
    case "$installed" in
        *"${EXPECTED_CONTAINER_VERSION}"*) ;;
        *)
            echo "WARNING: expected container ${EXPECTED_CONTAINER_VERSION}; results are only comparable" >&2
            echo "         across runs with the same version." >&2
            ;;
    esac
fi

echo "==> Python environment"
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
pip freeze > requirements.lock
echo "Resolved versions written to requirements.lock (commit it alongside the results)."

if [ "$missing" -ne 0 ]; then
    echo "==> Finished with missing runtimes (see above). Install them and re-run this script." >&2
    exit 1
fi
echo "==> Done. Next: bash src/utils/verify_experiment_requirements.sh"
