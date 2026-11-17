#!/usr/bin/env bash
# Runs the addon's busted specs in real Lua 5.1. Uses the first of:
#   1. .lua/bin/busted         a repo-local hererocks install (see README.md)
#   2. busted on PATH          when it runs Lua 5.1
#   3. Docker                  the image in test/docker, built once and cached
# Exits 3 when none is available, so callers can report "skipped" rather than a failure.
# Any arguments are passed to busted (e.g. ./busted.sh test/hmac_spec.lua).
set -euo pipefail
ADDON="$(cd "$(dirname "$0")" && pwd)"
cd "$ADDON"

if [ -x "$ADDON/.lua/bin/busted" ]; then exec "$ADDON/.lua/bin/busted" "$@"; fi
if command -v busted >/dev/null 2>&1 && busted --version >/dev/null 2>&1 && lua -v 2>&1 | grep -q "Lua 5\.1"; then exec busted "$@"; fi

# `docker info` can hang while Docker Desktop is starting or broken, so give it 10 seconds where `timeout` exists.
docker_ready() {
    command -v docker >/dev/null 2>&1 || return 1
    if command -v timeout >/dev/null 2>&1; then timeout 10 docker info >/dev/null 2>&1; else docker info >/dev/null 2>&1; fi
}

if docker_ready; then
    IMAGE="lfgplus-busted:$(sha256sum "$ADDON/test/docker/Dockerfile" | cut -c1-12)"
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "Building $IMAGE (once; cached afterwards)" >&2
        docker build -q -t "$IMAGE" "$ADDON/test/docker" >/dev/null
    fi
    MOUNT="$ADDON"
    # Git Bash: hand Docker a Windows path and stop MSYS rewriting the container paths.
    if command -v cygpath >/dev/null 2>&1; then MOUNT="$(cygpath -w "$ADDON")"; export MSYS_NO_PATHCONV=1; fi
    # The addon is read-only inside; .coverage, when it exists, is writable for the coverage run (coverage.sh).
    COVERAGE=()
    if [ -d "$ADDON/.coverage" ]; then
        COVERAGE_DIR="$ADDON/.coverage"
        if command -v cygpath >/dev/null 2>&1; then COVERAGE_DIR="$(cygpath -w "$COVERAGE_DIR")"; fi
        COVERAGE=(-v "$COVERAGE_DIR:/addon/.coverage")
    fi
    exec docker run --rm -v "$MOUNT:/addon:ro" ${COVERAGE[@]+"${COVERAGE[@]}"} -w /addon "$IMAGE" busted "$@"
fi

echo "No Lua 5.1 busted found: install one with hererocks (README.md) or start Docker." >&2
exit 3
