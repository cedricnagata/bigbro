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

# One pass, not two. Dylibs are commonly not marked executable, so the permission
# filter alone misses them — but collecting those separately listed anything
# matching both criteria twice, and duplicates are *not* harmless here: the list is
# signed in parallel below, so the same file gets two concurrent codesign processes.
# Each writes its signature by renaming a temp over the original, so they race, and
# one of them finds the file mid-swap:
#
#   libpython3.12.dylib: object file format unrecognized, invalid, or unsuitable
#   libpython3.12.dylib: No such file or directory
#
# codesign is idempotent with --force, which is why this looked safe. Idempotent is
# not the same as concurrency-safe. Widening the find and testing every candidate
# for Mach-O magic cannot produce a duplicate, and is what verify-signing.sh walks.
# The bundle's main executable is deliberately excluded. Pointed at it, codesign
# resolves the enclosing bundle and seals *that* — writing Contents/_CodeSignature
# over every resource in the app — rather than signing the one file it was given.
# Inside `xargs -P 8` that is one worker walking and sealing 1.3 GB of Resources
# while the other seven are still rewriting files in it, so it reads one that has
# been renamed out from under it:
#
#   build/BigBro.app/Contents/MacOS/BigBroApp: No such file or directory
#
# It is signed by the bundle step below, which is the only correct way to sign it.
MAIN_EXECUTABLE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"

find "$APP" -type f \( -perm +111 -o -name '*.dylib' -o -name '*.so' \) -print0 \
    | while IFS= read -r -d '' file; do
        if [ "$file" = "$MAIN_EXECUTABLE" ]; then
            continue
        fi
        if [ "$(file --mime-type -b "$file" 2>/dev/null)" = "application/x-mach-binary" ]; then
            printf '%s\0' "$file"
        fi
    done > "$BINARIES"

# Count the NUL separators. `tr -d '\0' | wc -l` counted newlines in a stream that
# has none by construction, so this always reported 0.
count="$(tr -cd '\0' < "$BINARIES" | wc -c | tr -d ' ')"
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
