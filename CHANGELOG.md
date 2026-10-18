# Changelog

## Unreleased

### Zig 0.17

zig-fping now requires **Zig 0.17.0** (`minimum_zig_version`, `.zigversion`,
CI). Stay on Zig 0.16 with `v0.1.3`. No behaviour change: the unit,
functional and golden-diff suites pass unchanged.

- `[_]u8{0} ** 15` → `@splat` (array repetition is gone in 0.17).
- `@bitCast` of received bytes into `sockaddr.in`/`in6` (now a compile error
  for extern structs) → `std.mem.bytesToValue`. The `[4]u8` ↔ `u32` in_addr
  casts also moved to `bytesToValue`/`toBytes`: 0.17 bit-casts arrays as
  little-endian on every target, so the old casts would have byte-swapped
  addresses on a big-endian Linux target.
- `std.mem.indexOfScalar`/`lastIndexOfScalar` → `findScalar`/`findScalarLast`,
  `std.fmt.allocPrint` → `Allocator.print` (deprecated in 0.17).
- `build.zig`: `b.args` → `run.addPassthruArgs()`.
- The vendored skill is now `zig-0.17` (zig-skills `v0.17.0-r1`).
- Migration audit of scripts, CI and docs: `.gitignore` covers 0.17's
  `zig-pkg/` and `.claude/worktrees/`; CI/`fuzz.sh` comments no longer claim
  the 0.16 self-hosted fuzz-runner crash still needs dodging.
### Audit fixes

A post-migration audit found the defects below; most predate 0.17.

- 32-bit Linux (x86, arm, riscv32) now compiles; unit tests pass on x86 and
  arm. Two casts that assumed a 64-bit `usize`/`isize` got explicit
  `@intCast`, and the `SO_TIMESTAMPNS_OLD` cmsg is parsed as the legacy
  two-`long` timespec instead of `linux.timespec` (64-bit on riscv32, so the
  kernel timestamp was never read there).
- Fix (big-endian Linux, predates 0.17): the received `sa_family` and the
  `IP_TTL`/`IPV6_HOPLIMIT`/`IPV6_TCLASS` control messages are host-order ints
  but were read as little-endian. On s390x/ppc64, `--check-source` therefore
  never saw a source address (every reply was accepted) and `--print-ttl` /
  IPv6 `--print-tos` printed 0. Regression tests verified under qemu-s390x.
- Fix: reverse DNS (`-n`/`-d`) no longer fails on legal DNS names that are not
  RFC 1123 host names, e.g. RFC 2317 classless-delegation owners
  (`5.0/26.2.0.192.in-addr.arpa`) or PTR targets with `_`. These names used
  to go through `std.Io.net.HostName.expand`, which validates the name.
- Fix: `-i`/`-p`/`-t`/`-Q`/`--seqmap-timeout` with `nan` caused a panic
  (`@intFromFloat`). They are now usage errors (fping hits C undefined
  behaviour here). The engine's backoff saturates instead of panicking on
  NaN, negative or huge `backoff_factor` values or after many retries.
- fping compatibility: the post-parse checks from fping v5.5 `main()` are
  implemented with fping's messages (stderr, exit 1):
  `ttl N out of range` (`-H` > 255; `-H 0` is a usage error),
  `specify only one of a, u`, `-p must be >= 0.001` (non-root),
  `data size N not valid, must not be larger than 65507` (previously
  65508..65535 were accepted and larger values were a usage error),
  `backoff factor X not valid, must be between 1.0 and 5.0` (previously
  any factor was accepted, and `-B 1e30` panicked on the first retry),
  `cannot change ICMP Timestamp size`, and, from fping develop together
  with `--oiface`, `specify only --oiface or -I, --iface`.
- Fix: resolving a name with more than 32 results (A+AAAA, long `/etc/hosts`
  entries) hung forever: `HostName.lookup` blocks on a full result queue that
  was only drained after it returned. The queue is now drained concurrently.
- Fix: library users setting `Config` durations (`timeout_ns` etc.) above
  `maxInt(i64)` hit an overflow panic in the run loop; `Pinger.init` now
  clamps them to 2^62 ns. CLI behaviour is unchanged.
- Tests: the rdns hosts-file test now asserts real lookups against a fixture
  file; the `::1` vs `127.0.0.1` ordering test reports a skip instead of
  passing silently on hosts without IPv6.
