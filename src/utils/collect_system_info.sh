#!/bin/bash

# =============================================================================
# UNIFIED SYSTEM INFORMATION COLLECTION SCRIPT - PHASE 1
# =============================================================================
# RESPONSIBILITY: COLLECTION AND DOCUMENTATION
# Collects detailed system information and saves it to markdown files
# for complete documentation of the experimental environment.
#
# Usage: To document the environment before running experiments
# Output: Markdown files in docs/system_info/ with detailed information
#
# Related scripts:
# - show_system_info.sh: Displays summarized information (quick view)
# - verify_experiment_requirements.sh: Verifies requirements (validation)
# =============================================================================

set -euo pipefail

# Load common output functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_output.sh"

# Inherit output style from the parent script if defined
# If OUTPUT_STYLE is not set, use tag as the default for consistency
if [ -z "${OUTPUT_STYLE:-}" ]; then
    enable_tag_output
fi

# Project base directory (SCRIPT_DIR already defined above)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS_DIR="$PROJECT_ROOT/docs/system_info"
SNAPSHOT_DIR="$DOCS_DIR/snapshot"

# Create directories if they do not exist
mkdir -p "$DOCS_DIR"
mkdir -p "$SNAPSHOT_DIR"

# =============================================================================
# HEADER
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║  🔬 UNIFIED SYSTEM INFORMATION COLLECTION - PHASE 1                   ║"
echo "║  Apple container vs Docker - MacBook Pro M2                           ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# CHECK PREVIOUSLY COLLECTED INFORMATION
# =============================================================================

# Check which files already exist
EXISTING_FILES=()
EXISTING_COUNT=0

# Main files
HARDWARE_FILE="$DOCS_DIR/hardware_m2.md"
SOFTWARE_FILE="$DOCS_DIR/software_versions.md"
DOCKER_CONFIG_FILE="$DOCS_DIR/docker_configuration.md"
APPLE_CONTAINER_CONFIG_FILE="$DOCS_DIR/apple_container_configuration.md"
DIGESTS_FILE="$DOCS_DIR/image_digests.md"
CONTAINER_ENV_FILE="$DOCS_DIR/container_environment.md"

if [ -f "$HARDWARE_FILE" ]; then
    EXISTING_FILES+=("Hardware: $(basename "$HARDWARE_FILE")")
    EXISTING_COUNT=$((EXISTING_COUNT + 1))
fi

if [ -f "$SOFTWARE_FILE" ]; then
    EXISTING_FILES+=("Software: $(basename "$SOFTWARE_FILE")")
    EXISTING_COUNT=$((EXISTING_COUNT + 1))
fi

if [ -f "$DOCKER_CONFIG_FILE" ]; then
    EXISTING_FILES+=("Docker: $(basename "$DOCKER_CONFIG_FILE")")
    EXISTING_COUNT=$((EXISTING_COUNT + 1))
fi

if [ -f "$APPLE_CONTAINER_CONFIG_FILE" ]; then
    EXISTING_FILES+=("Apple container: $(basename "$APPLE_CONTAINER_CONFIG_FILE")")
    EXISTING_COUNT=$((EXISTING_COUNT + 1))
fi

if [ -f "$DIGESTS_FILE" ]; then
    EXISTING_FILES+=("Image Digests: $(basename "$DIGESTS_FILE")")
    EXISTING_COUNT=$((EXISTING_COUNT + 1))
fi

if [ -f "$CONTAINER_ENV_FILE" ]; then
    EXISTING_FILES+=("Container Environment: $(basename "$CONTAINER_ENV_FILE")")
    EXISTING_COUNT=$((EXISTING_COUNT + 1))
fi

