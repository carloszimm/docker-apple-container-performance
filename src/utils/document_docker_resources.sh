#!/bin/bash

# Helper script to document Docker Desktop resource settings
# Usage: ./document_docker_resources.sh

set -euo pipefail

# Load common output functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_output.sh"

# This script uses emojis, so we override the functions to use emojis
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Directories (SCRIPT_DIR already defined above)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS_DIR="$PROJECT_ROOT/docs/system_info"
DOCKER_CONFIG_FILE="$DOCS_DIR/docker_configuration.md"

# =============================================================================
# HEADER
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║  📝 DOCKER DESKTOP RESOURCE DOCUMENTATION                              ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# INITIAL CHECKS
# =============================================================================

print_step "📋 Checking Prerequisites"
echo ""

# Check whether Docker is running
if ! docker info >/dev/null 2>&1; then
    print_error "Docker is not running!"
    print_info "Run: open -a Docker"
    exit 1
fi

print_success "  ✓ Docker Desktop: Running"

# Get Docker version
DOCKER_VERSION=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
print_info "  ℹ Version: $DOCKER_VERSION"

# Get current date and time
CURRENT_DATE=$(date +"%Y-%m-%d")
CURRENT_DATETIME=$(date +"%Y-%m-%d %H:%M:%S")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# =============================================================================
# INSTRUCTIONS
# =============================================================================

print_step "📖 Instructions"
echo ""
print_info "  This script will help you document the resource settings."
echo ""
print_warning "  IMPORTANT: Manually check the settings in Docker Desktop"
echo ""
echo "  Steps (in the order they appear in Docker Desktop):"
echo ""
echo "  📍 PART 1: Settings → General"
echo "    1. Open Docker Desktop"
echo "    2. Go to Settings (⚙️) → General"
echo "    3. In the 'Virtual Machine Options' section, check:"
echo "       • Which Virtual Machine Manager (VMM) is in use"
echo "       • Whether Rosetta is disabled"
echo "    4. In the section above 'Virtual Machine Options', check:"
echo "       • Whether containerd is disabled for pulling and storing images"
echo ""
echo "  📍 PART 2: Settings → Resources"
echo "    4. Go to Settings (⚙️) → Resources"
echo "    5. Note the values of:"
echo "       • Allocated CPUs"
echo "       • Allocated memory (GB)"
echo "       • Allocated disk (GB)"
echo ""

# Try to open Docker Desktop (macOS)
if [[ "$OSTYPE" == "darwin"* ]]; then
    print_info "  Trying to open Docker Desktop..."
    open -a "Docker" 2>/dev/null || print_warning "  Could not open automatically"
    sleep 2
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# =============================================================================
# INFORMATION COLLECTION
# =============================================================================

print_step "📝 Collecting Resource Information"
echo ""
print_info "  We will collect the information in the order it appears in Docker Desktop"
echo ""

# =============================================================================
# PART 1: SETTINGS → GENERAL (Virtual Machine)
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_step "📍 PART 1: Settings → General → Virtual Machine Options"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Ask for Virtual Machine Manager (VMM)
print_info "  Virtual Machine Manager (VMM):"
echo ""
echo "    1) Apple Virtualization framework (RECOMMENDED)"
echo "    2) Docker VMM (Beta)"
read -p "  Choose (1 or 2) [default: 1]: " VMM_MODE
VMM_MODE=${VMM_MODE:-1}
if [[ "$VMM_MODE" == "1" ]]; then
    VMM_MODE_TEXT="Apple Virtualization framework"
else
    VMM_MODE_TEXT="Docker VMM (Beta)"
fi
echo ""

