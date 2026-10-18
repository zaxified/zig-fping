# fping-watch

A small ping monitor built on the `zig_fping` library: a daemon that pings a
handful of targets once a minute and serves a web page with the last 24 hours.

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
| `GET /api/state` | everything the page shows: per target status, flags and the 24 h series `rtt` (ms) and `loss` (%), one entry per cycle, oldest first, `null` = no data |
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
- **One request per connection, no timeouts.** Each connection is served on its
  own thread and closed after one response. A reverse proxy in front provides
  keep-alive, TLS and timeouts.
- **At most 64 targets**, one address per name (the first one DNS returns).
- History is saved as JSON after every cycle (about 400 KB for 10 targets).

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
