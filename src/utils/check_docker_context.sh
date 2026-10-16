#!/bin/bash

# =============================================================================
# DOCKER CONTEXT CHECK AND CONFIGURATION SCRIPT
# =============================================================================
# Checks the current Docker context and allows switching to the correct context
# for running experiments.
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

# Recommended context for experiments
RECOMMENDED_CONTEXT="desktop-linux"

print_step "Docker Context Check"
echo ""

# Check whether Docker is installed
if ! command -v docker &> /dev/null; then
    print_critical "Docker not found. Install Docker Desktop first."
    exit 1
fi

# Check whether Docker is running FIRST (before any other docker command)
# This prevents the script from exiting silently when Docker is not running
if ! docker info &> /dev/null; then
    print_critical "Docker is not running"
    print_detail "Start Docker Desktop: open -a Docker"
    print_detail "After starting Docker Desktop, run the script again"
    exit 1
fi

# Get the current context (we now know Docker is running)
CURRENT_CONTEXT=$(docker context show 2>/dev/null || echo "unknown")

print_info "Current context: ${CURRENT_CONTEXT}"

# Check whether it is the recommended context
if [ "$CURRENT_CONTEXT" = "$RECOMMENDED_CONTEXT" ]; then
    print_success "Correct context for experiments: ${RECOMMENDED_CONTEXT}"
    echo ""
    
    # Show Docker information (we now know it is running)
    print_info "Docker information:"
    if docker info 2>/dev/null | grep -E "(Context|Name|Operating System|Server Version)" | head -5 | sed 's/^/  /'; then
        : # Command executed successfully
    else
        print_warning "Could not obtain detailed Docker information"
    fi
    echo ""
    
    print_success "Docker is running"
    exit 0
else
    print_warning "Current context: ${CURRENT_CONTEXT}"
    print_warning "Recommended context for experiments: ${RECOMMENDED_CONTEXT}"
    echo ""
    
    # Show current context information (Docker is already running, verified above)
    print_info "Current context information:"
    if docker info 2>/dev/null | grep -E "(Context|Name|Operating System)" | head -3 | sed 's/^/  /'; then
        : # Command executed successfully
    else
        print_warning "Could not obtain detailed Docker information"
    fi
    echo ""
    
    # Check whether the recommended context exists (Docker is already running)
    if docker context ls 2>/dev/null | grep -q "^${RECOMMENDED_CONTEXT}"; then
        print_info "The context '${RECOMMENDED_CONTEXT}' is available."
        echo ""
        
        # Ask whether to switch
        if [ "${1:-}" = "--auto" ]; then
            # Automatic mode: switches without asking
            print_info "Automatic mode: switching to ${RECOMMENDED_CONTEXT}..."
            if docker context use "${RECOMMENDED_CONTEXT}" 2>/dev/null; then
                print_success "Context changed to ${RECOMMENDED_CONTEXT}"
                echo ""
                print_info "Docker information:"
                if docker info 2>/dev/null | grep -E "(Context|Name|Operating System|Server Version)" | head -5 | sed 's/^/  /'; then
                    : # Command executed successfully
                else
                    print_warning "Could not obtain detailed Docker information"
                fi
                exit 0
            else
                print_critical "Failed to switch context"
                print_detail "Check that Docker is running: docker info"
                exit 1
            fi
        else
            # Interactive mode: asks the user
            read -p "Switch to '${RECOMMENDED_CONTEXT}' now? (y/n) " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                if docker context use "${RECOMMENDED_CONTEXT}" 2>/dev/null; then
                    print_success "Context changed to ${RECOMMENDED_CONTEXT}"
                    echo ""
                    print_info "Docker information:"
                    if docker info 2>/dev/null | grep -E "(Context|Name|Operating System|Server Version)" | head -5 | sed 's/^/  /'; then
                        : # Command executed successfully
                    else
                        print_warning "Could not obtain detailed Docker information"
                    fi
                    exit 0
                else
                    print_critical "Failed to switch context"
                    print_detail "Check that Docker is running: docker info"
                    exit 1
                fi
            else
                print_warning "Continuing with context '${CURRENT_CONTEXT}'"
                print_important "WARNING: Experiments may produce invalid results!"
                print_detail "The experiments compare LOCAL Docker Desktop vs LOCAL Apple container"
                print_detail "Using a remote context invalidates the scientific comparison"
                exit 1
            fi
        fi
    else
        print_critical "Context '${RECOMMENDED_CONTEXT}' not found"
        print_info "Available contexts:"
        if docker context ls 2>/dev/null | sed 's/^/  /'; then
            : # Command executed successfully
        else
            print_warning "Could not list Docker contexts"
            print_detail "Check that Docker is running: docker info"
        fi
        exit 1
    fi
fi

