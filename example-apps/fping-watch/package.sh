#!/bin/sh
# Build the Debian packages: fping-watch_<version>_{amd64,arm64}.deb. The
# binary is static (no libc), so the package needs only what every systemd
# host has (init-system-helpers, for the maintainer scripts) and installs on
# any Debian or Ubuntu: `apt install ./fping-watch_<version>_amd64.deb`.
#
#   ./package.sh [--skip-tests] [OUTDIR]     (default OUTDIR: zig-out/deb)
#
# Before packing, the native package's own (stripped) binary runs the smoke
# test. scripts/release.sh calls this and attaches the packages to the
# GitHub release. Needs dpkg-deb. Also ships the about page for a demo hub
# (zig build about) in /usr/share/fping-watch/about/.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$HERE/../..
# zig-env.sh finds the repository from its own path ($0).
ZIG=$(sh -c '. "$0" && printf %s "$ZIG"' "$REPO/scripts/zig-env.sh")

TESTS=1
[ "${1:-}" = --skip-tests ] && { TESTS=; shift; }
OUT=${1:-$HERE/zig-out/deb}
mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)

VERSION=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$HERE/build.zig.zon")
[ -n "$VERSION" ] || { echo "package.sh: cannot read the version from build.zig.zon" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "package.sh: needs dpkg-deb" >&2; exit 1; }

umask 022 # the stage dirs become the package's system dirs
cd "$HERE"
for pair in x86_64-linux:amd64 aarch64-linux:arm64; do
    target=${pair%:*}
    arch=${pair#*:}
    stage=$HERE/zig-out/deb-stage/$arch
    deb=$OUT/fping-watch_${VERSION}_$arch.deb
    echo "==> $deb"
    rm -rf "$stage"
    "$ZIG" build -Dtarget="$target" -Dstrip=true --prefix "$stage/usr"
    if [ -n "$TESTS" ] && [ "$target" = "$(uname -m)-linux" ]; then
        sh smoke.sh "$stage/usr/bin/fping-watch"
    fi

    install -D -m 0644 deploy/fping-watch.service "$stage/usr/lib/systemd/system/fping-watch.service"
    install -D -m 0644 targets.json "$stage/usr/share/fping-watch/targets.json"
    install -D -m 0644 deploy/Caddyfile "$stage/usr/share/fping-watch/Caddyfile"
    # The about page for a demo hub: /usr/share/fping-watch/about/.
    "$ZIG" build about --prefix "$stage/usr/share/fping-watch"
    install -D -m 0644 README.md "$stage/usr/share/doc/fping-watch/README.md"
    install -D -m 0644 "$REPO/LICENSE" "$stage/usr/share/doc/fping-watch/copyright"
    install -d "$stage/DEBIAN"
    for script in postinst prerm postrm; do
        install -m 0755 "deploy/debian/$script" "$stage/DEBIAN/$script"
    done
    cat > "$stage/DEBIAN/control" <<EOF
Package: fping-watch
Version: $VERSION
Architecture: $arch
Maintainer: zaxified <zaxified@users.noreply.github.com>
Installed-Size: $(du -sk "$stage/usr" | cut -f1)
Depends: init-system-helpers
Section: net
Priority: optional
Homepage: https://github.com/zaxified/zig-fping/tree/main/example-apps/fping-watch
Description: ping monitor with a web page
 Pings a list of targets once a minute and serves a web page with the last
 24 hours of status, latency and packet loss, on 127.0.0.1:8080. Targets are
 added, paused and acknowledged in the page; FPING_WATCH_OPTS=--read-only in
 /etc/fping-watch/env turns it into a public demo for a reverse proxy.
 Built on zig-fping; one static binary.
EOF
    dpkg-deb --root-owner-group -Zxz --build "$stage" "$deb" >/dev/null
done
ls -l "$OUT"/fping-watch_"$VERSION"_*.deb
