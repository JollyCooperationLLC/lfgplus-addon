#!/usr/bin/env bash
# Packages LFGPlus/ as the zip players install: one top-level LFGPlus folder, as the game's AddOns folder expects,
# with the licence beside the code and the TOC's version set to the one given.
#
#   tools/package.sh <version>    writes dist/LFGPlus-<version>.zip and prints its path
#
# The development data add-on (LFGPlus_Data_*) is never packaged: players get the daily data from lfg.plus.
set -euo pipefail

VERSION="${1:?usage: tools/package.sh <version>}"
if [[ ! "$VERSION" =~ ^[0-9A-Za-z.+-]+$ ]]; then
    echo "package.sh: a version is letters, digits, dots, plus and minus signs only (got \"$VERSION\")" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$ROOT/LFGPlus" "$STAGE/LFGPlus"
cp "$ROOT/LICENSE" "$STAGE/LFGPlus/LICENSE.txt"

# The version the game shows (and LFG+ prints) comes from this one line of the TOC.
TOC="$STAGE/LFGPlus/LFGPlus.toc"
sed -i.orig "s/^## Version:.*/## Version: $VERSION/" "$TOC"
rm "$TOC.orig"
if ! grep -q "^## Version: $VERSION" "$TOC"; then
    echo "package.sh: LFGPlus.toc has no ## Version line to set" >&2
    exit 1
fi

mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/LFGPlus-$VERSION.zip"
rm -f "$OUT"
if command -v zip >/dev/null 2>&1; then
    (cd "$STAGE" && zip -qr -X "$OUT" LFGPlus)
else
    # Without zip (Git Bash on Windows, for instance), Python's zipfile does the same.
    PYTHON="$(command -v python3 || command -v python)"
    (cd "$STAGE" && "$PYTHON" -m zipfile -c "$OUT" LFGPlus)
fi
echo "$OUT"
