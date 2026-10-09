#!/usr/bin/env bash
# Compile AGENTS.md from .ai/guidelines/ with the sibling cribsheet checkout.
# Usage: scripts/agents.sh [check|--diff|--dry-run]
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CRIBSHEET="$REPO_ROOT/../cribsheet/bin/cribsheet.js"
[[ -f "$CRIBSHEET" ]] || { echo "cribsheet not found at $CRIBSHEET" >&2; exit 3; }
command -v bun > /dev/null || { echo "bun is required to run cribsheet" >&2; exit 3; }
cd "$REPO_ROOT"
exec bun "$CRIBSHEET" "$@" < /dev/null
