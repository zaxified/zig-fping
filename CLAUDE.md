# zig-fping

Zig (0.17+) port of the C project [fping](https://github.com/schweikert/fping),
shipped as a reusable Zig library plus the `zfping` CLI.
Public repository: `github.com/zaxified/zig-fping`.

Final deployment target: a Nagios-like monitoring system running 10k+ ping
checks per 5-minute cycle. Net-storm protection is therefore critical (global
send pacing, jitter, in-flight cap, per-subnet spacing) — bursting probes into
one network branch causes false DOWN states.

## Workspace rules

- All code comments, commit messages and documentation in the repository
  are in **English**.
- **No personal information** (real name, e-mail, `/home/<user>` paths) may
  appear in committed files — use `~` for home paths. GitHub user is
  `zaxified`.
- Preserve licenses of external sources (see LICENSE — fping's license must
  stay reproduced there).
- The repo is published as public `zig-fping` for use as a Zig package:
  **no external dependencies, no C/ASM hooks, no libc** (pure Zig + std
  only). **Linux-only is a permanent design decision** — do not add
  macOS/BSD/Windows support; it would require libc.
- `zfping` must be as close to 100% fping-compatible as possible; anything
  that cannot be implemented must carry a code comment explaining why
  (see also CHANGELOG.md "Known divergences").
- Released: **v0.1.0 "fping-complete-zig-port"**, **v0.1.1** (golden-diff
  suite, fuzz targets, sendmmsg/recvmmsg batching, compat fixes), **v0.1.2**
  (fuzzing unblocked on 0.16.0 via `--release=safe`, CI hardening, man page
  install, `src/main.zig`→`src/cli/` split), **v0.1.3** (2026-10-18, the
  last release for Zig 0.16 — no fixes planned for that line; `main` moves
  to Zig 0.17). See CHANGELOG.md.

## Upstream tracking (fping → zig-fping)

The port tracks upstream fping so the project stays an "improved clone" of
the C original. Upstream has no stable branch — `develop` is the mainline and
releases are tagged off it, roughly once or twice a year (v5.5: 2025-12-31,
v5.4: 2025-08-19, v5.3: 2025-01-02).

Two pins are maintained here:

- **Ported-from commit**: `8163e2813ad381df3593eb2b53018971c7e530b8`
  (fping develop, 2026-08-09) — how far develop has been *reviewed*. Advances
  on every review round, even when nothing gets ported.
- **Compatible-with release**: `v5.5` — the newest fping *release* whose CLI
  and output surface zfping fully implements.

### Porting policy

Not everything on `develop` is ported when it lands. The deciding question is
whether a change touches the public CLI/output contract, not whether it has
been released:

| upstream change | action |
| --- | --- |
| bugfix, protocol/behaviour correctness | port immediately |
| performance / internals | port if it fits the Zig design |
| upstream-internal refactor (file splits, decl moves) | skip — our layout is our own (mapping table in README.md) |
| **new CLI option or output-format change** | **defer until it appears in an upstream release tag** |
| autotools, upstream CI, unsupported platforms | not applicable |

Why CLI/output changes wait for a release:

1. `test/golden.sh` diffs against an *installed* reference fping, which is
   always a release — an unreleased flag has nothing to diff against.
2. "fping-compatible" is measured against the fping users actually have
   installed (distro packages), not against yesterday's develop HEAD.
3. The deployment target is monitoring 10k+ hosts; a flag renamed before
   release breaks production configs for something upstream never shipped.
   Not hypothetical: `292d56f` added `--print-srcaddr`, `acb6579` renamed it
   to `--print-reply-dst` two commits later.

Escape hatch: a deferred item may be ported early if it is genuinely needed
and has been stable on develop for a few months.

### Procedure

1. `git -C /tmp/fping-ref fetch origin && git -C /tmp/fping-ref log --oneline <pinned>..origin/develop -- src/ doc/`
2. Give every commit a disposition — **ported / skipped / deferred / n-a** —
   using the file mapping table in README.md (socket4.c→socket.zig,
   seqmap.c→seqmap.zig, …).
3. Port what is due, with tests; record every reviewed commit and its
   disposition in CHANGELOG.md, and advance **Ported-from commit** to the
   reviewed develop head (even if nothing was ported).
4. Deferred items live in the "Pending upstream (deferred)" section of
   CHANGELOG.md until the release that ships them.
5. On a new upstream release: implement the deferred items, **re-verify that
   already-ported develop-only features survived into the release unrenamed**
   (`--oiface` and friends), then bump **Compatible-with release**.

### Automation

`.github/workflows/upstream-check.yml` (GitHub Actions) runs monthly
(`cron: '17 6 1 * *'`) and on manual dispatch, using the built-in
`GITHUB_TOKEN` (no PAT). It clones upstream fping with full history and:

- lists commits touching `src/`/`doc/` since **Ported-from commit**, then
  opens (or updates) a single `upstream-tracking` issue with the commit list
  and a compare link — and closes that issue once the range is empty, so an
  open issue always means "unreviewed commits";
- compares **Compatible-with release** with the newest upstream release tag
  and opens an `upstream-release` issue when a newer one exists — that issue
  is the trigger for working through the deferred backlog.

## Environment

- **Zig version**: driven by `.zigversion` (read by the VSCode Zig extension)
  — currently 0.17.0.
  - binary: `.zig-toolchain/zig-0.17.0/zig` (downloaded by `scripts/zig-env.sh`;
    also exported as `$ZIG` via `.claude/settings.local.json`)
  - ZLS does not work with Zig 0.17.0 (the configurer/maker build split
    removed the hook it used) — no editor diagnostics; compile to see errors.
  - NOTE: if `zig version` in PATH does not match `.zigversion` (stale
    session), use the full path / `$ZIG`.
- **Zig std sources** (authoritative for 0.17 API checks):
  `.zig-toolchain/zig-0.17.0/lib/std/`
- **fping C reference**: `/tmp/fping-ref/src/` (shallow clone; restore after
  reboot with `git clone https://github.com/schweikert/fping /tmp/fping-ref`
  — full clone preferred now, the upstream-tracking procedure needs history).
- The vendored `zig-0.17` skill (`.claude/skills/zig-0.17`) covers 0.17 —
  still verify APIs against the std sources above (esp. std.Io, std.os.linux).
- `codedb` is registered in `.mcp.json` (MCP) and usable as a CLI; it can
  index the Zig std tree too:
  `codedb <std-path> symbol <Name>` / `search` / `outline`.

## Build & test

```sh
scripts/test.sh            # canonical pipeline: fmt + build + unit + functional + golden
scripts/release.sh         # release artifacts into releases/v<version>/
scripts/fuzz.sh [secs]     # deterministic fuzz driver, ReleaseSafe, one job per core (see below)
$ZIG build                 # library + zfping CLI
$ZIG build test            # unit tests
sh test/functional.sh      # functional suite (isolated user+net namespace)
sh test/golden.sh          # byte-diff against reference fping (needs fping installed)
```

Fuzzing: `hw run --slots 2 --name fz-zfping -- scripts/fuzz.sh 60`. The
verdict comes from the **deterministic driver** (`src/testing/fuzz_driver.zig`,
trimmed from zig-libs testkit), never from `zig build --fuzz` (no progress,
exit 0 on a crash, hangs invisible). Each harness
(`src/icmp.zig`, `src/rdns.zig`, `src/cli/options_fuzz.zig`,
`src/cli/generate_fuzz.zig`) is `fn(comptime S, src: *S, gpa)` generic over its
choice source: `Rng` (PRNG) for the driver, a `Script` built from one
`Smith.slice` for the optional `zig build test --fuzz` — never
`Smith{ .in = random bytes }`. A seed replays with
`ZFPING_FUZZ=1,<seed> ZFPING_FUZZ_ONLY=<target> .zig-cache/fz/fuzz/fuzz-{lib,cli}`.
Each harness has a seed corpus and `hit("label")` reach counters; the
`fuzz harness: … reaches every branch` tests in `zig build test` fail if a
label is not reached in 500 seeds. After changing a harness or the code's
branching, re-check reach and plant a bug in a copy under `.zig-cache`
(`FZ_ROOT=<copy> scripts/fuzz.sh`).

Every compile step uses the LLVM backend; `-Dselfhosted=true` is for the
edit loop only. Which command runs when (and in which mode):
`.claude/rules/zig-pitfalls.md`.

scripts/zig-env.sh resolves the pinned toolchain ($ZIG → PATH →
.zig-toolchain/ → download from ziglang.org); CI and the release workflow
call the same scripts.

Functional tests and ad-hoc runs work without root via namespaces:

```sh
unshare -Urn sh -c 'ip link set lo up; ./zig-out/bin/zfping 127.0.0.1 ::1'
```

## Key Zig 0.16/0.17 API notes

- `std.posix` no longer has socket/sendto/epoll — use `std.os.linux` raw
  syscalls (`linux.errno(rc)` for error checks, not `E.init`).
- `std.time.Instant`/`Timer` are gone — use `linux.clock_gettime(.MONOTONIC, ...)`.
- `std.crypto.random` is gone (CSPRNG needs an Io); seed PRNGs from
  clock/pid when cryptographic quality is not needed.
- Entry point: `pub fn main(init: std.process.Init) !void`; args via
  `init.minimal.args.toSlice(arena)`; stdout via
  `Io.File.Writer.init(.stdout(), init.io, &buf)`; files via
  `Io.Dir.cwd().openFile(io, path, .{})`.
- `std.Io.net.IpAddress` (union ip4/ip6) replaces `std.net.Address` for
  parsing; sockaddr structs live in `std.os.linux`. Forward DNS:
  `std.Io.net.HostName.lookup` (A/AAAA/CNAME + /etc/hosts; **no PTR**).
- PriorityQueue: unmanaged — `.empty` / `initContext`, `push(alloc, e)`,
  `pop()`, `deinit(alloc)`.
- 0.17: array `**` is gone (`@splat`); `@bitCast` into/out of an extern
  struct is a compile error and arrays bit-cast as little-endian on every
  target — reinterpret bytes with `std.mem.bytesToValue(T, bytes)` /
  `std.mem.toBytes(x)`; `std.mem.find*` replaces `indexOf*`;
  `allocator.print` replaces `std.fmt.allocPrint`; `run.addPassthruArgs()`
  replaces `b.args`.
