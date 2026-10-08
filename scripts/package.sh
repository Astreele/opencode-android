#!/usr/bin/env bash
# Package the android build: zip + Termux deb + pacman archive + SHA256SUMS.
# (The Termux paths inside are install *targets*, not the build host.)
# Runs on Linux x86_64 CI and anywhere with zip/dpkg-deb/xz (incl. Termux);
# `make package UPSTREAM_TAG=...` is the local entry point.
# Env: REPO_ROOT, UPSTREAM_TAG (e.g. v2.0.24).
# Inputs: $WORKSPACE/dist/cli/cli-linux-arm64-android/bin/opencode (from build).
# The renderer is embedded in the binary (bionic lib swapped into the npm musl
# slot pre-build), so packages carry no sidecar .so.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORKSPACE="${WORKSPACE:-$REPO_ROOT}"
WORK="${WORK:-$REPO_ROOT/work}"
OUT="${OUT:-$REPO_ROOT/out}"
UPSTREAM_TAG="${UPSTREAM_TAG:?set UPSTREAM_TAG, e.g. v2.0.24}"
VER="${UPSTREAM_TAG#v}"

CLI_BIN="$WORKSPACE/dist/cli/cli-linux-arm64-android/bin/opencode"
test -x "$CLI_BIN" || { echo "missing CLI binary: $CLI_BIN" >&2; exit 1; }
mkdir -p "$OUT"

STAGE="$WORK/flat"
mkdir -p "$OUT" "$STAGE"

echo "==> wrapper"
cat > "$STAGE/opencode2" <<'WEOF'
#!/data/data/com.termux/files/usr/bin/sh
# opencode2 - wrapper for OpenCode 2 CLI on Android/Termux
set -eu
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
DIR="$(CDPATH= cd -- "$(dirname "$SELF")" && pwd)"
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
# watcher.node (parcel android-arm64) needs Termux libc++_shared.so; the
# official Bun android base has no RUNPATH to $PREFIX/lib.
export LD_LIBRARY_PATH="${PREFIX}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Stale var from pre-watcher builds (v2 ignored it anyway); never force-disable.
unset OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER || true
# A dead background service can leave a stale service-*.json record behind;
# the CLI then trusts the dead URL and the TUI dies with
# "Transport: Unable to connect" instead of starting a fresh service.
# Drop records whose process is gone so auto-start kicks in (kill -0 plus a
# /proc cmdline check: builtins and files only, no extra dependencies).
STATE_DIR="${XDG_STATE_HOME:-${HOME:-}/.local/state}/opencode"
if [ -d "$STATE_DIR" ]; then
    for record in "$STATE_DIR"/service-*.json; do
        [ -e "$record" ] || continue
        pid="$(sed -n 's/^.*"pid":[ ]*\([0-9][0-9]*\).*$/\1/p' "$record")"
        [ -n "$pid" ] || continue
        stale=1
        if kill -0 "$pid" 2>/dev/null; then
            if [ ! -e "/proc/$pid/cmdline" ] || grep -qa opencode "/proc/$pid/cmdline" 2>/dev/null; then
                stale=0
            fi
        fi
        if [ "$stale" = 1 ]; then
            echo "opencode: note: removing stale service record (pid $pid gone)" >&2
            rm -f "$record"
        fi
    done
fi
for candidate in \
    "$DIR/../libexec/opencode2/opencode2.bin" \
    "$PREFIX/libexec/opencode2/opencode2.bin" \
    "$DIR/opencode2.bin"
do
    if [ -x "$candidate" ]; then
        exec "$candidate" "$@"
    fi
done
echo "opencode2: error: could not find opencode2.bin" >&2
exit 127
WEOF
chmod 755 "$STAGE/opencode2"
cp -f "$CLI_BIN" "$STAGE/opencode2.bin"
chmod 755 "$STAGE/opencode2.bin"
# NOTE: packages carry no sidecar libs. The renderer is embedded in the
# binary (bionic lib swapped into the npm musl slot pre-build).

echo "==> license"
cp -f "$REPO_ROOT/LICENSE" "$STAGE/"

