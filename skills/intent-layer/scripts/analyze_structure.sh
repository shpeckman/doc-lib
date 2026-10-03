#!/usr/bin/env bash
# Analyze codebase structure for Intent Layer placement
# Usage: bash analyze_structure.sh [path]

set -e

TARGET_PATH="${1:-.}"
TARGET_PATH="${TARGET_PATH%/}"   # normalize trailing slash

# Directories never worth analyzing
PRUNE=( -path "*/.git" -o -path "*/node_modules" -o -path "*/dist"
        -o -path "*/.next" -o -path "*/build" -o -path "*/__pycache__"
        -o -path "*/coverage" -o -path "*/vendor" -o -path "*/target" )

echo "=== Intent Layer Structure Analysis ==="
echo "Target: $TARGET_PATH"
echo ""

echo "## Directory Structure (depth 3)"
find "$TARGET_PATH" -maxdepth 3 \( "${PRUNE[@]}" \) -prune -o -type d -print 2>/dev/null | head -50

echo ""
echo "## Existing Intent Nodes"
find "$TARGET_PATH" \( "${PRUNE[@]}" \) -prune -o -type f -name "AGENTS.md" -print 2>/dev/null | head -20

echo ""
echo "## Large Directories (potential boundaries)"
echo "(Directories with >20 files)"
find "$TARGET_PATH" \( "${PRUNE[@]}" \) -prune -o -type d -print 2>/dev/null | while IFS= read -r dir; do
    count=$(find "$dir" -maxdepth 1 -type f | wc -l | tr -d ' ')
    if [ "$count" -gt 20 ]; then
        echo "$count files: $dir"
    fi
done | sort -rn | head -15

echo ""
echo "## Package/Config Files (semantic boundaries)"
find "$TARGET_PATH" -maxdepth 4 \( "${PRUNE[@]}" \) -prune -o -type f \
    \( -name "package.json" -o -name "Cargo.toml" -o -name "go.mod" -o -name "pyproject.toml" \) \
    -print 2>/dev/null | head -20

echo ""
echo "## Suggested Intent Node Locations"
echo "1. Root: $TARGET_PATH/AGENTS.md (required)"

n=1
for dir in src lib app packages services api; do
    if [ -d "$TARGET_PATH/$dir" ]; then
        n=$((n + 1))
        echo "$n. Source: $TARGET_PATH/$dir/AGENTS.md"
    fi
done

echo ""
echo "Next: run estimate_tokens.sh on each candidate directory to decide which need their own node."
echo "Thresholds are defined in SKILL.md (Node Thresholds)."
