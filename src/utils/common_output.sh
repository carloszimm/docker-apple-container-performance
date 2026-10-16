#!/bin/bash

# =============================================================================
# COMMON OUTPUT FUNCTIONS
# =============================================================================
# Common output functions for project scripts
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/common_output.sh"
# 
# To use emoji style (default for benchmarks):
#   enable_emoji_output
#   or set the environment variable: OUTPUT_STYLE=emoji
# =============================================================================

# ANSI colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Output style (can be "tag" or "emoji")
# Controlled via the OUTPUT_STYLE environment variable or the enable_emoji_output() function
OUTPUT_STYLE=${OUTPUT_STYLE:-tag}

# Function to enable emoji style
enable_emoji_output() {
    OUTPUT_STYLE="emoji"
}

# Function to enable tag style (default)
enable_tag_output() {
    OUTPUT_STYLE="tag"
}

# Standardized output functions
# Format: [TAG] message (default for technical scripts)
# or with emojis if OUTPUT_STYLE=emoji
# NOTE: The functions already add emojis, so do NOT include emojis in the message passed

# Helper function to remove duplicated emojis from the message
_clean_message() {
    local msg="$1"
    # Remove ALL emojis from the start of the message (including multiple consecutive emojis)
    # List of common emojis used in the project
    local emoji_pattern="(✅|⚠️|ℹ️|❌|🔬|🚀|📊|💻|🧠|🌐|💾|📋|🧪|🧮|✓|⚠|🔍|📝|🎯|⚡|🔧|📦|🔄|⏱️|📈|📉|🎉|💡|🔒|🔓|🛠️|📌|📍|🎨|🌟|⭐|💫|🔥|💯|🎊|🎁|🎈|🎀|🎪|🎭|🎬|🎮|🎲|🎰|🎸|🎺|🎻|🎤|🎧)"
    # Remove repeated emojis at the start (with optional spaces between them)
    while echo "$msg" | grep -qE "^[[:space:]]*${emoji_pattern}[[:space:]]*"; do
        msg=$(echo "$msg" | sed -E "s/^[[:space:]]*${emoji_pattern}[[:space:]]*//")
    done
    # Remove remaining leading spaces
    echo "$msg" | sed -E 's/^[[:space:]]+//'
}

print_info() {
    local msg=$(_clean_message "$1")
    if [ "$OUTPUT_STYLE" = "emoji" ]; then
        echo -e "${BLUE}ℹ️  ${msg}${NC}"
    else
        echo -e "${BLUE}[INFO]${NC} ${msg}"
    fi
}

print_success() {
    local msg=$(_clean_message "$1")
    if [ "$OUTPUT_STYLE" = "emoji" ]; then
        echo -e "${GREEN}✅ ${msg}${NC}"
    else
        echo -e "${GREEN}[SUCCESS]${NC} ${msg}"
    fi
}

print_warning() {
    local msg=$(_clean_message "$1")
    if [ "$OUTPUT_STYLE" = "emoji" ]; then
        echo -e "${YELLOW}⚠️  ${msg}${NC}"
    else
        echo -e "${YELLOW}[WARNING]${NC} ${msg}"
    fi
}

print_error() {
    local msg=$(_clean_message "$1")
    if [ "$OUTPUT_STYLE" = "emoji" ]; then
        echo -e "${RED}❌ ${msg}${NC}"
    else
        echo -e "${RED}[ERROR]${NC} ${msg}"
    fi
}

# Functions for improved visual hierarchy
# Level 1: Critical - Errors that prevent execution
print_critical() {
    local msg=$(_clean_message "$1")
    echo ""
    if [ "$OUTPUT_STYLE" = "emoji" ]; then
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}❌ CRITICAL: ${msg}${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${RED}[CRITICAL]${NC} ${msg}"
    fi
    echo ""
}

# Level 2: Important - Warnings that require attention
print_important() {
    local msg=$(_clean_message "$1")
    if [ "$OUTPUT_STYLE" = "emoji" ]; then
        echo -e "${YELLOW}⚠️  IMPORTANT: ${msg}${NC}"
    else
        echo -e "${YELLOW}[IMPORTANT]${NC} ${msg}"
    fi
}