- Fix: local times (`-D`, `-Q`) now honour the POSIX TZ footer of TZif v2+
  files (e.g. `CET-1CEST,M3.5.0,M10.5.0/3`) for instants after the last
  listed transition, as glibc does. Before, "slim" zoneinfo files (few or no
  explicit transitions) lost DST after the last transition. A malformed
  footer falls back to the last transition's offset.

### Pending upstream (deferred)

To be implemented once the change reaches an upstream release tag
(Compatible-with release is `v5.5`):

- `--print-reply-dst` and the JSON `src` field (upstream `292d56f`,
  `e269abd`, `acb6579`, IPv6 in `8163e28`; unreleased as of v5.5). Prints
  the local address a reply arrived on, for both IPv4 and IPv6. `socket.zig`
  builds `IP_PKTINFO`/`IPV6_PKTINFO` only for *sending* (`--oiface`); the
  receive path enables `RECVTTL`/`RECVTOS` but not
  `IP_PKTINFO`/`IPV6_RECVPKTINFO`, so this needs the receive socket options,
  cmsg parsing for the reply's destination address, and that address carried
  through the reply struct into the renderers in `src/cli/output.zig`.

### Golden-diff against fping 5.5

- `scripts/fping-ref.sh` builds the pinned reference fping 5.5 (release
  tarball with generated configure, SHA256-checked, no root, cached under
  `.zig-cache/fping-ref-5.5/`) and prints the binary path.
- `test/golden.sh` reads the reference version from `fping -v`: the existing
  scenarios run against any reference, a new v5.5 block (`-b` limits, `-O`/`-H`
  range checks, `-J`, `-X`, `--print-ttl`/`--print-tos`, `--icmp-timestamp`,
  `--check-source`, `--timestamp-format`, `-Q N,cumulative`, `-k`, ...)
  runs only against >= 5.5 and prints one SKIP line otherwise.
- `scripts/test.sh` diffs against fping 5.5 and, when installed, the distro
  fping as well (`FPING_REF=<path>` pins a single reference); CI and the
  release workflow build 5.5 via the script and keep the apt 5.1 as well.

### Fixes from the zig-libs survey

- Reverse DNS (`-n`/`-d`, `src/rdns.zig`) now fails over like glibc: up to
  three `nameserver` lines (MAXNS) instead of only the first; attempts
  outside, servers inside; the next server on timeout, SERVFAIL, NOTIMP,
  REFUSED, any other error rcode or TC=1 (no TCP fallback). NXDOMAIN and an
  empty NOERROR end the lookup at once (they used to be retried, doubling the
  resolver load for unnamed hosts).
- `rdns.Options.timeout_ms`/`attempts` are now optional: when null,
  resolv.conf `options timeout:N attempts:N` apply (capped at 30 s / 5 like
  glibc), else the previous 2 s / 2 attempts. A caller value still wins; the
  CLI passes none. `options rotate` is not implemented.
- Reverse DNS responses are validated (RFC 5452): the UDP socket is
  `connect`ed to the server, the question section must echo our name, type
  and class, and only PTR records owned by the query name are taken, after
  following CNAMEs (RFC 2317 delegations keep working). The query id comes
  from `getrandom`.
- `/etc/hosts` and resolv.conf larger than their read buffers are cut at the
  last whole line instead of a partial line being parsed.
