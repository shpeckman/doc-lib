#!/usr/bin/env bash
# Estimate token count for a directory or a single file.
#
# Usage:
#     bash estimate_tokens.sh <path>     # directory or file
#
# Token estimation: ~4 bytes per token (rough approximation).
# Thresholds (20k / 64k / 4k) are defined in SKILL.md → "Node Thresholds".

set -e

TARGET_PATH="${1:-.}"

if [ ! -e "$TARGET_PATH" ]; then
    echo "Error: Path not found: $TARGET_PATH"
    exit 1
fi

# Source and doc extensions included in the estimate
EXTENSIONS="ts tsx js jsx mjs cjs py go rs java rb php swift kt c cc cpp h hpp cs cr ecr vue svelte astro md mdx json yaml yml toml sql graphql prisma sh"

# Lock files and generated artifacts excluded (they inflate estimates without adding intent)
EXCLUDE_NAMES="package-lock.json yarn.lock pnpm-lock.yaml Cargo.lock Gemfile.lock poetry.lock composer.lock Pipfile.lock go.sum bun.lockb"

NAME_EXPR=()
first=1
for ext in $EXTENSIONS; do
    if [ "$first" -eq 1 ]; then
        NAME_EXPR+=( \( -name "*.$ext" )
        first=0
    else
        NAME_EXPR+=( -o -name "*.$ext" )
    fi
done
NAME_EXPR+=( \) ! -name "*.min.js" ! -name "*.min.css" ! -name "*.map" )
for lock in $EXCLUDE_NAMES; do
    NAME_EXPR+=( ! -name "$lock" )
done

PRUNE=( -path "*/node_modules" -o -path "*/.git" -o -path "*/dist"
        -o -path "*/.next" -o -path "*/build" -o -path "*/__pycache__"
        -o -path "*/coverage" -o -path "*/vendor" -o -path "*/target" )

LABEL=$(basename "$TARGET_PATH")
echo "=== Token Estimate: $LABEL ==="
echo ""

if [ -f "$TARGET_PATH" ]; then
    BYTES=$(wc -c < "$TARGET_PATH" | tr -d ' ')
    FILE_COUNT=1
else
    BYTES=$(find "$TARGET_PATH" \( "${PRUNE[@]}" \) -prune -o -type f "${NAME_EXPR[@]}" \
        -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
    FILE_COUNT=$(find "$TARGET_PATH" \( "${PRUNE[@]}" \) -prune -o -type f "${NAME_EXPR[@]}" \
        -print 2>/dev/null | wc -l | tr -d ' ')
fi

BYTES=${BYTES:-0}
TOKENS=$((BYTES / 4))

FORMATTED=$(awk -v t="$TOKENS" 'BEGIN {
    if (t >= 1000000) printf "%.1fM", t / 1000000
    else if (t >= 1000) printf "%.1fk", t / 1000
    else printf "%d", t
}')

echo "Total tokens: ~$FORMATTED ($TOKENS)"
echo "File count: $FILE_COUNT"
echo ""

if [ -f "$TARGET_PATH" ]; then
    if [ "$TOKENS" -le 4000 ]; then
        echo "Node size: under 4k tokens — within the per-node guideline"
    else
        echo "Node size: over 4k tokens — compress before finalizing (see references/node-examples.md)"
    fi
elif [ "$TOKENS" -lt 20000 ]; then
    echo "Threshold: <20k"
    echo "Recommendation: No dedicated Intent Node needed"
elif [ "$TOKENS" -lt 64000 ]; then
    echo "Threshold: 20-64k"
    echo "Recommendation: Good candidate for 2-3k token Intent Node"
else
    echo "Threshold: >64k"
    echo "Recommendation: Consider splitting into child Intent Nodes"
fi
