#!/bin/sh
# Functional tests for zfping, run inside an isolated network namespace so
# no real network is touched and no privileges are required (user+net ns).
#
# Usage: test/functional.sh [path-to-zfping]
# Re-executes itself under `unshare -Urn` (or `sudo unshare -n` when
# unprivileged user namespaces are restricted, e.g. GitHub ubuntu-24.04).

set -u

Z="${1:-./zig-out/bin/zfping}"

if [ -z "${ZFPING_IN_NS:-}" ]; then
    if unshare -Urn true 2>/dev/null; then
        exec env ZFPING_IN_NS=1 unshare -Urn "$0" "$Z"
    elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
        exec sudo env ZFPING_IN_NS=1 unshare -n "$0" "$Z"
    else
        echo "SKIP: cannot create a network namespace" >&2
        exit 0
    fi
fi

ip link set lo up
ip route add 192.0.2.0/24 dev lo   # silent (blackhole-like) test subnet

fails=0
check() {
    desc="$1"; expected_exit="$2"; shift 2
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" != "$expected_exit" ]; then
        echo "FAIL: $desc: exit $rc != $expected_exit"
        echo "$out" | sed 's/^/    /'
        fails=$((fails+1))
    else
        echo "ok: $desc"
    fi
}

expect_grep() {
    desc="$1"; pattern="$2"; shift 2
    out=$("$@" 2>&1)
    if echo "$out" | grep -q "$pattern"; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc: missing /$pattern/ in:"
        echo "$out" | sed 's/^/    /'
        fails=$((fails+1))
    fi
}

check "alive v4+v6"                0 "$Z" -t 200 127.0.0.1 ::1
check "unreachable exit 1"         1 "$Z" -r 0 -t 100 192.0.2.9
check "mixed exit 1"               1 "$Z" -r 0 -t 100 127.0.0.1 192.0.2.9
check "count mode"                 0 "$Z" -c 2 -p 40 127.0.0.1
check "reachable threshold met"    0 "$Z" -r 0 -t 100 -x 1 127.0.0.1 192.0.2.9
check "reachable threshold unmet"  1 "$Z" -r 0 -t 100 -x 2 127.0.0.1 192.0.2.9
check "fast reachable"             0 "$Z" -t 2000 -X 1 127.0.0.1 192.0.2.9
check "unknown host exit 2"        2 "$Z" -t 100 nonexistent.invalid.zzz
check "bad option exit 3"          3 "$Z" --bogus
check "generate range"             1 "$Z" -g -r 0 -t 100 -u 192.0.2.1 192.0.2.3
check "icmp timestamp (raw)"       0 "$Z" --icmp-timestamp 127.0.0.1

expect_grep "is alive line"        "127.0.0.1 is alive"          "$Z" -t 200 127.0.0.1
expect_grep "per-recv format"      "64 bytes,"                   "$Z" -c 1 127.0.0.1
expect_grep "count summary"        "xmt/rcv/%loss = 2/2/0%"      "$Z" -c 2 -p 40 -q 127.0.0.1
expect_grep "vcount table"         "127.0.0.1 : 0\."             "$Z" -C 2 -p 40 127.0.0.1
expect_grep "json summary"         '"summary"'                   "$Z" -c 1 -J -q 127.0.0.1
expect_grep "json resp"            '"resp"'                      "$Z" -c 1 -J 127.0.0.1
expect_grep "print ttl"            "(TTL "                       "$Z" -c 1 --print-ttl 127.0.0.1
expect_grep "elapsed alive"        " is alive ("                 "$Z" -e 127.0.0.1
expect_grep "stats block"          "ICMP Echos sent"             "$Z" -c 1 -s 127.0.0.1
expect_grep "timeout line"         "timed out"                   "$Z" -c 1 -t 100 192.0.2.9
expect_grep "stdin targets"        "ok-marker-127.0.0.1"         sh -c "printf '127.0.0.1\n' | $Z -a | sed s/^/ok-marker-/"
expect_grep "loop interval report" "xmt/rcv/%loss"               timeout -s INT 1 "$Z" -l -p 150 -Q 0.3 127.0.0.1

check "oiface lo"                  0 "$Z" --oiface lo 127.0.0.1
check "oiface unknown exit 3"      3 "$Z" --oiface nonexistent0 127.0.0.1
expect_grep "rdns via /etc/hosts"  "localhost"                   "$Z" -n -t 200 127.0.0.1
expect_grep "iso timestamp"        "^\[[0-9-]*T[0-9:]*[+-]"      "$Z" -c 1 -D --timestamp-format iso 127.0.0.1

# IPv6 link-local with scope id.
if ip addr add fe80::1/64 dev lo nodad 2>/dev/null; then
    check "v6 scope id target"     0 "$Z" -t 300 fe80::1%lo
fi

# Latency simulation (requires the sch_netem module on the host).
if tc qdisc add dev lo root netem delay 30ms 2>/dev/null; then
    expect_grep "netem RTT ~60ms"  ", 6[0-9]\." "$Z" -c 1 -t 500 127.0.0.1
    tc qdisc del dev lo root
fi

if [ "$fails" != 0 ]; then
    echo "$fails functional test(s) failed"
    exit 1
fi
echo "all functional tests passed"
