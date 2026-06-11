# zig-fping

[![CI](https://github.com/zaxified/zig-fping/actions/workflows/ci.yml/badge.svg)](https://github.com/zaxified/zig-fping/actions/workflows/ci.yml)

[fping](https://github.com/schweikert/fping) reimplemented in Zig (0.16+) as a
reusable library plus the `zfping` CLI.

> **Note:** This project is a Claude (Fable 5) authored, automated rewrite of
> fping, created for study purposes (all in one 5 hour session).
> Agentic/AI-assisted pull requests are welcome — especially ones that keep
> the port coherent with upstream fping (see [CONTRIBUTING.md](CONTRIBUTING.md)).

Built for high-volume ICMP monitoring (10k+ host checks per 5-minute cycle,
e.g. as a backend for Nagios-like systems) with an emphasis on net-storm
protection — bursting probes into one network branch saturates links/CPE and
produces false DOWN states.

Pure Zig, standard library only: no external dependencies, no C/ASM hooks,
no libc — the binary is fully static. Linux only, by design (direct
`std.os.linux` syscalls; even reverse DNS and timezone handling are
reimplemented in Zig instead of calling libc).

## Why Zig (vs. the C original)

This project doubles as a showcase of what Zig brings over the C tree
it was ported from:

- **Testing built into the language.** fping ships zero unit tests (only
  a Perl end-to-end suite); here the parsers, checksum, seqmap, target
  generator, option parser and even the scheduler's pacing math have unit
  tests, and every test runs under a leak-detecting allocator.
- **Fuzzing built into the toolchain.** `scripts/fuzz.sh` (a time-boxed
  `zig build test --fuzz`) fuzzes the ICMP and DNS-response parsers — the
  code paths that consume untrusted bytes from the network — plus the CLI
  option parser and `-g` target generation. In C this needs external
  harnesses (libFuzzer/AFL). The same fuzz bodies also run as smoke tests
  in every `zig build test`.
- **Comptime.** The wire checksum is verified *at compile time* (see
  `icmp.zig` "comptime checksum" test) — a regression cannot even build.
  Tagged unions with exhaustive switches replace C's int-and-convention
  error handling.
- **Memory safety in safe builds.** Bounds-checked slices instead of raw
  pointer arithmetic over packet buffers; ReleaseSafe keeps the checks on
  in production.
- **No autotools.** `build.zig` replaces configure.ac/Makefile.am, and
  cross-compiling is one flag: `zig build -Dtarget=aarch64-linux`
  (CI builds aarch64, riscv64 and musl variants on every push).
- **One static binary, package-manager distribution.** No libc at all;
  consumers add the library with `zig fetch`.
- **Better algorithmic scaling.** Priority queues (O(log n)) replace
  fping's sorted linked-list event queue (O(n) insert) — relevant at 10k+
  concurrent targets.

## Performance vs. fping

Measured against fping 5.1, same isolated netns, 2000 loopback targets,
identical flags, ReleaseSafe build — regenerate any time with
`scripts/bench.sh`:

| Scenario | zfping | fping 5.1 |
| --- | --- | --- |
| `-c 1 -i 1` (pacing-bound) | 2.23 s, 3% CPU | 2.26 s, 3% CPU |
| `-c 1 -i 0.1` | 0.31 s, 11% CPU | 0.32 s, 14% CPU |
| `-c 3 -i 0.1 -p 100` | 0.94 s, 10% CPU | 0.94 s, 12% CPU |
| 250 silent targets `-i 0.1 -r 0 -t 100` | 0.14 s, 4% CPU | 0.14 s, 3% CPU |

Within noise of the original (slightly ahead in most runs), with ~1 MB
extra RSS for the fixed sequence-slot table. Since 0.1.1 the engine
batches syscalls: replies always drain via `recvmmsg` (16 packets per
syscall), and when pacing permits back-to-back sends (`-i 0`) consecutive
probes leave as one `sendmmsg` — with the default pacing the send path is
intentionally one packet per gap, keeping net-storm protection intact.

### Binary size

The released `zfping` is ~480 KB versus fping's ~52 KB — but fping is
dynamically linked against glibc (~2.2 MB shared), while zfping is fully
static with zero runtime dependencies. By symbol breakdown, the port's own
code is ~60 KB (on par with fping); the rest is the statically linked
"libc equivalent" from Zig's std: the I/O runtime with the DNS resolver,
panic/stack-trace machinery (which C has no equivalent of), formatting and
allocator code.

The build is intentionally **ReleaseSafe**: bounds checks stay enabled on
the code paths that parse untrusted network bytes (ICMP and DNS replies),
which is part of this port's value over the C original. The checks cost
~55 KB of the binary and no measurable speed (the benchmark above runs
with them on). For embedded targets with tight flash budgets,
`zig build -Doptimize=ReleaseSmall -Dstrip=true` produces a ~254 KB
binary — at the price of disabling those safety checks, so prefer
ReleaseSafe wherever size is not critical.

## Net-storm protection

| Mechanism | Config | fping equivalent |
| --- | --- | --- |
| Global minimum gap between any two packets | `interval_ns` (default 10 ms) | `-i` |
| Gap between probes to the same target | `perhost_interval_ns` | `-p` |
| Cap on concurrently outstanding probes | `max_inflight` (default 4096) | — |
| Minimum gap into the same /24 (v4) or /64 (v6) | `subnet_gap_ns` | — |
| Random jitter of each target's first probe (cycle decorrelation) | `jitter_ns` | — |
| Exponential timeout backoff on retries | `backoff_factor` | `-B` |

Concurrency lives in the 16-bit ICMP sequence space (one socket per address
family, seq → (target, probe) mapping like fping's seqmap), not in file
descriptor counts — the loop waits in `ppoll` on at most two sockets.
10 000 responding targets at a 0.05 ms interval complete in ~1.3 s
(single-threaded, ~15k packets/s including replies); a typical monitoring
cycle of 10k checks per 5 minutes uses well under 1% of that.

## Using the library

```sh
zig fetch --save git+https://github.com/zaxified/zig-fping
```

```zig
// build.zig
const fping_dep = b.dependency("zig_fping", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("fping", fping_dep.module("zig_fping"));
```

```zig
// use inside your code
const std = @import("std");
const fping = @import("fping");

var pinger = try fping.Pinger.init(allocator, .{
    .mode = .count,            // .alive = stop after first reply (host check)
    .count = 3,                // probes per target
    .interval_ns = 5 * std.time.ns_per_ms,
    .subnet_gap_ns = 2 * std.time.ns_per_ms,
    .jitter_ns = 500 * std.time.ns_per_ms,
});
defer pinger.deinit();

const id = try pinger.addTarget("192.0.2.1");
// optional: pinger.setResultCallback(ctx, onResult); — per-probe outcomes
try pinger.run(); // blocks until all probes complete

const st = pinger.stats(id);
// st.alive(), st.lossPermille(), st.avgNs(), st.min_ns, st.max_ns, ...
```

Modes:

- **`.alive`** — fping's default: one probe, retry on timeout (`retries`,
  default 3) with backoff, done on first reply. Cheapest host-alive check.
- **`.count`** — fping `-c`: exactly `count` probes per target, full RTT/loss
  statistics (perf data for monitoring).
- **`.loop`** — fping `-l`: probe forever until `stop()` is called
  (async-signal-safe, callable from a signal handler or another thread).

`run()` can be called repeatedly (statistics reset) — typically once per
monitoring cycle.

Threading: the engine is fully single-threaded and spawns no threads — one
event loop multiplexing the 16-bit ICMP sequence space over at most two
sockets. A `Pinger` instance must be driven by a single thread; the only
cross-thread entry point is `stop()` (atomic, async-signal-safe). For
parallelism, run independent `Pinger` instances (each owns its sockets and
buffers) — though one instance saturates typical monitoring workloads.

For integration into an existing event loop, skip `run()` and drive the
engine yourself — `step()` never blocks:

```zig
try pinger.prepare();
while (try pinger.step()) |deadline_mono_ns| {
    var buf: [2]std.os.linux.pollfd = undefined;
    const fds = pinger.pollFds(&buf);
    // poll/epoll fds until readable or the deadline, then step() again
}
```

## CLI

`zfping` is a thin shell over the library, compatible with fping options,
output formats and exit codes (`-c/-C/-l/-g/-f/-Q/-J/-N/-x/-X`,
`--icmp-timestamp`, `--check-source`, `--print-ttl/tos`, DNS targets, …).

Prebuilt static binaries (x86_64, aarch64, riscv64 — no libc required, run
anywhere) are published on the
[Releases page](https://github.com/zaxified/zig-fping/releases):

```sh
# adjust the version to the latest release tag
curl -fsSL -o zfping.tar.gz \
  https://github.com/zaxified/zig-fping/releases/download/v0.1.0/zfping-v0.1.0-x86_64-linux.tar.gz
tar xzf zfping.tar.gz && ./zfping --help
```

Or build from source:

```sh
zig build
./zig-out/bin/zfping -c 3 -i 5 192.0.2.1 2001:db8::1
./zig-out/bin/zfping -g 192.168.1.0/24 -a -q
./zig-out/bin/zfping --help
```

Known divergences from fping are listed in [CHANGELOG.md](CHANGELOG.md)
and commented at the relevant places in the code.

The package also exports small standalone modules: `fping.rdns` (pure-Zig
reverse DNS/PTR client), `fping.LocalTz` (/etc/localtime offsets) and
`fping.netutil` (interface name→index).

## Permissions

The library tries an unprivileged `SOCK_DGRAM` ICMP socket first, then falls
back to `SOCK_RAW`:

```sh
# unprivileged ping (recommended for monitoring daemons):
sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"
# or grant the binary the raw-socket capability:
sudo setcap cap_net_raw+ep zfping
```

Root-less testing works in an isolated namespace:

```sh
unshare -Urn sh -c 'ip link set lo up; ./zig-out/bin/zfping 127.0.0.1 ::1'
```

## Development

Everything works from a plain `git clone`, without sudo and without a
pre-installed Zig — the pinned toolchain (`.zigversion`, 0.16.0) is
downloaded automatically into `.zig-toolchain/` when missing:

```sh
scripts/test.sh      # fmt check + build + unit + functional + golden-diff
scripts/release.sh   # the above + static binaries for all targets
                     #   into releases/v<version>/ (tar.gz + SHA256SUMS)
scripts/fuzz.sh      # time-boxed fuzzing of the parser fuzz targets
```

Or directly with your own Zig 0.16.0:

```sh
zig build              # library + zfping
zig build test         # unit tests
sh test/functional.sh  # functional suite (isolated user+net namespace)
sh test/golden.sh      # byte-diff against an installed reference fping
```

The GitHub release workflow runs the same `scripts/release.sh`, so local
and published artifacts are identical.

## Mapping to fping sources

| fping | zig-fping |
| --- | --- |
| `socket4.c` / `socket6.c` | `src/socket.zig` |
| `seqmap.c` | `src/seqmap.zig` |
| ICMP build/parse in `fping.c` | `src/icmp.zig` |
| `main_loop()` in `fping.c` | `src/pinger.zig` (priority queues instead of linked lists) |
| CLI / output (`fping.c`, `output.c`, `stats.c`, `optparse.c`) | `src/main.zig`, `src/cli/` |
| libc `getnameinfo` (reverse DNS) | `src/rdns.zig` (pure-Zig PTR client) |
| libc `localtime` | `src/tzlocal.zig` (/etc/localtime via std.tz) |

## License

Derived from fping; the original fping license applies — see
[LICENSE](LICENSE).