# Check Rosetta automatically (macOS)
ROSETTA=""
ROSETTA_DETECTED=""
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo ""
    print_step "🔍 Checking Rosetta"
    print_info "  Running automatic check..."
    
    # Check whether Rosetta is functional
    if arch -x86_64 /usr/bin/true 2>/dev/null; then
        ROSETTA_DETECTED="functional"
        # Check whether Docker is using native ARM64
        DOCKER_ARCH=$(docker version --format '{{.Server.Arch}}' 2>/dev/null || echo "")
        CONTAINER_ARCH=$(docker run --rm alpine:3.19 uname -m 2>/dev/null || echo "")
        
        if [[ "$DOCKER_ARCH" == "arm64" ]] && [[ "$CONTAINER_ARCH" == "aarch64" ]]; then
            print_success "  Rosetta is active on the system, but Docker is using native ARM64 (ideal)"
            print_info "    Docker is not affected by Rosetta (ideal)"
            ROSETTA_DETECTED_STATUS="active_but_not_affecting_docker"
        else
            print_warning "  Rosetta is active and Docker may be using x86_64 emulation"
            ROSETTA_DETECTED_STATUS="active_and_may_affect"
        fi
    else
        ROSETTA_DETECTED="inactive"
        print_success "  Rosetta is not active on the system"
        ROSETTA_DETECTED_STATUS="inactive"
    fi
    
    echo ""
    print_info "  Confirm in Docker Desktop (Settings → General → Virtual Machine Options):"
    print_warning "  IMPORTANT: For a fair comparison, Rosetta must be DISABLED"
    echo ""
    print_info "  Automatic check: Rosetta is $ROSETTA_DETECTED on the system"
    read -p "  In Docker Desktop (Settings → General), is Rosetta enabled? (y/n) [default: n]: " ROSETTA_INPUT
    ROSETTA_INPUT=${ROSETTA_INPUT:-n}
    if [[ "$ROSETTA_INPUT" == "y" || "$ROSETTA_INPUT" == "Y" || "$ROSETTA_INPUT" == "s" || "$ROSETTA_INPUT" == "S" ]]; then
        ROSETTA="Enabled"
        print_warning "  IMPORTANT: Rosetta being enabled may affect a fair comparison!"
    else
        ROSETTA="Disabled"
        print_success "  Rosetta disabled (recommended)"
    fi
    echo ""
fi

# Check containerd automatically
echo ""
print_step "🔍 Checking containerd"
print_info "  Running automatic check..."

# Check whether containerd is available
CONTAINERD_AVAILABLE=false
CONTAINERD_VERSION=""
if docker info 2>/dev/null | grep -q "containerd version"; then
    CONTAINERD_AVAILABLE=true
    CONTAINERD_VERSION=$(docker info 2>/dev/null | grep "containerd version" | sed 's/.*containerd version: //' | awk '{print $1}')
    print_success "  containerd available (version: $CONTAINERD_VERSION)"
else
    print_warning "  containerd not found in Docker info"
fi

# Check containerd runtime
if docker info 2>/dev/null | grep -q "io.containerd.runc.v2"; then
    print_success "  containerd runtime (io.containerd.runc.v2) available"
    CONTAINERD_RUNTIME_AVAILABLE=true
else
    print_warning "  containerd runtime not found"
    CONTAINERD_RUNTIME_AVAILABLE=false
fi

echo ""
print_info "  Confirm in Docker Desktop (Settings → General → Virtual Machine):"
print_info "    Look for: 'Use containerd for pulling and storing images'"
echo ""
if [[ "$CONTAINERD_AVAILABLE" == true ]]; then
    print_info "  Automatic check: containerd available in Docker"
    read -p "  In the Docker Desktop panel, is containerd enabled? (y/n) [default: n]: " CONTAINERD_INPUT
    CONTAINERD_INPUT=${CONTAINERD_INPUT:-y}
else
    print_warning "  Automatic check: containerd was not detected"
    read -p "  In the Docker Desktop panel, is containerd enabled? (y/n) [default: n]: " CONTAINERD_INPUT
    CONTAINERD_INPUT=${CONTAINERD_INPUT:-n}
fi

