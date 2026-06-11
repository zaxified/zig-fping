#!/bin/sh
# Reproducible benchmark behind the "Performance vs. fping" table in
# README.md: builds zfping in ReleaseSafe and times identical scenarios
# for zfping and the reference fping (when installed) inside an isolated
# user+network namespace. 2000 responding loopback targets, 250 silent
# ones in the blackholed test subnet.
#
# Usage: scripts/bench.sh
# Numbers vary with hardware and load — run on an idle machine and prefer
# comparing the two columns over absolute values.

set -u

if [ -z "${ZFPING_IN_NS:-}" ]; then
    REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
    . "$REPO_ROOT/scripts/zig-env.sh"
    cd "$REPO_ROOT"
    echo "==> building ReleaseSafe zfping" >&2
    "$ZIG" build -Doptimize=ReleaseSafe
    if ! unshare -Urn true 2>/dev/null; then
        echo "SKIP: cannot create a network namespace" >&2
        exit 0
    fi
    exec env ZFPING_IN_NS=1 unshare -Urn "$0"
fi

ip link set lo up
ip route add 192.0.2.0/24 dev lo   # silent (blackhole-like) test subnet

Z=./zig-out/bin/zfping
F=$(command -v fping || true)

RESPONDING="-g 127.0.1.0 127.0.8.207"   # 2000 loopback addresses
SILENT="-g 192.0.2.1 192.0.2.250"       # 250 never-answering addresses

# measure <binary> <args...> — echoes "<elapsed> s, <cpu>% CPU".
# time(1) gets its own output file (-o): zfping's buffered stderr writes
# positionally, so sharing one redirected fd would interleave the streams.
measure() {
    bin="$1"; shift
    if [ -x /usr/bin/time ]; then
        /usr/bin/time -o /tmp/bench.time -f '%e s, %P CPU' \
            "$bin" "$@" >/dev/null 2>/dev/null || true
        tail -1 /tmp/bench.time
    else
        s=$(date +%s%N)
        "$bin" "$@" >/dev/null 2>&1 || true
        e=$(date +%s%N)
        echo "$(( (e - s) / 1000000 )) ms"
    fi
}

row() {
    desc="$1"; shift
    z=$(measure "$Z" "$@")
    if [ -n "$F" ]; then
        f=$(measure "$F" "$@")
    else
        f="(no fping installed)"
    fi
    printf '| %s | %s | %s |\n' "$desc" "$z" "$f"
}

fver=$([ -n "$F" ] && "$F" -v 2>&1 | sed -n 's/.*Version \([0-9.]*\).*/\1/p' || echo "-")
echo "| Scenario | zfping | fping $fver |"
echo "| --- | --- | --- |"
# shellcheck disable=SC2086
{
    row '`-c 1 -i 1` (pacing-bound)' -q -c 1 -i 1 -t 200 $RESPONDING
    row '`-c 1 -i 0.1`' -q -c 1 -i 0.1 -t 200 $RESPONDING
    row '`-c 3 -i 0.1 -p 100`' -q -c 3 -i 0.1 -p 100 -t 200 $RESPONDING
    row '250 silent targets `-i 0.1 -r 0 -t 100`' -q -i 0.1 -r 0 -t 100 $SILENT
}
