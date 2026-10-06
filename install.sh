#!/data/data/com.termux/files/usr/bin/bash
# RUNS ON: native Termux on device (aarch64 Android). Do NOT run in proot,
# do NOT run on CI runners.
# Install opencode2 (pure Android/aarch64 OpenCode) in native Termux.
# Usage: bash install.sh  (or bash <(curl -fsSL <raw-url>/install.sh))
# Env: VERSION (e.g. v2.0.24-android) to pin, REPO (default below).
set -euo pipefail

REPO="${REPO:-OWNER/opencode-android}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

STEP=0
step() { STEP=$((STEP+1)); echo "[$STEP $(date +%H:%M:%S)] ==> $*"; }
ok() { echo "[$STEP $(date +%H:%M:%S)] OK: $*"; }
fail() { echo "[$STEP $(date +%H:%M:%S)] FAILED: $*" >&2; exit 1; }

[ "$(uname -m)" = "aarch64" ] || fail "needs aarch64, got $(uname -m)"
[ -d "$PREFIX" ] || fail "not Termux native (no $PREFIX); don't run inside proot"
command -v curl >/dev/null || fail "curl missing: pkg install curl"
command -v unzip >/dev/null || fail "unzip missing: pkg install unzip"

step "resolving version (REPO=$REPO)"
if [ -n "${VERSION:-}" ]; then TAG="$VERSION"; else
  TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])") || \
    fail "could not resolve latest release"
fi
echo "TAG=$TAG"

step "installing dependencies (ripgrep, libc++ for parcel watcher)"
pkg install -y ripgrep libc++

step "downloading release"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
curl -fSL -O "https://github.com/${REPO}/releases/download/${TAG}/SHA256SUMS"
ZIP=$(grep -o "opencode2-.*-android-aarch64.zip" SHA256SUMS | head -n 1)
[ -n "$ZIP" ] || fail "no android zip in release $TAG"
curl -fSL -O "https://github.com/${REPO}/releases/download/${TAG}/${ZIP}"
sha256sum -c <(grep "$ZIP" SHA256SUMS) || fail "checksum mismatch"
ok "$ZIP verified"

step "stopping running server (installed binary is busy)"
"$PREFIX/bin/opencode2" service stop 2>/dev/null || true
sleep 1
pkill -f "libexec/opencode2/opencode2.bin" 2>/dev/null || true
sleep 1

step "installing to $PREFIX"
unzip -o -q "$ZIP"
mkdir -p "$PREFIX/bin" "$PREFIX/libexec/opencode2"
cp -f opencode2 "$PREFIX/bin/opencode2"
cp -f opencode2.bin "$PREFIX/libexec/opencode2/opencode2.bin"
chmod 755 "$PREFIX/bin/opencode2" "$PREFIX/libexec/opencode2/opencode2.bin"
# Intentional: v2 becomes the default `opencode` (side-by-side not promised).
ln -sf "$PREFIX/bin/opencode2" "$PREFIX/bin/opencode" 2>/dev/null || true
ok "files installed"

step "verifying"
command -v opencode2
opencode2 --version
ok "done. Run: opencode2 auth  (then: opencode2)"
