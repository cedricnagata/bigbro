#!/usr/bin/env bash
# Puts a complete, relocatable Python + the whole MLX stack inside the bundle.
#
#   stage-runtime.sh <app-bundle>
#
# Two decisions worth knowing about, because both are load-bearing:
#
# 1. No venv. A venv's pyvenv.cfg records `home = ` as an absolute path on the
#    machine that built it, and `uv venv --relocatable` fixes generated console
#    scripts but not that. Installing into the interpreter's own site-packages
#    and always invoking `python3 -m bigbro` sidesteps the entire problem — there
#    is one tree, and nothing in it refers to where it was built.
#
# 2. `uv sync` from the project, never a built wheel. spaCy's model is not on
#    PyPI; the URL that resolves it lives in [tool.uv.sources], which uv reads
#    from the project and does *not* carry into a wheel. Building a wheel of
#    bigbro and installing that is exactly the failure the README documents.
#    Syncing from the project directory keeps that table in play.
set -euo pipefail

APP="${1:?usage: stage-runtime.sh <app-bundle>}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$(dirname "$HERE")/.." && pwd)"
STAGE="$APP/Contents/Resources/python"

rm -rf "$STAGE"
mkdir -p "$(dirname "$STAGE")"

echo "==> installing CPython $PYTHON_VERSION into the bundle"
# python-build-standalone, which is already relocatable — that is the entire
# reason for using uv's managed interpreters rather than the system one.
uv python install "$PYTHON_VERSION" --install-dir "$(dirname "$STAGE")" --no-bin
INSTALLED="$(find "$(dirname "$STAGE")" -maxdepth 1 -type d -name 'cpython-*' | head -1)"
if [ -z "$INSTALLED" ]; then
    echo "error: uv did not leave a cpython-* directory to stage" >&2
    exit 1
fi
mv "$INSTALLED" "$STAGE"

# uv drops a minor-version alias symlink next to the versioned directory
# (cpython-3.12-macos-aarch64-none -> cpython-3.12.13-macos-aarch64-none). The
# find above takes the directory, so the move leaves that link pointing at
# nothing — inside Contents/Resources, where codesign seals it like any other
# resource and then cannot verify what it sealed:
#
#   build/BigBro.app: No such file or directory
#
# Which names the bundle, not the link, so it is worth removing at the source
# rather than diagnosing again later. Anything else uv left here is not ours
# either, and would only be dead weight in the DMG.
find "$(dirname "$STAGE")" -maxdepth 1 -name 'cpython-*' -exec rm -rf {} + 2>/dev/null || true

PYTHON="$STAGE/bin/python3"
if [ ! -x "$PYTHON" ]; then
    echo "error: no interpreter at $PYTHON" >&2
    exit 1
fi

# uv stamps its managed interpreters with a PEP 668 EXTERNALLY-MANAGED marker, and
# pip refuses to install into anything carrying one. The marker guards a *shared*
# interpreter that a package manager owns; this is a private copy inside our own
# bundle that exists to be installed into, and once staged uv does not manage it
# either. Dropping it is more honest than passing --break-system-packages, which
# would leave the shipped runtime still claiming to be somebody else's.
#
# Unanchored on purpose: the marker's path moves with the stdlib version, and at
# this point the tree is nothing but the freshly staged interpreter, so there is
# no other EXTERNALLY-MANAGED that could be caught by mistake.
find "$STAGE" -name EXTERNALLY-MANAGED -delete

echo "==> installing bigbro and the MLX stack"
# --frozen so this resolves exactly what uv.lock pins. A release that quietly
# re-resolved would ship something nobody tested.
(cd "$REPO_ROOT" && uv export --frozen --no-dev --no-emit-project --format requirements-txt \
    > "$STAGE/.requirements.txt")
"$PYTHON" -m pip install --no-cache-dir --disable-pip-version-check \
    -r "$STAGE/.requirements.txt"
(cd "$REPO_ROOT" && "$PYTHON" -m pip install --no-cache-dir --disable-pip-version-check \
    --no-deps .)
rm -f "$STAGE/.requirements.txt"

echo "==> verifying the bundled runtime can actually import bigbro"
"$PYTHON" -m bigbro --help >/dev/null

"$HERE/trim-runtime.sh" "$STAGE"

echo "==> precompiling"
# unchecked-hash is the point of this step, not -O.
#
# Default timestamp-based .pyc files record the source mtime. Copying the app out
# of a DMG changes mtimes, so every module is judged stale and recompiled on
# import — and then fails to write the result, because a signed bundle is
# read-only. That is the full compile cost of ~1.3 GB of Python on *every*
# launch, silently. unchecked-hash pycs are trusted unconditionally.
#
# The .py sources stay: spaCy and thinc resolve through catalogue, transformers
# loads modules dynamically, and inspect.getsource callers read them.
"$PYTHON" -m compileall -q -o 2 --invalidation-mode unchecked-hash "$STAGE/lib" || true

echo "==> staged $(du -sh "$STAGE" | cut -f1) at $STAGE"
