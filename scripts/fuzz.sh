#!/bin/sh
# Continuous-fuzzing entry point: runs the in-tree fuzz tests (ICMP and
# DNS-response parsers, CLI option and target-list parsers) under Zig's
# built-in fuzzer for a bounded time window.
#
# Usage: scripts/fuzz.sh [seconds]    (default: 300)
#
# KNOWN ISSUE: Zig 0.16.0 cannot compile its own fuzz test runner
# (lib/compiler/test_runner.zig: *builtin.StackTrace vs *debug.StackTrace
# mismatch), so instrumented fuzzing fails on the pinned toolchain. The
# fuzz bodies still execute as smoke tests in every `zig build test`.
# Re-run this script after the next .zigversion bump; wire it into CI
# (scheduled job) once the toolchain compiles it.

set -eu

SECONDS_TO_RUN="${1:-300}"

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/zig-env.sh"
cd "$REPO_ROOT"

echo "==> fuzzing for ${SECONDS_TO_RUN}s (zig build test --fuzz)"
log=$(mktemp)
trap 'rm -f "$log"' EXIT

# timeout exit 124 means the window elapsed without a crash — success.
rc=0
timeout "$SECONDS_TO_RUN" "$ZIG" build test --fuzz >"$log" 2>&1 || rc=$?
sed 's/^/    /' "$log"

if grep -q "error:" "$log"; then
    echo "==> fuzz runner failed to build (expected on Zig 0.16.0, see header)"
    exit 1
fi
if [ "$rc" != 0 ] && [ "$rc" != 124 ]; then
    echo "==> fuzzing aborted (exit $rc) — inspect the log above"
    exit 1
fi
echo "==> fuzz window completed without findings"
