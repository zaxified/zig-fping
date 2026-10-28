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

It is the library's example application and a public demo, finished for that
purpose and deliberately kept small enough to read in one sitting:
`src/monitor.zig` (targets, probing, history, persistence), `src/main.zig`
(HTTP server and API), `src/web/` (the page; no framework and no build step,
embedded into the binary). Nothing beyond Zig's standard library and
`zig_fping`. It ships as a Debian package with a sandboxed systemd service
([Deploying](#deploying)).

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
| `--version` | | print the version and exit |

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
| `GET /healthz` | `200 {"ok":true,...}` while cycles keep finishing (at most 3 cycles apart) and the ICMP socket opens; `503` otherwise. Unreachable targets do not count: they are what is being monitored |

Changes must be sent as `application/json`: a cross-site HTML form cannot do
that without a CORS preflight, which the server never approves, so a page on
another site cannot change the targets behind your back.

## Scope

Kept out on purpose, so the example stays small; they belong to a real
monitoring product, not to a library demo:

- **No authentication.** Without `--read-only`, anyone who reaches the port can
  change the targets. The default address is loopback; the public instance runs
  read-only.
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

## Deploying

Every zig-fping release carries `fping-watch_<version>_amd64.deb` and
`_arm64.deb` (built by `package.sh`; checksums in `SHA256SUMS`). The binary is
static, so the package has no dependencies; it needs a Debian or Ubuntu host
with systemd.

```sh
apt install ./fping-watch_1.0.0_amd64.deb
```

That installs and starts `fping-watch.service`, read-only, on
`127.0.0.1:8080`:

| path | |
|---|---|
| `/usr/bin/fping-watch` | the binary |
| `/usr/lib/systemd/system/fping-watch.service` | the service ([deploy/fping-watch.service](deploy/fping-watch.service)) |
| `/etc/fping-watch/targets.json` | the target list; the bundled default is copied there on first install only, then it is yours (not a conffile: upgrades never ask about it) |
| `/etc/fping-watch/env` | optional, `FPING_WATCH_LISTEN=ADDR:PORT` |
| `/var/lib/fping-watch/history.json` | the history (systemd `StateDirectory`) |
| `/usr/share/fping-watch/Caddyfile` | a Caddy site to start from ([deploy/Caddyfile](deploy/Caddyfile)) |

After changing the targets or the env file: `systemctl restart fping-watch`.
`apt remove` keeps the configuration and history, `apt purge` deletes them.

The service runs as a throwaway user (`DynamicUser`) that can write only its
state directory, under a strict sandbox: seccomp `@system-service`, IPv4/IPv6
sockets only, no writable-executable memory, read-only system, `TasksMax`
and `MemoryMax` (`systemd-analyze security fping-watch`: 1.6, "OK"). ICMP uses
unprivileged ping sockets where `net.ipv4.ping_group_range` covers the
service's group (the Debian and Ubuntu default), raw sockets through
`CAP_NET_RAW` otherwise.

With Ansible the whole deployment is a package, two files and a check:

```yaml
- name: fping-watch package
  ansible.builtin.apt:
    deb: https://github.com/zaxified/zig-fping/releases/download/vX.Y.Z/fping-watch_1.0.0_amd64.deb
- name: fping-watch targets
  ansible.builtin.copy: { src: targets.json, dest: /etc/fping-watch/targets.json, mode: "0644" }
  notify: restart fping-watch
- name: fping-watch listen address
  ansible.builtin.copy: { content: "FPING_WATCH_LISTEN=127.0.0.1:8080\n", dest: /etc/fping-watch/env, mode: "0644" }
  notify: restart fping-watch
- name: fping-watch is healthy
  ansible.builtin.uri: { url: "http://127.0.0.1:8080/healthz" }
  register: health
  until: health.status == 200
  retries: 10
  delay: 2
```

Then publish it through the reverse proxy, compressed:

```caddyfile
ping.example.org {
	encode zstd gzip
	reverse_proxy 127.0.0.1:8080
}
```

## About page

For a page that lists several demos, the package carries a description of
this one in `/usr/share/fping-watch/about/` (`zig build about` writes the same
into `zig-out/about/`), generated from [deploy/about.json](deploy/about.json):

| file | |
|---|---|
| `about-card.html` | an HTML fragment to include: one `<article class="demo" id="demo-fping-watch">`, no styles, no scripts; class names (`demo-title`, `demo-tagline`, `demo-screenshot`, `demo-summary`, `demo-features`, `demo-facts`, `demo-source`) for the hub to style, schema.org `SoftwareApplication` microdata, `data-version` |
| `about.html` | the same card as a standalone page (light and dark) |
| `about.json` | the same data plus `version`, for templating |
| `screenshot.png` | referenced by both pages relatively, keep it next to them |

None of them links to the demo itself: only the hub knows its URL. With
Ansible, after the package is installed on the same host:

```yaml
- name: fping-watch about card
  ansible.builtin.copy:
    src: /usr/share/fping-watch/about/
    dest: "{{ demo_hub_root }}/fping-watch/"
    remote_src: true
```

## Tests

```sh
zig build test     # unit tests: status, acknowledgement, history ring, cache, health, validation, escaping
sh smoke.sh        # end to end: loopback targets, API, ETag, health, deadline, read-only mode
./package.sh       # the .deb packages; smoke-tests the packaged binary first
```

Inside the repository `scripts/test.sh` runs the first two, the smoke test in
an isolated network namespace; `scripts/release.sh` runs `package.sh`.
