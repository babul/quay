#!/usr/bin/env bash
# Compile AGENTS.md from .ai/guidelines/ with cribsheet: a ../cribsheet checkout when present,
# otherwise the published package.
# Usage: scripts/agents.sh [check|--diff|--dry-run]
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CRIBSHEET="$REPO_ROOT/../cribsheet/bin/cribsheet.js"
cd "$REPO_ROOT"
if [[ -f "$CRIBSHEET" ]]; then
	command -v bun > /dev/null || { echo "bun is required to run cribsheet" >&2; exit 3; }
	exec bun "$CRIBSHEET" "$@" < /dev/null
else
	exec npx --yes cribsheet@^1.1.0 "$@" < /dev/null
fi
