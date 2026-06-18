# zig-fping

Zig (0.16+) port of the C project [fping](https://github.com/schweikert/fping),
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
  install, `src/main.zig`→`src/cli/` split). See CHANGELOG.md.

## Upstream tracking (fping → zig-fping)

The port is pinned to an upstream fping commit; fixes and features landing
in fping should be reviewed periodically and re-implemented here so the
project stays an "improved clone" of the C original.

- **Ported-from commit**: `780ec46747803f89ef02b841785a7518110b75b8`
  (fping develop, 2026-04-25).
- Update procedure:
  1. `git -C /tmp/fping-ref fetch origin && git -C /tmp/fping-ref log --oneline 780ec46..origin/develop -- src/ doc/`
  2. For each new commit, decide: port / not applicable (autotools, CI,
     platforms we don't support) / defer. Use the file mapping table in
     README.md (socket4.c→socket.zig, seqmap.c→seqmap.zig, …).
  3. Port semantic changes with tests, add a CHANGELOG entry referencing the
     upstream commit hash, and bump the pinned SHA above.
- Audit trail: record every reviewed upstream commit in CHANGELOG.md under
  the release that ported (or skipped) it.
- Candidate automation (not set up yet): a scheduled Claude Code routine
  (e.g. monthly `/schedule`) that fetches upstream, lists unreviewed commits
  touching `src/`, and prepares a port proposal branch with failing/passing
  tests; human review merges it.

## Environment

- **Zig version**: driven by `.zigversion` (read by the VSCode Zig extension)
  — currently 0.16.0.
  - binary: `~/.config/Code/User/globalStorage/ziglang.vscode-zig/zig/x86_64-linux-0.16.0/zig`
    (also exported as `$ZIG` via `.claude/settings.local.json`)
  - NOTE: if `zig version` in PATH does not match `.zigversion` (stale
    session), use the full path / `$ZIG`.
- **Zig std sources** (authoritative for 0.16 API checks):
  `~/.config/Code/User/globalStorage/ziglang.vscode-zig/zig/x86_64-linux-0.16.0/lib/std/`
- **fping C reference**: `/tmp/fping-ref/src/` (shallow clone; restore after
  reboot with `git clone https://github.com/schweikert/fping /tmp/fping-ref`
  — full clone preferred now, the upstream-tracking procedure needs history).
- The Claude Code `zig` skill documents 0.15.x patterns — always verify 0.16
  APIs against the std sources above (esp. std.Io, std.posix, std.os.linux).
- `codedb` is registered in `.mcp.json` (MCP) and usable as a CLI; it can
  index the Zig std tree too:
  `codedb <std-path> symbol <Name>` / `search` / `outline`.

## Build & test

```sh
scripts/test.sh            # canonical pipeline: fmt + build + unit + functional + golden
scripts/release.sh         # release artifacts into releases/v<version>/
scripts/fuzz.sh [secs]     # time-boxed fuzzing (blocked on Zig 0.16.0, see header)
$ZIG build                 # library + zfping CLI
$ZIG build test            # unit tests
sh test/functional.sh      # functional suite (isolated user+net namespace)
sh test/golden.sh          # byte-diff against reference fping (needs fping installed)
```

scripts/zig-env.sh resolves the pinned toolchain ($ZIG → PATH →
.zig-toolchain/ → download from ziglang.org); CI and the release workflow
call the same scripts.

Functional tests and ad-hoc runs work without root via namespaces:

```sh
unshare -Urn sh -c 'ip link set lo up; ./zig-out/bin/zfping 127.0.0.1 ::1'
```

## Key 0.16 API notes (differ from 0.15.x skill docs)

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
