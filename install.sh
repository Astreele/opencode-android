#!/data/data/com.termux/files/usr/bin/bash
#
# Installer for pure Android/aarch64 OpenCode builds (opencode-android).
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/astreele/opencode-android/master/install.sh)
#
# Options (append after the command):
#   --cmd opencode     install ONLY as `opencode` (run from just that command;
#                      no opencode2 name, no symlink)
#   --cmd opencode2    default: install opencode2 + link opencode -> opencode2
#   --no-link          never touch $PREFIX/bin/opencode
#   --force            replace an existing opencode this installer doesn't manage
#   --no-verify        skip SHA256SUMS verification (emergency only)
#
set -e

REPO="astreele/opencode-android"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

CMD="${OPENCODE_CMD:-opencode2}"
LINK=1
FORCE="${OPENCODE_FORCE:-0}"
VERIFY=1

usage() {
    cat <<'EOF'
opencode-android installer

Usage: install.sh [options]

Options:
  --cmd NAME    Which command to install: 'opencode2' (default) or 'opencode'.
                '--cmd opencode' installs the program so it runs from just
                the `opencode` command — no opencode2 name, no symlink.
  --link        Create/refresh the `opencode` -> `opencode2` symlink
                (default for --cmd opencode2).
  --no-link     Install opencode2 but never touch $PREFIX/bin/opencode
                (use when a v1 `opencode` should keep working).
  --force       Replace an existing $PREFIX/bin/opencode that this installer
                does not manage (e.g. a v1 install). Without this flag such a
                file is left untouched and v2 stays available as `opencode2`.
  --no-verify   Skip SHA256SUMS verification. The installer verifies the
                download digest by default; only use this in an emergency.
  -h, --help    Show this help.

Environment: OPENCODE_CMD (same as --cmd), OPENCODE_FORCE=1 (same as --force).

Examples:
  install.sh                      # opencode2 + opencode symlink (default)
  install.sh --cmd opencode       # just the `opencode` command
  install.sh --no-link            # opencode2 only, leave v1's opencode alone
EOF
}

die() {
    echo "FAILED: $*" >&2
    exit 1
}

# Is $1 a binary/link managed by this project (and not a foreign/v1 install)?
is_ours() {
    if [ -L "$1" ]; then
        case "$(readlink "$1")" in
            *opencode2*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    [ -f "$1" ] || return 1
    grep -q "wrapper for OpenCode 2 CLI" "$1" 2>/dev/null
}

# Who owns a path according to the package manager (best effort, for hints)?
owner_of() {
    if command -v dpkg >/dev/null 2>&1; then
        dpkg -S "$1" 2>/dev/null | head -n 1 || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Qo "$1" 2>/dev/null || true
    fi
}

# ── options ────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --cmd)
            [ $# -ge 2 ] || die "--cmd needs a value (opencode|opencode2)"
            CMD="$2"; shift 2 ;;
        --cmd=*) CMD="${1#--cmd=}"; shift ;;
        --link) LINK=1; shift ;;
        --no-link) LINK=0; shift ;;
        --force) FORCE=1; shift ;;
        --no-verify) VERIFY=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

case "$CMD" in
    opencode|opencode2) ;;
    *) die "--cmd must be 'opencode' or 'opencode2' (got '$CMD')" ;;
esac

echo "[1] Resolving latest release..."

API="https://api.github.com/repos/${REPO}/releases/latest"

TAG=$(curl -fsSL "$API" |
    awk -F'"' '/"tag_name"/ {print $4; exit}')

if [ -z "$TAG" ]; then
    die "could not resolve latest release"
fi

echo "TAG=$TAG"

echo "[2] Installing dependencies..."

pkg update -y
pkg install -y curl unzip grep ripgrep libc++ coreutils

echo "[3] Creating temporary directory..."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"

echo "[4] Getting release information..."

RELEASE_API="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"

RELEASE=$(curl -fsSL "$RELEASE_API")

echo "[5] Finding Android ARM64 binary..."

ZIP=$(printf '%s\n' "$RELEASE" |
    grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*android[^"]*aarch64[^"]*\.zip"' |
    head -n 1 |
    cut -d '"' -f 4)

if [ -z "$ZIP" ]; then
    echo
    die "could not find Android ARM64 ZIP. Available release assets:
$(printf '%s\n' "$RELEASE" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | cut -d '"' -f 4)"
fi

echo "Found: $ZIP"

DOWNLOAD="https://github.com/${REPO}/releases/download/${TAG}/${ZIP}"

echo "[6] Downloading..."

curl -fL --retry 3 -o "$ZIP" "$DOWNLOAD"

echo "[7] Verifying download (SHA256SUMS)..."

if [ "$VERIFY" = 1 ]; then
    command -v sha256sum >/dev/null 2>&1 ||
        die "sha256sum missing (coreutils); refusing to install unverified — fix coreutils or pass --no-verify"
    curl -fL --retry 3 -o SHA256SUMS \
        "https://github.com/${REPO}/releases/download/${TAG}/SHA256SUMS" ||
        die "release $TAG has no SHA256SUMS; pass --no-verify only if you accept an unverified download"
    # 2>/dev/null || true: an unreadable SHA256SUMS must fall through to the
    # explicit "no entry" error below, not die silently under set -e.
    EXPECTED=$(awk -v f="$ZIP" '$2 == f {print $1; exit}' SHA256SUMS 2>/dev/null || true)
    [ -n "$EXPECTED" ] || die "SHA256SUMS contains no entry for $ZIP"
    ACTUAL=$(sha256sum "$ZIP" | awk '{print $1}')
    if [ "$EXPECTED" != "$ACTUAL" ]; then
        die "checksum mismatch for $ZIP
  expected: $EXPECTED
  actual:   $ACTUAL
