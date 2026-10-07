#!/data/data/com.termux/files/usr/bin/bash
set -e

REPO="astreele/opencode-android"
PREFIX="${PREFIX:-$PREFIX}"

echo "[1] Resolving latest release..."

API="https://api.github.com/repos/${REPO}/releases/latest"

TAG=$(curl -fsSL "$API" |
    awk -F'"' '/"tag_name"/ {print $4; exit}')

if [ -z "$TAG" ]; then
    echo "FAILED: could not resolve latest release"
    exit 1
fi

echo "TAG=$TAG"

echo "[2] Installing dependencies..."

pkg update -y
pkg install -y curl unzip grep ripgrep libc++

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
    echo "FAILED: could not find Android ARM64 ZIP."
    echo
    echo "Available release assets:"
    printf '%s\n' "$RELEASE" |
        grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' |
        cut -d '"' -f 4
    echo
    exit 1
fi

echo "Found: $ZIP"

DOWNLOAD="https://github.com/${REPO}/releases/download/${TAG}/${ZIP}"

echo "[6] Downloading..."

curl -fL --retry 3 -o "$ZIP" "$DOWNLOAD"

echo "[7] Extracting..."

unzip -o "$ZIP"

if [ ! -f opencode2 ]; then
    echo "FAILED: opencode2 not found in archive"
    exit 1
fi

if [ ! -f opencode2.bin ]; then
    echo "FAILED: opencode2.bin not found in archive"
    exit 1
fi

echo "[8] Stopping existing OpenCode..."

if [ -x "$PREFIX/bin/opencode2" ]; then
    "$PREFIX/bin/opencode2" service stop 2>/dev/null || true
fi

pkill -f "libexec/opencode2/opencode2.bin" 2>/dev/null || true

sleep 1

echo "[9] Installing..."

mkdir -p "$PREFIX/bin"
mkdir -p "$PREFIX/libexec/opencode2"

cp -f opencode2 "$PREFIX/bin/opencode2"
cp -f opencode2.bin "$PREFIX/libexec/opencode2/opencode2.bin"

chmod 755 "$PREFIX/bin/opencode2"
chmod 755 "$PREFIX/libexec/opencode2/opencode2.bin"

ln -sf "$PREFIX/bin/opencode2" "$PREFIX/bin/opencode"

# Ship the license alongside the binary (present in release zips).
if [ -f LICENSE ]; then
    mkdir -p "$PREFIX/share/doc/opencode2"
    cp -f LICENSE "$PREFIX/share/doc/opencode2/"
fi

echo "[10] Verifying..."

"$PREFIX/bin/opencode2" --version

echo
echo "================================"
echo " OpenCode installed successfully"
echo "================================"
echo
echo "Run:"
echo "  opencode2 auth"
echo
echo "Then:"
echo "  opencode2"
