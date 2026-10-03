#!/usr/bin/env bash
# Detect Intent Layer state in a project
# Usage: bash detect_state.sh [path]
# Returns state: "none" | "partial" | "complete"

set -e

TARGET_PATH="${1:-.}"
TARGET_PATH="${TARGET_PATH%/}"   # normalize trailing slash

ROOT_FILE=""
HAS_INTENT_SECTION=false
CHILD_NODES=()

# The Intent Layer has exactly one root context file: AGENTS.md
if [ -f "$TARGET_PATH/AGENTS.md" ]; then
    ROOT_FILE="AGENTS.md"
fi

# Check for Intent Layer section
if [ -n "$ROOT_FILE" ] && grep -q "## Intent Layer" "$TARGET_PATH/$ROOT_FILE" 2>/dev/null; then
    HAS_INTENT_SECTION=true
fi

# Find child AGENTS.md files (exclude the root file, .git, node_modules)
while IFS= read -r file; do
    CHILD_NODES+=("$file")
done < <(find "$TARGET_PATH" \
    \( -path "*/.git" -o -path "*/node_modules" \) -prune \
    -o -type f -name "AGENTS.md" ! -path "$TARGET_PATH/AGENTS.md" -print 2>/dev/null)

# Output state
echo "=== Intent Layer State ==="
echo "root_file: ${ROOT_FILE:-none}"
echo "has_intent_section: $HAS_INTENT_SECTION"
echo "child_nodes: ${#CHILD_NODES[@]}"

for node in "${CHILD_NODES[@]}"; do
    echo "  - $node"
done

echo ""
if [ -z "$ROOT_FILE" ]; then
    echo "state: none"
    if [ "${#CHILD_NODES[@]}" -gt 0 ]; then
        echo "action: create root AGENTS.md and link the existing child nodes in its Intent Layer section"
    else
        echo "action: initial setup required (create root AGENTS.md)"
    fi
elif [ "$HAS_INTENT_SECTION" = false ]; then
    echo "state: partial"
    echo "action: add Intent Layer section to $ROOT_FILE"
else
    echo "state: complete"
    echo "action: maintenance mode (audit/candidates/both)"
fi