echo "==> zip"
ZIP="$OUT/opencode2-${VER}-android-aarch64.zip"
(cd "$STAGE" && zip -9 "$ZIP" opencode2 opencode2.bin LICENSE >/dev/null)
ls -lh "$ZIP"

echo "==> deb + pacman (Termux layouts)"
PKGROOT="$WORK/pkg"
rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/data/data/com.termux/files/usr/bin"
mkdir -p "$PKGROOT/data/data/com.termux/files/usr/libexec/opencode2"
cp "$STAGE/opencode2" "$PKGROOT/data/data/com.termux/files/usr/bin/opencode2"
cp "$STAGE/opencode2.bin" "$PKGROOT/data/data/com.termux/files/usr/libexec/opencode2/opencode2.bin"
chmod 755 "$PKGROOT/data/data/com.termux/files/usr/bin/opencode2" "$PKGROOT/data/data/com.termux/files/usr/libexec/opencode2/opencode2.bin"
# The package owns the `opencode` -> `opencode2` command link (relative target,
# resolves inside $PREFIX/bin). dpkg/pacman therefore track it: upgrades
# replace it, removals delete it — no out-of-band `ln -sf` over a v1 binary.
# Coexistence with v1 is handled via Conflicts/Replaces below.
ln -sf opencode2 "$PKGROOT/data/data/com.termux/files/usr/bin/opencode"
# ship the license with the packages
mkdir -p "$PKGROOT/data/data/com.termux/files/usr/share/doc/opencode2"
cp -f "$STAGE/LICENSE" "$PKGROOT/data/data/com.termux/files/usr/share/doc/opencode2/"

# `-1` Debian revision: packaging-only fixes bump it (2.0.24 -> 2.0.24-2) so
# dpkg/apt see a newer version instead of "same version, nothing to do".
DEB="$OUT/opencode2_${VER}-1_aarch64.deb"
DEBDIR="$WORK/deb"
rm -rf "$DEBDIR"
mkdir -p "$DEBDIR/DEBIAN"
# dpkg requires the control dir 0755-0775; with a umask-077 shell (typical
# on-device) mkdir would make it 0700 and dpkg-deb would reject the package.
chmod 755 "$DEBDIR/DEBIAN"
# hardlink, not copy: the 166M binary already exists twice at this point.
# Hard links are denied on-device (Android blocks link() in app data), so
# fall back to a real copy when packaging locally on Termux instead of CI.
# A failed cp -al leaves a partial tree behind, which the fallback would then
# nest as data/data — clean it before retrying.
if ! cp -al "$PKGROOT/data" "$DEBDIR/data" 2>/dev/null; then
    rm -rf "$DEBDIR/data"
    cp -a "$PKGROOT/data" "$DEBDIR/data"
fi
INSTALLED_SIZE=$(du -sk "$DEBDIR/data" | cut -f1)
cat > "$DEBDIR/DEBIAN/control" <<DEOF
Package: opencode2
Version: ${VER}-1
Architecture: aarch64
Maintainer: opencode-android <noreply@example.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: ripgrep, libc++
Conflicts: opencode, opencode1
Replaces: opencode, opencode1
Section: utils
Priority: optional
Homepage: https://github.com/anomalyco/opencode
Description: OpenCode AI coding assistant for Android/Termux
 Pure Android/aarch64 build of upstream OpenCode, installs side by side
 as opencode2 (never touches v1 opencode).
DEOF

# ── maintainer scripts ──────────────────────────────────────────────────
# Stop stale background daemons around install/upgrade/removal: a leftover
# `serve` process from the previous binary makes the new TUI time out waiting
# for the old service (the failure mode opencode-termux fixed with its
# `stale-serve-kill` hook). Best effort — every call is guarded.

cat > "$DEBDIR/DEBIAN/postinst" <<'SEOF'
#!/data/data/com.termux/files/usr/bin/sh
# Stop stale daemons from the previous version, then sanity-check the CLI.
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

stop_stale_service() {
    if [ -x "$PREFIX/bin/opencode2" ]; then
        "$PREFIX/bin/opencode2" service stop >/dev/null 2>&1 || true
    fi
    if command -v pkill >/dev/null 2>&1; then
        pkill -f "libexec/opencode" >/dev/null 2>&1 || true
    fi
    return 0
}

