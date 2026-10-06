#!/usr/bin/env bash
# RUNS ON: Linux x86_64 CI runner (NOT on Termux, NOT on device).
# Build libopentui.so for Android aarch64 (Linux x86_64 CI).
# Self-contained: clones anomalyco/opentui at $OPENTUI_VERSION, applies the
# android patch, merges the NDK sysroot, and runs the Zig build.
# Env: REPO_ROOT (this repo), OPENTUI_VERSION, NDK_DIR, ANDROID_API.
# Zig must be on PATH.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OPENTUI_VERSION="${OPENTUI_VERSION:-0.5.14}"
ANDROID_API="${ANDROID_API:-29}"
NDK_DIR="${NDK_DIR:-/opt/android-ndk}"
WORK="${WORK:-$REPO_ROOT/work}"
OUT="${OUT:-$REPO_ROOT/out}"
SRC="$WORK/opentui-${OPENTUI_VERSION}/packages/native"

mkdir -p "$WORK" "$OUT"

echo "==> clone opentui v${OPENTUI_VERSION}"
if [ ! -d "$WORK/opentui-${OPENTUI_VERSION}/.git" ]; then
  git clone --depth 1 --branch "v${OPENTUI_VERSION}" https://github.com/anomalyco/opentui.git "$WORK/opentui-${OPENTUI_VERSION}"
fi
git -C "$WORK/opentui-${OPENTUI_VERSION}" apply --check "$REPO_ROOT/patches/v2-android.patch"
git -C "$WORK/opentui-${OPENTUI_VERSION}" apply "$REPO_ROOT/patches/v2-android.patch" 2>/dev/null || true
# idempotent: already-applied is fine, broken-patch is fatal (checked above)

echo "==> merged bionic sysroot"
BIONIC_INC="$WORK/bionic-include"
NDK_SYSROOT="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
test -d "$NDK_SYSROOT/usr/include" || { echo "no NDK sysroot at $NDK_SYSROOT" >&2; exit 1; }
rm -rf "$BIONIC_INC" && mkdir -p "$BIONIC_INC"
cp -a "$NDK_SYSROOT/usr/include/." "$BIONIC_INC/"
cp -a "$NDK_SYSROOT/usr/include/aarch64-linux-android/." "$BIONIC_INC/"
mkdir -p "$BIONIC_INC/__opentui"
cat > "$BIONIC_INC/__opentui/miniaudio_shimmed.h" <<'EOF'
#define _Nullable
#define _Nonnull
#ifndef __ANDROID_MIN_SDK_VERSION__
#define __ANDROID_MIN_SDK_VERSION__ 29
#endif
#include "../miniaudio.h"
EOF
cat > "$BIONIC_INC/__opentui/Yoga_shimmed.h" <<'EOF'
#define _Nullable
#define _Nonnull
#ifndef __ANDROID_MIN_SDK_VERSION__
#define __ANDROID_MIN_SDK_VERSION__ 29
#endif
#include "../yoga/yoga/Yoga.h"
EOF
cp -f "$SRC/src/vendor/miniaudio/miniaudio.h" "$BIONIC_INC/miniaudio.h"
ls "$BIONIC_INC/miniaudio.h"

echo "==> zig deps"
cd "$SRC"
sh scripts/prepare-zig-deps.sh
ls -d zig-deps/yoga zig-deps/ghostty

echo "==> link yoga tree for the Yoga shim"
ln -sfn "$SRC/zig-deps/yoga" "$BIONIC_INC/yoga"
ls "$BIONIC_INC/yoga/yoga/Yoga.h"

echo "==> zig libc config (Zig has no bundled Android libc; NDK provides it)"
CRT_DIR=""
for cand in "$NDK_SYSROOT/usr/lib/aarch64-linux-android/29" \
            "$NDK_SYSROOT/usr/lib/aarch64-linux-android/28" \
            "$NDK_SYSROOT/usr/lib/aarch64-linux-android"; do
  if [ -f "$cand/crtbegin_dynamic.o" ]; then CRT_DIR="$cand"; break; fi
done
test -n "$CRT_DIR" || { echo "no Android crt dir" >&2; ls "$NDK_SYSROOT/usr/lib/aarch64-linux-android" >&2; exit 1; }
echo "CRT_DIR=$CRT_DIR"
cat > "$WORK/android-libc.txt" <<EOF
include_dir=$BIONIC_INC
sys_include_dir=$BIONIC_INC
crt_dir=$CRT_DIR
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

echo "==> zig build"
export BIONIC_SYSROOT_INC="$BIONIC_INC"
export ANDROID_NDK_HOME="$NDK_DIR"
zig build --libc "$WORK/android-libc.txt" -Dlibrary-target=aarch64-linux-android -Doptimize=ReleaseSafe --summary all

echo "==> install"
LIB_SO="$(find "$SRC/lib" -name libopentui.so | head -n 1)"
test -n "$LIB_SO"
cp -v "$LIB_SO" "$OUT/libopentui.so"
ls -lh "$OUT/libopentui.so"
