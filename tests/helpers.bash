# shellcheck disable=SC2154  # $status/$output are bats' `run` outputs
# Shared bats helpers for the opencode-android test suite.
#
# Every test runs inside a throw-away sandbox: install.sh and package.sh are
# exercised for real, but `curl` is replaced by a fixture server, `pkg`/`pkill`/
# `sleep` are no-ops, and $PREFIX points into the sandbox — so a test run never
# touches the network, never touches the real Termux prefix, and never kills a
# running opencode daemon.

# Allows expected-exit-code flags on `run` (e.g. `run -127 cmd`) in all suites.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

# Test-generated executables get the host's sh path baked into their shebang:
# Termux lives at /data/data/.../usr/bin/sh, CI at /bin/sh, and neither can
# execute the other's interpreter line.
HOST_SH="#!$(command -v sh)"

# Default fake release. install.sh greps release assets for
# "<anything>android<anything>aarch64<anything>.zip", so the decoys below must
# contain android but never aarch64.
FIXTURE_TAG="v2.0.99"
FIXTURE_ZIP="opencode2-v2.0.99-android-aarch64.zip"

# ── sandbox ────────────────────────────────────────────────────────────
make_sandbox() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/opencode-android-test.XXXXXX")"
    STUBS="$SANDBOX/stubs"
    FIXTURE_DIR="$SANDBOX/fixtures"
    PREFIX_DIR="$SANDBOX/prefix"
    mkdir -p "$STUBS" "$FIXTURE_DIR" "$PREFIX_DIR" "$SANDBOX/tmp"
    write_curl_stub
    write_pkg_stub      # `pkg update` is a no-op; `pkg install opencode2`
                        # lays the fixture package into the sandbox $PREFIX
    write_noop_stub pkill   # must never kill a real serve daemon
    write_noop_stub sleep   # keep the suite fast
    # Files the pkg stub installs for `pkg install opencode2`.
    mkdir -p "$FIXTURE_DIR/pkgfiles"
    write_test_wrapper "$FIXTURE_DIR/pkgfiles/opencode2"
    write_stub_cli "$FIXTURE_DIR/pkgfiles/opencode2.bin" "9.9.9-test"
    printf 'fake repository key\n' > "$FIXTURE_DIR/opencode-android.gpg"
}

# Run install.sh inside the sandbox. Network, pkg and pkill resolve to stubs
# via PATH; everything else (curl parsing, unzip, sha256sum, symlinks) is real.
# Default method is the package-manager path; use run_install_zip for the
# legacy direct-download path.
run_install() {
    run env PATH="$STUBS:$PATH" \
        FIXTURE_DIR="$FIXTURE_DIR" \
        PREFIX="$PREFIX_DIR" \
        TMPDIR="$SANDBOX/tmp" \
        bash "$REPO_ROOT/install.sh" "$@"
}

run_install_zip() {
    run_install --zip "$@"
}

# ── stubs ──────────────────────────────────────────────────────────────
write_curl_stub() {
    cat > "$STUBS/curl" <<'EOF'
#!/bin/sh
# Test double for curl: serves files from $FIXTURE_DIR, never opens a socket.
# Understands exactly the invocations install.sh makes:
#   curl -fsSL URL                  (stdout)
#   curl -fL --retry 3 -o FILE URL  (download)
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --retry) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
serve() {
    if [ -n "$out" ]; then cat "$1" > "$out"; else cat "$1"; fi
}
case "$url" in
    *releases/latest*)        serve "$FIXTURE_DIR/latest.json" ;;
    *releases/tags/*)         serve "$FIXTURE_DIR/release.json" ;;
    *opencode-android.gpg*)   [ -f "$FIXTURE_DIR/opencode-android.gpg" ] || exit 22
                              serve "$FIXTURE_DIR/opencode-android.gpg" ;;
    *SHA256SUMS*)             [ -f "$FIXTURE_DIR/SHA256SUMS" ] || exit 22
                              serve "$FIXTURE_DIR/SHA256SUMS" ;;
    *releases/download/*)     name="${url##*/}"
                              [ -f "$FIXTURE_DIR/$name" ] || exit 22
                              serve "$FIXTURE_DIR/$name" ;;
    *) echo "curl-stub: unexpected URL: $url" >&2; exit 22 ;;
