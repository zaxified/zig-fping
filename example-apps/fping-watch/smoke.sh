#!/bin/sh
# End-to-end smoke test: run the daemon against loopback targets with a short
# cycle, then check the API, the write endpoints and the read-only mode.
#
#   ./smoke.sh [path/to/fping-watch]
#
# Inside this repository it re-runs itself in an isolated network namespace
# (scripts/netns-run: loopback up, unprivileged ICMP sockets); a standalone
# copy runs on the host and needs net.ipv4.ping_group_range to cover you.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$(realpath "${1:-$HERE/zig-out/bin/fping-watch}")
NETNS_RUN="$HERE/../../scripts/netns-run"
if [ -z "${ZFPING_NETNS:-}" ] && [ -x "$NETNS_RUN" ]; then
    exec "$NETNS_RUN" sh "$0" "$BIN"
fi

WORK=$(mktemp -d)
PID=
cleanup() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"

PORT=18089
URL=http://127.0.0.1:$PORT
cat > targets.json <<'EOF'
{ "targets": [
  { "name": "lo4", "host": "127.0.0.1" },
  { "name": "lo6", "host": "::1" },
  { "name": "nowhere", "host": "192.0.2.1" }
] }
EOF

fail() { echo "smoke: FAIL: $*" >&2; [ -f log ] && cat log >&2; exit 1; }

start() {
    "$BIN" --listen 127.0.0.1:$PORT --cycle 5 --history history.json "$@" >log 2>&1 &
    PID=$!
    i=0
    until curl -sf "$URL/" >/dev/null; do
        i=$((i + 1)); [ $i -lt 50 ] || fail "server did not start"; sleep 0.1
    done
}
stop() { kill "$PID"; wait "$PID" 2>/dev/null || true; PID=; }

# status <code> <method> <path> [body]
status() {
    got=$(curl -s -o body -w '%{http_code}' -X "$2" -H 'content-type: application/json' \
        ${4:+-d "$4"} "$URL$3")
    [ "$got" = "$1" ] || fail "$2 $3: HTTP $got, expected $1 ($(cat body))"
}

"$BIN" --version | grep -q '^fping-watch [0-9]' || fail "--version"
"$BIN" --read-only --targets missing.json >log 2>&1 && fail "read-only started without a target list"
grep -q 'cannot load the targets from missing.json: FileNotFound' log || fail "startup error message: $(cat log)"

start
curl -sf "$URL/app.js" >/dev/null || fail "app.js"
curl -sf "$URL/favicon.svg" | grep -q '<svg' || fail "favicon.svg"
curl -sf "$URL/healthz" | grep -q '"ok":true.*"read_only":false' || fail "not healthy at start"
# DNS rebinding: a writable instance answers only to IP literals, localhost
# and --allow-host names.
host() { curl -s -o /dev/null -w '%{http_code}' -H "host: $1" "$URL/api/state"; }
[ "$(host evil.example)" = 421 ] || fail "writable instance answers to any Host"
[ "$(host localhost:$PORT)" = 200 ] || fail "writable instance refuses localhost"
curl -sI "$URL/" | grep -qi '^content-security-policy:' || fail "no CSP header"
# A client that connects and sends nothing is cut off at the connection
# deadline (10 s); checked at the end, it runs while the cycle completes.
date +%s > idle.start
(timeout 20 nc -d 127.0.0.1 $PORT >/dev/null 2>&1; date +%s > idle.end) &
IDLE=$!

# Wait for the first cycle (5 probes at 1 s per host + 1 s timeout).
i=0
until curl -sf "$URL/api/state" | grep -q '"name":"nowhere"[^}]*"status":"down"'; do
    i=$((i + 1)); [ $i -lt 150 ] || fail "no completed cycle"; sleep 0.1
done
STATE=$(curl -sf "$URL/api/state")
echo "$STATE" | grep -q '"name":"lo4"[^}]*"status":"up"' || fail "127.0.0.1 not up"
echo "$STATE" | grep -q '"name":"lo6"[^}]*"status":"up"' || fail "::1 not up"
echo "$STATE" | grep -q '"name":"lo4"[^}]*"jitter":\[[^]]*[0-9]' || fail "no jitter for 127.0.0.1"

# Polling with the ETag costs a body-less 304 until the state changes (a
# cycle may complete between the two requests: retry).
etag() { curl -sfI "$URL/api/state" | tr -d '\r' | sed -n 's/^etag: //Ip'; }
revalidate() { curl -s -o /dev/null -w '%{http_code}' -H "if-none-match: $1" "$URL/api/state"; }
i=0
until [ "$(revalidate "$(etag)")" = 304 ]; do
    i=$((i + 1)); [ $i -lt 3 ] || fail "revalidation with the current ETag is not 304"
done
ETAG=$(etag)

status 409 POST /api/targets/1/ack                 # only DOWN can be acknowledged
status 200 POST /api/targets/3/ack
status 200 POST /api/targets/2/pause
[ "$(revalidate "$ETAG")" = 200 ] || fail "a change does not change the ETag"
status 400 POST /api/targets '{"name":"x","host":"no such host!"}'
status 201 POST /api/targets '{"name":"added","host":"127.0.0.2"}'
status 200 DELETE /api/targets/4
status 404 DELETE /api/targets/4
# A form post (no JSON content type) is refused: the CSRF guard.
got=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d 'x=1' "$URL/api/targets/1/pause")
[ "$got" = 415 ] || fail "form post: HTTP $got, expected 415"
grep -q '"paused": true' targets.json || fail "pause not saved"
grep -q '"acked": true' targets.json || fail "ack not saved"
wait "$IDLE"
idle=$(( $(cat idle.end) - $(cat idle.start) ))
[ "$idle" -ge 9 ] && [ "$idle" -le 13 ] || fail "idle connection closed after ${idle} s, expected ~10 s"
stop

# Read-only: history survives the restart, every change is refused.
start --read-only
curl -sf "$URL/api/state" | grep -q '"read_only":true' || fail "not read-only"
curl -sf "$URL/healthz" | grep -q '"read_only":true' || fail "/healthz does not report read-only"
[ "$(host ping.example.org)" = 200 ] || fail "read-only instance refuses a proxy's Host"
curl -sf "$URL/api/state" | grep -q '"loss":\[[^]]*[0-9]' || fail "history lost on restart"
status 403 POST /api/targets/1/pause
status 403 DELETE /api/targets/1
stop

# Demo: read-only, the hours before the first cycle are sample data.
cat > demo.json <<'EOF2'
{ "targets": [ { "id": 1, "name": "lo", "host": "127.0.0.1", "demo": "outage" } ] }
EOF2
sed 's/"outage"/"nope"/' demo.json > bad-demo.json
# (A timeout, 124, means it started serving.)
rc=0; timeout 5 "$BIN" --listen 127.0.0.1:$PORT --demo --targets bad-demo.json >log 2>&1 || rc=$?
[ "$rc" != 0 ] && [ "$rc" != 124 ] || fail "demo started with an unknown scenario"
start --demo --targets demo.json
curl -sf "$URL/healthz" | grep -q '"read_only":true,"demo":true' || fail "/healthz does not report the demo"
i=0
until curl -sf "$URL/api/state" | grep -q '"demo_from":[1-9]'; do
    i=$((i + 1)); [ $i -lt 150 ] || fail "no sample data after the first cycle"; sleep 0.1
done
# Sample data reaches back the full 24 hours: the first loss entry is a number.
curl -sf "$URL/api/state" | grep -q '"loss":\[[0-9]' || fail "sample data does not fill the history"
status 403 DELETE /api/targets/1
stop

echo "smoke: ok"
