#!/bin/sh
# Build release artifacts into releases/v<version>/: stripped static
# binaries for every supported target, tarballs, the fping-watch demo's
# .deb packages and SHA256SUMS. Runs the full test pipeline first. Works
# after a plain `git clone` with no sudo (needs dpkg-deb for the packages).
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

# The version lives in three places; `zfping -v` and the man page must not
# disagree with the package.
grep -q "\"zfping $VERSION (" src/main.zig ||
    { echo "release: src/main.zig version_string is not $VERSION" >&2; exit 1; }
grep -q "^\.TH ZFPING 8 .* \"zfping $VERSION\"" doc/zfping.8 ||
    { echo "release: doc/zfping.8 .TH line is not $VERSION" >&2; exit 1; }
# In the release workflow the tag must name this version too.
if [ -n "${GITHUB_REF_NAME:-}" ] && [ "$GITHUB_REF_NAME" != "v$VERSION" ]; then
    echo "release: tag $GITHUB_REF_NAME does not match build.zig.zon version $VERSION" >&2
    exit 1
fi

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

# The fping-watch demo's Debian packages; they carry the app's own version
# (example-apps/fping-watch/build.zig.zon), not the library's.
if [ "${1:-}" = "--skip-tests" ]; then
    sh example-apps/fping-watch/package.sh --skip-tests "$OUT"
else
    sh example-apps/fping-watch/package.sh "$OUT"
fi

(cd "$OUT" && sha256sum zfping-*.tar.gz fping-watch_*.deb > SHA256SUMS)

# Smoke test the native artifact.
native="$OUT/$(uname -m)-linux/bin/zfping"
if [ -x "$native" ]; then
    echo "==> smoke test: $("$native" -v)"
fi

echo "==> artifacts:"
ls -l "$OUT"/zfping-*.tar.gz "$OUT"/fping-watch_*.deb "$OUT/SHA256SUMS"
