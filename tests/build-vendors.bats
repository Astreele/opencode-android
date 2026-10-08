# Tests for scripts/build-vendors.sh: plan output, cache-hit staging,
# vendor selection, usage errors, and the missing-toolchain failure mode.
# No toolchain needed: only the vendor/ cache and the script itself.

load helpers

setup() {
    SCRATCH="$BATS_FILE_TMPDIR/scratch"
    rm -rf "$SCRATCH"
    mkdir -p "$SCRATCH"
}

# Versions matching the files committed under vendor/.
vendored_env() {
    export OPENTUI_VERSION=0.5.16 PTY_VERSION=0.2.0 BUN_PTY_VERSION=0.4.9
}

@test "--plan reports no builds needed when the cache is warm" {
    vendored_env
    run bash "$REPO_ROOT/scripts/build-vendors.sh" --plan
    assert_success
    assert_contains "$output" "need_libopentui=false"
    assert_contains "$output" "need_pty=false"
}

@test "--plan with --force reports every selected vendor as needed" {
    vendored_env
    run bash "$REPO_ROOT/scripts/build-vendors.sh" --plan --force
    assert_success
    assert_contains "$output" "need_libopentui=true"
    assert_contains "$output" "need_pty=true"
}

@test "--plan honours --vendors selection" {
    vendored_env
    run bash "$REPO_ROOT/scripts/build-vendors.sh" --plan --vendors pty
    assert_success
    assert_contains "$output" "need_libopentui=false"
}

@test "cache-hit run stages all three natives into out/ and touches nothing else" {
    vendored_env
    run env OUT="$SCRATCH/out" WORK="$SCRATCH/work" \
        bash "$REPO_ROOT/scripts/build-vendors.sh"
    assert_success
    assert_contains "$output" "libopentui=vendored"
    assert_contains "$output" "pty=vendored"
    assert_file_exists "$SCRATCH/out/libopentui.so"
    assert_file_exists "$SCRATCH/out/opencode-pty"
    assert_file_exists "$SCRATCH/out/librust_pty_arm64.so"
}

@test "--vendors libopentui stages only the renderer" {
    vendored_env
    run env OUT="$SCRATCH/out" WORK="$SCRATCH/work" \
        bash "$REPO_ROOT/scripts/build-vendors.sh" --vendors libopentui
    assert_success
    assert_contains "$output" "libopentui=vendored"
    assert_contains "$output" "pty=skipped"
    assert_file_exists "$SCRATCH/out/libopentui.so"
    assert_file_absent "$SCRATCH/out/opencode-pty"
    assert_file_absent "$SCRATCH/out/librust_pty_arm64.so"
}

@test "unknown vendor names fail with usage" {
    run bash "$REPO_ROOT/scripts/build-vendors.sh" --vendors bogus
    assert_failure
    assert_contains "$output" "unknown vendor"
}

@test "unknown options fail with usage" {
    run bash "$REPO_ROOT/scripts/build-vendors.sh" --frobnicate
    assert_failure
    assert_contains "$output" "unknown option"
}

@test "--help prints usage and exits 0" {
    run bash "$REPO_ROOT/scripts/build-vendors.sh" --help
    assert_success
    assert_contains "$output" "--vendors"
    assert_contains "$output" "--force"
}

@test "--force without a toolchain fails before doing anything" {
    # A bin dir with mkdir only: zig/cargo stay hidden on every host, so the
    # pre-check fails deterministically instead of depending on installed tools.
    local bindir="$SCRATCH/nobin"
    mkdir -p "$bindir"
    ln -sf "$(command -v mkdir)" "$bindir/mkdir"
    vendored_env
    run env PATH="$bindir" "$BASH" "$REPO_ROOT/scripts/build-vendors.sh" \
        --force --vendors libopentui --out "$SCRATCH/out" --work "$SCRATCH/work"
    assert_failure
    assert_contains "$output" "zig missing"
}
