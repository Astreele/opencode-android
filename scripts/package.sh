#!/usr/bin/env bash
# Package the android build: zip + Termux deb + pacman archive + SHA256SUMS.
# Env: REPO_ROOT, UPSTREAM_TAG (e.g. v2.0.24).
# Inputs: $WORKSPACE/dist/cli/cli-linux-arm64-android/bin/opencode (from build),
#         $REPO_ROOT/out/libopentui.so (from lib build).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORKSPACE="${WORKSPACE:-$REPO_ROOT}"
WORK="${WORK:-$REPO_ROOT/work}"
OUT="${OUT:-$REPO_ROOT/out}"
UPSTREAM_TAG="${UPSTREAM_TAG:?set UPSTREAM_TAG, e.g. v2.0.24}"
VER="${UPSTREAM_TAG#v}"

CLI_BIN="$WORKSPACE/dist/cli/cli-linux-arm64-android/bin/opencode"
LIB="$OUT/libopentui.so"
test -x "$CLI_BIN" || { echo "missing CLI binary: $CLI_BIN" >&2; exit 1; }
test -f "$LIB" || { echo "missing lib: $LIB" >&2; exit 1; }
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
if [ -f "$PREFIX/libexec/opencode2/otui-assets/@opentui/core-linux-arm64-musl/libopentui.so" ]; then
    export OTUI_ASSET_ROOT="$PREFIX/libexec/opencode2/otui-assets"
fi
export LD_LIBRARY_PATH="$PREFIX/libexec/opencode2${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# @parcel/watcher ships no Android binding; the build embeds a stub instead.
export OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER="${OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER:-true}"
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
cp -f "$LIB" "$STAGE/libopentui.so"
chmod 755 "$STAGE/opencode2.bin"

echo "==> zip"
ZIP="$OUT/opencode2-${VER}-android-aarch64.zip"
(cd "$STAGE" && zip -9 "$ZIP" opencode2 opencode2.bin libopentui.so >/dev/null)
ls -lh "$ZIP"

echo "==> deb + pacman (Termux layouts)"
PKGROOT="$WORK/pkg"
rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/data/data/com.termux/files/usr/bin"
mkdir -p "$PKGROOT/data/data/com.termux/files/usr/libexec/opencode2/otui-assets/@opentui/core-linux-arm64-musl"
cp "$STAGE/opencode2" "$PKGROOT/data/data/com.termux/files/usr/bin/opencode2"
cp "$STAGE/opencode2.bin" "$PKGROOT/data/data/com.termux/files/usr/libexec/opencode2/opencode2.bin"
cp "$STAGE/libopentui.so" "$PKGROOT/data/data/com.termux/files/usr/libexec/opencode2/otui-assets/@opentui/core-linux-arm64-musl/libopentui.so"
chmod 755 "$PKGROOT/data/data/com.termux/files/usr/bin/opencode2" "$PKGROOT/data/data/com.termux/files/usr/libexec/opencode2/opencode2.bin"

DEB="$OUT/opencode2_${VER}_aarch64.deb"
DEBDIR="$WORK/deb"
rm -rf "$DEBDIR"
mkdir -p "$DEBDIR/DEBIAN"
cp -a "$PKGROOT/data" "$DEBDIR/data"
INSTALLED_SIZE=$(du -sk "$DEBDIR/data" | cut -f1)
cat > "$DEBDIR/DEBIAN/control" <<DEOF
Package: opencode2
Version: ${VER}
Architecture: aarch64
Maintainer: opencode-android <noreply@example.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: ripgrep
Section: utils
Priority: optional
Homepage: https://github.com/anomalyco/opencode
Description: OpenCode AI coding assistant for Android/Termux
 Pure Android/aarch64 build of upstream OpenCode, installs side by side
 as opencode2 (never touches v1 opencode).
DEOF
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
depend = ripgrep
PEOF
(cd "$PKGROOT" && tar cf - .PKGINFO data | xz -9 > "$PACMAN")
ls -lh "$PACMAN"

echo "==> checksums"
(cd "$OUT" && sha256sum opencode2-*.zip opencode2_*.deb opencode2-*.pkg.tar.xz > SHA256SUMS)
cat "$OUT/SHA256SUMS"