# Level 3: Informational - General information (no emoji, color only)
print_info_plain() {
    local msg=$(_clean_message "$1")
    if [ "$OUTPUT_STYLE" = "emoji" ]; then
        echo -e "${BLUE}   ${msg}${NC}"
    else
        echo -e "${BLUE}[INFO]${NC} ${msg}"
    fi
}

# Level 4: Success - Confirmations (print_success already exists)
# Level 5: Details - Secondary information with indentation
print_detail() {
    local msg=$(_clean_message "$1")
    if [ "$OUTPUT_STYLE" = "emoji" ]; then
        echo -e "${CYAN}    → ${msg}${NC}"
    else
        echo -e "${CYAN}[DETAIL]${NC} ${msg}"
    fi
}

print_step() {
    local msg=$(_clean_message "$1")
    if [ "$OUTPUT_STYLE" = "emoji" ]; then
        echo -e "${PURPLE}🔹 ${msg}${NC}"
    else
        echo -e "${PURPLE}[STEP]${NC} ${msg}"
    fi
}

# Function for visual separator
print_separator() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Function for benchmark header
print_benchmark_header() {
    local benchmark_num=$1
    local total=$2
    local benchmark_name=$3
    local mode=${4:-""}  # Optional: "validation", etc.
    
    print_separator
    if [ -n "$mode" ]; then
        # Build title without emoji for length calculation
        local title_no_emoji="BENCHMARK ${benchmark_num}/${total}: ${benchmark_name} (${mode})"
        local title_with_emoji="🚀 BENCHMARK ${benchmark_num}/${total}: ${benchmark_name} (${mode})"
        # Compute visual width (emoji counts as 2 visual characters)
        local title_len=$((${#title_no_emoji} + 2))  # +2 for the 🚀 emoji
        local box_width=66
        local padding=$(( (box_width - title_len) / 2 ))
        local spaces=""
        for ((i=0; i<padding; i++)); do
            spaces="${spaces} "
        done
        # Adjust if needed to ensure the line has exactly box_width characters
        local right_padding=$((box_width - title_len - padding))
        local right_spaces=""
        for ((i=0; i<right_padding; i++)); do
            right_spaces="${right_spaces} "
        done
        echo "╔════════════════════════════════════════════════════════════════════════╗"
        echo "║${spaces}${title_with_emoji}${right_spaces}║"
        echo "╚════════════════════════════════════════════════════════════════════════╝"
    else
        # Build title without emoji for length calculation
        local title_no_emoji="BENCHMARK ${benchmark_num}/${total}: ${benchmark_name}"
        local title_with_emoji="🚀 BENCHMARK ${benchmark_num}/${total}: ${benchmark_name}"
        # Compute visual width (emoji counts as 2 visual characters)
        local title_len=$((${#title_no_emoji} + 2))  # +2 for the 🚀 emoji
        local box_width=66
        local padding=$(( (box_width - title_len) / 2 ))
        local spaces=""
        for ((i=0; i<padding; i++)); do
            spaces="${spaces} "
        done
        # Adjust if needed to ensure the line has exactly box_width characters
        local right_padding=$((box_width - title_len - padding))
        local right_spaces=""
        for ((i=0; i<right_padding; i++)); do
            right_spaces="${right_spaces} "
        done
        echo "╔════════════════════════════════════════════════════════════════════════╗"
        echo "║${spaces}${title_with_emoji}${right_spaces}║"
        echo "╚════════════════════════════════════════════════════════════════════════╝"
    fi
    echo ""
}

# Function for progress indicator
print_progress() {
    local current=$1
    local total=$2
    
    # Compute percentage
    local percent=$((current * 100 / total))
    
    # Create progress bar (20 characters)
    local filled=$((current * 20 / total))
    local empty=$((20 - filled))
    
    local bar=""
    for ((i=0; i<filled; i++)); do
        bar="${bar}█"
    done
    for ((i=0; i<empty; i++)); do
        bar="${bar}░"
    done
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📊 PROGRESS: [${bar}] ${current}/${total} benchmarks completed (${percent}%)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}
