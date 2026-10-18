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
# The reference version is read from `fping -v`. Scenarios in the first
# block exist in fping 5.1 (the oldest reference we test against) and run
# against any reference; the "v5.5" block (options and messages added after
# 5.1) runs only when the reference is >= 5.5 and prints one SKIP line
# otherwise. scripts/fping-ref.sh builds a pinned 5.5 reference.

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

# Reference version as "major minor" ("fping: Version 5.5" -> "5 5"; a
# trailing "-dev"/"-rcN" is ignored). ref_ge <major> <minor> tests >=.
ref_ver=$("$F" -v 2>&1 | sed -n 's/.*Version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -n 1)
ref_major=${ref_ver% *}; ref_minor=${ref_ver#* }
ref_ge() { [ -n "$ref_ver" ] && { [ "$ref_major" -gt "$1" ] || { [ "$ref_major" -eq "$1" ] && [ "$ref_minor" -ge "$2" ]; }; }; }
echo "reference: $("$F" -v 2>&1 | head -n 1)"

ip link set lo up
ip route add 192.0.2.0/24 dev lo   # silent (blackhole-like) test subnet

TMP=$(mktemp -d)
ROUTER_PID=
trap 'rm -rf "$TMP"; [ -z "$ROUTER_PID" ] || kill "$ROUTER_PID" 2>/dev/null' EXIT

# A "router" in a nested network namespace, behind a veth pair, whose
# unreachable/prohibit routes make the kernel answer our probes with real
# ICMP errors (the only way to see fping's "... from <router> for ICMP Echo
# sent to <host>" warnings; the kernel's ICMP error rate limits are off so
# repeated scenarios keep getting answers). Left unset (and the scenarios skipped) when the
# environment cannot create it.
have_router=0
unshare -n sleep 600 &
ROUTER_PID=$!
sleep 0.3
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
        ip -6 route add unreachable fd88::/64 &&
        ip route add 10.90.0.0/24 dev vethB &&
        ip -6 route add fd90::/64 dev vethB' 2>/dev/null &&
    ip route add 10.88.0.0/24 via 10.77.0.2 &&
    ip route add 10.89.0.0/24 via 10.77.0.2 &&
    ip -6 route add fd88::/64 via fd77::2 &&
    ip route add 10.90.0.0/24 via 10.77.0.2 &&
    ip -6 route add fd90::/64 via fd77::2; then
    have_router=1
fi

# Mask what legitimately differs between runs/binaries:
#  - both argv[0]s (and any literal "zfping") become PROG
#  - fping <= 5.1 netdata chart titles carry " for host X"; the pinned
#    upstream (and this port) dropped it — map the old form onto the new
#  - --timestamp-format values ([ISO]/[RFC3339]/[CTIME] keep the format shape)
#    and ICMP Timestamp reply fields (ms since midnight UTC) become fixed tokens
#  - standalone decimals (RTTs, averages, epoch timestamps) become <N>;
#    the guards keep dotted-quad IPv4 addresses intact, and the :a/ta loop
#    re-scans so adjacent values like "0.1/0.2/0.3" are all masked
normalize() {
    sed -e "s|$F|PROG|g" -e "s|$Z|PROG|g" -e 's/zfping/PROG/g' \
        -e "s/'FPing \(Packets\|Quality\|Latency\) for host [^']*'/'FPing \1'/" \
        -e 's/\[[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9:]\{8\}[-+][0-9]\{4\}\]/[ISO]/' \
        -e 's/\[[0-9]\{4\}-[0-9][0-9]-[0-9][0-9] [0-9:]\{8\}\]/[RFC3339]/' \
        -e 's/\[[A-Z][a-z]\{2\} [A-Z][a-z]\{2\} [ 0-9][0-9] [0-9:]\{8\} [0-9]\{4\}\]/[CTIME]/' \
        -e 's/\(Originate\|Receive\|Transmit\|Localreceive\)=[0-9]*/\1=<T>/g' \
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
golden "backoff too large"      full -B 6 127.0.0.1
golden "backoff too small"      full -B 0.5 127.0.0.1
golden "ttl out of range"       full -H 300 127.0.0.1
golden "only one of a, u"       full -a -u 127.0.0.1
# Usage dumps list each port's own option set, so compare exit codes only.
golden "invalid option value"   rc   -c x
golden "generate without args"  rc   -g
golden "ttl zero"               rc   -H 0 127.0.0.1

# ICMP errors from the router, printed to stderr by print_warning (so -q
# silences them). Router routes: host unreachable, administratively
# prohibited, ICMPv6 no route; -H 1 towards the forwarding routes makes the
# router answer time exceeded.
# The kernel rate-limits "unreachable"/"prohibit" route errors (ip_error(),
# 5 per second burst, not tunable from a namespace): only the first scenario
# uses the v4 routes (2 errors per binary), the rest stay at 1 or none.
if [ "$have_router" = 1 ]; then
    golden "icmp errors v4"         full -r 0 -t 300 10.88.0.5 10.89.0.5
    golden "icmp errors -q"         full -q -r 0 -t 300 10.88.0.5
    golden "icmp time exceeded v4"  full -H 1 -r 0 -t 300 10.90.0.5
    golden "icmp time exceeded -c"  full -H 1 -c 2 -p 100 -t 300 10.90.0.5
else
    echo "SKIP: icmp error scenarios (cannot create the router namespace)"
fi

golden_loop "loop per-recv -l"        2.5 -l -p 700 127.0.0.1
golden_loop "loop interval report -Q" 2.5 -l -p 700 -Q 1 127.0.0.1
golden_loop "netdata -N"              2.5 -N -l -p 700 -Q 1 127.0.0.1

# ---- v5.5 scenarios: options and messages newer than fping 5.1 -------------
if ref_ge 5 5; then
    # Option validation. The usage dump differs between ports (each lists its
    # own option set), so out-of-range values that end in usage(1) compare
    # exit codes only.
    golden "v5.5 -b above max"      full -b 65508 127.0.0.1
    golden "v5.5 -b at max"         full -b 65507 -c 1 127.0.0.1
    golden "v5.5 -O above 255"      rc   -O 256 127.0.0.1
    golden "v5.5 -O negative"       rc   -O -1 127.0.0.1
    golden "v5.5 -H above 255"      full -H 256 127.0.0.1
    golden "v5.5 -H zero"           rc   -H 0 127.0.0.1
    golden "v5.5 -B above max"      full -B 6 127.0.0.1
    golden "v5.5 -a with -u"        full -a -u 127.0.0.1
    golden "v5.5 -k bad mark"       rc   -k abc 127.0.0.1
    golden "v5.5 -k fwmark"         full -k 5 -c 1 127.0.0.1
    # The userns maps us to uid 0, so fping's "non-root may not use -p/-i
    # below the minimum" check cannot trigger here (a nested non-root userns
    # cannot open ICMP sockets); this only checks that root may go lower.
    # Without -t, fping autotunes the timeout to the period (0 ms), so the
    # probe times out even though the loopback reply is already queued.
    golden "v5.5 -p 0 -c 1 autotune" full -p 0 -c 1 127.0.0.1
    golden "v5.5 -p 0 as root"      full -p 0 -t 200 -c 1 127.0.0.1
    golden "v5.5 -i 0 as root"      full -i 0 -c 1 127.0.0.1
    # -g beyond MAX_GENERATE: "<prog>: -g parameter generates too many
    # addresses", exit 1 (not a usage dump).
    golden "v5.5 -g too many v4"    full -g 10.0.0.0/14
    golden "v5.5 -g too many range" full -g 10.0.0.1 10.9.0.1
    golden "v5.5 -g too many v6"    full -g 2001:db8:: 2001:db9::
    # ICMPv6 error warnings (fping >= 5.2).
    if [ "$have_router" = 1 ]; then
        golden "v5.5 icmp6 unreachable" full -r 0 -t 300 fd88::5
        golden "v5.5 icmp6 -q"          full -q -r 0 -t 300 fd88::5
        golden "v5.5 icmp6 -c"          full -c 2 -p 100 -t 300 fd88::5
        golden "v5.5 icmp6 time exceeded" full -H 1 -r 0 -t 300 fd90::5
    fi
    # -i/-t nan: fping accepts it (strtod, C undefined behaviour downstream),
    # zfping rejects it by design — deliberately not compared.

    # New output options.
    golden "v5.5 --print-ttl"       full --print-ttl -c 1 127.0.0.1
    golden "v5.5 --print-tos"       full --print-tos -c 1 127.0.0.1
    golden "v5.5 ttl+tos"           full --print-ttl --print-tos -c 2 -p 40 127.0.0.1
    golden "v5.5 --icmp-timestamp"  full --icmp-timestamp -c 1 127.0.0.1
    golden "v5.5 icmp-ts + -b"      rc   --icmp-timestamp -b 100 127.0.0.1
    golden "v5.5 --check-source"    full --check-source -c 1 127.0.0.1
    golden "v5.5 --seqmap-timeout"  full --seqmap-timeout=5000 -c 1 127.0.0.1
    golden "v5.5 ts iso"            full -D --timestamp-format=iso -c 1 127.0.0.1
    golden "v5.5 ts rfc3339"        full -D --timestamp-format=rfc3339 -c 1 127.0.0.1
    golden "v5.5 ts ctime"          full -D --timestamp-format=ctime -c 1 127.0.0.1
    golden "v5.5 ts format w/o -D"  full --timestamp-format=iso -c 1 127.0.0.1
    golden "v5.5 ts format bad"     rc   -D --timestamp-format=bad 127.0.0.1

    # -X / --fast-reachable.
    golden "v5.5 -X met"            full -X 1 -r 0 -t 100 127.0.0.1 192.0.2.9
    golden "v5.5 -X unmet"          full -X 2 -r 0 -t 100 127.0.0.1 192.0.2.9
    golden "v5.5 -X with -x"        full -X 1 -x 2 127.0.0.1
    golden "v5.5 -X zero"           rc   -X 0 127.0.0.1

    # JSON output.
    golden "v5.5 -J -c"             full -J -c 2 -p 40 127.0.0.1
    golden "v5.5 -J -C"             full -J -C 2 -p 40 127.0.0.1
    golden "v5.5 -J -q -c"          full -J -q -c 1 127.0.0.1
    golden "v5.5 -J -C -q"          full -J -C 1 -q 127.0.0.1
    golden "v5.5 -J -s"             full -J -s -c 1 127.0.0.1
    golden "v5.5 -J loss"           full -J -c 1 -r 0 -t 100 127.0.0.1 192.0.2.9
    golden "v5.5 -J -n"             full -J -c 1 -n 127.0.0.1
    golden "v5.5 -J -A -d"          full -J -c 1 -A -d 127.0.0.1
    golden "v5.5 -J ttl"            full -J -c 1 --print-ttl 127.0.0.1
    golden "v5.5 -J -D"             full -J -c 1 -D 127.0.0.1
    golden "v5.5 -J without count"  full -J 127.0.0.1
    golden_loop "v5.5 -J loop"             2.5 -J -l -p 700 127.0.0.1
    golden_loop "v5.5 -Q cumulative"       2.5 -l -p 700 -Q 1,cumulative 127.0.0.1
else
    echo "SKIP: v5.5 scenarios (reference is ${ref_ver:-unknown}, need >= 5 5)"
fi

if [ "$fails" != 0 ]; then
    echo "$fails golden test(s) failed"
    exit 1
fi
echo "all golden tests passed"
