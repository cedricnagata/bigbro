#!/usr/bin/env bash
# Regenerates the Xcode project and opens it.
#
#   Scripts/dev.sh          regenerate and open
#   Scripts/dev.sh --build  regenerate and build headlessly, without opening
#
# BigBro.xcodeproj is generated, not committed, so this is how you get one — and
# how you get one back after adding a file, since a new source file only enters
# the project when the spec is re-read.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(dirname "$HERE")"
cd "$APP_ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found. brew install xcodegen" >&2
    exit 1
fi

xcodegen generate

# The app has no bundled runtime in a development build, so it needs a daemon
# from somewhere. Say so once here rather than leaving an empty window to explain
# itself.
if [ ! -x "$APP_ROOT/../.venv/bin/bigbro" ]; then
    echo
    echo "note: no .venv/bin/bigbro — run 'uv sync --extra dev' in the repo root,"
    echo "      or start a daemon another way. The app attaches to whatever is"
    echo "      already running before it tries to start one."
fi

if [ "${1:-}" = "--build" ]; then
    xcodebuild -project BigBro.xcodeproj -scheme BigBro -configuration Debug build
else
    open BigBro.xcodeproj
fi
