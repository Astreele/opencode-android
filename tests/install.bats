# Tests for install.sh: the default package-manager path (apt repository
# registration, fake `pkg install opencode2`, v1-clobber guard) and the legacy
# --zip path (release/asset parsing, checksum verification, --cmd rewriting,
# full install into a sandbox $PREFIX).
# Network (`curl`), `pkg`, `pkill` and `sleep` are stubbed — see helpers.bash.

load helpers

setup() {
    make_sandbox
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "--zip installs the android aarch64 asset, verifies its checksum and links opencode" {
    make_good_release

    run_install_zip
    assert_success

    # release + asset resolution (decoy armv7 assets must be skipped)
    assert_contains "$output" "TAG=$FIXTURE_TAG"
    assert_contains "$output" "Found: $FIXTURE_ZIP"
    assert_contains "$output" "checksum OK: $FIXTURE_ZIP"

    # files landed under the sandbox prefix
    assert_executable "$PREFIX_DIR/bin/opencode2"
    assert_file_exists "$PREFIX_DIR/libexec/opencode2/opencode2.bin"
    assert_file_exists "$PREFIX_DIR/share/doc/opencode2/LICENSE"

    # the package-owned command link
    [ -L "$PREFIX_DIR/bin/opencode" ]
    case "$(readlink "$PREFIX_DIR/bin/opencode")" in
        *opencode2*) : ;;
        *) echo "opencode link does not point at opencode2"; return 1 ;;
    esac

    # step [12] ran the installed wrapper, which exec'd the stub .bin
    assert_contains "$output" "9.9.9-test"
    assert_contains "$output" "OpenCode installed successfully"
}

@test "fails when the release has no android aarch64 zip and lists what it found" {
    make_release_fixture ""   # no aarch64 asset

    run_install_zip
    assert_failure
    assert_contains "$output" "could not find Android ARM64 ZIP"
    assert_contains "$output" "opencode2-2.0.99-android-armv7.zip"
    assert_file_absent "$PREFIX_DIR/bin/opencode2"
}

@test "fails when the latest release cannot be resolved" {
    printf '{ }\n' > "$FIXTURE_DIR/latest.json"

    run_install_zip
    assert_failure
    assert_contains "$output" "could not resolve latest release"
}

@test "rejects a checksum mismatch and installs nothing" {
    make_good_release
    # valid-looking but wrong digest (64 zeros)
    printf '%064d  %s\n' 0 "$FIXTURE_ZIP" > "$FIXTURE_DIR/SHA256SUMS"

    run_install_zip
    assert_failure
    assert_contains "$output" "checksum mismatch for $FIXTURE_ZIP"
    assert_contains "$output" "nothing was installed"
    assert_file_absent "$PREFIX_DIR/bin/opencode2"
    assert_file_absent "$PREFIX_DIR/libexec"
}

@test "fails when the release ships no SHA256SUMS" {
    make_good_release
    rm "$FIXTURE_DIR/SHA256SUMS"

    run_install_zip
    assert_failure
    assert_contains "$output" "has no SHA256SUMS"
    assert_file_absent "$PREFIX_DIR/bin/opencode2"
}

@test "--no-verify installs without a SHA256SUMS" {
    make_good_release
    rm "$FIXTURE_DIR/SHA256SUMS"

    run_install_zip --no-verify
    assert_success
    assert_contains "$output" "skipped (--no-verify)"
    assert_executable "$PREFIX_DIR/bin/opencode2"
}

@test "rejects an invalid --cmd value" {
    run_install --cmd sshd
    assert_failure
    assert_contains "$output" "--cmd must be 'opencode' or 'opencode2'"
}

@test "rejects unknown options" {
    run_install --frobnicate
    assert_failure
    assert_contains "$output" "unknown option: --frobnicate"
}

@test "--help prints usage and exits 0" {
    run_install --help
    assert_success
    assert_contains "$output" "Usage: install.sh [options]"
    assert_contains "$output" "--apt"
    assert_contains "$output" "--zip"
    assert_contains "$output" "--no-verify"
}

@test "fails when the zip has no opencode2.bin" {
    make_release_fixture
    make_fake_zip "$FIXTURE_DIR/$FIXTURE_ZIP" no-bin
    (cd "$FIXTURE_DIR" && sha256sum "$FIXTURE_ZIP" > SHA256SUMS)

    run_install_zip
    assert_failure
    assert_contains "$output" "opencode2.bin not found in archive"
}

@test "--cmd opencode refuses to overwrite a foreign opencode" {
    make_good_release
    make_foreign_opencode

    run_install --cmd opencode
    assert_failure
    assert_contains "$output" "uses the direct-download path"
    assert_contains "$output" "already exists and is not managed by this installer"
    assert_contains "$output" "Nothing was installed"
    # the v1 file is untouched and nothing was laid down beside it
    assert_contains "$(cat "$PREFIX_DIR/bin/opencode")" "v1 opencode"
    assert_file_absent "$PREFIX_DIR/libexec"
}

