#!/bin/sh
# Build release artifacts into releases/v<version>/: stripped static
# binaries for every supported target, tarballs and SHA256SUMS. Runs the
# full test pipeline first. Works after a plain `git clone` with no sudo.
#
# Usage: scripts/release.sh [--skip-tests]
#
# The version is read from build.zig.zon. The same script is used by the
# GitHub release workflow, so local and CI artifacts are identical.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/zig-env.sh"
cd "$REPO_ROOT"

TARGETS="x86_64-linux aarch64-linux riscv64-linux"

VERSION=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
[ -n "$VERSION" ] || { echo "release: cannot read version from build.zig.zon" >&2; exit 1; }
OUT="$REPO_ROOT/releases/v$VERSION"

if [ "${1:-}" != "--skip-tests" ]; then
    sh scripts/test.sh
fi

echo "==> building v$VERSION into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"

for target in $TARGETS; do
    echo "==> $target"
    "$ZIG" build -Dtarget="$target" -Doptimize=ReleaseSafe -Dstrip=true --prefix "$OUT/$target"
    tar -C "$OUT/$target/bin" -czf "$OUT/zfping-v$VERSION-$target.tar.gz" zfping
done

(cd "$OUT" && sha256sum zfping-*.tar.gz > SHA256SUMS)

# Smoke test the native artifact.
native="$OUT/$(uname -m)-linux/bin/zfping"
if [ -x "$native" ]; then
    echo "==> smoke test: $("$native" -v)"
fi

echo "==> artifacts:"
ls -l "$OUT"/zfping-*.tar.gz "$OUT/SHA256SUMS"
