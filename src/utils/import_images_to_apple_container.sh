#!/bin/bash

# =============================================================================
# SCRIPT TO IMPORT IMAGES FROM DOCKER INTO APPLE CONTAINER
# =============================================================================
# Imports the required images from Docker into Apple container
# Ensures that both tools use exactly the same images
# =============================================================================

set -euo pipefail

# Load common output functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_output.sh"

print_step "🔬 Image Import: Docker → Apple container"
echo ""

# =============================================================================
# INITIAL CHECKS
# =============================================================================

print_info "Checking prerequisites..."

# Check Docker
if ! command -v docker &> /dev/null; then
    print_error "Docker not found. Install Docker Desktop first."
    exit 1
fi

if ! docker info &> /dev/null; then
    print_error "Docker is not running. Start Docker Desktop first."
    print_info "Run: open -a Docker"
    exit 1
fi
print_success "✅ Docker is running"

# Check Apple container
if ! command -v container &> /dev/null; then
    print_error "Apple container not found."
    exit 1
fi

if ! container system status &> /dev/null; then
    print_warning "Apple container is not running. Trying to start..."
    if container system start &> /dev/null; then
        sleep 3
        print_success "✅ Apple container started"
    else
        print_error "Failed to start Apple container"
        exit 1
    fi
else
    print_success "✅ Apple container is running"
fi

echo ""

# =============================================================================
# IMAGES TO IMPORT
# =============================================================================

# IMPORTANT: Use fixed tags (not "latest") for scientific reproducibility
# Note: sysbench is installed dynamically inside alpine:3.24 at runtime
# If a prebuilt image is needed, it will be built locally
IMAGES=(
    "alpine:3.24"
    "nginx:stable"
)

# Optional image that will be built locally if needed
# Tag based on the sysbench version (1.0.20) and base (alpine:3.24)
SYSBENCH_IMAGE="local/sysbench:1.0.20-alpine3.24"
BUILD_SYSBENCH=false

# Temporary directory for TAR files
TMP_DIR="/tmp/docker_images_import"
mkdir -p "$TMP_DIR"

# =============================================================================
# FUNCTION TO IMPORT AN IMAGE
# =============================================================================

import_image() {
    local image=$1
    local image_name=$(echo "$image" | tr '/:' '_')
    local tar_file="$TMP_DIR/${image_name}.tar"
    
    print_info "Processing: $image"
    
    # Check whether the image exists in Docker
    if ! docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -q "^${image}$"; then
        print_warning "  Image $image not found in Docker. Pulling..."
        if ! docker pull "$image" &> /dev/null; then
            print_error "  ❌ Failed to download $image from Docker Hub"
            return 1
        fi
        print_success "  ✅ $image downloaded into Docker"
    else
        print_success "  ✅ $image already exists in Docker"
    fi
    
    # Check whether the image already exists in Apple container
    if container image ls | awk '{print $1":"$2}' | grep -q "^${image}$"; then
        print_warning "  ⚠️  $image already exists in Apple container"
        print_info "  Checking whether it is the same image..."
        
        # Capture digests
        local docker_digest=$(docker image inspect "$image" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "")
        local apple_digest=$(container image inspect "$image" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "")
        
        if [ -n "$docker_digest" ] && [ -n "$apple_digest" ] && [ "$docker_digest" = "$apple_digest" ]; then
            print_success "  ✅ Identical digests - same image already imported"
            return 0
        else
            print_warning "  ⚠️  Different or unavailable digests - re-importing..."
            # Remove existing image
            container image rm "$image" &> /dev/null || true
        fi
    fi
    
    # Export from Docker
    print_info "  Exporting $image from Docker..."
    if ! docker save "$image" -o "$tar_file" &> /dev/null; then
        print_error "  ❌ Failed to export $image from Docker"
        return 1
    fi
    print_success "  ✅ $image exported from Docker"
    
    # Import into Apple container
    print_info "  Importing $image into Apple container..."
    if ! container image load --input "$tar_file" &> /dev/null; then
        print_error "  ❌ Failed to import $image into Apple container"
        rm -f "$tar_file" &> /dev/null || true
        return 1
    fi
    print_success "  ✅ $image imported into Apple container"
    
    # Clean up temporary file
    rm -f "$tar_file" &> /dev/null || true
    
    # Check digests after import
    print_info "  Checking digests..."
    local docker_digest=$(docker image inspect "$image" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "")
    local apple_digest=$(container image inspect "$image" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "")
    
    if [ -n "$docker_digest" ] && [ -n "$apple_digest" ]; then
        if [ "$docker_digest" = "$apple_digest" ]; then
            print_success "  ✅ Identical digests confirmed - same image in both systems"
        else
            print_error "  ⚠️  WARNING: Different digests!"
            print_warning "  Docker: ${docker_digest:0:50}..."
            print_warning "  Apple container: ${apple_digest:0:50}..."
            print_warning "  The images may not be identical"
        fi
    else
        print_warning "  ⚠️  Could not verify digests (local images)"
    fi
    
    echo ""
    return 0
}

