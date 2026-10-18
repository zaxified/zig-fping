#!/bin/sh
# Build (once) the reference C fping used by test/golden.sh and print the
# path of the binary on stdout. Everything else goes to stderr.
#
# The release tarball ships a generated configure, so no autotools are
# needed; the build needs only a C compiler and make, and no root.
# The result is cached under .zig-cache/fping-ref-<version>/ (idempotent).
#
# fping.org publishes only a detached PGP signature, no checksum, so the
# SHA256 below was pinned from a download of the official tarball.
#
# Usage: scripts/fping-ref.sh        (prints <cache>/install/sbin/fping)
#   FPING_REF_MAKE="hw run --slots 1 --name fping-ref --" overrides how
#   make is wrapped (default: plain make).

set -eu

VERSION=5.5
SHA256=15c4e32b6c55ff105bafe03e8c91c7ca1b2eda31bf9a7127326bb87887ee18fe
URL="https://fping.org/dist/fping-$VERSION.tar.gz"

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIR="$REPO_ROOT/.zig-cache/fping-ref-$VERSION"
BIN="$DIR/install/sbin/fping"

if [ -x "$BIN" ]; then
    echo "$BIN"
    exit 0
fi

mkdir -p "$DIR"
TARBALL="$DIR/fping-$VERSION.tar.gz"
if [ ! -f "$TARBALL" ]; then
    echo "==> downloading $URL" >&2
    if command -v curl >/dev/null; then
        curl -fsSL -o "$TARBALL.part" "$URL" >&2
    else
        wget -q -O "$TARBALL.part" "$URL" >&2
    fi
    mv "$TARBALL.part" "$TARBALL"
fi

echo "$SHA256  $TARBALL" | sha256sum -c - >&2 || {
    echo "fping-ref: SHA256 mismatch for $TARBALL" >&2
    rm -f "$TARBALL"
    exit 1
}

rm -rf "$DIR/src"
mkdir -p "$DIR/src"
tar xzf "$TARBALL" -C "$DIR/src" --strip-components=1

echo "==> configure + make fping $VERSION" >&2
(
    cd "$DIR/src"
    ./configure --prefix="$DIR/install" >"$DIR/configure.log" 2>&1
    # shellcheck disable=SC2086
    ${FPING_REF_MAKE:-} make >"$DIR/make.log" 2>&1
    make install >"$DIR/install.log" 2>&1
) || {
    echo "fping-ref: build failed, see logs in $DIR" >&2
    exit 1
}

echo "$BIN"
