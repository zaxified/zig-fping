# Changelog

## 0.1.0 — fping-complete-zig-port

First release: fping reimplemented in Zig 0.16 as a reusable library
(`zig_fping` module) plus the `zfping` CLI.

### Library

- ICMP Echo (v4/v6) and ICMP Timestamp (v4) probing over unprivileged
  DGRAM ping sockets with RAW fallback.
- fping-equivalent scheduling: global send pacing (`-i`), per-host period
  (`-p`), per-probe timeout (`-t`) with exponential backoff retries
  (`-r`/`-B`), seqmap sequence-space multiplexing.
- Monitoring-scale additions over fping: in-flight probe cap, per-subnet
  send spacing (/24 v4, /64 v6), random first-probe jitter,
  priority-queue scheduling (O(log n) at 10k+ targets).
- Kernel receive timestamps (SO_TIMESTAMPNS) for RTT accuracy under load;
  TTL/TOS capture; duplicate-reply detection; source-address checking.
- Modes: alive (fping default), count (`-c`), loop (`-l`, `stop()`-able).
- Embedding API for external event loops: `prepare()` / `step()` /
  `pollFds()` — `run()` is implemented on top of it.
- Performance parity with fping 5.1 (see README); resolved probes purge
  their timeout events lazily so batch rounds end with the last reply
  instead of waiting out the timeout window.

### CLI (zfping)

fping-compatible options, output formats and exit codes (0/1/2/3/4),
including: `-4 -6 -a -A -b -B -c -C -d -D -e -f -g -h -H -i -I -J -k -l
-m -M -n -N -o -O -p -q -Q -r -R -s -S -t -u -v -x -X`, `--check-source`,
`--icmp-timestamp`, `--oiface`, `--print-tos`, `--print-ttl`,
`--timestamp-format` (localtime via /etc/localtime), `--seqmap-timeout`,
IPv6 scope ids (`fe80::1%eth0`), SIGQUIT status snapshots and
stdin/file/CIDR/range target sources.

### Standalone helper modules (also usable outside of pinging)

- `fping.rdns` — reverse DNS (PTR) client in pure Zig: /etc/hosts first,
  then a minimal RFC 1035 UDP query against /etc/resolv.conf nameservers
  (std.Io.net only implements forward lookups). Powers `-n`/`-d`.
- `fping.LocalTz` — local timezone offsets from /etc/localtime via
  std.tz. Powers localtime rendering of `-D` timestamps and `-Q` headers.
- `fping.netutil` — interface name→index (SIOCGIFINDEX) and raw file
  reads without a std.Io instance.

### Known divergences from fping

Each is marked with a comment at the relevant place in the code.

- **Linux only, by design**: the engine uses raw `std.os.linux` syscalls
  to stay libc-free; macOS/BSD would require routing through libc.
- `--seqmap-timeout`: accepted, no observable effect. This port frees
  sequence slots when the probe timeout fires; fping keeps them for the
  seqmap window but discards late replies anyway (fping issue #32), so
  behaviour matches (`src/pinger.zig` module docs).
- Timestamp rendering uses /etc/localtime; POSIX rule strings in the TZ
  environment variable are not interpreted (`src/tzlocal.zig`).
