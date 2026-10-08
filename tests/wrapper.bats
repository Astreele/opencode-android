# Artifact-shape tests for the shipped wrapper (the one scripts/package.sh
# writes into the zip): .bin resolution in every supported layout, failure
# mode, and the no-sidecar/no-runtime-hack contract. The wrapper's shebang is
# Termux-only by design, so tests invoke it as `sh <wrapper>` — everything
# after the shebang (resolution, exec) is what runs on-device.

load helpers

have_package_deps() {
    command -v zip >/dev/null 2>&1 &&
        command -v dpkg-deb >/dev/null 2>&1 &&
        command -v xz >/dev/null 2>&1 &&
        command -v unzip >/dev/null 2>&1
}

setup_file() {
    have_package_deps || return 0
    build_artifacts "$BATS_FILE_TMPDIR" || exit 1
    touch "$BATS_FILE_TMPDIR/built"
}

setup() {
    have_package_deps || skip "package test deps missing — Termux: pkg install zip xz-utils; CI: apt install zip xz-utils"
    [ -f "$BATS_FILE_TMPDIR/built" ] || {
        echo "artifacts were not built (package.sh failed in setup_file)"
        return 1
    }
    # fresh extraction of the shipped zip for this test
    FLAT="$BATS_FILE_TMPDIR/flat"
    rm -rf "$FLAT"
    mkdir -p "$FLAT"
    unzip -q "$BATS_FILE_TMPDIR/out/opencode2-9.9.9-android-aarch64.zip" -d "$FLAT"
    PREFIX_SANDBOX="$BATS_FILE_TMPDIR/prefix"
    rm -rf "$PREFIX_SANDBOX"
    mkdir -p "$PREFIX_SANDBOX"
}

@test "zip contains only opencode2, opencode2.bin and LICENSE (no sidecar libs)" {
    run unzip -Z1 "$BATS_FILE_TMPDIR/out/opencode2-9.9.9-android-aarch64.zip"
    assert_success
    [ "$(printf '%s\n' "$output" | awk 'NF' | sort | tr '\n' ' ')" = \
        "LICENSE opencode2 opencode2.bin " ]
}

@test "wrapper targets Termux sh and carries no runtime hacks" {
    [ "$(head -n 1 "$FLAT/opencode2")" = "#!/data/data/com.termux/files/usr/bin/sh" ]

    local body
    body="$(cat "$FLAT/opencode2")"
    assert_contains "$body" "wrapper for OpenCode 2 CLI"
    assert_contains "$body" 'LD_LIBRARY_PATH'   # watcher needs $PREFIX/lib
    assert_not_contains "$body" "LD_PRELOAD"
    assert_not_contains "$body" "patchelf"
    assert_not_contains "$body" "OTUI_ASSET_ROOT"
    assert_contains "$body" "OPENCODE_DISABLE_FFF=1"

    run sh -n "$FLAT/opencode2"
    assert_success
}

@test "wrapper resolves a .bin lying next to it (flat zip layout)" {
    # PREFIX pinned to an empty dir so only the flat candidate can win
    run env PREFIX="$PREFIX_SANDBOX" sh "$FLAT/opencode2" --version
    assert_success
    assert_contains "$output" "9.9.9-test"
}

@test "wrapper resolves the installed libexec layout" {
    mkdir -p "$PREFIX_SANDBOX/bin" "$PREFIX_SANDBOX/libexec/opencode2"
    cp "$FLAT/opencode2" "$PREFIX_SANDBOX/bin/opencode2"
    cp "$FLAT/opencode2.bin" "$PREFIX_SANDBOX/libexec/opencode2/opencode2.bin"
    rm "$FLAT/opencode2" "$FLAT/opencode2.bin"   # nothing flat may satisfy it

    run sh "$PREFIX_SANDBOX/bin/opencode2" --version
    assert_success
    assert_contains "$output" "9.9.9-test"
}

@test "wrapper falls back to \$PREFIX/libexec/opencode2" {
    mkdir -p "$BATS_FILE_TMPDIR/lonely"
    cp "$FLAT/opencode2" "$BATS_FILE_TMPDIR/lonely/opencode2"
    mkdir -p "$PREFIX_SANDBOX/libexec/opencode2"
    cp "$FLAT/opencode2.bin" "$PREFIX_SANDBOX/libexec/opencode2/opencode2.bin"

    run env PREFIX="$PREFIX_SANDBOX" sh "$BATS_FILE_TMPDIR/lonely/opencode2" --version
    assert_success
    assert_contains "$output" "9.9.9-test"
}

@test "wrapper exits 127 with a clear error when no .bin exists" {
    mkdir -p "$BATS_FILE_TMPDIR/lonely"
    cp "$FLAT/opencode2" "$BATS_FILE_TMPDIR/lonely/opencode2"
    mkdir -p "$PREFIX_SANDBOX/empty"

    # PREFIX is pinned to an empty dir so a real on-device install can never
    # satisfy the candidate lookup during a test run
    run -127 env PREFIX="$PREFIX_SANDBOX/empty" sh "$BATS_FILE_TMPDIR/lonely/opencode2" --version
    assert_status 127
    assert_contains "$output" "could not find opencode2.bin"
}
