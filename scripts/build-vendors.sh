#!/usr/bin/env bash
# Ensure the Android natives: use the vendor/ cache when present, otherwise
# build from source with scripts/build-*-ci.sh, then stage results into out/.
#
# This is the vendor build separated from the main build: the release workflow
# invokes it for cache misses (see build-weekly.yml), and
# .github/workflows/build-vendors.yml exposes it via manual workflow_dispatch
# (pick vendors, force rebuilds). `make vendors` runs the local path.
#
# Usage: build-vendors.sh [--plan] [--force] [--commit]
#                         [--vendors SEL] [--out DIR] [--work DIR]
#   --plan      print need_libopentui=/need_pty= lines (for CI) and exit;
#               takes --vendors/--force into account, builds nothing
#   --force     rebuild even when the vendor files exist (also: FORCE=1)
#   --commit    git add/commit/push rebuilt vendor files (CI; default: off)
#   --vendors   all (default), libopentui, pty, or comma combos (also: VENDORS=)
# Env: REPO_ROOT, OUT, WORK, OPENTUI_VERSION (0.5.14), PTY_VERSION (0.2.0),
#      BUN_PTY_VERSION (0.4.9), NDK_DIR (/opt/android-ndk), ANDROID_API (29).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT="${OUT:-$REPO_ROOT/out}"
WORK="${WORK:-$REPO_ROOT/work}"
OPENTUI_VERSION="${OPENTUI_VERSION:-0.5.14}"
PTY_VERSION="${PTY_VERSION:-0.2.0}"
BUN_PTY_VERSION="${BUN_PTY_VERSION:-0.4.9}"
NDK_DIR="${NDK_DIR:-/opt/android-ndk}"
ANDROID_API="${ANDROID_API:-29}"
VENDORS="${VENDORS:-all}"
FORCE="${FORCE:-0}"
export REPO_ROOT OUT WORK OPENTUI_VERSION PTY_VERSION BUN_PTY_VERSION
export NDK_DIR ANDROID_API

PLAN=0
COMMIT=0

usage() {
    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --plan) PLAN=1; shift ;;
        --force) FORCE=1; shift ;;
        --commit) COMMIT=1; shift ;;
        --vendors) [ $# -ge 2 ] || { usage >&2; exit 2; }; VENDORS="$2"; shift 2 ;;
        --vendors=*) VENDORS="${1#--vendors=}"; shift ;;
        --out) [ $# -ge 2 ] || { usage >&2; exit 2; }; OUT="$2"; shift 2 ;;
        --out=*) OUT="${1#--out=}"; shift ;;
        --work) [ $# -ge 2 ] || { usage >&2; exit 2; }; WORK="$2"; shift 2 ;;
        --work=*) WORK="${1#--work=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$FORCE" in
    1|true|yes|TRUE|YES) FORCE=1 ;;
    *) FORCE=0 ;;
esac

WANT_LIB=0
WANT_PTY=0
OLD_IFS="$IFS"
IFS=','
for sel in $VENDORS; do
    case "$sel" in
        all) WANT_LIB=1; WANT_PTY=1 ;;
        libopentui) WANT_LIB=1 ;;
        pty) WANT_PTY=1 ;;
        *) echo "unknown vendor: '$sel' (want all|libopentui|pty, comma-separated)" >&2; exit 2 ;;
    esac
done
IFS="$OLD_IFS"
if [ "$WANT_LIB" = 0 ] && [ "$WANT_PTY" = 0 ]; then
    echo "no vendors selected (VENDORS=$VENDORS)" >&2
    exit 2
fi

# Vendor file names (relative to REPO_ROOT) and their staged out/ names.
LIB_FILE="vendor/libopentui-${OPENTUI_VERSION}-android-aarch64.so"
PTY_BIN="vendor/opencode-pty-${PTY_VERSION}-android-aarch64"
RUSTPTY_SO="vendor/librust_pty-${BUN_PTY_VERSION}-android-aarch64.so"

missing_lib() {
    [ "$FORCE" = 1 ] || [ ! -f "$REPO_ROOT/$LIB_FILE" ]
}

missing_pty() {
    [ "$FORCE" = 1 ] || [ ! -f "$REPO_ROOT/$PTY_BIN" ] || [ ! -f "$REPO_ROOT/$RUSTPTY_SO" ]
}

# --plan: report whether a source build would be needed (CI gates the heavy
# toolchain installs on this). Prints ONLY name=value lines to stdout.
if [ "$PLAN" = 1 ]; then
    NEED_LIB=false
    NEED_PTY=false
    if [ "$WANT_LIB" = 1 ] && missing_lib; then NEED_LIB=true; fi
    if [ "$WANT_PTY" = 1 ] && missing_pty; then NEED_PTY=true; fi
    echo "need_libopentui=$NEED_LIB"
    echo "need_pty=$NEED_PTY"
    exit 0
fi

mkdir -p "$OUT"

# Toolchain pre-checks: fail fast with a clear message instead of cloning
# repos for minutes before the build script discovers a missing tool.
require_lib_toolchain() {
    command -v zig >/dev/null 2>&1 || {
        echo "zig missing (needed to build libopentui ${OPENTUI_VERSION} from source)" >&2
        exit 1
    }
    test -d "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include" || {
        echo "no NDK sysroot at $NDK_DIR (needed to build libopentui ${OPENTUI_VERSION} from source)" >&2
        exit 1
    }
}

