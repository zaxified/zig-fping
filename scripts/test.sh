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
#
# Golden reference: FPING_REF=<path> pins one fping binary. Otherwise the
# pinned fping 5.5 is built (cached) by scripts/fping-ref.sh, and the
# distro fping (e.g. 5.1) is diffed as well when installed, so both the
# oldest and the newest supported reference are covered. If 5.5 cannot be
# built (no C compiler / network), the distro fping alone is used.

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
if [ -n "${FPING_REF:-}" ]; then
    sh test/golden.sh "$ZFPING_BIN" "$FPING_REF"
else
    SYS_FPING=$(command -v fping || true)
    if REF55=$(sh scripts/fping-ref.sh); then
        sh test/golden.sh "$ZFPING_BIN" "$REF55"
        if [ -n "$SYS_FPING" ]; then
            sh test/golden.sh "$ZFPING_BIN" "$SYS_FPING"
        fi
    else
        echo "warning: fping 5.5 reference unavailable, using the system fping" >&2
        sh test/golden.sh "$ZFPING_BIN" "$SYS_FPING"
    fi
fi

echo "==> all checks passed"