case "$1" in
    configure)
        stop_stale_service
        if ! "$PREFIX/bin/opencode2" --version >/dev/null 2>&1; then
            echo "opencode2: warning: 'opencode2 --version' failed after install" >&2
        fi
        ;;
esac
exit 0
SEOF

cat > "$DEBDIR/DEBIAN/prerm" <<'SEOF'
#!/data/data/com.termux/files/usr/bin/sh
# Stop the running daemon before the binary disappears (remove/upgrade).
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

case "$1" in
    remove|upgrade|deconfigure)
        if [ -x "$PREFIX/bin/opencode2" ]; then
            "$PREFIX/bin/opencode2" service stop >/dev/null 2>&1 || true
        fi
        if command -v pkill >/dev/null 2>&1; then
            pkill -f "libexec/opencode" >/dev/null 2>&1 || true
        fi
        ;;
esac
exit 0
SEOF

cat > "$DEBDIR/DEBIAN/postrm" <<'SEOF'
#!/data/data/com.termux/files/usr/bin/sh
# On purge, remove what dpkg does not track (leftovers from older installs).
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

case "$1" in
    purge)
        rm -rf "$PREFIX/libexec/opencode2" 2>/dev/null || true
        if [ -L "$PREFIX/bin/opencode" ]; then
            case "$(readlink "$PREFIX/bin/opencode")" in
                *opencode2) rm -f "$PREFIX/bin/opencode" || true ;;
            esac
        fi
        ;;
esac
exit 0
SEOF

chmod 755 "$DEBDIR/DEBIAN/postinst" "$DEBDIR/DEBIAN/prerm" "$DEBDIR/DEBIAN/postrm"

dpkg-deb -b "$DEBDIR" "$DEB" >/dev/null
ls -lh "$DEB"

PACMAN="$OUT/opencode2-${VER}-1-aarch64.pkg.tar.xz"
cat > "$PKGROOT/.PKGINFO" <<PEOF
pkgname = opencode2
pkgver = ${VER}-1
pkgdesc = OpenCode AI coding assistant for Android/Termux
url = https://github.com/anomalyco/opencode
builddate = $(date +%s)
packager = opencode-android
arch = aarch64
license = MIT
install = opencode2.install
depend = ripgrep
depend = libc++
PEOF

# pacman equivalent of the deb maintainer scripts: stop stale daemons around
# install/upgrade/removal, clean untracked leftovers on removal.
cat > "$PKGROOT/opencode2.install" <<'SEOF'
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

stop_stale_service() {
    if [ -x "$PREFIX/bin/opencode2" ]; then
        "$PREFIX/bin/opencode2" service stop >/dev/null 2>&1 || true
    fi
    if command -v pkill >/dev/null 2>&1; then
        pkill -f "libexec/opencode" >/dev/null 2>&1 || true
    fi
    return 0
}

post_install() {
    stop_stale_service
    if ! "$PREFIX/bin/opencode2" --version >/dev/null 2>&1; then
        echo "opencode2: warning: 'opencode2 --version' failed after install" >&2
    fi
}

pre_upgrade() {
    stop_stale_service
}

post_upgrade() {
    stop_stale_service
}

pre_remove() {
    stop_stale_service
}

post_remove() {
    rm -rf "$PREFIX/libexec/opencode2" 2>/dev/null || true
    if [ -L "$PREFIX/bin/opencode" ]; then
        case "$(readlink "$PREFIX/bin/opencode")" in
            *opencode2) rm -f "$PREFIX/bin/opencode" || true ;;
        esac
    fi
    return 0
}
SEOF

(cd "$PKGROOT" && tar cf - .PKGINFO opencode2.install data | xz -9 > "$PACMAN")
ls -lh "$PACMAN"

echo "==> checksums"
(cd "$OUT" && sha256sum opencode2-*.zip opencode2_*.deb opencode2-*.pkg.tar.xz > SHA256SUMS)
cat "$OUT/SHA256SUMS"