- Engine: `-r 65535` no longer panics (the retry comparison added in `u16`;
  the attempt counter is now `u32` so 65536 sends neither wrap nor retry a
  dead host forever, and the retry's probe index wraps like everywhere else).
- Engine: one reply drain handles at most 64 `recvmmsg` batches (1024
  packets) per socket and step, so an ICMP flood on a RAW socket cannot starve
  timeouts and the stop flag; the kernel keeps the rest and `ppoll` reports
  the socket readable again.
- Engine: a RTT of exactly 0 ns is a sample, not an "unset" marker, in the
  engine statistics and in the CLI's `-Q`/`-s` min tracking.
- `icmp.checksum` accumulates in `u64` (a `u32` overflowed past ~131 kB).
- ICMP error warnings like fping: unreachable, source quench, redirect, time
  exceeded and parameter problem (ICMPv6: destination unreachable, packet too
  big, time exceeded, parameter problem) for a live probe are printed on
  stderr as `<reason> from <router> for ICMP Echo sent to <host>` with
  fping's wording, and suppressed by `-q`/`-Q` like `print_warning`. They
  need a RAW socket (DGRAM ping sockets never receive them, same as fping).
  Library API: new `Outcome.icmp_error: IcmpError` (`family`, `icmp_type`,
  `code`, `from: ?Addr`), also exported as `zig_fping.IcmpError`;
  `icmp.Reply.icmp_error` gained `icmp_type`. The probe still resolves via its
  timeout.
- `-g` beyond 131072 targets prints `<prog>: -g parameter generates too many
  addresses` and exits 1 like fping (it printed the usage dump); an IPv6 range
  whose upper 64 bits differ gets the same message.
- Engine: timeouts due right after a send are served before the socket is
  read, so `-p 0 -c 1` (fping autotunes `-t` to the period, 0 ms) reports a
  timeout like fping instead of taking the loopback reply.
- Socket-free engine tests (retry/backoff sequence, duplicate and late
  replies, stale slot ownership, `--check-source`, RAW/DGRAM ident handling,
  `max_inflight`, ICMP error correlation, bounded drain); golden scenarios for
  `-g` overflow, `-p 0 -c 1` and real ICMP errors (a nested "router" network
  namespace behind a veth pair, skipped when it cannot be created). The
  live-socket tests skip instead of passing when no ICMP socket can be opened.

- `--check-source` now rejects a reply when no source address is available
  (fail closed; unreachable on Linux, where recvmsg always reports it).
- Pacing buckets: IPv4 /24 keys no longer collide with the IPv6 /64s
  `0:1:xxxx:xxxx::/64` (keys widened to u128).

### Deterministic fuzz driver

Fuzzing no longer relies on `zig build --fuzz` (no progress, exit 0 on a
crash, hangs invisible).

- `src/testing/fuzz_driver.zig` (test-only, trimmed from zig-libs testkit, MIT
  header kept) drives each harness from PRNG seeds in the ordinary ReleaseSafe
  test binary: seed range via `ZFPING_FUZZ=<runs>[,<first>]`, a watchdog per
  input (`HANG <target> seed=N`, exit 124), `FAIL <target> seed=N`, a seed file
  for panics, replay of one seed or of a saved `--fuzz` input, reach counters.
- The four harnesses (ICMP parsers, DNS `classify`/`expandName`, option parser,
  `-g` generation) were degenerate: `smith.bytes` followed by a ranged length
  draw gives length 0 in Smith's `.in` mode. They are now generic over their
  choice source (`Rng` for the driver, a `Script` over one `Smith.slice` for
  the optional `--fuzz` mode), draw one `slice`, start from seed corpora of real
  inputs (v4/v6 echo replies and errors, PTR with a compression pointer,
  RFC 2317 CNAME to PTR, option argv vectors, `-g` ranges and CIDRs) and check
  oracles (strip path equals plain path, option spellings agree, generated
  counts and boundary addresses, exact errors).
- Reach counters per harness, and a test in every `zig build test` that runs 500
  fixed seeds and fails if a labelled branch is never reached.
- `scripts/fuzz.sh [secs]` builds the `fuzz-bins` step once (LLVM, ReleaseSafe),
  runs all targets in parallel under `setsid -w timeout -s KILL`, prints a
  verdict per job, seeds/s per target and reach; the manual CI `fuzz` job runs
  it. Planted bugs in a copy of the tree (parse bound off by one, removed
  pointer-loop guard, accepted zero count, /31 treated as /30) are found in
  about two seconds each.

### Library API hardening (breaking, before v0.2.0)

Size and count preconditions on the public API were `std.debug.assert`s,
which compile out in ReleaseFast (undefined behaviour for a library caller).
They are now returned errors; internal invariants stay asserts. The CLI is
unchanged: every call it makes is within the limits.

- `icmp.writeEchoRequest` / `icmp.writeTimestampRequest` now return
  `error{BufferTooSmall}!void` (buffer shorter than the 8-byte header /
  `timestamp_msg_len`).
- `Socket.sendMany` returns `error{ TooManyPackets, LengthMismatch }!usize`
  (more than `batch_max` packets; `addrs` and `packets` of different length).
- `Socket.recvBatch` returns `error{BufferTooSmall}![]const RecvInfo`
  (slab shorter than `batch_max * slot_size`).
- `Pinger.init` returns `error.MaxInflightTooLarge` when `max_inflight` does
  not fit the 16-bit sequence space (`>= SeqMap.capacity`).
- `netutil.sortByDestinationPolicy` returns `error.TooManyAddresses` for more
  than `netutil.max_sort_addrs` (64) addresses and leaves the slice untouched;
  `netutil.sortWithReachability` is the same sort with the route lookup
  injected (a pure seam for tests).
- `rdns.lookupPtr` returns `error{BufferTooSmall}!?[]const u8` (`out` shorter
  than 256 bytes); `null` still means "no name found".
- Fix: `netutil` gave `3ffe::/16` (6bone) precedence 40 instead of the RFC 6724
  section 2.1 value 1, so it sorted ahead of `::/96`, `fec0::/10` and ULA
  addresses. Found by the oracle replay below.

- New `Config.raw_ident` / `Socket.Options.raw_ident` (`.pid`, `.unique`,
  `.fixed`): the echo identifier of RAW sockets. `.pid` (default, used by the
  CLI) is fping's `pid & 0xffff`; `.unique` gives every socket of the process
  its own identifier (random per-process base plus a counter), so several
  Pinger instances in one embedding process cannot take each other's
  replies. DGRAM sockets keep the kernel-assigned identifier.

### Tests

- tcpdump-oracle ICMP error fixtures (`src/testing/tcpdump_fixtures.zig`, data
  from zig-libs, MIT): kind, type, code and the quoted request's ident/seq of
  11 IPv4/IPv6 errors, read from tcpdump's decoding, are compared with
  `icmp.parseV4`/`parseV6` (bare and behind the IPv4 header). No mismatch.
  The quoted source/destination addresses in the fixtures are not exposed by
  `icmp.Reply` and are not compared.
- RFC 6724 oracle replay (`src/testing/rfc6724_vectors.zig`, glibc 2.43
  orderings from zig-libs, MIT) against `netutil.sortWithReachability` with a
  stub that reports "usable" for entries glibc gave a source. Only pairs that
  rules 1 and 6 decide are checked (1848 reachability pairs, 842 precedence
  pairs where scope and label rules tie); the rest involve source selection
  or rules 8/9, which are not implemented.
- `std.testing.checkAllAllocationFailures` over `Pinger.init`, `addTarget` /
  `addTargetAddr`, `prepare` and `options.parse`; no leak found.
- A test per new error above (`src/testing/api_errors_test.zig`).
- `scripts/netns-run` (adapted from zig-libs, MIT): a double user namespace
  (outer `unshare -rn` brings up `lo` and opens `ping_group_range`, the inner
  one maps the caller's uid back, so no `CAP_NET_RAW`). `scripts/test.sh`
  runs `zig build test` through it with a private cache directory, so the
  live-socket tests run instead of skipping on hosts without
  `ping_group_range`.
- Skip guard in `scripts/test.sh`: the gate fails unless exactly the four
  intended skips occur (the fuzz-driver tests, which skip without
  `ZFPING_FUZZ`).
- Mutation pass over `icmp.zig` (parse bounds, type dispatch, id/seq/offset
  reads, checksum), `seqmap.zig`, `pinger.zig` (reply correlation, stale-slot
  ownership, retries, pacing gates, drain cap, stats, prepare resets) and the
  `socket.zig` parsers, using one schemata build (118 mutants behind a runtime
  switch, run under a 20 s cap): **64 of 118 killed before** (54%), **116 of
  118 after**; the two survivors are equivalent (a `buf.len <= ihl` bound
  whose remainder is empty either way, and an `init` clear that safe builds
  mask with allocator poison). 33 tests added next to the code they pin
  (redundant ownership guards in `fireTimeouts`/`handleTimeout`, the
  `dispatchDue` gates, `failProbe`, `prepare()` resets, kernel receive
  timestamps, ICMP timestamp/IHL-option layouts, cmsg bounds).

## 0.1.3 — last release for Zig 0.16 (2026-10-18)

**This is the last zig-fping release that builds with Zig 0.16.** `main`
moves to Zig 0.17 next (0.2.0). Projects that stay on Zig 0.16 should pin
this tag:

```sh
zig fetch --save git+https://github.com/zaxified/zig-fping#v0.1.3
```

No fixes are planned for the 0.16 line.

### Upstream tracking policy

The rule for *when* an upstream change is ported is now written down in
CLAUDE.md instead of being decided ad hoc: bugfixes and correctness changes
are ported as they land on `develop`, while **new CLI options and
output-format changes wait until they appear in an upstream release tag**.
The golden-diff suite can only diff against an installed (i.e. released)
fping, distro packages are what "fping-compatible" is measured against, and
an unreleased flag can still be renamed — as `--print-srcaddr` was, below.

Two pins are now tracked: **Ported-from commit** (how far `develop` has been
reviewed) and **Compatible-with release** (currently `v5.5`). The monthly
`upstream-check` workflow closes its tracking issue once the review pin has
caught up, and opens a separate `upstream-release` issue when upstream tags a
new release — that is what triggers the deferred backlog.

### Build: LLVM backend by default

Every compile step in `build.zig` now sets `use_llvm`, so a plain Debug
`zig build` / `zig build test` uses LLVM instead of Zig 0.16's self-hosted
x86_64 backend. `-Dselfhosted=true` brings the self-hosted backend back for a
fast edit loop. Release modes, CI and the scripts were already LLVM
(ReleaseSafe) and are unchanged. The vendored `zig` skill moves to
zig-skills `v0.16.0-r4`.

### Upstream commits reviewed

Reviewed `develop` up to `bde54df` (2026-08-08); the previous pin was
`780ec46` (2026-04-25). Everything between fping v5.5 and `780ec46` — the
`--oiface` series, `20df7c6` (`ipi_spec_dst` from `-S`), `3f754df`
(`ipi6_addr` in `IPV6_PKTINFO`), `977d47f` (crash with `-0`) and the upstream
file-split refactors — was already covered by the 0.1.0 port, which was made
from the `780ec46` tree.

| upstream | change | disposition |
| --- | --- | --- |
| `292d56f` | new `--print-srcaddr`, plus a `src` field in JSON output | deferred |
| `e269abd` | document the JSON `src` field | deferred |
| `acb6579` | rename `--print-srcaddr` to `--print-reply-dst` | deferred |
| `6731abf` | asymmetric IPv6 routing test for `--oiface` | n/a (upstream CI) |
| `bde54df` | test tuning for `--print-reply-dst` | n/a (upstream CI) |

Second round (2026-10-18): reviewed `develop` up to `8163e28` (committed
2026-08-09, the develop head); fping v5.5 is still the newest release.

| upstream | change | disposition |
| --- | --- | --- |
| `48cb332` | open ICMP sockets with `IPPROTO_ICMP`/`IPPROTO_ICMPV6` instead of `getprotobyname()` (missing on Android) | n/a — `socket.zig` has always used the `linux.IPPROTO` constants (no libc) |
| `8163e28` | IPv6 support for `--print-reply-dst` | deferred |

## 0.1.2 — fuzzing unblocked, CI hardening & src/cli split (2026-06-18)

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
  space) running `scripts/fuzz.sh 60`.

### Build & CI

- The test pipeline (`scripts/test.sh`) now builds and runs everything
  ReleaseSafe, the same optimize mode we ship, instead of Debug; the golden
  and functional suites exercise the shipped optimize mode.
- `scripts/release.sh` builds the native shipping binary once and runs the
  pipeline against that exact stripped ReleaseSafe artifact, rather than
  rebuilding it in the test step.
- CI actions bumped to `actions/checkout@v5` (Node 24; v4's Node 20 is
  deprecated). Workflows gained least-privilege `permissions: contents: read`
  and `concurrency` cancel-in-progress. (`mlugg/setup-zig@v2` still declares
  Node 20 but GitHub already force-runs it on Node 24, so it is left as is.)
- The cross-compile check moved into the test job (one coherent Zig cache)
  instead of a separate matrix that shared a single cache key, so all targets
  cache and recompile consistently.
- CI opens `net.ipv4.ping_group_range` before the tests so the embed-API
  loopback unit test runs instead of self-skipping — the only place the
  library's `prepare`/`step`/`pollFds` loop is exercised against a live socket.
- The man page is installed by `build.zig` (`share/man/man8/zfping.8`), like
  fping's `man_MANS`, so `zig build --prefix …` places it for `man zfping`.

### Refactor

- `src/main.zig` (the CLI, ~1080 lines) split into `src/cli/`: `context.zig`
  (shared `Ctx`/`TargetState` and formatting helpers), `output.zig` (per-probe
  and interval/netdata/JSON renderers), `stats.zig` (final per-system and
  global reports) and `signals.zig`; `main.zig` keeps argument handling and
  target resolution. Pure reorganization — output is byte-identical (the
  golden suite passes unchanged).

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
- Timestamp rendering uses /etc/localtime (including its POSIX TZ footer);
  the TZ environment variable is not consulted (`src/tzlocal.zig`).
- Reverse DNS without resolv.conf `options timeout:` waits 2 s per query
  instead of glibc's 5 s: with three nameservers and two attempts glibc
  can block 30 s on one unresponsive address, which a 10k-host monitoring
  run cannot afford (`src/rdns.zig`, `default_timeout_ms`).
