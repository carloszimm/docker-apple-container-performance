#!/bin/bash

# Rosetta Check Script
# Developed for the Docker vs Apple container benchmark experiment
# Ensures that Rosetta is not interfering with the performance tests

echo "=== Rosetta Check ==="
echo "Date: $(date)"
echo ""

echo "1. Rosetta Status:"
if arch -x86_64 /usr/bin/true 2>/dev/null; then
    echo "❌ Rosetta ACTIVE - May affect benchmark performance"
    echo "   Recommendation: Disable Rosetta in Docker Desktop"
    ROSETTA_ACTIVE=true
else
    echo "✅ Rosetta INACTIVE - Ideal for benchmarking"
    ROSETTA_ACTIVE=false
fi
echo ""

echo "2. Rosetta Processes:"
ROSETTA_PROCS=$(ps aux | grep -i rosetta | grep -v grep | wc -l)
if [ $ROSETTA_PROCS -gt 0 ]; then
    echo "❌ $ROSETTA_PROCS Rosetta process(es) found:"
    ps aux | grep -i rosetta | grep -v grep
else
    echo "✅ No active Rosetta process"
fi
echo ""

echo "3. Docker Status:"
if docker version >/dev/null 2>&1; then
    DOCKER_ARCH=$(docker version --format '{{.Server.Arch}}' 2>/dev/null)
    echo "✅ Docker running - Architecture: $DOCKER_ARCH"
    if [ "$DOCKER_ARCH" = "x86_64" ]; then
        echo "⚠️  Docker is using x86_64 (possibly via Rosetta)"
    elif [ "$DOCKER_ARCH" = "arm64" ]; then
        echo "✅ Docker is using native ARM64"
        
        # Additional check: test a real container
        echo "   Testing native ARM64 container..."
        if CONTAINER_ARCH=$(docker run --rm alpine:3.24 uname -m 2>/dev/null); then
            if [ "$CONTAINER_ARCH" = "aarch64" ]; then
                echo "✅ Docker containers running natively on ARM64"
            elif [ "$CONTAINER_ARCH" = "x86_64" ]; then
                echo "❌ Docker containers using x86_64 emulation"
            else
                echo "⚠️  Could not verify container architecture"
            fi
        else
            echo "❌ Failed to run Docker container - Docker daemon may not be running"
        fi
    fi
else
    echo "❌ Docker is not running"
fi
echo ""

echo "4. Apple container Status:"
if command -v container >/dev/null 2>&1; then
    CONTAINER_VERSION=$(container --version 2>/dev/null)
    echo "✅ Apple container available: $CONTAINER_VERSION"
else
    echo "❌ Apple container not found"
fi
echo ""

echo "5. Recommendations:"
if [ "$ROSETTA_ACTIVE" = true ]; then
    # Check whether Docker is running natively
    if docker version >/dev/null 2>&1; then
        DOCKER_ARCH=$(docker version --format '{{.Server.Arch}}' 2>/dev/null)
        if [ "$DOCKER_ARCH" = "arm64" ]; then
            if CONTAINER_ARCH=$(docker run --rm alpine:3.24 uname -m 2>/dev/null); then
                if [ "$CONTAINER_ARCH" = "aarch64" ]; then
                    echo "✅ DOCKER RUNNING NATIVELY ON ARM64"
                    echo "   Active Rosetta will not affect the Docker benchmark."
                    echo "   You can proceed safely."
                    echo ""
                    echo "💡 Rosetta is active for other system processes,"
                    echo "   but Docker is using native ARM64 (ideal)."
                else
                    echo "❌ Docker using x86_64 emulation - REAL PROBLEM"
                    echo "🔧 To disable Rosetta:"
                    echo "   1. Docker Desktop → Settings → Virtualization"
                    echo "   2. Uncheck 'Use Rosetta for x86/amd64 emulation'"
                    echo "   3. Apply & Restart Docker Desktop"
                fi
            else
                echo "❌ Failed to test Docker container - Docker daemon may not be running"
                echo "🔧 Start Docker Desktop first"
            fi
        else
            echo "❌ Docker using x86_64 - REAL PROBLEM"
            echo "🔧 To disable Rosetta:"
            echo "   1. Docker Desktop → Settings → Virtualization"
            echo "   2. Uncheck 'Use Rosetta for x86/amd64 emulation'"
            echo "   3. Apply & Restart Docker Desktop"
        fi
    else
        echo "❌ Docker is not running"
        echo "🔧 Start Docker Desktop first"
    fi
    echo ""
    echo "⚠️  IMPORTANT: If Docker is using native ARM64,"
    echo "    active Rosetta will not affect the benchmark results."
else
    echo "✅ System correctly configured for benchmarking"
    echo "   You can proceed with running the tests."
fi
echo ""

echo "6. Quick Check Commands:"
echo "   Check Rosetta: arch -x86_64 /usr/bin/true && echo 'Active' || echo 'Inactive'"
echo "   View Docker: docker version --format '{{.Server.Arch}}'"
echo "   View processes: ps aux | grep -i rosetta | grep -v grep"
echo ""

# Return exit code based on the actual Docker status
if [ "$ROSETTA_ACTIVE" = true ]; then
    if docker version >/dev/null 2>&1; then
        DOCKER_ARCH=$(docker version --format '{{.Server.Arch}}' 2>/dev/null)
        if [ "$DOCKER_ARCH" = "arm64" ]; then
            if CONTAINER_ARCH=$(docker run --rm alpine:3.24 uname -m 2>/dev/null); then
                if [ "$CONTAINER_ARCH" = "aarch64" ]; then
                    echo "✅ System ready for benchmarking (native ARM64 Docker)"
                    exit 0
                else
                    echo "❌ Docker using x86_64 emulation - Real problem"
                    exit 1
                fi
            else
                echo "❌ Failed to test Docker container - Docker daemon is not running"
                exit 1
            fi
        else
            echo "❌ Docker using x86_64 - Real problem"
            exit 1
        fi
    else
        echo "❌ Docker is not running"
        exit 1
    fi
else
    echo "✅ System ready for benchmarking"
    exit 0
fi
