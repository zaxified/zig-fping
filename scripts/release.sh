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
NATIVE="$(uname -m)-linux"

VERSION=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
[ -n "$VERSION" ] || { echo "release: cannot read version from build.zig.zon" >&2; exit 1; }
OUT="$REPO_ROOT/releases/v$VERSION"

echo "==> building v$VERSION into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"

# Build one target's stripped ReleaseSafe binary into the release prefix.
build_bin() {
    echo "==> $1"
    "$ZIG" build -Dtarget="$1" -Doptimize=ReleaseSafe -Dstrip=true --prefix "$OUT/$1"
    cp doc/zfping.8 "$OUT/$1/bin/"
}

# Compile the native shipping binary once, then run the full test pipeline
# against that exact artifact — so the binary we publish is what gets tested,
# and it is not rebuilt by test.sh.
build_bin "$NATIVE"
if [ "${1:-}" != "--skip-tests" ]; then
    sh scripts/test.sh "$OUT/$NATIVE/bin/zfping"
fi

# Remaining cross targets (build-only; Zig cross-compiles without sysroots).
for target in $TARGETS; do
    [ "$target" = "$NATIVE" ] && continue
    build_bin "$target"
done

for target in $TARGETS; do
    tar -C "$OUT/$target/bin" -czf "$OUT/zfping-v$VERSION-$target.tar.gz" zfping zfping.8
done

(cd "$OUT" && sha256sum zfping-*.tar.gz > SHA256SUMS)

# Smoke test the native artifact.
native="$OUT/$(uname -m)-linux/bin/zfping"
if [ -x "$native" ]; then
    echo "==> smoke test: $("$native" -v)"
fi

echo "==> artifacts:"
ls -l "$OUT"/zfping-*.tar.gz "$OUT/SHA256SUMS"