esac
EOF
    chmod 755 "$STUBS/curl"
}

# Test double for pkg: dependency installs and `pkg update` are no-ops, but
# `pkg install ... opencode2` lays the fixture package files into $PREFIX —
# mirroring what the real deb owns (wrapper, .bin, command link, license).
write_pkg_stub() {
    cat > "$STUBS/pkg" <<'EOF'
#!/bin/sh
if [ "${1:-}" != install ]; then exit 0; fi
shift
for a in "$@"; do
    case "$a" in opencode2) do_install=1 ;; esac
done
if [ "${do_install:-0}" = 1 ]; then
    mkdir -p "$PREFIX/bin" "$PREFIX/libexec/opencode2" "$PREFIX/share/doc/opencode2"
    cp "$FIXTURE_DIR/pkgfiles/opencode2" "$PREFIX/bin/opencode2"
    cp "$FIXTURE_DIR/pkgfiles/opencode2.bin" "$PREFIX/libexec/opencode2/opencode2.bin"
    chmod 755 "$PREFIX/bin/opencode2" "$PREFIX/libexec/opencode2/opencode2.bin"
    ln -sf opencode2 "$PREFIX/bin/opencode"
    printf 'MIT test license\n' > "$PREFIX/share/doc/opencode2/LICENSE"
fi
exit 0
EOF
    chmod 755 "$STUBS/pkg"
}

write_noop_stub() {
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/$1"
    chmod 755 "$STUBS/$1"
}

# ── fixtures ───────────────────────────────────────────────────────────
# release JSON with the aarch64 asset (pass "" to omit it) + matching latest.json.
make_release_fixture() {
    local zip="${1-$FIXTURE_ZIP}"
    printf '{ "tag_name": "%s" }\n' "$FIXTURE_TAG" > "$FIXTURE_DIR/latest.json"
    {
        printf '{\n "tag_name": "%s",\n "assets": [\n' "$FIXTURE_TAG"
        printf '  { "name": "opencode2-2.0.99-android-armv7.zip" },\n'
        printf '  { "name": "opencode2-2.0.99-armv7.zip" },\n'
        printf '  { "name": "SHA256SUMS" }'
        if [ -n "$zip" ]; then printf ',\n  { "name": "%s" }' "$zip"; fi
        printf '\n ]\n}\n'
    } > "$FIXTURE_DIR/release.json"
}

# A runnable fake release zip: wrapper + stub CLI + license.
# Second arg "no-bin" omits opencode2.bin (for the corrupt-archive test).
make_fake_zip() {
    local zip_path="$1" with_bin="${2:-yes}"
    local src="$SANDBOX/zip-src"
    rm -rf "$src"
    mkdir -p "$src"
    write_test_wrapper "$src/opencode2"
    write_stub_cli "$src/opencode2.bin" "9.9.9-test"
    printf 'MIT test license\n' > "$src/LICENSE"
    local files=(opencode2 LICENSE)
    [ "$with_bin" = yes ] && files+=(opencode2.bin)
    (cd "$src" && zip -q -9 "$zip_path" "${files[@]}")
}

# The good path: valid zip asset + SHA256SUMS that matches it.
make_good_release() {
    make_release_fixture
    make_fake_zip "$FIXTURE_DIR/$FIXTURE_ZIP"
    (cd "$FIXTURE_DIR" && sha256sum "$FIXTURE_ZIP" > SHA256SUMS)
}