# =============================================================================
# BUILD SYSBENCH IMAGE LOCALLY (if needed)
# =============================================================================

build_sysbench_image() {
    print_info "Building sysbench image locally..."
    
    local build_dir="$TMP_DIR/sysbench_build"
    mkdir -p "$build_dir"
    
    cat > "$build_dir/Dockerfile" << 'EOF'
FROM alpine:3.24
RUN apk add --no-cache sysbench
ENTRYPOINT ["/usr/bin/sysbench"]
LABEL version="1.0.20"
LABEL base="alpine:3.24"
LABEL description="sysbench 1.0.20 on Alpine Linux 3.24"
EOF
    
    # Build in Docker
    print_info "  Building in Docker..."
    if docker build -q -t "$SYSBENCH_IMAGE" "$build_dir" &> /dev/null; then
        print_success "  ✅ sysbench image built in Docker: $SYSBENCH_IMAGE"
        
        # Export and import into Apple container
        local tar_file="$TMP_DIR/sysbench.tar"
        print_info "  Exporting from Docker..."
        if docker save "$SYSBENCH_IMAGE" -o "$tar_file" &> /dev/null; then
            print_info "  Importing into Apple container..."
            if container image load --input "$tar_file" &> /dev/null; then
                print_success "  ✅ sysbench image imported into Apple container"
                rm -f "$tar_file" &> /dev/null || true
                return 0
            else
                print_error "  ❌ Failed to import into Apple container"
                rm -f "$tar_file" &> /dev/null || true
                return 1
            fi
        else
            print_error "  ❌ Failed to export from Docker"
            return 1
        fi
    else
        print_error "  ❌ Failed to build sysbench image"
        return 1
    fi
}

# =============================================================================
# IMPORT ALL IMAGES
# =============================================================================

print_step "📦 Importing images from Docker into Apple container..."
echo ""

failed_images=()
successful_images=()

for image in "${IMAGES[@]}"; do
    if import_image "$image"; then
        successful_images+=("$image")
    else
        failed_images+=("$image")
    fi
done

# Build sysbench locally (optional, but recommended for reproducibility)
print_info ""
print_info "Note: sysbench is installed dynamically while the benchmarks run."
print_info "Building a prebuilt image for reproducibility..."
echo ""

if build_sysbench_image; then
    successful_images+=("$SYSBENCH_IMAGE (built locally)")
    BUILD_SYSBENCH=true
else
    print_warning "⚠️  Failed to build sysbench image (not critical - it will be installed dynamically)"
fi

# Clean up temporary directory
rm -rf "$TMP_DIR" &> /dev/null || true

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
print_step "📋 Import Summary"
echo ""

if [ ${#successful_images[@]} -gt 0 ]; then
    print_success "✅ Images imported successfully (${#successful_images[@]}):"
    for img in "${successful_images[@]}"; do
        echo "   - $img"
    done
    echo ""
fi

if [ ${#failed_images[@]} -gt 0 ]; then
    print_error "❌ Images that failed (${#failed_images[@]}):"
    for img in "${failed_images[@]}"; do
        echo "   - $img"
    done
    echo ""
fi

# =============================================================================
# FINAL CHECK
# =============================================================================

print_info "Checking images in Apple container..."
echo ""

all_present=true
for image in "${IMAGES[@]}"; do
    if container image ls | awk '{print $1":"$2}' | grep -q "^${image}$"; then
        print_success "  ✅ $image present in Apple container"
    else
        print_error "  ❌ $image is NOT in Apple container"
        all_present=false
    fi
done

# Check sysbench (if it was built)
if [ "$BUILD_SYSBENCH" = true ]; then
    if container image ls | awk '{print $1":"$2}' | grep -q "^${SYSBENCH_IMAGE}$"; then
        print_success "  ✅ $SYSBENCH_IMAGE present in Apple container"
    else
        print_warning "  ⚠️  $SYSBENCH_IMAGE is not in Apple container (not critical)"
    fi
fi

echo ""

if [ "$all_present" = true ]; then
    print_success "✅ All essential images are present in Apple container!"
    echo ""
    if [ "$BUILD_SYSBENCH" = true ]; then
        print_info "ℹ️  Note: The sysbench image was built locally (optional)."
        print_info "   The benchmarks install sysbench dynamically at runtime."
    fi
    echo ""
    print_info "Next steps:"
    print_info "  1. Run the collection script: ./src/utils/collect_system_info.sh"
    print_info "  2. Check digests in: docs/system_info/image_digests.md"
    print_info "  3. Confirm that digests are identical in Docker and Apple container"
else
    print_error "❌ Some essential images were not imported. Check the errors above."
    exit 1
fi

echo ""