@test "--cmd opencode --force replaces a foreign opencode" {
    make_good_release
    make_foreign_opencode

    run_install --cmd opencode --force
    assert_success
    assert_contains "$output" "uses the direct-download path"
    assert_contains "$output" "WARNING: replacing existing $PREFIX_DIR/bin/opencode"
    assert_contains "$(cat "$PREFIX_DIR/bin/opencode")" "wrapper for OpenCode 2 CLI"
}

@test "leaves a foreign opencode link alone by default (v1 coexistence)" {
    make_good_release
    make_foreign_opencode

    run_install_zip --zip
    assert_success
    assert_contains "$output" "left untouched (existing '$PREFIX_DIR/bin/opencode' is not ours)"
    assert_contains "$output" "v2 is installed and runs as:  opencode2"
    assert_contains "$(cat "$PREFIX_DIR/bin/opencode")" "v1 opencode"
    assert_executable "$PREFIX_DIR/bin/opencode2"
}

@test "--no-link never touches an existing opencode" {
    make_good_release
    make_foreign_opencode

    run_install --no-link
    assert_success
    assert_contains "$output" "uses the direct-download path"
    assert_contains "$output" "skipped (--no-link)"
    assert_contains "$(cat "$PREFIX_DIR/bin/opencode")" "v1 opencode"
    # --no-link still installs opencode2 itself
    assert_executable "$PREFIX_DIR/bin/opencode2"
}

@test "--cmd opencode installs as opencode with wrapper paths rewritten" {
    make_good_release

    run_install --cmd opencode
    assert_success
    assert_contains "$output" "uses the direct-download path"
    assert_contains "$output" "runs directly as 'opencode' (no symlink)"

    [ -f "$PREFIX_DIR/bin/opencode" ]
    [ ! -L "$PREFIX_DIR/bin/opencode" ]
    assert_executable "$PREFIX_DIR/bin/opencode"
    assert_file_exists "$PREFIX_DIR/libexec/opencode/opencode.bin"

    # every opencode2 token in the wrapper was rewritten for this command name
    run grep opencode2 "$PREFIX_DIR/bin/opencode"
    assert_status 1   # grep: no match
    assert_contains "$(cat "$PREFIX_DIR/bin/opencode")" "# opencode - wrapper"

    # and the rewritten wrapper still resolves its .bin
    run "$PREFIX_DIR/bin/opencode" --version
    assert_success
    assert_contains "$output" "9.9.9-test"
}

# ── package-manager path (default) ───────────────────────────────────

@test "installs opencode2 through the package manager by default" {
    run_install
    assert_success

    # repository registration landed under the sandbox prefix
    assert_contains "$(cat "$PREFIX_DIR/etc/apt/sources.list.d/opencode-android.list")" \
        "deb https://astreele.github.io/opencode-android stable main"
    assert_file_exists "$PREFIX_DIR/etc/apt/trusted.gpg.d/opencode-android.gpg"

    # the pkg stub laid the packaged files down like apt would
    assert_executable "$PREFIX_DIR/bin/opencode2"
    assert_file_exists "$PREFIX_DIR/libexec/opencode2/opencode2.bin"
    assert_file_exists "$PREFIX_DIR/share/doc/opencode2/LICENSE"
    [ -L "$PREFIX_DIR/bin/opencode" ]
    case "$(readlink "$PREFIX_DIR/bin/opencode")" in
        *opencode2*) : ;;
        *) echo "opencode link does not point at opencode2"; return 1 ;;
    esac

    # installed build answers, and updates are a pkg operation now
    assert_contains "$output" "9.9.9-test"
    assert_contains "$output" "OpenCode installed successfully"
    assert_contains "$output" "pkg upgrade"
}

@test "re-running the installer is a no-op update check" {
    run_install
    assert_success
    run_install
    assert_success
    assert_contains "$output" "9.9.9-test"
    assert_executable "$PREFIX_DIR/bin/opencode2"
}

@test "apt path refuses a foreign opencode without --force" {
    make_foreign_opencode

    run_install
    assert_failure
    assert_contains "$output" "already exists and is not managed by this installer"
    assert_contains "$output" "Nothing was installed"
    # the guard runs before anything is registered or downloaded
    assert_contains "$(cat "$PREFIX_DIR/bin/opencode")" "v1 opencode"
    assert_file_absent "$PREFIX_DIR/etc/apt/sources.list.d"
    assert_file_absent "$PREFIX_DIR/bin/opencode2"
}

@test "apt path --force replaces a foreign opencode" {
    make_foreign_opencode

    run_install --force
    assert_success
    assert_contains "$output" "WARNING: replacing existing $PREFIX_DIR/bin/opencode"
    [ -L "$PREFIX_DIR/bin/opencode" ]
    assert_executable "$PREFIX_DIR/bin/opencode2"
}

@test "--apt with --cmd opencode is rejected" {
    run_install --apt --cmd opencode
    assert_failure
    assert_contains "$output" "--cmd opencode needs --zip"
}

@test "--apt with --no-link is rejected" {
    run_install --apt --no-link
    assert_failure
    assert_contains "$output" "--no-link needs --zip"
}

@test "apt path fails when the repository key cannot be fetched" {
    rm "$FIXTURE_DIR/opencode-android.gpg"

    run_install
    assert_failure
    assert_contains "$output" "could not fetch the repository key"
    assert_file_absent "$PREFIX_DIR/bin/opencode2"
}
