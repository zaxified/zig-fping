#!/bin/sh
# Continuous-fuzzing entry point: runs the in-tree fuzz tests (ICMP and
# DNS-response parsers, CLI option and target-list parsers) under Zig's
# built-in fuzzer for a bounded time window.
#
# Usage: scripts/fuzz.sh [seconds]    (default: 300)
#
# Instrumented fuzzing is forced onto the LLVM backend with --release=safe:
# Zig 0.16.0's default self-hosted x86_64 backend crashes the fuzz runner
# in debug mode (ziglang/zig#30655, *builtin.StackTrace vs *debug.StackTrace).
# --release=safe (or --release=fast) sidesteps it without a patched toolchain;
# safe keeps the runtime checks the fuzzer wants. The fuzz bodies also run as
# one-shot smoke tests in every plain `zig build test`.

set -eu

SECONDS_TO_RUN="${1:-300}"

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/zig-env.sh"
cd "$REPO_ROOT"

echo "==> fuzzing for ${SECONDS_TO_RUN}s (zig build test --fuzz --release=safe)"
log=$(mktemp)
trap 'rm -f "$log"' EXIT

# timeout exit 124 means the window elapsed without a crash — success.
rc=0
timeout "$SECONDS_TO_RUN" "$ZIG" build test --fuzz --release=safe >"$log" 2>&1 || rc=$?
sed 's/^/    /' "$log"

if grep -q "error:" "$log"; then
    echo "==> fuzz runner failed to build — inspect the log above"
    exit 1
fi
if [ "$rc" != 0 ] && [ "$rc" != 124 ]; then
    echo "==> fuzzing aborted (exit $rc) — inspect the log above"
    exit 1
fi
echo "==> fuzz window completed without findings"
