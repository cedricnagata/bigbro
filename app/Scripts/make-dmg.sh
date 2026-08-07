#!/usr/bin/env bash
# Wraps the app in a drag-to-Applications disk image.
#
#   make-dmg.sh <app-bundle> <output.dmg> [volume-name]
#
# ULFO (LZFSE) rather than UDZO (zlib) or ULMO (LZMA). LZMA is a little smaller
# but noticeably slower to mount, and mounting is something every single user
# does once while watching. LZFSE lands within a few percent of LZMA and mounts
# quickly. Supported since 10.11; the floor here is 14.
set -euo pipefail

APP="${1:?usage: make-dmg.sh <app-bundle> <output.dmg> [volume-name]}"
OUTPUT="${2:?usage: make-dmg.sh <app-bundle> <output.dmg> [volume-name]}"
VOLUME="${3:-BigBro}"

rm -f "$OUTPUT"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
# The half of drag-to-install that people actually understand.
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "$VOLUME" \
    -srcfolder "$STAGING" \
    -ov \
    -format ULFO \
    "$OUTPUT"

echo "==> $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