# install.sh rewrites this wrapper with sed when --cmd differs from opencode2,
# and is_ours() greps for the "wrapper for OpenCode 2 CLI" marker — so the
# stand-in must carry the same tokens as the real wrapper in package.sh.
write_test_wrapper() {
    cat > "$1" <<EOF
$HOST_SH
# opencode2 - wrapper for OpenCode 2 CLI on Android/Termux (test stand-in;
# mirrors the wrapper scripts/package.sh generates)
set -eu
SELF="\$(readlink -f "\$0" 2>/dev/null || echo "\$0")"
DIR="\$(CDPATH= cd -- "\$(dirname "\$SELF")" && pwd)"
export PREFIX="\${PREFIX:-/data/data/com.termux/files/usr}"
for candidate in \\
    "\$DIR/../libexec/opencode2/opencode2.bin" \\
    "\$PREFIX/libexec/opencode2/opencode2.bin" \\
    "\$DIR/opencode2.bin"
do
    if [ -x "\$candidate" ]; then
        exec "\$candidate" "\$@"
    fi
done
echo "opencode2: error: could not find opencode2.bin" >&2
exit 127
EOF
    chmod 755 "$1"
}

# Stand-in for the CI-built CLI (the input scripts/package.sh expects).
write_stub_cli() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<EOF
$HOST_SH
# test stand-in for the built opencode CLI
case "\${1:-}" in
    --version) echo "opencode ${2:-9.9.9-test}" ;;
    *) exit 0 ;;
esac
EOF
    chmod 755 "$1"
}

# A file at $PREFIX/bin/opencode that this installer does NOT manage (v1).
make_foreign_opencode() {
    mkdir -p "$PREFIX_DIR/bin"
    printf '#!/bin/sh\necho "v1 opencode"\n' > "$PREFIX_DIR/bin/opencode"
    chmod 755 "$PREFIX_DIR/bin/opencode"
}

# ── package.sh driver ──────────────────────────────────────────────────
# Build the real artifacts once per bats file. $1 = scratch dir (use
# $BATS_FILE_TMPDIR); the output lands in "$1/out".
build_artifacts() {
    local base="$1"
    write_stub_cli "$base/ws/dist/cli/cli-linux-arm64-android/bin/opencode" "9.9.9-test"
    if ! env WORK="$base/work" OUT="$base/out" WORKSPACE="$base/ws" \
            UPSTREAM_TAG=v9.9.9 bash "$REPO_ROOT/scripts/package.sh" \
            > "$base/package.log" 2>&1; then
        echo "package.sh failed:" >&2
        cat "$base/package.log" >&2
        return 1
    fi
}

# ── assertions ─────────────────────────────────────────────────────────
assert_success() {
    [ "$status" -eq 0 ] || {
        echo "expected exit 0, got $status"
        echo "── output ──"
        echo "$output"
        return 1
    }
}

assert_failure() {
    [ "$status" -ne 0 ] || {
        echo "expected non-zero exit, but the command succeeded"
        echo "── output ──"
        echo "$output"
        return 1
    }
    return 0
}

assert_status() {
    [ "$status" -eq "$1" ] || {
        echo "expected exit $1, got $status"
        echo "── output ──"
        echo "$output"
        return 1
    }
    return 0
}

assert_contains() {
    case "$1" in
        *"$2"*) return 0 ;;
        *)
            echo "expected output to contain: $2"
            echo "── output ──"
            echo "$1"
            return 1
            ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*)
            echo "expected output NOT to contain: $2"
            echo "── output ──"
            echo "$1"
            return 1
            ;;
        *) return 0 ;;
    esac
}

assert_file_exists() {
    [ -e "$1" ] || { echo "missing file: $1"; return 1; }
}

assert_file_absent() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        echo "file should not exist: $1"
        return 1
    fi
    return 0
}

assert_executable() {
    [ -x "$1" ] || { echo "not executable: $1"; return 1; }
}
