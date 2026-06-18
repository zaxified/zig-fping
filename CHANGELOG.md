# Changelog

## Unreleased

### Fuzzing unblocked on Zig 0.16.0

Instrumented fuzzing works on the pinned toolchain after all. The blocker
reported in 0.1.1 (`zig build test --fuzz` crashing in the fuzz runner) is
ziglang/zig#30655: Zig 0.16.0's default self-hosted x86_64 backend mishandles
the runner in debug mode (`*builtin.StackTrace` vs `*debug.StackTrace`).
Forcing the LLVM backend with `--release=safe` sidesteps it — no patched
toolchain needed.

- `scripts/fuzz.sh` now runs `zig build test --fuzz --release=safe` and
  treats a genuine `error:` (not the previously-expected build failure) as
  a hard failure.
- CI gained an on-demand `fuzz` job (`workflow_dispatch` only — no corpus is
  persisted between runs, so a schedule would just re-explore the same shallow
  space) running `scripts/fuzz.sh 600`.

### Build & CI

- The test pipeline (`scripts/test.sh`) now builds and runs everything
  ReleaseSafe, the same optimize mode we ship, instead of Debug; the golden
  and functional suites exercise the shipped optimize mode.
- `scripts/release.sh` builds the native shipping binary once and runs the
  pipeline against that exact stripped ReleaseSafe artifact, rather than
  rebuilding it in the test step.
- CI actions bumped to `actions/checkout@v5` (Node 24; v4's Node 20 is
  deprecated). Workflows gained least-privilege `permissions: contents: read`
  and `concurrency` cancel-in-progress.
- The cross-compile check moved into the test job (one coherent Zig cache)
  instead of a separate matrix that shared a single cache key, so all targets
  cache and recompile consistently.

## 0.1.1 — golden-diff, syscall batching & compat fixes (2026-06-11)

### Golden-diff test suite

New `test/golden.sh` (wired into `scripts/test.sh` and CI): runs zfping and
a reference fping binary (5.1) with identical arguments in an isolated
namespace and requires equal exit codes plus byte-identical stdout/stderr
after masking volatile values (RTTs, timestamps, argv[0]). 35 scenarios.

### Tooling & docs

- `scripts/bench.sh`: reproducible generation of the README performance
  table (ReleaseSafe build, 2000 loopback + 250 silent targets in an
  isolated namespace, timed via time(1)).
- `doc/zfping.8` man page, shipped inside the release tarballs
  (`scripts/release.sh`).
- Golden suite covers loop modes: `-l`, `-l -Q` and `-N -l -Q` run for a
  fixed window, get SIGINTed and are compared with run-phase-dependent
  counters and wall-clock timestamps masked.

### More compatibility fixes (loop/netdata golden tests)

- `-N` netdata chart ids sanitize non-alphanumeric characters to `_`
  (`fping.127_0_0_1_packets`, like fping's `add_addr()`); the chart
  family keeps the display name. Chart titles intentionally match the
  pinned upstream (`'FPing Packets'`) — fping <= 5.1 still printed
  `'FPing Packets for host X'`, which upstream later dropped.
- The netdata chart interval renders like printf `%.0f` (round half to
  even) instead of truncating (`-Q 1.5` now prints `2`).

### Engine: sendmmsg/recvmmsg syscall batching

- Replies are drained with `recvmmsg`, up to 16 packets per syscall, in
  every mode (`Socket.recvBatch`).
- Consecutive due sends are transmitted as one `sendmmsg` batch
  (`Socket.sendMany`). Batches only form when the global send gap is zero
  (`-i 0`); with pacing enabled the send path stays one packet per gap by
  design — net-storm protection is unaffected. Packets the kernel did not
  accept from a batch are retried via `sendto` for accurate per-packet
  errno handling.
- Measured in a netns: 14 targets with `-i 0` now take 1 `sendmmsg` +
  2 `recvmmsg` syscalls (previously 14 `sendto` + 15 `recvmsg`).

### Fuzzing

- New fuzz targets for the CLI option parser and `-g` target generation,
  joining the existing ICMP/DNS-response parser fuzz tests; all of them
  run as smoke tests in every `zig build test`.
- `scripts/fuzz.sh`: time-boxed `zig build test --fuzz` entry point.
  Instrumented fuzzing is currently blocked by the pinned toolchain —
  Zig 0.16.0 fails to compile its own fuzz test runner
  (`lib/compiler/test_runner.zig`: `*builtin.StackTrace` vs
  `*debug.StackTrace`). Revisit at the next toolchain bump, then wire a
  scheduled CI fuzz job.

### Compatibility fixes found by the golden suite

All verified byte-for-byte against fping 5.1 and the pinned upstream source
(`780ec46`):

- **Usage errors now exit 1, not 3.** fping's man page documents exit 3
  for invalid arguments, but the binary calls `usage(1)`/`exit(1)` on every
  usage error; we now match the binary. Unknown options and missing values
  print fping's optparse-style message (`<argv0>: invalid option -- 'x'` +
  `see 'fping -h' for usage information`); invalid option values and
  target-source conflicts dump the usage text to stderr like `usage(1)`.
- **`-A` combined with `-n`/`-d` prints `name (addr)`** like fping's
  `add_name()`; `-m` alone no longer forces numeric-address display (it
  keeps the printname for every resolved address).
- **Hostname targets pick the same address as fping.** glibc's getaddrinfo
  sorts results per RFC 6724 (e.g. `::1` before `127.0.0.1` for
  `localhost`); std's lookup returns file/DNS order, so resolved addresses
  are now ordered by `fping.netutil.sortByDestinationPolicy` (destination
  precedence + a UDP-connect route-lookup reachability probe).
- **`-x`/`-X` suppress per-target alive/unreachable lines** (fping clears
  `opt_verbose_on` when `opt_min_reachable` is set).
- **`-c` and `-C` are no longer mutually exclusive** — like fping, both set
  the probe count (last one wins) and `-C` switches on the verbose RTT
  table.
- **`-N` without `-l`/`-Q` is accepted** (fping never validates netdata
  prerequisites) and no longer suppresses normal output on its own.
- **Resolver failures print the gai_strerror text** (`Temporary failure in
  name resolution` vs `Name or service not known`) and are suppressed by
  `-q`, matching `print_warning()`.
- **Validation messages mirror fping** (`can't specify both -4 and -6`,
  `specify only one of c, l`, `option -J, --json requires -c, -C, or -l`,
  `ICMP Timestamp is IPv4 only`, `can't parse source address: X`,
  `unknown interface 'X'`), prefixed with argv[0] like upstream's `prog`.
- `-c`/`-C`/`-x`/`-X` now reject a zero value (upstream `usage(1)`).

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
