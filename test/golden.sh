#!/bin/sh
# Golden-diff tests: run zfping and a reference fping binary with identical
# arguments inside an isolated user+network namespace and require equal exit
# codes plus byte-identical stdout/stderr after masking run-to-run noise
# (RTT/elapsed decimals, epoch timestamps, argv[0] program names).
#
# Usage: test/golden.sh [path-to-zfping] [path-to-fping]
# Exits 0 with a SKIP message when no reference fping binary is available,
# so the pipeline stays usable on hosts without fping installed.
#
# Scenarios are limited to options that exist in fping 5.1 (the oldest
# reference we test against); newer flags are covered by test/functional.sh.

set -u

Z="${1:-./zig-out/bin/zfping}"
F="${2:-$(command -v fping || true)}"

if [ -z "$F" ] || [ ! -x "$F" ]; then
    echo "SKIP: no reference fping binary found" >&2
    exit 0
fi

if [ -z "${ZFPING_IN_NS:-}" ]; then
    if unshare -Urn true 2>/dev/null; then
        exec env ZFPING_IN_NS=1 unshare -Urn "$0" "$Z" "$F"
    elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
        exec sudo env ZFPING_IN_NS=1 unshare -n "$0" "$Z" "$F"
    else
        echo "SKIP: cannot create a network namespace" >&2
        exit 0
    fi
fi

ip link set lo up
ip route add 192.0.2.0/24 dev lo   # silent (blackhole-like) test subnet

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Mask what legitimately differs between runs/binaries:
#  - both argv[0]s (and any literal "zfping") become PROG
#  - fping <= 5.1 netdata chart titles carry " for host X"; the pinned
#    upstream (and this port) dropped it — map the old form onto the new
#  - standalone decimals (RTTs, averages, epoch timestamps) become <N>;
#    the guards keep dotted-quad IPv4 addresses intact, and the :a/ta loop
#    re-scans so adjacent values like "0.1/0.2/0.3" are all masked
normalize() {
    sed -e "s|$F|PROG|g" -e "s|$Z|PROG|g" -e 's/zfping/PROG/g' \
        -e "s/'FPing \(Packets\|Quality\|Latency\) for host [^']*'/'FPing \1'/" \
        -e ':a' \
        -e 's/\(^\|[^0-9.]\)[0-9]\{1,\}\.[0-9]\{1,\}\([^0-9.]\|$\)/\1<N>\2/' \
        -e 'ta'
}

# Loop-mode runs are killed after a fixed window, so probe/report counters
# and wall-clock [HH:MM:SS] headers depend on run phase — mask all integers
# on top of normalize(); the diff then validates line structure and field
# formats rather than exact counts.
normalize_loop() {
    normalize | sed -e 's/\[[0-9:]\{8\}\]/[TS]/g' -e 's/[0-9]\{1,\}/<I>/g'
}

fails=0

# golden <desc> <mode> <args...>
#   mode "full": compare exit code + normalized stdout + stderr
#   mode "rc":   compare exit code only (output known to differ, e.g. the
#                usage dump of newer options not present in fping 5.1)
golden() {
    desc="$1"; mode="$2"; shift 2
    "$F" "$@" >"$TMP/f.out" 2>"$TMP/f.err"; frc=$?
    "$Z" "$@" >"$TMP/z.out" 2>"$TMP/z.err"; zrc=$?

    if [ "$frc" != "$zrc" ]; then
        echo "FAIL: $desc: exit $zrc != $frc"
        fails=$((fails+1))
        return
    fi
    if [ "$mode" = full ]; then
        for s in out err; do
            normalize <"$TMP/f.$s" >"$TMP/f.$s.n"
            normalize <"$TMP/z.$s" >"$TMP/z.$s.n"
            if ! diff -u --label "fping.std$s" --label "zfping.std$s" \
                    "$TMP/f.$s.n" "$TMP/z.$s.n" >"$TMP/diff"; then
                echo "FAIL: $desc: std$s differs"
                sed 's/^/    /' "$TMP/diff"
                fails=$((fails+1))
                return
            fi
        done
    fi
    echo "ok: $desc"
}

