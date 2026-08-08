#!/usr/bin/env bash
# Assembles BigBro.app around the binary SwiftPM produced.
#
# SwiftPM emits a bare Mach-O, not a bundle. That is fine: macOS decides what is
# an application by layout, so a binary at Contents/MacOS with an Info.plist
# beside it gets a Dock icon, a menu bar and a working Bundle.main like anything
# built by Xcode.
#
#   make-app.sh <build-dir> <output-dir> [version]
#
# The Python runtime is staged separately by stage-runtime.sh, which writes
# straight into Contents/Resources/python. Run that first for a bundle that can
# actually serve; skip it for a UI-only build that attaches to a daemon started
# some other way.
set -euo pipefail

BUILD_DIR="${1:?usage: make-app.sh <build-dir> <output-dir> [version]}"
OUTPUT_DIR="${2:?usage: make-app.sh <build-dir> <output-dir> [version]}"
VERSION="${3:-0.0.0}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(dirname "$HERE")"

APP="$OUTPUT_DIR/BigBro.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BUILD_DIR/BigBroApp" "$CONTENTS/MacOS/BigBroApp"
chmod +x "$CONTENTS/MacOS/BigBroApp"
cp "$APP_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# CFBundleVersion must increase between releases and be numeric-ish; the tag is
# the readable one. Both are rewritten here rather than committed, so a release
# never ships whatever happened to be in the file.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS/Info.plist"

# Xcode expands $(EXECUTABLE_NAME) itself; SwiftPM does not, and it names the
# binary after the target rather than the product. Nothing launches without this.
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable BigBroApp" "$CONTENTS/Info.plist"

printf 'APPL????' > "$CONTENTS/PkgInfo"

if [ -d "$APP_ROOT/Resources/Assets.xcassets" ] && command -v actool >/dev/null 2>&1; then
    actool \
        --compile "$CONTENTS/Resources" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$(mktemp)" \
        "$APP_ROOT/Resources/Assets.xcassets" >/dev/null
fi

echo "built $APP (version $VERSION)"
if [ -x "$CONTENTS/Resources/python/bin/python3" ]; then
    echo "  with a bundled runtime: $(du -sh "$CONTENTS/Resources/python" | cut -f1)"
else
    echo "  without a bundled runtime — it will look for a bigbro on PATH"
fi
