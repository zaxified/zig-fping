#!/bin/sh
# Full local test pipeline: format check, build, unit tests, functional
# tests. Works after a plain `git clone` with no sudo — the pinned Zig
# toolchain is downloaded automatically if missing, and the functional
# suite runs in an unprivileged user+network namespace.
#
# Usage: scripts/test.sh

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/zig-env.sh"
cd "$REPO_ROOT"

echo "==> zig fmt --check"
"$ZIG" fmt --check src build.zig

echo "==> zig build"
"$ZIG" build

echo "==> zig build test"
"$ZIG" build test --summary all

echo "==> functional tests (isolated namespace)"
sh test/functional.sh ./zig-out/bin/zfping

echo "==> golden-diff tests against reference fping"
sh test/golden.sh ./zig-out/bin/zfping

echo "==> all checks passed"
