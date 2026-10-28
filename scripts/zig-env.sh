#!/bin/sh
# Resolve the Zig toolchain pinned by .zigversion. Sourced by test.sh and
# release.sh; sets $ZIG to a usable compiler, downloading an official
# release tarball into .zig-toolchain/ when none is available locally.
# No sudo, no system-wide installation.

set -u

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZIG_VERSION=$(tr -d ' \n' <"$REPO_ROOT/.zigversion")
TOOLCHAIN_DIR="$REPO_ROOT/.zig-toolchain"

# SHA256 of the official tarballs (ziglang.org/download/index.json, the
# "shasum" field), pinned so a download is checked against what was
# reviewed, not against whatever the server sends with it. Add a line here
# when .zigversion changes.
tarball_sha256() {
    case "$1" in
        zig-x86_64-linux-0.17.0.tar.xz) echo 1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
        zig-aarch64-linux-0.17.0.tar.xz) echo 9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;;
        *) return 1 ;;
    esac
}

zig_version_ok() {
    [ -x "$1" ] && [ "$("$1" version 2>/dev/null)" = "$ZIG_VERSION" ]
}

resolve_zig() {
    # 1. explicit override
    if [ -n "${ZIG:-}" ] && zig_version_ok "$ZIG"; then
        return 0
    fi
    # 2. zig in PATH with the pinned version
    if command -v zig >/dev/null 2>&1 && zig_version_ok "$(command -v zig)"; then
        ZIG=$(command -v zig)
        return 0
    fi
    # 3. previously downloaded toolchain
    ZIG="$TOOLCHAIN_DIR/zig-$ZIG_VERSION/zig"
    if zig_version_ok "$ZIG"; then
        return 0
    fi
    # 4. download an official release tarball
    arch=$(uname -m)
    case "$arch" in
        x86_64 | aarch64) ;;
        *) echo "zig-env: unsupported architecture: $arch" >&2; return 1 ;;
    esac
    tarball="zig-$arch-linux-$ZIG_VERSION.tar.xz"
    sha256=$(tarball_sha256 "$tarball") || {
        echo "zig-env: no pinned SHA256 for $tarball (add it to tarball_sha256 in scripts/zig-env.sh)" >&2
        return 1
    }
    url="https://ziglang.org/download/$ZIG_VERSION/$tarball"
    echo "zig-env: downloading $url" >&2
    mkdir -p "$TOOLCHAIN_DIR"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$TOOLCHAIN_DIR/$tarball" "$url" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$TOOLCHAIN_DIR/$tarball" "$url" || return 1
    else
        echo "zig-env: need curl or wget to download Zig" >&2
        return 1
    fi
    echo "$sha256  $TOOLCHAIN_DIR/$tarball" | sha256sum -c - >/dev/null 2>&1 || {
        echo "zig-env: SHA256 mismatch for $tarball, not using it" >&2
        rm -f "$TOOLCHAIN_DIR/$tarball"
        return 1
    }
    tar -C "$TOOLCHAIN_DIR" -xJf "$TOOLCHAIN_DIR/$tarball" || return 1
    rm -f "$TOOLCHAIN_DIR/$tarball"
    mv "$TOOLCHAIN_DIR/zig-$arch-linux-$ZIG_VERSION" "$TOOLCHAIN_DIR/zig-$ZIG_VERSION"
    zig_version_ok "$ZIG"
}

if ! resolve_zig; then
    echo "zig-env: could not provide Zig $ZIG_VERSION" >&2
    exit 1
fi
export ZIG
echo "zig-env: using $ZIG ($ZIG_VERSION)" >&2
