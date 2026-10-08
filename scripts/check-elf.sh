#!/usr/bin/env bash
# Shared ELF gate for shipped Android artifacts.
#
# Used inline by .github/workflows/build-weekly.yml (so the gates are one
# reviewable file instead of shell snippets in YAML) and re-runnable from the
# tests (tests/vendor.bats) or by hand:
#
#   scripts/check-elf.sh --no-glibc --arch aarch64 vendor/libopentui-*.so
#
# For every FILE it prints DT_NEEDED (the same lines CI always printed), then
# asserts:
#   --no-glibc            no glibc soname in NEEDED (libc.so.6 / libm.so.6)
#   --no-musl             no musl soname in NEEDED (libc.musl* / ld-musl*)
#   --no-errno-location   no undefined __errno_location (musl errno shim;
#                         the bionic build resolves errno itself)
#   --arch NAME           ELF machine equals NAME (e.g. aarch64)
#
# Tool lookup: readelf/greadelf/llvm-readelf and nm/gnm/llvm-nm (GNU binutils
# is `g*`-prefixed on Termux). Override with READELF=/NM= environment variables.
set -euo pipefail

die() {
    echo "check-elf: $*" >&2
    exit 1
}

usage() {
    sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

NO_GLIBC=0
NO_MUSL=0
NO_ERRNO=0
ARCH=""
FILES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --no-glibc) NO_GLIBC=1; shift ;;
        --no-musl) NO_MUSL=1; shift ;;
        --no-errno-location) NO_ERRNO=1; shift ;;
        --arch) [ $# -ge 2 ] || die "--arch needs a value"; ARCH="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *) FILES+=("$1"); shift ;;
    esac
done

[ ${#FILES[@]} -gt 0 ] || { usage >&2; exit 1; }

READELF_BIN="${READELF:-}"
if [ -z "$READELF_BIN" ]; then
    for c in readelf greadelf llvm-readelf; do
        if command -v "$c" >/dev/null 2>&1; then READELF_BIN="$c"; break; fi
    done
fi
[ -n "$READELF_BIN" ] || die "no readelf found — install binutils (Termux: pkg install binutils) or set READELF="

NM_BIN="${NM:-}"
if [ "$NO_ERRNO" = 1 ] && [ -z "$NM_BIN" ]; then
    for c in nm gnm llvm-nm; do
        if command -v "$c" >/dev/null 2>&1; then NM_BIN="$c"; break; fi
    done
    [ -n "$NM_BIN" ] || die "no nm found — install binutils or set NM= (needed for --no-errno-location)"
fi

for f in "${FILES[@]}"; do
    [ -f "$f" ] || die "no such file: $f"
    "$READELF_BIN" -h "$f" >/dev/null 2>&1 || die "not an ELF file: $f"
    echo "==> $f"

    if [ -n "$ARCH" ]; then
        MACHINE=$("$READELF_BIN" -h "$f" | awk -F: '/Machine/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
        [ "$(printf '%s' "$MACHINE" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$ARCH" | tr '[:upper:]' '[:lower:]')" ] ||
            die "wrong ELF machine in $f: expected $ARCH, got ${MACHINE:-unknown}"
        echo "arch OK: $MACHINE"
    fi

    # `|| true`: a file with no dynamic section (static binary) is not a
    # failure here; the NEEDED gates below simply see an empty list.
    NEED=$("$READELF_BIN" -d "$f" 2>/dev/null | grep NEEDED || true)
    if [ -n "$NEED" ]; then
        echo "$NEED"
    else
        echo "  (no DT_NEEDED)"
    fi

    if [ "$NO_GLIBC" = 1 ] && printf '%s\n' "$NEED" | grep -qE 'libc\.so\.6|libm\.so\.6'; then
        die "glibc library needed by $f — glibc-ism leaked into an android artifact:
$NEED"
    fi

    if [ "$NO_MUSL" = 1 ] && printf '%s\n' "$NEED" | grep -qE 'libc\.musl|ld-musl'; then
        die "musl library needed by $f — musl-linked artifact cannot load on bionic:
$NEED"
    fi

    if [ "$NO_ERRNO" = 1 ] && "$NM_BIN" -D -u "$f" 2>/dev/null | grep -q __errno_location; then
        die "undefined __errno_location in $f — musl errno shim leaked into the bionic build"
    fi
    if [ "$NO_GLIBC" = 1 ] || [ "$NO_MUSL" = 1 ] || [ "$NO_ERRNO" = 1 ] || [ -n "$ARCH" ]; then
        echo "check-elf: all gates passed (${#FILES[@]} file(s))"
    fi
    exit 0
done
exit 0