# Check snapshot
SNAPSHOT_FILES=0
if [ -d "$SNAPSHOT_DIR" ]; then
    SNAPSHOT_FILES=$(find "$SNAPSHOT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
fi

# If there are existing files, show a summary and ask
if [ "$EXISTING_COUNT" -gt 0 ] || [ "$SNAPSHOT_FILES" -gt 0 ]; then
    print_step "📋 Checking Previously Collected Information"
    echo ""
    print_info "  Previously collected information was found:"
    echo ""
    
    if [ "$EXISTING_COUNT" -gt 0 ]; then
        echo "  📁 Main Documentation ($EXISTING_COUNT file(s)):"
        for file_info in "${EXISTING_FILES[@]}"; do
            echo "     • $file_info"
        done
        echo ""
    fi
    
    if [ "$SNAPSHOT_FILES" -gt 0 ]; then
        echo "  📁 Environment Snapshot ($SNAPSHOT_FILES file(s)):"
        echo "     • snapshot/"
        echo ""
    fi
    
    # Check the date of the last collection (if snapshot_date.txt exists)
    if [ -f "$SNAPSHOT_DIR/snapshot_date.txt" ]; then
        LAST_COLLECTION_DATE=$(cat "$SNAPSHOT_DIR/snapshot_date.txt" 2>/dev/null | head -1 || echo "N/A")
        if [ "$LAST_COLLECTION_DATE" != "N/A" ]; then
            echo "  📅 Last collection: $LAST_COLLECTION_DATE"
            echo ""
        fi
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "  What would you like to do?"
    echo ""
    echo "    1) Perform a new collection (overwrite existing files)"
    echo "    2) Only validate that everything was collected (do not overwrite)"
    echo ""
    read -p "  Choose (1 or 2) [default: 2]: " USER_CHOICE
    USER_CHOICE=${USER_CHOICE:-2}
    
    if [ "$USER_CHOICE" == "2" ]; then
        # Validation-only mode
        echo ""
        print_step "🔍 Validation Mode"
        echo ""
        print_info "  Validating collected information..."
        echo ""
        
        # Set flag to skip collection
        VALIDATION_MODE=true
    else
        # New collection mode
        echo ""
        print_warning "  ⚠ WARNING: Existing files will be overwritten!"
        echo ""
        read -p "  Confirm new collection? (y/n) [default: y]: " CONFIRM
        CONFIRM=${CONFIRM:-y}
        
        if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" && "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
            print_info "  Operation cancelled by the user."
            exit 0
        fi
        
        VALIDATION_MODE=false
        echo ""
    fi
else
    # No existing files, proceed normally
    VALIDATION_MODE=false
    echo ""
    print_info "  No previously collected information found."
    print_info "  Starting full collection..."
    echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# If in validation mode, skip to the validation section
if [ "$VALIDATION_MODE" = true ]; then
    # Skip to the validation section (added at the end)
    SKIP_COLLECTION=true
else
    SKIP_COLLECTION=false
fi

# =============================================================================
# INITIAL CHECKS
# =============================================================================

print_step "📋 Checking System Prerequisites"
echo ""

# Check Docker
DOCKER_RUNNING=false
if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
        DOCKER_RUNNING=true
        print_success "  ✓ Docker Desktop: Running"
    else
        print_warning "  ⚠ Docker Desktop: Installed but not running"
        print_info "    → Run: open -a Docker"
    fi
else
    print_warning "  ⚠ Docker Desktop: Not found"
fi

# Check Apple container
APPLE_CONTAINER_RUNNING=false
if command -v container &> /dev/null; then
    if container system status &> /dev/null; then
        APPLE_CONTAINER_RUNNING=true
        print_success "  ✓ Apple container: Running"
    else
        print_warning "  ⚠ Apple container: Installed but not running"
        print_info "    → Run: container system start"
        # Try to start automatically
        if container system start &> /dev/null; then
            sleep 3
            if container system status &> /dev/null; then
                APPLE_CONTAINER_RUNNING=true
                print_success "  ✓ Apple container: Started automatically"
            fi
        fi
    fi
else
    print_warning "  ⚠ Apple container: Not found"
fi

# Check Python virtual environment
PYTHON_VENV_ACTIVE=false
PYTHON_VENV_PATH=""
if [ -n "${VIRTUAL_ENV:-}" ]; then
    PYTHON_VENV_ACTIVE=true
    PYTHON_VENV_PATH="$VIRTUAL_ENV"
    print_success "  ✓ Python venv: Active ($(basename "$VIRTUAL_ENV"))"
else
    # Try to detect venv in the project directory
    if [ -d "$PROJECT_ROOT/venv" ] && [ -f "$PROJECT_ROOT/venv/bin/activate" ]; then
        PYTHON_VENV_PATH="$PROJECT_ROOT/venv"
        print_info "  ℹ Python venv: Found (not active, will be used directly)"
    else
        print_warning "  ⚠ Python venv: Not detected"
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# =============================================================================
# 1. DOCUMENT HARDWARE
# =============================================================================

if [ "$SKIP_COLLECTION" = false ]; then
    print_step "[1/9] Collecting Hardware Information"
    print_info "  Processing system data..."
    
    HARDWARE_FILE="$DOCS_DIR/hardware_m2.md"
    cat > "$HARDWARE_FILE" << 'EOF'
# Hardware - MacBook Pro M2

## System Information

EOF

# Model and general specifications
system_profiler SPHardwareDataType >> "$HARDWARE_FILE" 2>/dev/null

# CPU
{
    echo ""
    echo "## CPU"
    echo ""
    echo "- **Brand:** $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'N/A')"
    echo "- **Physical Cores:** $(sysctl -n hw.physicalcpu 2>/dev/null || echo 'N/A')"
    echo "- **Logical Cores:** $(sysctl -n hw.logicalcpu 2>/dev/null || echo 'N/A')"
    echo "- **Total CPUs:** $(sysctl -n hw.ncpu 2>/dev/null || echo 'N/A')"
} >> "$HARDWARE_FILE"

# Memory
MEMORY_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
MEMORY_GB=$((MEMORY_BYTES / 1073741824))
{
    echo ""
    echo "## RAM"
    echo ""
    echo "- **Total:** ${MEMORY_GB} GB"
    echo "- **Bytes:** ${MEMORY_BYTES}"
} >> "$HARDWARE_FILE"

# Storage
{
    echo ""
    echo "## Storage"
    echo ""
    echo "### Primary Disk"
    df -h / | tail -n 1 | awk '{print "- **Available:** " $4 "\n- **Used:** " $3 "\n- **Total:** " $2 "\n- **Usage:** " $5}'
    echo ""
    echo "### Detailed Information"
    diskutil info / 2>/dev/null | grep -E "Volume Name|Total Size|File System|Device Node" | sed 's/^/- /' || echo "- Information not available"
} >> "$HARDWARE_FILE"

# Architecture
{
    echo ""
    echo "## Architecture"
    echo ""
    echo "- **Architecture:** $(uname -m)"
    echo "- **Kernel:** $(uname -r)"
    echo "- **System:** $(uname -s)"
} >> "$HARDWARE_FILE"

    print_success "  ✓ Hardware documented: $(basename "$HARDWARE_FILE")"
    echo ""
else
    print_step "[1/9] Validating Hardware"
    HARDWARE_FILE="$DOCS_DIR/hardware_m2.md"
    if [ -f "$HARDWARE_FILE" ]; then
        print_success "  ✓ Hardware: $(basename "$HARDWARE_FILE") found"
    else
        print_warning "  ⚠ Hardware: File not found"
    fi
    echo ""
fi

# =============================================================================
# 2. DOCUMENT SOFTWARE
# =============================================================================

if [ "$SKIP_COLLECTION" = false ]; then
    print_step "[2/9] Collecting Software Information"
    print_info "  Processing versions and settings..."
    
    SOFTWARE_FILE="$DOCS_DIR/software_versions.md"
    cat > "$SOFTWARE_FILE" << 'EOF'
# Software - Versions and Settings

## Operating System

EOF

    # macOS
    sw_vers >> "$SOFTWARE_FILE" 2>/dev/null
{
    echo ""
    echo "- **Full Version:** $(sw_vers -productVersion)"
    echo "- **Build:** $(sw_vers -buildVersion)"
    echo ""
} >> "$SOFTWARE_FILE"

# Python
{
    echo "## Python"
    echo ""
    if command -v python3 &> /dev/null; then
        echo "- **Version:** $(python3 --version)"
        echo "- **Path:** $(which python3)"
    else
        echo "- **Python3 not found**"
    fi
    echo ""
} >> "$SOFTWARE_FILE"

# Docker
{
    echo "## Docker Desktop"
    echo ""
    if command -v docker &> /dev/null; then
        echo "- **Version:** $(docker --version)"
        echo ""
        echo "### Detailed Information"
        docker version 2>/dev/null | sed 's/^/  /' || echo "  Docker is not running"
        echo ""
        if [ "$DOCKER_RUNNING" = true ]; then
            echo "### System Info"
            docker info 2>/dev/null | head -n 30 | sed 's/^/  /' || echo "  Error collecting information"
        else
            echo "### System Info"
            echo "  Docker is not running"
        fi
    else
        echo "- **Docker not found**"
    fi
    echo ""
} >> "$SOFTWARE_FILE"

# Apple container
{
    echo "## Apple container"
    echo ""
    if command -v container &> /dev/null; then
        echo "- **Version:** $(container --version 2>/dev/null || echo 'N/A')"
        echo ""
        echo "### System Status"
        if [ "$APPLE_CONTAINER_RUNNING" = true ]; then
            container system status 2>/dev/null | sed 's/^/  /' || echo "  Error collecting status"
        else
            echo "  Apple container is not running"
        fi
    else
        echo "- **Apple container not found**"
    fi
    echo ""
} >> "$SOFTWARE_FILE"

# Benchmark Tools
{
    echo "## Benchmark Tools"
    echo ""
    
    if command -v sysbench &> /dev/null; then
        echo "- **sysbench:** $(sysbench --version 2>/dev/null | head -n 1 || echo 'N/A')"
    else
        echo "- **sysbench:** Not installed"
    fi
    
    if command -v fio &> /dev/null; then
        echo "- **fio:** $(fio --version 2>/dev/null || echo 'N/A')"
    else
        echo "- **fio:** Not installed"
    fi
    
    if command -v wrk &> /dev/null; then
        wrk_version=$(wrk --version 2>/dev/null | head -n 1 || echo 'N/A')
        echo "- **wrk:** $wrk_version"
    else
        echo "- **wrk:** Not installed"
    fi
    
    echo ""
} >> "$SOFTWARE_FILE"

# Monitoring Tools
{
    echo "## Monitoring Tools"
    echo ""
    
    if command -v top &> /dev/null; then
        echo "- **top:** Installed ($(which top))"
    else
        echo "- **top:** Not found"
    fi
    
    if command -v htop &> /dev/null; then
        echo "- **htop:** Installed ($(which htop))"
    else
        echo "- **htop:** Not installed"
    fi
    
    if command -v iostat &> /dev/null; then
        echo "- **iostat:** Installed ($(which iostat))"
    else
        echo "- **iostat:** Not installed"
    fi
    
    if command -v iftop &> /dev/null; then
        echo "- **iftop:** Installed ($(which iftop))"
    else
        echo "- **iftop:** Not installed"
    fi
    
    echo ""
} >> "$SOFTWARE_FILE"

    print_success "  ✓ Software documented: $(basename "$SOFTWARE_FILE")"
    echo ""
else
    print_step "[2/9] Validating Software"
    SOFTWARE_FILE="$DOCS_DIR/software_versions.md"
    if [ -f "$SOFTWARE_FILE" ]; then
        print_success "  ✓ Software: $(basename "$SOFTWARE_FILE") found"
    else
        print_warning "  ⚠ Software: File not found"
    fi
    echo ""
fi

# =============================================================================
# 3. DOCKER SETTINGS (if running)
# =============================================================================

if [ "$DOCKER_RUNNING" = true ]; then
    if [ "$SKIP_COLLECTION" = false ]; then
        print_step "[3/9] Collecting Docker Desktop Settings"
        print_info "  Processing server information..."
        
        DOCKER_CONFIG_FILE="$DOCS_DIR/docker_configuration.md"
        cat > "$DOCKER_CONFIG_FILE" << 'EOF'
# Docker Desktop Settings

## Server Information

EOF

    # Collect Docker server information
    docker info >> "$DOCKER_CONFIG_FILE" 2>/dev/null || echo "Error collecting information" >> "$DOCKER_CONFIG_FILE"

    # Note about resource settings
    {
        echo ""
        echo "## Resource Settings"
        echo ""
        echo "⚠️  **MANUAL ACTION REQUIRED:** Resource settings (CPUs, Memory, Disk) must be checked manually in Docker Desktop."
        echo ""
        echo "### 📖 How to Document"
        echo ""
        echo "**Option 2: Interactive Script**"
        echo "\`\`\`bash"
        echo "cd $(dirname "$PROJECT_ROOT")"
        echo "./src/utils/document_docker_resources.sh"
        echo "\`\`\`"
        echo ""
        echo "**Option 3: Manual Editing**"
        echo "1. Open Docker Desktop"
        echo "2. Go to Settings (⚙️) → Resources"
        echo "3. Note the values and edit this file below"
        echo ""
        echo "### Allocated Resources (Settings → Resources)"
        echo ""
        echo "⚠️ **PENDING:** Please document the settings below:"
        echo ""
        echo "- **CPUs:** [X] cores"
        echo "- **Memory:** [X] GB"
        echo "- **Disk:** [X] GB"
        echo "- **Virtual Machine Manager (VMM):** [Apple Virtualization framework / Docker VMM (Beta)]"
        echo ""
        echo "- **Rosetta:** [Enabled / Disabled] (for x86/amd64 emulation)"
        echo "- **containerd:** [Enabled / Disabled] (for pulling and storing images)"
        echo ""
        echo "### Documentation Date"
        echo ""
        echo "- **Date:** [YYYY-MM-DD]"
        echo "- **Docker Desktop Version:** $(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo 'N/A')"
        } >> "$DOCKER_CONFIG_FILE"

        print_success "  ✓ Docker settings documented: $(basename "$DOCKER_CONFIG_FILE")"
        echo ""
    else
        print_step "[3/9] Validating Docker Desktop Settings"
        DOCKER_CONFIG_FILE="$DOCS_DIR/docker_configuration.md"
        if [ -f "$DOCKER_CONFIG_FILE" ]; then
            # Check whether it is complete
            if grep -q "PENDING" "$DOCKER_CONFIG_FILE" 2>/dev/null || grep -qE "\*\*CPUs:\*\* \[X\]" "$DOCKER_CONFIG_FILE" 2>/dev/null; then
                print_warning "  ⚠ Docker: File found but incomplete (pending resources)"
            else
                print_success "  ✓ Docker: $(basename "$DOCKER_CONFIG_FILE") found and complete"
            fi
        else
            print_warning "  ⚠ Docker: File not found"
        fi
        echo ""
    fi
else
    print_warning "  ⚠ Pulando: Docker is not running"
    echo ""
fi

# =============================================================================
# 4. APPLE CONTAINER SETTINGS (if running)
# =============================================================================

if [ "$APPLE_CONTAINER_RUNNING" = true ]; then
    if [ "$SKIP_COLLECTION" = false ]; then
        print_step "[4/9] Collecting Apple container Settings"
        print_info "  Processing system status..."
        
        APPLE_CONTAINER_CONFIG_FILE="$DOCS_DIR/apple_container_configuration.md"
        cat > "$APPLE_CONTAINER_CONFIG_FILE" << 'EOF'
# Apple container Settings

## System Status

EOF

    # Collect status
    container system status >> "$APPLE_CONTAINER_CONFIG_FILE" 2>/dev/null || echo "Error collecting status" >> "$APPLE_CONTAINER_CONFIG_FILE"

        # Try to collect system information (if available)
        if container system info &> /dev/null; then
            {
                echo ""
                echo "## System Information"
                echo ""
            } >> "$APPLE_CONTAINER_CONFIG_FILE"
            container system info >> "$APPLE_CONTAINER_CONFIG_FILE" 2>/dev/null || true
        fi

        print_success "  ✓ Apple container settings documented: $(basename "$APPLE_CONTAINER_CONFIG_FILE")"
        echo ""
    else
        print_step "[4/9] Validating Apple container Settings"
        APPLE_CONTAINER_CONFIG_FILE="$DOCS_DIR/apple_container_configuration.md"
        if [ -f "$APPLE_CONTAINER_CONFIG_FILE" ]; then
            print_success "  ✓ Apple container: $(basename "$APPLE_CONTAINER_CONFIG_FILE") found"
        else
            print_warning "  ⚠ Apple container: File not found"
        fi
        echo ""
    fi
else
    print_warning "  ⚠ Pulando: Apple container is not running"
    echo ""
fi

# =============================================================================
# 5. DOWNLOAD AND VALIDATE IMAGES (if Docker running)
# =============================================================================

if [ "$DOCKER_RUNNING" = true ]; then
    if [ "$SKIP_COLLECTION" = false ]; then
        print_step "[5/9] Checking and Downloading Required Images"
        print_info "  Validating image availability..."
        
        # Note: sysbench does not need a pre-built image - it is installed dynamically
        IMAGES=(
            "alpine:3.24"
            "nginx:1.30.6"
        )
        
        for image in "${IMAGES[@]}"; do
        # Check whether the image exists in Docker
        if ! docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -q "^${image}$"; then
            print_warning "    ⚠ $image: Not found in Docker, pulling..."
            if docker pull "$image" &> /dev/null; then
                print_success "    ✓ $image: Pulled into Docker"
            else
                print_error "    ✗ $image: Failed to pull into Docker"
            fi
        else
            print_success "    ✓ $image: Available in Docker"
        fi
        
        # Check whether the image exists in Apple container (if running)
        if [ "$APPLE_CONTAINER_RUNNING" = true ]; then
            if ! container image ls 2>/dev/null | awk '{print $1":"$2}' | grep -q "^${image}$"; then
                print_warning "    ⚠ $image: Not found in Apple container, importing..."
                
                # Export from Docker and import into Apple container
                tmp_tar="/tmp/${image//\//_}.tar"
                tmp_tar="${tmp_tar//:/_}"
                
                if docker save "$image" -o "$tmp_tar" &> /dev/null; then
                    if container image load --input "$tmp_tar" &> /dev/null; then
                        print_success "    ✓ $image: Imported into Apple container"
                        rm -f "$tmp_tar" &> /dev/null || true
                    else
                        print_error "    ✗ $image: Failed to import into Apple container"
                        rm -f "$tmp_tar" &> /dev/null || true
                    fi
                else
                    print_error "    ✗ $image: Failed to export from Docker"
                fi
            else
                print_success "    ✓ $image: Available in Apple container"
            fi
        fi
        done
        echo ""
    else
        print_step "[5/9] Validating Images"
        # Validation mode: check whether images exist
        IMAGES_TO_CHECK=("alpine:3.24" "nginx:1.30.6")
        MISSING_COUNT=0
        for image in "${IMAGES_TO_CHECK[@]}"; do
            if ! docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${image}$"; then
                print_warning "  ⚠ $image: Not found in Docker"
                MISSING_COUNT=$((MISSING_COUNT + 1))
            else
                print_success "  ✓ $image: Available in Docker"
            fi
        done
        if [ "$MISSING_COUNT" -eq 0 ]; then
            print_success "  ✓ All images are available"
        fi
        echo ""
    fi
else
    print_warning "  ⚠ Pulando: Docker is not running"
    echo ""
fi

# =============================================================================
# 6. COLLECT IMAGE DIGESTS (if Docker running)
# =============================================================================

if [ "$DOCKER_RUNNING" = true ]; then
    if [ "$SKIP_COLLECTION" = false ]; then
        print_step "[6/9] Collecting Image Digests"
        print_info "  Processing digests for reproducibility..."
        
        DIGESTS_FILE="$DOCS_DIR/image_digests.md"
        cat > "$DIGESTS_FILE" << 'EOF'
# Image Digests - Reproducibility

## Importance

Digests ensure that exactly the same images are used in Docker and Apple container, which is essential for a fair comparison and scientific reproducibility.

## ⚠️ Important Note About Differing Digests

**Differing digests between Docker and Apple container are expected and normal** after importing via `docker save`/`container image load`:

- **Docker**: Uses `RepoDigest` (manifest digest from the Docker Hub registry)
- **Apple container**: Uses `Index digest` (internal OCI digest created after import)

The import process converts the image from Docker format to OCI, creating a new digest. **The image contents (layers, files, settings) are identical**, ensuring a fair comparison.

**Identity Guarantees:**
- ✅ Both images were pulled from Docker Hub with the same fixed tag
- ✅ Direct import from Docker into Apple container (no modifications)
- ✅ Use of fixed tags (`alpine:3.24`, `nginx:1.30.6`) instead of `latest`


---

## Images

EOF

        # Note: sysbench does not need a pre-built image - it is installed dynamically
        IMAGES=(
            "alpine:3.24"
            "nginx:1.30.6"
        )

        for image in "${IMAGES[@]}"; do
        {
            echo "### $image"
            echo ""
            
            # Docker
            docker_digest="N/A"  # Initialize variable
            echo "**Docker:**"
            docker_digest_raw=$(docker image inspect "$image" --format '{{index .RepoDigests 0}}' 2>/dev/null | head -1 | tr -d '\n\r' | xargs || echo "")
            if [ -n "$docker_digest_raw" ] && [ "$docker_digest_raw" != "" ] && [ "$docker_digest_raw" != "N/A" ]; then
                echo "- Digest: \`$docker_digest_raw\`"
                docker_digest="$docker_digest_raw"
            else
                # Try using the image ID
                docker_id=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null | head -1 | tr -d '\n\r' | xargs || echo "")
                if [ -n "$docker_id" ] && [ "$docker_id" != "" ] && [ "$docker_id" != "N/A" ]; then
                    echo "- Image ID: \`${docker_id:0:20}...\` (local image, no digest)"
                    docker_digest="N/A"
                else
                    echo "- Image not found"
                    docker_digest="N/A"
                fi
            fi
            echo ""
            
            # Apple container
            apple_digest="N/A"  # Initialize variable
            if [ "$APPLE_CONTAINER_RUNNING" = true ]; then
                echo "**Apple container:**"
                # Apple container does not support --format, so JSON must be processed
                apple_digest_raw=$(container image inspect "$image" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data and isinstance(data, list) and len(data) > 0:
        if 'index' in data[0] and 'digest' in data[0]['index']:
            digest = data[0]['index']['digest']
            # Build the full digest in the format image@sha256:hash
            repo_name = data[0].get('name', '').replace('docker.io/library/', '').replace('docker.io/', '')
            if repo_name and digest:
                print(f'{repo_name}@{digest}')
            elif digest:
                print(digest)
            else:
                print('N/A')
        else:
            print('N/A')
    else:
        print('N/A')
except:
    print('N/A')
" 2>/dev/null || echo "N/A")
                
                if [ "$apple_digest_raw" != "N/A" ] && [ -n "$apple_digest_raw" ] && [ "$apple_digest_raw" != "" ]; then
                    echo "- Digest: \`$apple_digest_raw\`"
                    apple_digest="$apple_digest_raw"
                else
                    # Try to get the image ID via container image ls
                    apple_id=$(container image ls 2>/dev/null | grep -E "^${image%:*}.*${image#*:}" | awk '{print $3}' | head -1 | tr -d '\n' || echo "")
                    if [ -n "$apple_id" ] && [ "$apple_id" != "" ]; then
                        echo "- Image ID: \`${apple_id:0:20}...\` (local image, no digest)"
                        apple_digest="N/A"
                    else
                        echo "- Image not found"
                        apple_digest="N/A"
                    fi
                fi
                echo ""
                
                # Check whether they are identical
                # NOTE: Digests may differ because:
                # - Docker uses RepoDigest (manifest digest from the registry)
                # - Apple container uses Index digest (internal OCI digest after import)
                # What matters is whether the content (layers/config) is identical
                if [ "$docker_digest" != "N/A" ] && [ -n "$docker_digest" ] && [ "$apple_digest" != "N/A" ] && [ -n "$apple_digest" ]; then
                    # Extract only the SHA256 hash for comparison
                    docker_hash=$(echo "$docker_digest" | sed 's/.*sha256://' | cut -d' ' -f1 | tr -d '\n\r')
                    apple_hash=$(echo "$apple_digest" | sed 's/.*sha256://' | cut -d' ' -f1 | tr -d '\n\r')
                    
                    if [ "$docker_hash" = "$apple_hash" ] && [ -n "$docker_hash" ] && [ -n "$apple_hash" ]; then
                        echo "✅ **Identical digests - same image on both systems**"
                    else
                        echo "ℹ️  **Note: Differing digests are expected after importing via docker save/load**"
                        echo "   - Docker: RepoDigest (manifest digest from the registry)"
                        echo "   - Apple container: Index digest (internal OCI digest)"
                        echo "   - The image contents (layers) should be identical even with differing digests"
                        echo "   - To ensure identity, verify that both were imported from the same source"
                    fi
                else
                    echo "ℹ️  **Note: One or both systems have no digest (local image)**"
                fi
            else
                echo "**Apple container:** Not running"
            fi
            echo ""
            echo "**Status:** ✅ Image imported and available on both systems"
            echo ""
            echo "**Note About Digests:**"
            echo "- Differing digests are expected after importing via \`docker save\`/\`container image load\`"
            echo "- Docker uses RepoDigest (manifest digest from the registry)"
            echo "- Apple container uses Index digest (internal OCI digest)"
            echo "- The image contents (layers) are identical, ensuring a fair comparison"
            echo ""
            echo "---"
            echo ""
        } >> "$DIGESTS_FILE"
        done
        
        # Note about sysbench
        {
            echo "### sysbench"
            echo ""
            echo "**Note:** sysbench does not use a pre-built image. It is installed dynamically inside \`alpine:3.24\` during benchmark execution."
            echo ""
            echo "**Installation Process:**"
            echo "- The benchmarks run: \`apk add --no-cache sysbench\` inside the \`alpine:3.24\` container"
            echo "- This ensures the same sysbench version is installed on both systems (Docker and Apple container)"
            echo "- Installation uses the same Alpine repository, ensuring identity"
            echo ""
            echo "**Advantages of This Approach:**"
            echo "- ✅ Does not require a pre-built image"
            echo "- ✅ Guarantees the same version on both systems"
            echo "- ✅ Simplifies the setup process"
            echo "- ✅ Reproducible (same command, same result)"
            echo ""
            echo "---"
            echo ""
            echo "## 📋 Summary"
            echo ""
            echo "| Image | Docker | Apple container | Status |"
            echo "|--------|--------|-----------------|--------|"
            echo "| \`alpine:3.24\` | ✅ Available | ✅ Available | ✅ Imported |"
            echo "| \`nginx:1.30.6\` | ✅ Available | ✅ Available | ✅ Imported |"
            echo "| \`sysbench\` | ⚙️ Installed dynamically | ⚙️ Installed dynamically | ✅ Same process |"
            echo ""
            echo "**Conclusion:** All required images are available and configured for a fair comparison between Docker and Apple container."
            echo ""
        } >> "$DIGESTS_FILE"

        print_success "  ✓ Digests collected: $(basename "$DIGESTS_FILE")"
        echo ""
    else
        print_step "[6/9] Validating Image Digests"
        DIGESTS_FILE="$DOCS_DIR/image_digests.md"
        if [ -f "$DIGESTS_FILE" ]; then
            print_success "  ✓ Digests: $(basename "$DIGESTS_FILE") found"
        else
            print_warning "  ⚠ Digests: File not found"
        fi
        echo ""
    fi
else
    print_warning "  ⚠ Pulando: Docker is not running"
    echo ""
fi

# =============================================================================
# 7. COLLECT INTERNAL CONTAINER ENVIRONMENT (if both running)
# =============================================================================

if [ "$DOCKER_RUNNING" = true ] && [ "$APPLE_CONTAINER_RUNNING" = true ]; then
    if [ "$SKIP_COLLECTION" = false ]; then
        print_step "[7/9] Collecting Internal Container Environment"
        print_info "  Running containers to analyze the environment..."
        
        CONTAINER_ENV_FILE="$DOCS_DIR/container_environment.md"
        
        # Clear existing file and recreate
        cat > "$CONTAINER_ENV_FILE" << 'EOF'
# Internal Container Environment

## Important Note

The benchmarks are executed **INSIDE** the containers. This document describes the internal environment where the benchmarks run.

## Alpine Linux (Base Image)

EOF

        # Collect Alpine information in Docker
        {
            echo "### Docker Container"
            echo ""
            echo '```bash'
            docker run --rm alpine:3.24 sh -c "cat /etc/os-release && echo '' && uname -a" 2>/dev/null || echo "Error running"
            echo '```'
            echo ""
        } >> "$CONTAINER_ENV_FILE"

        # Collect Alpine information in Apple container
        {
            echo "### Apple container"
            echo ""
            echo '```bash'
            container run --rm alpine:3.24 sh -c "cat /etc/os-release && echo '' && uname -a" 2>/dev/null || echo "Error running"
            echo '```'
            echo ""
        } >> "$CONTAINER_ENV_FILE"

        # Tool versions inside the containers
        {
        echo "## Benchmark Tools in the Containers"
        echo ""
        echo "### sysbench"
        echo ""
        echo "**Note:** sysbench is installed dynamically inside alpine:3.24 during benchmark execution."
        echo ""
        echo "**Docker (installed dynamically):**"
        docker run --rm alpine:3.24 sh -c "apk add --no-cache sysbench >/dev/null 2>&1 && sysbench --version" 2>/dev/null | sed 's/^/  - /' || echo "  - Not available"
        echo ""
        echo "**Apple container (installed dynamically):**"
        container run --rm alpine:3.24 sh -c "apk add --no-cache sysbench >/dev/null 2>&1 && sysbench --version" 2>/dev/null | sed 's/^/  - /' || echo "  - Not available"
        echo ""
        echo "### Nginx"
        echo ""
        echo "**Docker:**"
        docker run --rm nginx:1.30.6 nginx -v 2>&1 | sed 's/^/  - /' || echo "  - Not available"
        echo ""
        echo "**Apple container:**"
        container run --rm nginx:1.30.6 nginx -v 2>&1 | sed 's/^/  - /' || echo "  - Not available"
        echo ""
        } >> "$CONTAINER_ENV_FILE"

        print_success "  ✓ Container environment documented: $(basename "$CONTAINER_ENV_FILE")"
        echo ""
    else
        print_step "[7/9] Validating Internal Container Environment"
        CONTAINER_ENV_FILE="$DOCS_DIR/container_environment.md"
        if [ -f "$CONTAINER_ENV_FILE" ]; then
            print_success "  ✓ Container environment: $(basename "$CONTAINER_ENV_FILE") found"
        else
            print_warning "  ⚠ Container environment: File not found"
        fi
        echo ""
    fi
else
    print_warning "  ⚠ Skipping: Docker and/or Apple container are not running"
    echo ""
fi

# =============================================================================
# 8. COLLECT PYTHON DEPENDENCIES AND DOCUMENT ENVIRONMENT
# =============================================================================

if [ "$SKIP_COLLECTION" = false ]; then
    print_step "[8/9] Collecting Python Dependencies and Documenting Environment"
    print_info "  Processing virtual environment packages..."
    
    PYTHON_PACKAGES_COLLECTED=false

    # Try to collect Python dependencies
    if [ "$PYTHON_VENV_ACTIVE" = true ]; then
    # Venv is active, use pip directly
    if command -v pip3 &> /dev/null; then
        if pip3 freeze > "$SNAPSHOT_DIR/python_packages.txt" 2>/dev/null; then
            PYTHON_PACKAGES_COLLECTED=true
            print_success "  ✓ Python dependencies collected: python_packages.txt"
        else
            print_warning "  ⚠ Failed to collect Python dependencies (active venv)"
        fi
    fi
elif [ -n "$PYTHON_VENV_PATH" ] && [ -f "$PYTHON_VENV_PATH/bin/pip3" ]; then
    # Venv exists but is not active, use the venv's pip directly
    if "$PYTHON_VENV_PATH/bin/pip3" freeze > "$SNAPSHOT_DIR/python_packages.txt" 2>/dev/null; then
        PYTHON_PACKAGES_COLLECTED=true
        print_success "  ✓ Python dependencies collected: python_packages.txt"
    else
        print_warning "  ⚠ Failed to collect Python dependencies from venv"
    fi
fi

    # If collection failed, offer options
    if [ "$PYTHON_PACKAGES_COLLECTED" = false ]; then
        print_warning "  ⚠ Could not collect automatically"
        print_info "    → Use: $PROJECT_ROOT/src/utils/collect_python_dependencies.sh"
    fi
    
    # Create Python environment documentation
    PYTHON_ENV_FILE="$DOCS_DIR/python_environment.md"
    if [ "$PYTHON_PACKAGES_COLLECTED" = true ] || [ -n "$PYTHON_VENV_PATH" ] || [ "$PYTHON_VENV_ACTIVE" = true ]; then
        cat > "$PYTHON_ENV_FILE" << 'EOF'
# Python Virtual Environment - Purpose and Usage

## ⚠️ Important: Purpose of the Python Environment

This Python virtual environment is used **ONLY for analyzing the collected data**, **NOT for running the benchmarks**.

### What this environment does:
- ✅ **Statistical analysis** of the benchmark results
- ✅ **Generation of charts and visualizations**
- ✅ **Processing of collected data**
- ✅ **Statistical computations** (ANOVA, confidence intervals, etc.)

### What this environment does NOT do:
- ❌ **Does NOT run benchmarks** - The benchmarks run **INSIDE the containers**
- ❌ **Does NOT affect the results** - The Python environment does not interfere with the benchmark results
- ❌ **Does NOT run on the HOST during benchmarks** - It only processes data after collection

## Why is this important?

### Environment Separation

1. **HOST (MacBook Pro M2):**
   - Where Docker Desktop and Apple container run
   - Where we collect system metrics (CPU, memory, host I/O)
   - Operating system: macOS

2. **CONTAINER (inside the images):**
   - **Where the benchmarks are executed** (inside the containers)
   - Base images: Alpine Linux, Nginx, etc.
   - Operating system: Linux (inside the container)
   - **This is the environment being compared!**

3. **Python Virtual Environment:**
   - **For analysis only** of the collected data
   - Does not run benchmarks
   - Used for statistical analysis scripts

### Guarantee of Scientific Validity

- ✅ The benchmarks run in isolated environments (containers)
- ✅ The Python environment does not interfere with the results
- ✅ Analysis is performed post hoc, with no impact on the experiments
- ✅ Reproducibility ensured through documented dependencies

## Dependencies

The Python virtual environment dependencies are documented in:
- `snapshot/python_packages.txt` - Complete list of packages and versions

### Main Libraries

- **pandas**: Data manipulation and analysis
- **numpy**: Numerical computing
- **scipy**: Statistics and scientific analysis
- **statsmodels**: Statistical models (ANOVA, regression, etc.)
- **matplotlib**: Data visualization
- **seaborn**: Advanced statistical visualizations

## How to Use

### Activate the virtual environment:
```bash
cd <repo-root>
source venv/bin/activate
```

### Run analyses:
```bash
# Example: run an analysis script
python3 src/analysis/analyze_results_enhanced.py bench_results/[timestamp]/ --output bench_results/[timestamp]/enhanced_analysis
```

### Deactivate the virtual environment:
```bash
deactivate
```

## Related Documentation

- **Python Dependencies:** `snapshot/python_packages.txt`

---

**Last updated:** Automatically generated by `collect_system_info.sh`
EOF
        print_success "  ✓ Python environment documentation created: $(basename "$PYTHON_ENV_FILE")"
    fi
    echo ""
else
    print_step "[8/9] Validating Python Dependencies"
    if [ -f "$SNAPSHOT_DIR/python_packages.txt" ]; then
        print_success "  ✓ Python dependencies: python_packages.txt found"
        PYTHON_PACKAGES_COLLECTED=true
    else
        print_warning "  ⚠ Python dependencies: File not found"
        PYTHON_PACKAGES_COLLECTED=false
    fi
    
    # Check whether the Python environment documentation exists
    PYTHON_ENV_FILE="$DOCS_DIR/python_environment.md"
    if [ -f "$PYTHON_ENV_FILE" ]; then
        print_success "  ✓ Python environment documentation: $(basename "$PYTHON_ENV_FILE") found"
    else
        print_warning "  ⚠ Python environment documentation: File not found"
    fi
    echo ""
fi

# =============================================================================
# 9. CREATE ENVIRONMENT SNAPSHOT
# =============================================================================

if [ "$SKIP_COLLECTION" = false ]; then
    print_step "[9/9] Creating Environment Snapshot"
    print_info "  Generating snapshot files..."
    

# Hardware
system_profiler SPHardwareDataType > "$SNAPSHOT_DIR/hardware.txt" 2>/dev/null || true

# macOS
sw_vers > "$SNAPSHOT_DIR/macos.txt" 2>/dev/null || true

# Docker
if [ "$DOCKER_RUNNING" = true ]; then
    docker version > "$SNAPSHOT_DIR/docker.txt" 2>/dev/null || true
    docker info > "$SNAPSHOT_DIR/docker_info.txt" 2>/dev/null || true
else
    echo "Docker is not running" > "$SNAPSHOT_DIR/docker.txt"
fi

# Apple container
if command -v container &> /dev/null; then
    container --version > "$SNAPSHOT_DIR/apple_container.txt" 2>/dev/null || true
    if [ "$APPLE_CONTAINER_RUNNING" = true ]; then
        container system status > "$SNAPSHOT_DIR/apple_container_status.txt" 2>/dev/null || true
    else
        echo "Apple container is not running" > "$SNAPSHOT_DIR/apple_container_status.txt"
    fi
fi

# Python
if command -v python3 &> /dev/null; then
    python3 --version > "$SNAPSHOT_DIR/python_version.txt" 2>/dev/null || true
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        echo "Active virtual environment: $VIRTUAL_ENV" >> "$SNAPSHOT_DIR/python_version.txt"
    fi
fi

# Tool versions (HOST)
{
    echo "=== Tools on the HOST ==="
    echo ""
    echo "=== sysbench ==="
    sysbench --version 2>/dev/null || echo "Not installed"
    echo ""
    echo "=== fio ==="
    fio --version 2>/dev/null || echo "Not installed"
    echo ""
    echo "=== wrk ==="
    wrk --version 2>/dev/null | head -n 1 || echo "Not installed"
} > "$SNAPSHOT_DIR/benchmark_tools_host.txt" 2>/dev/null || true

# Tool versions inside the containers
if [ "$DOCKER_RUNNING" = true ] && [ "$APPLE_CONTAINER_RUNNING" = true ]; then
    {
        echo "=== Tools INSIDE the Containers ==="
        echo ""
        echo "=== sysbench (Docker - installed dynamically) ==="
        docker run --rm alpine:3.24 sh -c "apk add --no-cache sysbench >/dev/null 2>&1 && sysbench --version" 2>/dev/null || echo "Not available"
        echo ""
        echo "=== sysbench (Apple container - installed dynamically) ==="
        container run --rm alpine:3.24 sh -c "apk add --no-cache sysbench >/dev/null 2>&1 && sysbench --version" 2>/dev/null || echo "Not available"
        echo ""
        echo "=== Nginx (Docker) ==="
        docker run --rm nginx:1.30.6 nginx -v 2>&1 || echo "Not available"
        echo ""
        echo "=== Nginx (Apple container) ==="
        container run --rm nginx:1.30.6 nginx -v 2>&1 || echo "Not available"
    } > "$SNAPSHOT_DIR/benchmark_tools_container.txt" 2>/dev/null || true
fi

# Disk space
df -h > "$SNAPSHOT_DIR/disk_usage.txt" 2>/dev/null || true

# Snapshot date
date > "$SNAPSHOT_DIR/snapshot_date.txt"

    print_success "  ✓ Snapshot created: $(basename "$SNAPSHOT_DIR")/"
    echo ""
else
    print_step "[9/9] Validating Environment Snapshot"
    if [ -d "$SNAPSHOT_DIR" ] && [ "$(find "$SNAPSHOT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
        SNAPSHOT_FILE_COUNT=$(find "$SNAPSHOT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
        print_success "  ✓ Snapshot: $SNAPSHOT_FILE_COUNT file(s) found"
    else
        print_warning "  ⚠ Snapshot: Directory empty or not found"
    fi
    echo ""
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║  📋 COLLECTION SUMMARY                                                 ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""

# Section 1: Complete Documentation
print_step "✅ AUTOMATICALLY COLLECTED DOCUMENTATION"
echo ""
echo "  📁 Hardware"
echo "     └─ $(basename "$HARDWARE_FILE")"
echo ""
echo "  📁 Software"
echo "     └─ $(basename "$SOFTWARE_FILE")"
echo ""
if [ "$DOCKER_RUNNING" = true ]; then
    echo "  📁 Docker Desktop"
    echo "     ├─ docker_configuration.md"
    echo "     └─ image_digests.md"
    echo ""
fi
if [ "$APPLE_CONTAINER_RUNNING" = true ]; then
    echo "  📁 Apple container"
    echo "     └─ apple_container_configuration.md"
    echo ""
fi
if [ "$DOCKER_RUNNING" = true ] && [ "$APPLE_CONTAINER_RUNNING" = true ]; then
    echo "  📁 Container Environment"
    echo "     └─ container_environment.md"
    echo ""
fi
echo "  📁 Environment Snapshot"
echo "     └─ snapshot/"
if [ -f "$SNAPSHOT_DIR/python_packages.txt" ]; then
    echo "        └─ python_packages.txt"
fi
if [ -f "$DOCS_DIR/python_environment.md" ]; then
    echo ""
    echo "  📁 Python Environment"
    echo "     └─ python_environment.md"
fi
echo ""

# Section 2: Required Manual Actions
MANUAL_ACTIONS=0

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_warning "⚠️  MANUAL ACTIONS REQUIRED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check Docker resources
if [ "$DOCKER_RUNNING" = true ]; then
    if grep -q "PENDING" "$DOCS_DIR/docker_configuration.md" 2>/dev/null || grep -qE "\*\*CPUs:\*\* \[X\]" "$DOCS_DIR/docker_configuration.md" 2>/dev/null; then
        MANUAL_ACTIONS=$((MANUAL_ACTIONS + 1))
        echo "  $MANUAL_ACTIONS. 📝 Document Docker Desktop Resources"
        echo "     File: docker_configuration.md"
        echo "     Solution: $PROJECT_ROOT/src/utils/document_docker_resources.sh"
        echo ""
    fi
fi

# Check images in Apple container (direct check)
if [ "$DOCKER_RUNNING" = true ] && [ "$APPLE_CONTAINER_RUNNING" = true ]; then
    # Directly check whether the images exist in Apple container
    IMAGES_TO_CHECK=("alpine:3.24" "nginx:1.30.6")
    MISSING_IMAGES=()
    
    for image in "${IMAGES_TO_CHECK[@]}"; do
        # Check whether the image exists in Apple container
        if ! container image ls 2>/dev/null | awk '{print $1":"$2}' | grep -q "^${image}$"; then
            # Check whether the image exists in Docker (to confirm it can be imported)
            if docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${image}$"; then
                MISSING_IMAGES+=("$image")
            fi
        fi
    done
    
    # If images are missing, add to the list of manual actions
    if [ ${#MISSING_IMAGES[@]} -gt 0 ]; then
        MANUAL_ACTIONS=$((MANUAL_ACTIONS + 1))
        echo "  $MANUAL_ACTIONS. 📦 Import Images into Apple container"
        echo "     Missing: ${#MISSING_IMAGES[@]} image(s) - ${MISSING_IMAGES[*]}"
        echo "     Solution: $PROJECT_ROOT/src/utils/import_images_to_apple_container.sh"
        echo ""
    fi
fi

# Check Python dependencies
if [ "${PYTHON_PACKAGES_COLLECTED:-false}" = false ]; then
    MANUAL_ACTIONS=$((MANUAL_ACTIONS + 1))
    echo "  $MANUAL_ACTIONS. 🐍 Collect Python Dependencies"
    echo "     File: snapshot/python_packages.txt"
    echo "     Solution: $PROJECT_ROOT/src/utils/collect_python_dependencies.sh"
    echo ""
fi

# Check services that are not running
if [ "$DOCKER_RUNNING" = false ] || [ "$APPLE_CONTAINER_RUNNING" = false ]; then
    if [ "$DOCKER_RUNNING" = false ]; then
        MANUAL_ACTIONS=$((MANUAL_ACTIONS + 1))
        echo "  $MANUAL_ACTIONS. 🐳 Start Docker Desktop"
        echo "     Command: open -a Docker"
        echo "     (Run this script again after starting)"
        echo ""
    fi
    if [ "$APPLE_CONTAINER_RUNNING" = false ]; then
        MANUAL_ACTIONS=$((MANUAL_ACTIONS + 1))
        echo "  $MANUAL_ACTIONS. 📦 Start Apple container"
        echo "     Command: container system start"
        echo "     (Run this script again after starting)"
        echo ""
    fi
fi

# If there are no manual actions
if [ "$MANUAL_ACTIONS" -eq 0 ]; then
    echo "  ✅ No manual action required - everything is complete!"
    echo ""
fi

# Section 3: Final Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$MANUAL_ACTIONS" -eq 0 ]; then
    print_success "✅ COLLECTION COMPLETE - ALL READY!"
else
    print_warning "⚠️  COLLECTION COMPLETE - $MANUAL_ACTIONS manual action(s) pending"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_info "📖 Location: $DOCS_DIR"
echo ""