# golden_loop <desc> <window-seconds> <args...>
# Loop modes never exit on their own: run each binary for a fixed window,
# stop it with SIGINT (like an interactive ^C) and compare the masked
# output. Probe spacing (-p) leaves >=0.3 s between any probe/report and
# the kill moment, so both binaries emit the same number of lines.
golden_loop() {
    desc="$1"; window="$2"; shift 2
    timeout -s INT "$window" "$F" "$@" >"$TMP/f.out" 2>"$TMP/f.err"; frc=$?
    timeout -s INT "$window" "$Z" "$@" >"$TMP/z.out" 2>"$TMP/z.err"; zrc=$?

    if [ "$frc" != "$zrc" ]; then
        echo "FAIL: $desc: exit $zrc != $frc"
        fails=$((fails+1))
        return
    fi
    for s in out err; do
        normalize_loop <"$TMP/f.$s" >"$TMP/f.$s.n"
        normalize_loop <"$TMP/z.$s" >"$TMP/z.$s.n"
        if ! diff -u --label "fping.std$s" --label "zfping.std$s" \
                "$TMP/f.$s.n" "$TMP/z.$s.n" >"$TMP/diff"; then
            echo "FAIL: $desc: std$s differs"
            sed 's/^/    /' "$TMP/diff"
            fails=$((fails+1))
            return
        fi
    done
    echo "ok: $desc"
}

printf '127.0.0.1\n::1\n' >"$TMP/targets"

golden "alive v4+v6"            full -t 200 127.0.0.1 ::1
golden "unreachable"            full -r 0 -t 100 192.0.2.9
golden "mixed alive/unreach"    full -r 0 -t 100 127.0.0.1 192.0.2.9
golden "show alive only"        full -a -r 0 -t 100 127.0.0.1 192.0.2.9
golden "show unreach only"      full -u -r 0 -t 100 127.0.0.1 192.0.2.9
golden "elapsed"                full -e 127.0.0.1
golden "count mode"             full -c 2 -p 40 127.0.0.1
golden "count quiet"            full -q -c 2 -p 40 127.0.0.1
golden "vcount table"           full -C 2 -p 40 127.0.0.1
golden "outage"                 full -o -c 2 -p 40 127.0.0.1
golden "final stats"            full -s -c 1 127.0.0.1
golden "name lookup -n"         full -n -t 200 127.0.0.1
golden "forced rdns -d"         full -d -t 200 127.0.0.1
golden "addr+name -A -n"        full -A -n -t 200 127.0.0.1
golden "hostname by addr -A"    full -A -t 200 localhost
golden "all addrs -m"           full -m -t 200 localhost
golden "timestamp -D"           full -D -c 1 127.0.0.1
golden "payload size -b"        full -b 120 -c 1 127.0.0.1
golden "generate range"         full -g 192.0.2.1 192.0.2.3 -r 0 -t 100 -u
golden "generate CIDR"          full -g 192.0.2.0/30 -r 0 -t 100 -u
golden "reachable met -x"       full -x 1 -r 0 -t 100 127.0.0.1 192.0.2.9
golden "reachable unmet -x"     full -x 2 -r 0 -t 100 127.0.0.1 192.0.2.9
golden "unknown host"           full -t 100 nonexistent.invalid.zzz
golden "unknown option"         full --bogus
golden "missing option value"   full -c
golden "-4 -6 conflict"         full -4 -6 127.0.0.1
golden "targets from file"      full -t 200 -f "$TMP/targets"
golden "ttl+tos"                full -H 64 -O 0 -t 200 127.0.0.1
golden "random payload"         full -R -t 200 127.0.0.1
golden "source address"         full -S 127.0.0.1 -t 200 127.0.0.1
# Usage dumps list each port's own option set, so compare exit codes only.
golden "invalid option value"   rc   -c x
golden "generate without args"  rc   -g

golden_loop "loop per-recv -l"        2.5 -l -p 700 127.0.0.1
golden_loop "loop interval report -Q" 2.5 -l -p 700 -Q 1 127.0.0.1
golden_loop "netdata -N"              2.5 -N -l -p 700 -Q 1 127.0.0.1

if [ "$fails" != 0 ]; then
    echo "$fails golden test(s) failed"
    exit 1
fi
echo "all golden tests passed"