The download is corrupt or was tampered with; nothing was installed."
    fi
    echo "checksum OK: $ZIP"
else
    echo "skipped (--no-verify)"
fi

echo "[8] Extracting..."

unzip -o "$ZIP"

if [ ! -f opencode2 ]; then
    die "opencode2 not found in archive"
fi

if [ ! -f opencode2.bin ]; then
    die "opencode2.bin not found in archive"
fi

# ── guard: never silently clobber a command we don't own (e.g. v1) ─────
TARGET="$PREFIX/bin/$CMD"
if { [ -e "$TARGET" ] || [ -L "$TARGET" ]; } && ! is_ours "$TARGET"; then
    OWNER=$(owner_of "$TARGET")
    if [ "$FORCE" = 1 ]; then
        echo "WARNING: replacing existing $TARGET (--force)"
        if [ -n "$OWNER" ]; then echo "  it was provided by: $OWNER"; fi
    else
        if [ "$CMD" = "opencode" ]; then
            die "$TARGET already exists and is not managed by this installer.
${OWNER:+  It is provided by: $OWNER}
Options:
  • replace it with this build:          install.sh --cmd opencode --force
  • keep it and install v2 under
    a different command name:            install.sh --cmd opencode2 --no-link
    (v2 then runs as \`opencode2\`)
Nothing was installed."
        else
            die "$TARGET already exists and is not managed by this installer.
${OWNER:+  It is provided by: $OWNER}
Options:
  • install without touching it:         install.sh --no-link
  • replace it with this build:          install.sh --force
  • install v2 under a single command:   install.sh --cmd opencode
Nothing was installed."
        fi
    fi
fi

echo "[9] Stopping existing OpenCode..."

for c in opencode opencode2; do
    if [ -x "$PREFIX/bin/$c" ] && is_ours "$PREFIX/bin/$c"; then
        "$PREFIX/bin/$c" service stop >/dev/null 2>&1 || true
    fi
done
if command -v pkill >/dev/null 2>&1; then
    pkill -f "libexec/opencode" >/dev/null 2>&1 || true
fi

sleep 1

echo "[10] Installing (command: $CMD)..."

mkdir -p "$PREFIX/bin"
mkdir -p "$PREFIX/libexec/$CMD"

# The shipped wrapper is named opencode2; rewrite its internal paths when the
# user asked for a different command name (--cmd opencode).
sed -e "s/opencode2\.bin/${CMD}.bin/g" \
    -e "s|libexec/opencode2|libexec/${CMD}|g" \
    -e "s/opencode2: error/${CMD}: error/g" \
    -e "s/# opencode2 - wrapper/# ${CMD} - wrapper/g" \
    opencode2 > "$PREFIX/bin/$CMD"
chmod 755 "$PREFIX/bin/$CMD"
cp -f opencode2.bin "$PREFIX/libexec/$CMD/$CMD.bin"
chmod 755 "$PREFIX/libexec/$CMD/$CMD.bin"

# Ship the license alongside the binary (present in release zips).
if [ -f LICENSE ]; then
    mkdir -p "$PREFIX/share/doc/$CMD"
    cp -f LICENSE "$PREFIX/share/doc/$CMD/"
fi

echo "[11] Linking 'opencode'..."

LINK_STATE="not requested"
if [ "$CMD" = "opencode" ]; then
    LINK_STATE="runs directly as 'opencode' (no symlink)"
elif [ "$LINK" = 0 ]; then
    LINK_STATE="skipped (--no-link)"
else
    L="$PREFIX/bin/opencode"
    if { [ -e "$L" ] || [ -L "$L" ]; } && ! is_ours "$L"; then
        if [ "$FORCE" = 1 ]; then
            OWNER=$(owner_of "$L")
            echo "WARNING: replacing existing $L (--force)"
            if [ -n "$OWNER" ]; then echo "  it was provided by: $OWNER"; fi
            ln -sf "$TARGET" "$L"
            LINK_STATE="replaced (--force)"
        else
            LINK_STATE="left untouched (existing '$L' is not ours)"
            echo
            echo "  NOTE: $L exists and was left alone (likely a v1 install)."
            echo "  v2 is installed and runs as:  opencode2"
            echo "  To make \`opencode\` run v2 instead:"
            echo "    • remove the old command first (e.g. pkg uninstall <package>),"
            echo "      or re-run with --force to replace it,"
            echo "    • or re-run with --no-link to keep both as-is."
        fi
    else
        ln -sf "$TARGET" "$L"
        LINK_STATE="created ($L -> opencode2)"
    fi
fi

echo "[12] Verifying..."

"$PREFIX/bin/$CMD" --version

echo
echo "================================"
echo " OpenCode installed successfully"
echo "================================"
echo
echo "Installed:"
echo "  $PREFIX/bin/$CMD"
echo "  $PREFIX/libexec/$CMD/$CMD.bin"
if [ "$CMD" = "opencode2" ]; then
    echo "  symlink opencode: $LINK_STATE"
else
    echo "  opencode link: $LINK_STATE"
fi
echo
echo "Uninstall:"
echo "  rm -f  $PREFIX/bin/$CMD"
echo "  rm -rf $PREFIX/libexec/$CMD"
echo "  rm -f  $PREFIX/share/doc/$CMD/LICENSE"
if [ "$CMD" = "opencode2" ]; then
    echo "  rm -f  $PREFIX/bin/opencode   # only if it points to opencode2"
fi
echo
echo "Run:"
echo "  $CMD auth   # connect a provider"
echo "  $CMD        # TUI"
