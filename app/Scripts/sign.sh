#!/usr/bin/env bash
# Signs every Mach-O in the bundle, inside out.
#
#   sign.sh <app-bundle> <signing-identity>
#
# `codesign --deep` is deprecated and Apple says not to rely on it, so nested
# code is signed explicitly, innermost first, and the bundle itself last.
#
# Binaries are found by Mach-O magic rather than by extension. Several wheels in
# the MLX stack ship executables and dylibs whose names end in neither .so nor
# .dylib, and one missed file is a notarization rejection fifteen minutes later
# rather than an error here.
set -euo pipefail

APP="${1:?usage: sign.sh <app-bundle> <identity>}"
IDENTITY="${2:?usage: sign.sh <app-bundle> <identity>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="$(dirname "$HERE")/Resources/BigBro.entitlements"

echo "==> finding Mach-O binaries"
BINARIES="$(mktemp)"
trap 'rm -f "$BINARIES"' EXIT

find "$APP" -type f -perm +111 -print0 \
    | while IFS= read -r -d '' file; do
        if [ "$(file --mime-type -b "$file" 2>/dev/null)" = "application/x-mach-binary" ]; then
            printf '%s\0' "$file"
        fi
    done > "$BINARIES"

# Dylibs are commonly not marked executable, so the permission filter above misses
# them. Catch them by extension as well; duplicates are harmless, codesign is
# idempotent with --force.
find "$APP" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 >> "$BINARIES"

count="$(tr -d '\0' < "$BINARIES" | wc -l | tr -d ' ')"
echo "==> signing nested code"

# -P 8: serially this is a minute and a half of process spawns for no reason.
xargs -0 -P 8 -n 1 codesign \
    --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" < "$BINARIES"

echo "==> signing the bundle"
codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"

echo "==> signed (${count}+ nested binaries)"
