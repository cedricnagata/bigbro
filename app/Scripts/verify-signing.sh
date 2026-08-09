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

# Same exclusion as sign.sh, for the same reason: handed a bundle's main
# executable, codesign resolves the enclosing bundle and reports on *that*. Left
# in, a broken bundle seal shows up here as "unsigned or invalid:
# Contents/MacOS/<exe>", which points at the one file that is not the problem.
MAIN_EXECUTABLE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"

while IFS= read -r -d '' file; do
    if [ "$file" = "$MAIN_EXECUTABLE" ]; then
        continue
    fi
    # First line only — see sign.sh. Comparing the whole output skipped every
    # universal binary, so this walked 360 of 366 and reported "all good" on a
    # bundle notarization then rejected for six unsigned fat libraries.
    if [ "$(file --mime-type -b "$file" 2>/dev/null | head -1)" != "application/x-mach-binary" ]; then
        continue
    fi
    checked=$((checked + 1))
    if ! codesign -v --strict "$file" 2>/dev/null; then
        echo "unsigned or invalid: ${file#"$APP"/}"
        failures=$((failures + 1))
    fi
done < <(find "$APP" -type f \( -perm +111 -o -name '*.dylib' -o -name '*.so' \) -print0)

echo "==> checked $checked nested binaries"

# A sealed resource that isn't on disk verifies as "No such file or directory",
# naming the bundle rather than the file it went looking for — so list the
# candidates before asking, or the error says nothing actionable.
echo "==> checking for symlinks with no target"
dangling="$(find "$APP" -type l ! -exec test -e {} \; -print 2>/dev/null || true)"
if [ -n "$dangling" ]; then
    printf '%s\n' "$dangling" | sed "s|^$APP/||" | head -20
    echo "==> $(printf '%s\n' "$dangling" | wc -l | tr -d ' ') dangling symlink(s)"
else
    echo "==> none"
fi

# Split deliberately. The shallow pass checks the bundle's own seal; the deep pass
# also walks every nested item. Which one fails says where to look, and running
# only the deep one — as this did — conflates the two.
echo "==> verifying the bundle's own seal"
shallow=0
codesign --verify --strict --verbose=4 "$APP" || shallow=$?
echo "==> shallow verify exit=$shallow"

echo "==> verifying nested code too"
deep=0
codesign --verify --deep --strict --verbose=4 "$APP" || deep=$?
echo "==> deep verify exit=$deep"

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
# Checked after the per-file summary on purpose. These used to run under `set -e`,
# so a failing bundle verify killed the script before it could report how many
# nested binaries were bad — losing the more useful number of the two.
if [ "$shallow" -ne 0 ] || [ "$deep" -ne 0 ]; then
    echo "error: bundle verification failed (shallow=$shallow deep=$deep)" >&2
    exit 1
fi
echo "==> all good"