if [[ "$CONTAINERD_INPUT" == "y" || "$CONTAINERD_INPUT" == "Y" || "$CONTAINERD_INPUT" == "s" || "$CONTAINERD_INPUT" == "S" ]]; then
    CONTAINERD="Enabled"
    print_success "  containerd enabled"
else
    CONTAINERD="Disabled"
    print_info "  containerd disabled"
fi

# =============================================================================
# PART 2: SETTINGS → RESOURCES
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_step "📍 PART 2: Settings → Resources"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_info "  Now we will collect the allocated resources:"
echo ""

# Ask for CPUs
read -p "Allocated CPUs (e.g., 12): " CPUS
if [[ -z "$CPUS" ]]; then
    print_error "CPUs cannot be empty!"
    exit 1
fi

# Ask for memory
read -p "Allocated memory in GB (e.g., 8): " MEMORY
if [[ -z "$MEMORY" ]]; then
    print_error "Memory cannot be empty!"
    exit 1
fi

# Ask for disk
read -p "Allocated disk in GB (e.g., 64): " DISK
if [[ -z "$DISK" ]]; then
    print_error "Disk cannot be empty!"
    exit 1
fi

# Get system information for context
TOTAL_CPUS=$(sysctl -n hw.ncpu 2>/dev/null || echo "N/A")
TOTAL_MEMORY=$(sysctl -n hw.memsize 2>/dev/null)
if [[ "$TOTAL_MEMORY" != "N/A" && -n "$TOTAL_MEMORY" ]]; then
    TOTAL_MEMORY_GB=$((TOTAL_MEMORY / 1024 / 1024 / 1024))
else
    TOTAL_MEMORY_GB="N/A"
fi

# Create a backup of the original file
if [[ -f "$DOCKER_CONFIG_FILE" ]]; then
    BACKUP_FILE="${DOCKER_CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$DOCKER_CONFIG_FILE" "$BACKUP_FILE"
    print_info "  Backup created: $(basename "$BACKUP_FILE")"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_step "💾 Saving Settings"
print_info "  Updating documentation file..."
echo ""

