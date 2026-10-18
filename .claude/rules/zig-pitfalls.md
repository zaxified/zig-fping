# Zig pitfalls in this repository

Repository-specific lessons for zig-fping on Zig 0.16. General Zig 0.16 API
changes and gotchas live in the `zig` skill (`.claude/skills/zig`, vendored
from an audited release — never edit it here); the 0.16 API notes that matter
most for this code base are in CLAUDE.md.

## Build modes and backends here

Every compile step in `build.zig` (the `zfping` executable and both test
binaries) uses LLVM unless `-Dselfhosted=true` is passed. The self-hosted
backend is for the edit loop only; no gate and no CI lane uses it. Each defect
class is caught once, in the cheapest place:

| when | what to run |
|---|---|
| editing | whatever is fastest; `-Dselfhosted=true` is fine here |
| iterating on a fix | `zig build test` — LLVM Debug |
| before ending work | `scripts/test.sh` — fmt, build, unit, functional and golden suites, all ReleaseSafe (the shipped mode) |
| every push / PR | CI (`ci.yml`): the same `scripts/test.sh` plus cross-compiles, ReleaseSafe |
| fuzzing | `scripts/fuzz.sh` / the manual CI `fuzz` job: `zig build test --fuzz --release=safe` |
| releases | `scripts/release.sh`: ReleaseSafe, stripped, tested as the exact shipped binary |
| benchmarks | `scripts/bench.sh`: ReleaseSafe, never Debug |

- There is no direct `zig test` / `zig build-exe` / `zig run` call in
  `scripts/` or `test/`; a new one takes `-fllvm`.
- `zig build test` needs unprivileged ICMP sockets
  (`net.ipv4.ping_group_range`); without them the live-socket test in
  `pinger.zig` skips rather than fails — check the pass count, not just the exit code.
