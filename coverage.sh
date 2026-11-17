#!/usr/bin/env bash
# The coverage check: runs every busted spec in Lua 5.1 with luacov (lines) and the branch
# counter in test/helpers/coverage.lua, then fails unless every line and branch of the addon's own files ran.
# Uses busted.sh, so the same hererocks / PATH / Docker choice applies. Exits 3 when no Lua 5.1 busted is available.
set -euo pipefail
ADDON="$(cd "$(dirname "$0")" && pwd)"

rm -rf "$ADDON/.coverage"
mkdir -p "$ADDON/.coverage"
"$ADDON/busted.sh" --coverage --helper=test/helpers/coverage_helper.lua "$@"
node "$ADDON/tools/check-coverage.mjs"