require_pty_toolchain() {
    command -v cargo >/dev/null 2>&1 || {
        echo "cargo missing (needed to build pty natives ${PTY_VERSION}/${BUN_PTY_VERSION} from source)" >&2
        exit 1
    }
    test -x "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${ANDROID_API}-clang" || {
        echo "no NDK clang at $NDK_DIR (needed to build pty natives from source)" >&2
        exit 1
    }
}

BUILT_LIB=0
BUILT_PTY=0

ensure_lib() {
    if ! missing_lib; then
        (cd "$REPO_ROOT/vendor" && sha256sum -c "$(basename "$LIB_FILE").sha256")
        cp -v "$REPO_ROOT/$LIB_FILE" "$OUT/libopentui.so"
        echo "libopentui ${OPENTUI_VERSION}: vendored"
        return 0
    fi
    require_lib_toolchain
    echo "libopentui ${OPENTUI_VERSION}: no vendored file, building from source"
    bash "$REPO_ROOT/scripts/build-libopentui-ci.sh"
    bash "$REPO_ROOT/scripts/check-elf.sh" --no-glibc --no-musl --no-errno-location --arch aarch64 "$OUT/libopentui.so"
    cp -v "$OUT/libopentui.so" "$REPO_ROOT/$LIB_FILE"
    (cd "$REPO_ROOT/vendor" && sha256sum "$(basename "$LIB_FILE")" > "$(basename "$LIB_FILE").sha256")
    BUILT_LIB=1
}

ensure_pty() {
    if ! missing_pty; then
        (cd "$REPO_ROOT/vendor" && sha256sum -c "$(basename "$PTY_BIN").sha256" "$(basename "$RUSTPTY_SO").sha256")
        cp -v "$REPO_ROOT/$PTY_BIN" "$OUT/opencode-pty"
        cp -v "$REPO_ROOT/$RUSTPTY_SO" "$OUT/librust_pty_arm64.so"
        echo "pty ${PTY_VERSION} + rust_pty ${BUN_PTY_VERSION}: vendored"
        return 0
    fi
    require_pty_toolchain
    echo "pty ${PTY_VERSION} + rust_pty ${BUN_PTY_VERSION}: no vendored files, building from source"
    bash "$REPO_ROOT/scripts/build-pty-android-ci.sh"
    bash "$REPO_ROOT/scripts/check-elf.sh" --no-glibc --no-musl --no-errno-location --arch aarch64 "$OUT/opencode-pty" "$OUT/librust_pty_arm64.so"
    cp -v "$OUT/opencode-pty" "$REPO_ROOT/$PTY_BIN"
    cp -v "$OUT/librust_pty_arm64.so" "$REPO_ROOT/$RUSTPTY_SO"
    (cd "$REPO_ROOT/vendor" && sha256sum "$(basename "$PTY_BIN")" > "$(basename "$PTY_BIN").sha256")
    (cd "$REPO_ROOT/vendor" && sha256sum "$(basename "$RUSTPTY_SO")" > "$(basename "$RUSTPTY_SO").sha256")
    BUILT_PTY=1
}

if [ "$WANT_LIB" = 1 ]; then ensure_lib; fi
if [ "$WANT_PTY" = 1 ]; then ensure_pty; fi

if [ "$COMMIT" = 1 ] && { [ "$BUILT_LIB" = 1 ] || [ "$BUILT_PTY" = 1 ]; }; then
    git -C "$REPO_ROOT" config user.name "opencode-android-bot"
    git -C "$REPO_ROOT" config user.email "opencode-android-bot@users.noreply.github.com"
    COMMITTED=0
    if [ "$BUILT_LIB" = 1 ]; then
        git -C "$REPO_ROOT" add "$LIB_FILE" "$LIB_FILE.sha256"
        if git -C "$REPO_ROOT" commit -m "vendor libopentui ${OPENTUI_VERSION} android-aarch64 (CI-built)"; then
            COMMITTED=1
        else
            echo "nothing to commit for libopentui ${OPENTUI_VERSION}"
        fi
    fi
    if [ "$BUILT_PTY" = 1 ]; then
        git -C "$REPO_ROOT" add "$PTY_BIN" "$PTY_BIN.sha256" "$RUSTPTY_SO" "$RUSTPTY_SO.sha256"
        if git -C "$REPO_ROOT" commit -m "vendor pty ${PTY_VERSION} + rust_pty ${BUN_PTY_VERSION} android-aarch64 (CI-built)"; then
            COMMITTED=1
        else
            echo "nothing to commit for pty ${PTY_VERSION} + rust_pty ${BUN_PTY_VERSION}"
        fi
    fi
    if [ "$COMMITTED" = 1 ]; then
        git -C "$REPO_ROOT" push
    fi
fi

if [ "$WANT_LIB" = 1 ]; then
    if [ "$BUILT_LIB" = 1 ]; then LIB_MODE=built; else LIB_MODE=vendored; fi
else
    LIB_MODE=skipped
fi
if [ "$WANT_PTY" = 1 ]; then
    if [ "$BUILT_PTY" = 1 ]; then PTY_MODE=built; else PTY_MODE=vendored; fi
else
    PTY_MODE=skipped
fi
echo "libopentui=$LIB_MODE"
echo "pty=$PTY_MODE"
