#!/bin/sh
# Deterministic fuzzing: a verdict in seconds, from seeds (not `zig build --fuzz`).
#
# Usage: scripts/fuzz.sh [seconds]    (fuzz window, default 60; build not included)
#
# Builds the "fuzz driver" test binaries ONCE (LLVM, ReleaseSafe: the shipped
# mode), then runs every target (icmp, rdns, options, generate) in parallel,
# a few jobs per target (one process each, disjoint seed ranges), each under
# `setsid -w timeout -s KILL`. Prints one verdict line per job (clean / HANG
# seed / FAIL seed / CRASH seed / CAP), the seeds/s per target and the reach
# counters, and exits non-zero on anything but clean.
#
#   FZ_JOBS=N      jobs in total (default: cores, at least one per target)
#   FZ_RUNS=N      fixed seeds per job instead of the time window
#   FZ_MS=N        per-input hang limit in ms (default 2000)
#   FZ_ONLY="a b"  only these targets (default: icmp rdns options generate)
#   FZ_ROOT=dir    build and run a copy of the tree (planted-bug checks)
#
# A failing seed replays in seconds: ZFPING_FUZZ=1,<seed> ZFPING_FUZZ_ONLY=<target>
# <bin> where <bin> is .zig-cache/fz/fuzz/fuzz-lib (icmp, rdns) or fuzz-cli
# (options, generate). A crash input saved by an optional
# `zig build test --fuzz` run replays with ZFPING_FUZZ_INPUT=<file>.
#
# Heavy job: run it through the shared queue,
#   hw run --slots 2 --name fz-zfping -- scripts/fuzz.sh 60
# The optional coverage-guided mode (`zig build test --fuzz --release=safe`) is
# exploration only: it exits 0 on a crash and hides hangs, so it never gives a
# verdict.

set -eu

SECS="${1:-60}"
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/zig-env.sh"
ROOT="${FZ_ROOT:-$REPO_ROOT}"
cd "$ROOT"

OUT="$ROOT/.zig-cache/fz"
LIB="$OUT/fuzz/fuzz-lib"
CLI="$OUT/fuzz/fuzz-cli"
TARGETS="${FZ_ONLY:-icmp rdns options generate}"
NT=$(echo "$TARGETS" | wc -w)
CORES=$(nproc)
JOBS="${FZ_JOBS:-$CORES}"
PER=$((JOBS / NT))
[ "$PER" -ge 1 ] || PER=1

echo "==> building fuzz binaries (ReleaseSafe, LLVM)"
rm -rf "$OUT"
"$ZIG" build fuzz-bins -Doptimize=ReleaseSafe --prefix "$OUT"

cap=$((SECS + 30))
if [ -n "${FZ_RUNS:-}" ]; then
    runs=$FZ_RUNS
    secs_env=""
    cap=${FZ_CAP:-120}
else
    runs=4294967296
    secs_env=$SECS
fi

if [ -n "${FZ_RUNS:-}" ]; then window="$FZ_RUNS seeds per job"; else window="${SECS}s window"; fi
echo "==> fuzzing: targets [$TARGETS], $PER job(s) each, $window"
t0=$(date +%s)
for t in $TARGETS; do
    case "$t" in
        icmp | rdns) bin=$LIB ;;
        options | generate) bin=$CLI ;;
        *) echo "unknown target: $t" >&2; exit 2 ;;
    esac
    j=0
    while [ "$j" -lt "$PER" ]; do
        (
            export ZFPING_FUZZ="$runs,$((j * 4294967296))"
            export ZFPING_FUZZ_ONLY="$t"
            export ZFPING_FUZZ_SEEDFILE="$OUT/seed-$t-$j"
            export ZFPING_FUZZ_MS="${FZ_MS:-2000}"
            [ -z "$secs_env" ] || export ZFPING_FUZZ_SECS="$secs_env"
            rc=0
            setsid -w timeout -s KILL "$cap" "$bin" >"$OUT/job-$t-$j.log" 2>&1 || rc=$?
            echo "$rc" >"$OUT/rc-$t-$j"
        ) &
        j=$((j + 1))
    done
done
wait
wall=$(($(date +%s) - t0))

bad=0
for t in $TARGETS; do
    j=0
    while [ "$j" -lt "$PER" ]; do
        log="$OUT/job-$t-$j.log"
        rc=$(cat "$OUT/rc-$t-$j")
        seedtxt=$(tr -d '\n' <"$OUT/seed-$t-$j" 2>/dev/null | sed -E 's/ 0+([0-9])/ \1/' || true)
        # The test runner prefixes the first line of a test ("2/3 name..."), so
        # the driver's lines are matched unanchored.
        if [ "$rc" = 0 ] && grep -q 'DONE [a-z]* runs=' "$log"; then
            v="clean: $(grep -o 'DONE [a-z]* runs=.*' "$log")"
        elif grep -q 'HANG [a-z]* seed=' "$log"; then
            v="$(grep -o 'HANG [a-z]* seed=.*' "$log" | head -1)"
            bad=1
        elif grep -q 'FAIL [a-z]* seed=' "$log"; then
            v="$(grep -o 'FAIL [a-z]* seed=.*' "$log" | head -1)"
            bad=1
        elif [ "$rc" = 137 ]; then
            v="CAP (killed at ${cap}s) last seed: $seedtxt"
            bad=1
        else
            v="CRASH rc=$rc last seed: $seedtxt: $(grep -o 'panic: .*' "$log" | head -1) (see $log)"
            bad=1
        fi
        echo "$t job $j: $v"
        j=$((j + 1))
    done
done

echo "==> seeds/s per target"
for t in $TARGETS; do
    cat "$OUT"/job-"$t"-*.log | grep -o 'DONE [a-z]* runs=.*' | awk -v t="$t" -v wall="$wall" '
        { split($3, a, "="); runs += a[2]; n++ }
        END { printf "  %-9s runs=%d  (%d/s over %d jobs)\n", t, runs, (wall > 0 ? runs / wall : runs), n }'
done
echo "==> reach (job 0 of each target)"
for t in $TARGETS; do
    grep -o 'REACH .*' "$OUT/job-$t-0.log" | sed 's/^/  /' | tr '\n' ' ' | fold -s -w 110
    echo
done
echo "==> wall ${wall}s"
if [ "$bad" != 0 ]; then
    echo "==> FUZZ FINDING (see lines above)"
    exit 1
fi
echo "==> no findings"
