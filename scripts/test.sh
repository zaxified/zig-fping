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

# Unit tests run through scripts/netns-run: a double user namespace with a
# live loopback and unprivileged ICMP sockets but no CAP_NET_RAW, so the
# live-socket tests run instead of skipping on hosts without ping_group_range.
# The test run steps have side effects (build.zig), so they execute on every
# run; only the compilation is cached.
echo "==> zig build test (ReleaseSafe, double user namespace)"
TEST_LOG=$(mktemp)
trap 'rm -f "$TEST_LOG"' EXIT
if ! "$REPO_ROOT/scripts/netns-run" "$ZIG" build test -Doptimize=ReleaseSafe \
    --summary all >"$TEST_LOG" 2>&1; then
    cat "$TEST_LOG"
    echo "error: unit tests failed" >&2
    exit 1
fi
cat "$TEST_LOG"

# Skip guard: a skipped test passes silently, so count the skips in the
# summary ("run test <N> pass, <M> skip (<T> total)" per test binary).
# Intended skips are the deterministic fuzz-driver tests, which skip unless
# ZFPING_FUZZ is set: "fuzz driver: icmp", "fuzz driver: rdns" (library
# binary), "fuzz driver: options", "fuzz driver: generate" (CLI binary).
# The summary does not name skipped tests, so the expected count is pinned.
# Any other skip (no loopback, no ICMP socket, no IPv6) fails the gate.
EXPECTED_SKIPS=4
RAN=$(grep -c 'run test .* pass' "$TEST_LOG" || true)
SKIPPED=$(sed -n 's/.*run test .* \([0-9][0-9]*\) skip.*/\1/p' "$TEST_LOG" | awk '{ n += $1 } END { print n + 0 }')
if [ "$RAN" -eq 0 ]; then
    echo "error: no 'run test' lines in the unit-test summary; cannot check skips" >&2
    exit 1
fi
if [ "$SKIPPED" -ne "$EXPECTED_SKIPS" ]; then
    echo "error: $SKIPPED skipped unit tests, expected exactly $EXPECTED_SKIPS (the fuzz-driver tests)" >&2
    exit 1
fi
echo "unit tests: $SKIPPED skips, all intended (fuzz drivers)"

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
