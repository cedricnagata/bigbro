#!/usr/bin/env bash
# Removes what a shipped runtime does not need.
#
#   trim-runtime.sh <runtime-root>
#
# Worth being conservative here. The DMG is large either way, and the difference
# between a 560 MB download and a 590 MB one is not worth a mysterious runtime
# failure on somebody else's Mac. Everything below is either not code, or code
# that only runs under a test runner.
#
# Two things this deliberately does NOT do:
#
#   * `strip -x` the dylibs. It invalidates any signature already applied and can
#     break dlopen symbol lookup, and torch dominates the total regardless.
#   * delete .py sources next to their .pyc. spaCy and thinc resolve through
#     catalogue, transformers loads modules dynamically, and anything calling
#     inspect.getsource reads them.
set -euo pipefail

ROOT="${1:?usage: trim-runtime.sh <runtime-root>}"
SITE="$(find "$ROOT/lib" -maxdepth 2 -type d -name site-packages | head -1)"

if [ -z "$SITE" ]; then
    echo "error: no site-packages under $ROOT/lib" >&2
    exit 1
fi

before="$(du -sm "$ROOT" | cut -f1)"

# Test suites shipped inside wheels. Never imported in anger.
#
# `tests` and `test` only — NOT `testing`, which shipped here once and broke every
# release it went out in. `torch/testing`, `numpy/testing` and `sympy/testing` are
# public API, not test suites, and torch imports its own on the way up:
# `torch/autograd/gradcheck.py` does `import torch.testing` at module scope. Delete
# it and `import torch` fails, which transformers catches and re-raises against
# whatever was being built at the time:
#
#   ModuleNotFoundError: Could not import module 'AutoTokenizer'.
#                        Are this object's requirements defined correctly?
#
# — a message that names neither torch nor this script, and reaches the user as a
# failed inference call on an iPhone. The convention that a directory called
# `tests` is disposable does not extend to `testing`.
find "$SITE" -type d \( -name tests -o -name test \) -prune -exec rm -rf {} + 2>/dev/null || true

# C++ headers for building against torch, which nothing here does.
rm -rf "$SITE/torch/include" "$SITE/torch/utils/tensorboard" 2>/dev/null || true

# Static archives are for linking, not loading.
find "$SITE" -name '*.a' -delete 2>/dev/null || true

# The interpreter's own test package and its static lib.
rm -rf "$ROOT/lib/python"*/test "$ROOT/lib/python"*/idlelib "$ROOT/lib/python"*/turtledemo 2>/dev/null || true
find "$ROOT/lib" -name 'libpython*.a' -delete 2>/dev/null || true

# Superseded by the -O2 pass in stage-runtime.sh.
find "$SITE" -name '*.opt-1.pyc' -delete 2>/dev/null || true

after="$(du -sm "$ROOT" | cut -f1)"
echo "==> trimmed ${before} MB to ${after} MB"