# Read the current file and replace the resources section
if [[ -f "$DOCKER_CONFIG_FILE" ]]; then
    # Create temporary file
    TEMP_FILE=$(mktemp)
    
    # Process the file line by line
    IN_RESOURCES_SECTION=false
    RESOURCES_SECTION_ENDED=false
    
    while IFS= read -r line; do
        # Detect start of the resources section
        if [[ "$line" == "## Resource Settings" ]]; then
            IN_RESOURCES_SECTION=true
            echo "$line" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"
            continue
        fi
        
        # If in the resources section, skip until the next section or end of file
        if [[ "$IN_RESOURCES_SECTION" == true ]]; then
            # If the next section (##) or end of file is found, stop skipping
            if [[ "$line" =~ ^##[[:space:]] ]] && [[ "$RESOURCES_SECTION_ENDED" == false ]]; then
                RESOURCES_SECTION_ENDED=true
                IN_RESOURCES_SECTION=false
                # Write the new resources section before the next section
                cat >> "$TEMP_FILE" << EOF
### Allocated Resources (Settings → Resources)

- **CPUs:** $CPUS cores (of $TOTAL_CPUS available on the system)
- **Memory:** $MEMORY GB (of $TOTAL_MEMORY_GB GB available on the system)
- **Disk:** $DISK GB
- **Virtual Machine Manager (VMM):** $VMM_MODE_TEXT
EOF
                if [[ -n "$ROSETTA" ]]; then
                    echo "- **Rosetta:** $ROSETTA (for x86/amd64 emulation)" >> "$TEMP_FILE"
                fi
                echo "- **containerd:** $CONTAINERD (for pulling and storing images)" >> "$TEMP_FILE"
                echo "" >> "$TEMP_FILE"
                echo "### Documentation Date" >> "$TEMP_FILE"
                echo "" >> "$TEMP_FILE"
                echo "- **Date and Time:** $CURRENT_DATETIME" >> "$TEMP_FILE"
                echo "- **Docker Desktop Version:** $DOCKER_VERSION" >> "$TEMP_FILE"
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    MACOS_VERSION=$(sw_vers -productVersion)
                    echo "- **macOS Version:** $MACOS_VERSION" >> "$TEMP_FILE"
                fi
                echo "" >> "$TEMP_FILE"
                echo "---" >> "$TEMP_FILE"
                echo "" >> "$TEMP_FILE"
                # Continue writing the next section
                echo "$line" >> "$TEMP_FILE"
                continue
            fi
            # Keep skipping lines of the old section
            continue
        fi
        
        # Write line normally
        echo "$line" >> "$TEMP_FILE"
    done < "$DOCKER_CONFIG_FILE"
    
    # If the resources section was at the end of the file
    if [[ "$IN_RESOURCES_SECTION" == true && "$RESOURCES_SECTION_ENDED" == false ]]; then
        cat >> "$TEMP_FILE" << EOF

### Allocated Resources (Settings → Resources)

- **CPUs:** $CPUS cores (of $TOTAL_CPUS available on the system)
- **Memory:** $MEMORY GB (of $TOTAL_MEMORY_GB GB available on the system)
- **Disk:** $DISK GB
- **Virtual Machine Manager (VMM):** $VMM_MODE_TEXT
EOF
        if [[ -n "$ROSETTA" ]]; then
            echo "- **Rosetta:** $ROSETTA (for x86/amd64 emulation)" >> "$TEMP_FILE"
        fi
        echo "- **containerd:** $CONTAINERD (for pulling and storing images)" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"
        echo "### Documentation Date" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"
        echo "- **Date and Time:** $CURRENT_DATETIME" >> "$TEMP_FILE"
        echo "- **Docker Desktop Version:** $DOCKER_VERSION" >> "$TEMP_FILE"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            MACOS_VERSION=$(sw_vers -productVersion)
            echo "- **macOS Version:** $MACOS_VERSION" >> "$TEMP_FILE"
        fi
        echo "" >> "$TEMP_FILE"
    fi
    
    # Replace original file
    mv "$TEMP_FILE" "$DOCKER_CONFIG_FILE"
else
    print_error "File $DOCKER_CONFIG_FILE not found!"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_success "✅ Settings documented successfully!"
echo ""
print_step "📋 Summary of Documented Settings"
echo ""
echo "  📁 File: $(basename "$DOCKER_CONFIG_FILE")"
echo ""
echo "  📍 Settings → General → Virtual Machine:"
echo "    • VMM: $VMM_MODE_TEXT"
if [[ -n "$ROSETTA" ]]; then
    echo "    • Rosetta: $ROSETTA"
    if [[ -n "$ROSETTA_DETECTED_STATUS" ]]; then
        case "$ROSETTA_DETECTED_STATUS" in
            "active_but_not_affecting_docker")
                echo "      └─ Check: Rosetta active, but Docker using native ARM64 ✓"
                ;;
            "active_and_may_affect")
                echo "      └─ Check: Rosetta active and may be affecting Docker ⚠"
                ;;
            "inactive")
                echo "      └─ Check: Rosetta inactive on the system ✓"
                ;;
        esac
    fi
fi
echo "    • containerd: $CONTAINERD"
if [[ "$CONTAINERD_AVAILABLE" == true ]]; then
    echo "      └─ Check: containerd available (version: $CONTAINERD_VERSION)"
fi
echo ""
echo "  📍 Settings → Resources:"
echo "    • CPUs: $CPUS cores (of $TOTAL_CPUS available)"
echo "    • Memory: $MEMORY GB (of $TOTAL_MEMORY_GB GB available)"
echo "    • Disk: $DISK GB"
echo ""
echo "  📅 Date and Time: $CURRENT_DATETIME"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_info "📖 Location: $DOCS_DIR"
echo ""

