# Contributing to zig-fping

Contributions are welcome, including fully agentic/AI-assisted pull
requests — this project itself is a Claude-authored automated rewrite of
[fping](https://github.com/schweikert/fping). PRs that port upstream fping
fixes and features are especially appreciated.

## Ground rules

- **Pure Zig, Linux only.** No external dependencies, no C/ASM, no libc.
  This is a permanent design decision; platform abstractions that route
  through libc will not be merged.
- **fping compatibility first.** `zfping` mirrors fping's options, output
  formats and exit codes. Anything that intentionally diverges must carry
  a code comment explaining why, plus an entry in CHANGELOG.md under
  "Known divergences".
- **Upstream coherence.** When porting an fping change, reference the
  upstream commit hash in the CHANGELOG entry and bump the pinned SHA in
  CLAUDE.md ("Upstream tracking"). The file mapping table in README.md
  shows where each piece of fping lives here.
- **English** for all code comments, commit messages and documentation.
- No personal information (names, e-mails, `/home/<user>` paths) in
  committed files.

## Checks before submitting

```sh
scripts/test.sh   # fmt check + build + unit tests + functional suite
```

This is the same entry point CI uses; it auto-downloads the pinned Zig
toolchain when none is installed and needs no sudo. The individual steps
are also available directly (`zig fmt`, `zig build test`,
`sh test/functional.sh`).

The functional suite needs `unshare -Urn` (unprivileged user namespaces)
or passwordless sudo; it touches no real network.

New behaviour needs a test: pure logic (parsers, generators, scheduling
helpers) gets a unit test next to the code; anything involving sockets
gets a case in `test/functional.sh`.

## License

By contributing you agree that your contribution is licensed under the
project license (see LICENSE — fping's original license, which requires
keeping the copyright notice intact).
