# Artifact-shape tests for the shipped wrapper (the one scripts/package.sh
# writes into the zip): .bin resolution in every supported layout, failure
# mode, stale service-record cleanup, and the no-sidecar/no-runtime-hack
# contract. The wrapper's shebang is
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
    # hermetic service-record dir: the wrapper preflight scans
    # $XDG_STATE_HOME/opencode, which must never be the real one here
    export XDG_STATE_HOME="$BATS_FILE_TMPDIR/xdg"
    rm -rf "$XDG_STATE_HOME"
    mkdir -p "$XDG_STATE_HOME"
}

teardown() {
    pkill -f opencode-fake-server 2>/dev/null || true
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
    assert_contains "$body" "stale service record"   # dead-daemon cleanup

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

@test "wrapper drops a stale service record and still resolves .bin" {
    mkdir -p "$XDG_STATE_HOME/opencode"
    # pid 999999999 can never be alive; the record must go, the .bin must win
    printf '{"url":"http://127.0.0.1:9","pid":999999999}\n' > "$XDG_STATE_HOME/opencode/service-test.json"
    run env PREFIX="$PREFIX_SANDBOX" sh "$FLAT/opencode2" --version
    assert_success
    assert_contains "$output" "9.9.9-test"
    assert_contains "$output" "stale service record"
    assert_file_absent "$XDG_STATE_HOME/opencode/service-test.json"
}

@test "wrapper keeps a live service record" {
    mkdir -p "$XDG_STATE_HOME/opencode"
    # stand-in server: cmdline contains "opencode" like the real daemon's
    printf 'sleep 120\n' > "$XDG_STATE_HOME/opencode-fake-server"
    sh "$XDG_STATE_HOME/opencode-fake-server" &
    LIVE=$!
    printf '{"url":"http://127.0.0.1:9","pid":%s}\n' "$LIVE" > "$XDG_STATE_HOME/opencode/service-test.json"
    run env PREFIX="$PREFIX_SANDBOX" sh "$FLAT/opencode2" --version
    assert_success
    assert_contains "$output" "9.9.9-test"
    assert_file_exists "$XDG_STATE_HOME/opencode/service-test.json"
    kill "$LIVE" 2>/dev/null || true
}

@test "wrapper ignores a missing state dir" {
    run env PREFIX="$PREFIX_SANDBOX" XDG_STATE_HOME="$BATS_FILE_TMPDIR/no-such-dir" sh "$FLAT/opencode2" --version
    assert_success
    assert_contains "$output" "9.9.9-test"
}

@test "wrapper keeps an unparseable service record" {
    mkdir -p "$XDG_STATE_HOME/opencode"
    printf '{not json}\n' > "$XDG_STATE_HOME/opencode/service-test.json"
    run env PREFIX="$PREFIX_SANDBOX" sh "$FLAT/opencode2" --version
    assert_success
    assert_contains "$output" "9.9.9-test"
    assert_file_exists "$XDG_STATE_HOME/opencode/service-test.json"
}
