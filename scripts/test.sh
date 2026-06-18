#!/bin/sh
# Full local test pipeline: format check, build, unit tests, functional and
# golden-diff tests. Works after a plain `git clone` with no sudo — the
# pinned Zig toolchain is downloaded automatically if missing, and the
# functional suite runs in an unprivileged user+network namespace.
#
# Everything is built ReleaseSafe so the suite exercises the same optimize
# mode we ship (scripts/release.sh), not Debug.
#
# Usage: scripts/test.sh [zfping_binary]
#   With no argument the CLI is built here. Pass a prebuilt binary (as
#   scripts/release.sh does) to run functional/golden against that exact
#   artifact instead of rebuilding it.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/zig-env.sh"
cd "$REPO_ROOT"

ZFPING_BIN="${1:-}"

echo "==> zig fmt --check"
"$ZIG" fmt --check src build.zig

if [ -z "$ZFPING_BIN" ]; then
    echo "==> zig build (ReleaseSafe)"
    "$ZIG" build -Doptimize=ReleaseSafe
    ZFPING_BIN=./zig-out/bin/zfping
fi

echo "==> zig build test (ReleaseSafe)"
"$ZIG" build test -Doptimize=ReleaseSafe --summary all

echo "==> functional tests (isolated namespace)"
sh test/functional.sh "$ZFPING_BIN"

echo "==> golden-diff tests against reference fping"
sh test/golden.sh "$ZFPING_BIN"

echo "==> all checks passed"
