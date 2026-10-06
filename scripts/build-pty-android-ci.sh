#!/usr/bin/env bash
# RUNS ON: Linux x86_64 CI runner (NOT on Termux, NOT on device).
# Build PTY natives for Android aarch64 (Linux x86_64 CI):
#   1. opencode-pty daemon binary (anomalyco/opencode-pty at $PTY_VERSION),
#      with the TMPDIR socket patch (Termux /tmp is not writable).
#   2. librust_pty cdylib (sursaone/bun-pty at $BUN_PTY_VERSION, rust-pty crate),
#      for bun-pty inline sessions (Bun compile embeds librust_pty_arm64.so).
# Env: REPO_ROOT (this repo), PTY_VERSION, BUN_PTY_VERSION, NDK_DIR, ANDROID_API.
# Requires: cargo + rustup target aarch64-linux-android + NDK clang.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PTY_VERSION="${PTY_VERSION:-0.2.0}"
BUN_PTY_VERSION="${BUN_PTY_VERSION:-0.4.9}"
ANDROID_API="${ANDROID_API:-29}"
NDK_DIR="${NDK_DIR:-/opt/android-ndk}"
WORK="${WORK:-$REPO_ROOT/work}"
OUT="${OUT:-$REPO_ROOT/out}"
TARGET="aarch64-linux-android"

mkdir -p "$WORK" "$OUT"

command -v cargo >/dev/null || { echo "cargo missing" >&2; exit 1; }
rustup target list --installed 2>/dev/null | grep -q "$TARGET" || \
  { echo "rust target $TARGET missing: rustup target add $TARGET" >&2; exit 1; }

TOOLCHAIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
test -x "$TOOLCHAIN/aarch64-linux-android${ANDROID_API}-clang" || \
  { echo "no NDK clang at $TOOLCHAIN" >&2; exit 1; }
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TOOLCHAIN/aarch64-linux-android${ANDROID_API}-clang"
export CC_aarch64_linux_android="$TOOLCHAIN/aarch64-linux-android${ANDROID_API}-clang"
export AR_aarch64_linux_android="$TOOLCHAIN/llvm-ar"
export CFLAGS_aarch64_linux_android="--sysroot=$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

echo "==> opencode-pty v${PTY_VERSION} (daemon binary)"
if [ ! -d "$WORK/opencode-pty-${PTY_VERSION}/.git" ]; then
  git clone --depth 1 --branch "v${PTY_VERSION}" https://github.com/anomalyco/opencode-pty.git "$WORK/opencode-pty-${PTY_VERSION}"
fi
for p in opencode-pty-socket-tmpdir.patch opencode-pty-buildrs-android.patch; do
  git -C "$WORK/opencode-pty-${PTY_VERSION}" apply --check "$REPO_ROOT/patches/$p"
  git -C "$WORK/opencode-pty-${PTY_VERSION}" apply "$REPO_ROOT/patches/$p" 2>/dev/null || true
done
# idempotent: already-applied is fine, broken-patch is fatal (checked above)
(
  cd "$WORK/opencode-pty-${PTY_VERSION}"
  cargo build --release --target "$TARGET"
)
BIN="$WORK/opencode-pty-${PTY_VERSION}/target/$TARGET/release/opencode-pty"
test -x "$BIN"
cp -v "$BIN" "$OUT/opencode-pty"
ls -lh "$OUT/opencode-pty"

echo "==> bun-pty v${BUN_PTY_VERSION} (librust_pty cdylib)"
if [ ! -d "$WORK/bun-pty-${BUN_PTY_VERSION}/.git" ]; then
  git clone --depth 1 --branch "v${BUN_PTY_VERSION}" https://github.com/sursaone/bun-pty.git "$WORK/bun-pty-${BUN_PTY_VERSION}"
fi
# portable-pty 0.8 pulls termios/serial (no Android target); 0.9 uses serial2.
# The rust-pty code compiles unchanged (verified on-device).
git -C "$WORK/bun-pty-${BUN_PTY_VERSION}" apply --check "$REPO_ROOT/patches/bun-pty-portable09.patch"
git -C "$WORK/bun-pty-${BUN_PTY_VERSION}" apply "$REPO_ROOT/patches/bun-pty-portable09.patch" 2>/dev/null || true
(
  cd "$WORK/bun-pty-${BUN_PTY_VERSION}/rust-pty"
  cargo build --release --target "$TARGET"
)
CDYLIB="$WORK/bun-pty-${BUN_PTY_VERSION}/rust-pty/target/$TARGET/release/librust_pty.so"
test -f "$CDYLIB"
cp -v "$CDYLIB" "$OUT/librust_pty_arm64.so"
ls -lh "$OUT/librust_pty_arm64.so"

echo "==> verify bionic (no glibc NEEDED)"
if command -v readelf >/dev/null 2>&1; then READELF=readelf; else READELF=llvm-readelf; fi
"$READELF" -d "$OUT/librust_pty_arm64.so" | grep NEEDED
if "$READELF" -d "$OUT/librust_pty_arm64.so" | grep -q "libc.so.6"; then
  echo "glibc-linked cdylib leaked into android build" >&2; exit 1
fi
if command -v llvm-readelf >/dev/null 2>&1; then
  llvm-readelf -h "$OUT/opencode-pty" | grep -q "AArch64" || { echo "daemon binary is not AArch64" >&2; exit 1; }
fi
echo "pty android artifacts OK"
