#!/bin/sh
# Functional tests for zfping, run inside an isolated network namespace so
# no real network is touched and no privileges are required (user+net ns).
#
# Usage: test/functional.sh [path-to-zfping]
# Re-executes itself under `unshare -Urn` (or `sudo unshare -n` when
# unprivileged user namespaces are restricted, e.g. GitHub ubuntu-24.04).

set -u

Z="${1:-./zig-out/bin/zfping}"

# Library-only feature test (Config.icmp_errors_dgram): the zfping CLI does
# not expose it, so build a small driver once, outside the namespace. Needs
# $ZIG (scripts/test.sh exports it) or a zig on PATH; skipped without one.
RECVERR_DRIVER="${RECVERR_DRIVER:-}"
if [ -z "${ZFPING_IN_NS:-}" ] && [ -z "$RECVERR_DRIVER" ]; then
    zig_bin="${ZIG:-$(command -v zig 2>/dev/null || true)}"
    if [ -n "$zig_bin" ] && [ -f src/testing/recverr_driver.zig ]; then
        mkdir -p .zig-cache/recverr
        if "$zig_bin" build-exe -fllvm -O ReleaseSafe --dep zig_fping \
            -Mroot=src/testing/recverr_driver.zig -Mzig_fping=src/root.zig \
            -femit-bin=.zig-cache/recverr/recverr-driver >/dev/null 2>&1; then
            RECVERR_DRIVER="$PWD/.zig-cache/recverr/recverr-driver"
        else
            echo "FAIL: could not build the recverr driver" >&2
            exit 1
        fi
    fi
fi
export RECVERR_DRIVER

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
# fping's man page says exit 3 for bad arguments, but the binary exits 1
# on every usage error; we match the binary (see main.zig exit codes).
check "bad option exit 1"          1 "$Z" --bogus
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
check "oiface unknown exit 1"      1 "$Z" --oiface nonexistent0 127.0.0.1
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

# ICMP errors on DGRAM sockets (library option icmp_errors_dgram). A nested
# "router" namespace (same technique as test/golden.sh) answers probes with
# real ICMP unreachable errors; the driver must report them from the router
# address, while the default (option off) reports nothing.
ROUTER_PID=
trap '[ -z "$ROUTER_PID" ] || kill "$ROUTER_PID" 2>/dev/null' EXIT
if [ -z "$RECVERR_DRIVER" ]; then
    echo "SKIP: icmp_errors_dgram scenarios (no zig to build the driver)"
else
    unshare -n sleep 600 &
    ROUTER_PID=$!
    sleep 0.3
    echo "0 0" > /proc/sys/net/ipv4/ping_group_range
    if ip link add vethA type veth peer name vethB 2>/dev/null &&
        ip link set vethB netns "$ROUTER_PID" 2>/dev/null &&
        ip addr add 10.77.0.1/24 dev vethA &&
        ip -6 addr add fd77::1/64 dev vethA nodad &&
        ip link set vethA up &&
        nsenter -t "$ROUTER_PID" -n sh -c '
            ip link set lo up &&
            ip addr add 10.77.0.2/24 dev vethB &&
            ip -6 addr add fd77::2/64 dev vethB nodad &&
            ip link set vethB up &&
            sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1 net.ipv4.icmp_ratelimit=0 net.ipv6.icmp.ratelimit=0 &&
            ip route add unreachable 10.88.0.0/24 &&
            ip route add prohibit 10.89.0.0/24 &&
            ip -6 route add unreachable fd88::/64' 2>/dev/null &&
        ip route add 10.88.0.0/24 via 10.77.0.2 &&
        ip route add 10.89.0.0/24 via 10.77.0.2 &&
        ip -6 route add fd88::/64 via fd77::2; then
        T="10.88.0.1 10.89.0.1 fd88::1"
        expect_grep "recverr: v4 unreachable route from router" "^icmp_error 10.88.0.1 type=3 code=1 from=10.77.0.2$" "$RECVERR_DRIVER" $T
        expect_grep "recverr: v4 prohibited from router"      "^icmp_error 10.89.0.1 type=3 code=13 from=10.77.0.2$" "$RECVERR_DRIVER" $T
        expect_grep "recverr: v6 unreachable from router"     "^icmp_error fd88::1 type=1 code=0 from=fd77::2$" "$RECVERR_DRIVER" $T
        expect_grep "recverr: probe still times out (counted)" "^summary 10.88.0.1 sent=1 recv=0 icmp_errors=1$" "$RECVERR_DRIVER" $T
        out=$("$RECVERR_DRIVER" --off $T 2>&1)
        if echo "$out" | grep -q '^icmp_error' || ! echo "$out" | grep -q '^summary 10.88.0.1 sent=1 recv=0 icmp_errors=0$'; then
            echo "FAIL: recverr: option off must report nothing:"
            echo "$out" | sed 's/^/    /'
            fails=$((fails+1))
        else
            echo "ok: recverr: option off reports nothing"
        fi
    else
        echo "SKIP: icmp_errors_dgram scenarios (cannot create the router namespace)"
    fi
fi

if [ "$fails" != 0 ]; then
    echo "$fails functional test(s) failed"
    exit 1
fi
echo "all functional tests passed"
