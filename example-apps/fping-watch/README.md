# fping-watch

A small ping monitor built on the `zig_fping` library: a daemon that pings a
handful of targets once a minute and serves a web page with the last 24 hours.

![fping-watch: eleven targets with status, recent cycles and uptime; one row expanded to its 24-hour latency chart](doc/screenshot.png)

<sub>Sample data: one target paused, one acknowledged, one row expanded.</sub>

- one row per target with its status, a strip of recent cycles (green: all
  replies, orange: some lost, red: all lost), 24-hour uptime and current latency;
- click a row for the 24-hour latency chart with packet loss underneath;
- add, remove and **pause** targets; **acknowledge** a DOWN target the way
  Nagios does: it shows ACK instead of DOWN until 5 cycles in a row are not DOWN
  again, so the next outage is reported;
- `--read-only` for a public demo: the server refuses every change (HTTP 403),
  and the page hides the controls.

It is a proof of concept and an example of the library, small enough to read
in one sitting: `src/monitor.zig` (targets, probing, history, persistence),
`src/main.zig` (HTTP server and API), `src/web/` (the page; no framework and no
build step, embedded into the binary). Nothing beyond Zig's standard library
and `zig_fping`.

## Build and run

Needs Zig 0.17.0. Inside this repository the library comes from the checkout
(`build.zig.zon` depends on `../..`):

```sh
zig build                     # ReleaseSafe by default
./zig-out/bin/fping-watch --targets targets.json --history history.json
# open http://127.0.0.1:8080
```

| option | default | |
|---|---|---|
| `--listen ADDR:PORT` | `127.0.0.1:8080` | web server address |
| `--targets FILE` | `targets.json` | target list; rewritten on every change |
| `--history FILE` | (memory only) | the 24-hour history, saved after every cycle |
| `--read-only` | off | refuse every change |
| `--cycle SECONDS` | `60` | seconds between cycles (the tests use 5) |

Pinging needs ICMP sockets: either unprivileged ones
(`sysctl net.ipv4.ping_group_range` covering your group, the default on most
distributions) or `CAP_NET_RAW`.

`targets.json` needs only names and hosts; ids, `paused` and `acked` are added
when the daemon saves it:

```json
{ "targets": [
  { "name": "Cloudflare DNS", "host": "1.1.1.1" },
  { "name": "Wikipedia", "host": "wikipedia.org" }
] }
```

## How a cycle works

Every cycle (aligned to the wall clock) takes a copy of the active targets,
resolves names, and pings all of them in **one** `Pinger` round in `.count`
mode: 5 echo requests per target, 1 s apart per target, 20 ms apart globally,
with a random start offset of up to 500 ms per target. That is the library's
pacing at work: the probes are spread out, never burst into the network. The
results are recorded under a lock: probes sent, replies, and the median
round-trip time. The web UI therefore never waits for a cycle.

History is a ring of 1440 slots per target, indexed by cycle number, so a gap
(daemon stopped, target paused) needs no bookkeeping: a slot whose timestamp is
not the expected one is shown as "no data".

## API

| | |
|---|---|
| `GET /api/state` | everything the page shows: per target status, flags and the 24 h series `rtt` (ms) and `loss` (%), one entry per cycle, oldest first, `null` = no data; carries an ETag, `If-None-Match` gets `304` until the state changes |
| `POST /api/targets` | add: `{"name": "...", "host": "..."}` |
| `DELETE /api/targets/ID` | remove |
| `POST /api/targets/ID/pause`, `/resume` | stop and resume probing |
| `POST /api/targets/ID/ack`, `/unack` | acknowledge a DOWN target, or withdraw the acknowledgement |

Changes must be sent as `application/json`: a cross-site HTML form cannot do
that without a CORS preflight, which the server never approves, so a page on
another site cannot change the targets behind your back.

## Deliberate simplifications

- **No authentication.** Without `--read-only`, anyone who reaches the port can
  change the targets. The default address is loopback; put a reverse proxy with
  authentication in front, or run the public instance read-only.
- **One request per connection, no TLS.** Each connection is served on its own
  thread and closed after one response. A reverse proxy in front provides
  keep-alive, TLS, compression and per-client rate limits.
- **At most 64 targets**, one address per name (the first one DNS returns).
- History is saved as JSON after every cycle (about 400 KB for 10 targets).

## Many viewers, and the open internet

Viewers only read: probing runs on its own schedule, and no request ever
sends a ping, however many people have the page open.

- **One serialization per change.** The state JSON is built once per cycle
  (or target change) and served to every viewer from a cache. The page polls
  every 15 s with `If-None-Match`, so most polls are a body-less `304`; a
  background tab does not poll at all. Measured with 64 targets (a 930 KB
  state): 50 concurrent clients, 2000 full responses in 3.4 s, 12 threads,
  7 MB RSS.
- **Bounded connections.** At most 256 at once (more are closed unanswered),
  each shut down 10 s after it was accepted, so a client that never finishes
  its request cannot hold a thread for longer. A flood of idle connections
  still fills the 256 slots for as long as it lasts; that is what the
  reverse proxy's per-client limits are for.
- **Nothing to change, nothing to read.** `--read-only` refuses every write
  in the server, not just in the page; the routes are a fixed list (no file
  serving, no path handling); every string reaches the page through
  `textContent`, under a CSP without inline script.

Without `--read-only`, anyone who reaches the server can make it ping
addresses of their choice, including ones on your internal network, and read
which ones answer. Never expose a writable instance.

Everything in `targets.json` (names *and* host addresses) is public on a
read-only instance; list only targets you are happy to show.

The state is about 15 KB per target, a long run of small numbers that
compresses well: enable compression in the proxy (`encode` below).

## Deploying the read-only demo

A sketch for a systemd host behind Caddy; adjust paths and names.

```ini
# /etc/systemd/system/fping-watch.service
[Unit]
Description=fping-watch demo
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/fping-watch --read-only --listen 127.0.0.1:8080 \
    --targets /etc/fping-watch/targets.json --history /var/lib/fping-watch/history.json
DynamicUser=yes
StateDirectory=fping-watch
# Only needed where ping_group_range does not cover the service's group.
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```caddyfile
ping.example.org {
    encode zstd gzip
    reverse_proxy 127.0.0.1:8080
}
```

## Tests

```sh
zig build test     # unit tests: status, acknowledgement, history ring, validation
sh smoke.sh        # end to end: loopback targets, API, read-only mode
```

Inside the repository `scripts/test.sh` runs both, the smoke test in an
isolated network namespace.
