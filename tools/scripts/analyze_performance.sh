#!/bin/bash
#
# Sorbet Performance Analysis Script
#
# This script helps you analyze your codebase and tune Sorbet's performance settings.
#
# Usage:
#   ./tools/scripts/analyze_performance.sh [path-to-project]
#

set -e

PROJECT_PATH="${1:-.}"
SORBET_BIN="${SORBET_BIN:-sorbet}"

echo "=============================================="
echo "Sorbet Performance Analysis"
echo "=============================================="
echo ""
echo "Analyzing: $PROJECT_PATH"
echo ""

# Check if sorbet is available
if ! command -v "$SORBET_BIN" &> /dev/null; then
    echo "Error: sorbet not found. Set SORBET_BIN environment variable."
    exit 1
fi

# Create temporary file for metrics
METRICS_FILE=$(mktemp)
trap "rm -f $METRICS_FILE" EXIT

echo "Running Sorbet with counters enabled..."
echo ""

# Run sorbet with counters
"$SORBET_BIN" --counters --typed=strict --silence-dev-message "$PROJECT_PATH" 2>&1 | tee "$METRICS_FILE" || true

echo ""
echo "=============================================="
echo "Analysis Results"
echo "=============================================="
echo ""

# Extract key metrics
echo "Key Metrics:"
echo "------------"

# Count files
FILE_COUNT=$(grep -E "^types\.input\.files" "$METRICS_FILE" | head -1 | awk '{print $NF}' || echo "unknown")
echo "Total files: $FILE_COUNT"

# Count classes
CLASS_COUNT=$(grep -E "^types\.input\.(classes|modules)" "$METRICS_FILE" | awk '{sum += $NF} END {print sum}' || echo "unknown")
echo "Classes/Modules: $CLASS_COUNT"

# Count methods
METHOD_COUNT=$(grep -E "^types\.input\.methods" "$METRICS_FILE" | awk '{print $NF}' || echo "unknown")
echo "Methods: $METHOD_COUNT"

echo ""
echo "=============================================="
echo "Recommended Configuration"
echo "=============================================="
echo ""
echo "Based on your codebase analysis, here are recommended settings:"
echo ""
echo "# Add these to your sorbet/config file:"
echo "--cache-dir=.sorbet-cache"

# Generate recommended table sizes (2x the actual count, rounded to power of 2)
if [ "$CLASS_COUNT" != "unknown" ] && [ -n "$CLASS_COUNT" ]; then
    # Calculate next power of 2 that's at least 2x the count
    RECOMMENDED_CLASS=$(python3 -c "import math; v=int('$CLASS_COUNT')*2; print(2**math.ceil(math.log2(max(v,1024))))" 2>/dev/null || echo "16384")
    echo "--reserve-class-table-capacity=$RECOMMENDED_CLASS"
fi

if [ "$METHOD_COUNT" != "unknown" ] && [ -n "$METHOD_COUNT" ]; then
    RECOMMENDED_METHOD=$(python3 -c "import math; v=int('$METHOD_COUNT')*2; print(2**math.ceil(math.log2(max(v,4096))))" 2>/dev/null || echo "65536")
    echo "--reserve-method-table-capacity=$RECOMMENDED_METHOD"
fi

echo ""
echo "=============================================="
echo "Quick Performance Tips"
echo "=============================================="
echo ""
echo "1. Enable caching: --cache-dir=.sorbet-cache"
echo "2. For memory-constrained systems: --threads=2"
echo "3. For large codebases: Use the reserve-*-table-capacity options above"
echo "4. For LSP mode: Tune --lsp-max-files-on-fast-path (default: 50)"
echo ""
echo "See PERFORMANCE_OPTIMIZATIONS.md for detailed guidance."
