#!/usr/bin/env bash
# Asserts every Mach-O in the bundle is properly signed, before notarization.
#
#   verify-signing.sh <app-bundle>
#
# Exists because notarization takes minutes to tell you that one file out of
# three thousand is unsigned, and tells you so only after the upload. This walks
# the same set the signing script does and fails in about thirty seconds instead.
set -euo pipefail

APP="${1:?usage: verify-signing.sh <app-bundle>}"

failures=0
checked=0

while IFS= read -r -d '' file; do
    if [ "$(file --mime-type -b "$file" 2>/dev/null)" != "application/x-mach-binary" ]; then
        continue
    fi
    checked=$((checked + 1))
    if ! codesign -v --strict "$file" 2>/dev/null; then
        echo "unsigned or invalid: ${file#"$APP"/}"
        failures=$((failures + 1))
    fi
done < <(find "$APP" -type f \( -perm +111 -o -name '*.dylib' -o -name '*.so' \) -print0)

echo "==> checked $checked nested binaries"

echo "==> verifying the bundle itself"
codesign --verify --deep --strict --verbose=2 "$APP"

# The question notarization actually asks. `spctl` reports rejection here for an
# un-notarized build, which is expected before submission — so it is reported,
# not fatal.
if ! spctl --assess --type execute --verbose=2 "$APP" 2>&1; then
    echo "note: not yet accepted by Gatekeeper — expected until it has been notarized and stapled"
fi

if [ "$failures" -gt 0 ]; then
    echo "error: $failures binaries would fail notarization" >&2
    exit 1
fi
echo "==> all good"
