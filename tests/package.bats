# Artifact-shape tests for scripts/package.sh: output names, deb/pacman
# metadata, maintainer scripts, and SHA256SUMS. Builds the real artifacts once
# per file with a stub CLI binary (no upstream checkout, no device).

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
}

OUT="$BATS_FILE_TMPDIR/out"
ZIP="$OUT/opencode2-9.9.9-android-aarch64.zip"
DEB="$OUT/opencode2_9.9.9-1_aarch64.deb"
PKG="$OUT/opencode2-9.9.9-1-aarch64.pkg.tar.xz"

@test "package.sh produces zip, deb, pacman and SHA256SUMS with the expected names" {
    assert_file_exists "$ZIP"
    assert_file_exists "$DEB"
    assert_file_exists "$PKG"
    assert_file_exists "$OUT/SHA256SUMS"
}

@test "deb carries a Debian revision, dependency and v1-conflict metadata" {
    run dpkg-deb -f "$DEB" Package
    assert_success
    assert_contains "$output" "opencode2"

    # packaging-only fixes must be expressible: 9.9.9 -> 9.9.9-2
    run dpkg-deb -f "$DEB" Version
    assert_success
    assert_contains "$output" "9.9.9-1"

    run dpkg-deb -f "$DEB" Architecture
    assert_success
    assert_contains "$output" "aarch64"

    run dpkg-deb -f "$DEB" Depends
    assert_success
    assert_contains "$output" "ripgrep"
    assert_contains "$output" "libc++"

    run dpkg-deb -f "$DEB" Conflicts
    assert_success
    assert_contains "$output" "opencode1"

    run dpkg-deb -f "$DEB" Replaces
    assert_success
    assert_contains "$output" "opencode1"

    run dpkg-deb -f "$DEB" Installed-Size
    assert_success
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "deb ships executable maintainer scripts that stop stale daemons and clean up" {
    local ctl="$BATS_FILE_TMPDIR/ctl"
    rm -rf "$ctl"
    run dpkg-deb -e "$DEB" "$ctl"
    assert_success

    for s in postinst prerm postrm; do
        assert_file_exists "$ctl/$s"
        assert_executable "$ctl/$s"
        run sh -n "$ctl/$s"          # must be valid POSIX sh
        assert_success
    done

    # upgrade/removal stops the running `serve` daemon (the stale-service bug)
    assert_contains "$(cat "$ctl/postinst")" "service stop"
    assert_contains "$(cat "$ctl/prerm")" "service stop"
    # purge removes untracked leftovers
    assert_contains "$(cat "$ctl/postrm")" 'rm -rf "$PREFIX/libexec/opencode2"'
}

@test "VERSION_SUFFIX=2 produces -2 revisions in deb and pacman names" {
    # A packaging-only rebuild of the same upstream tag must yield a higher
    # version, or apt/pacman (rightly) offer no upgrade.
    build_artifacts "$BATS_FILE_TMPDIR/suf2" 2
    local deb="$BATS_FILE_TMPDIR/suf2/out/opencode2_9.9.9-2_aarch64.deb"
    local pkg="$BATS_FILE_TMPDIR/suf2/out/opencode2-9.9.9-2-aarch64.pkg.tar.xz"
    assert_file_exists "$deb"
    assert_file_exists "$pkg"

    run dpkg-deb -f "$deb" Version
    assert_success
    assert_contains "$output" "9.9.9-2"

    run tar -xOf "$pkg" .PKGINFO
    assert_success
    assert_contains "$output" "pkgver = 9.9.9-2"
}

@test "package.sh rejects a non-positive VERSION_SUFFIX" {
    run env UPSTREAM_TAG=v9.9.9 VERSION_SUFFIX=0 bash "$REPO_ROOT/scripts/package.sh"
    assert_failure
    assert_contains "$output" "VERSION_SUFFIX must be a positive integer"
}

@test "pacman archive ships .PKGINFO, the install script and the Termux layout" {
    run tar -tf "$PKG"
    assert_success
    assert_contains "$output" ".PKGINFO"
    assert_contains "$output" "opencode2.install"
    assert_contains "$output" "data/data/com.termux/files/usr/bin/opencode2"
    assert_contains "$output" "data/data/com.termux/files/usr/libexec/opencode2/opencode2.bin"
    assert_contains "$output" "data/data/com.termux/files/usr/share/doc/opencode2/LICENSE"

    # the package owns the opencode -> opencode2 link (relative, resolves in $PREFIX/bin)
    run tar -tvf "$PKG"
    assert_success
    assert_contains "$output" "bin/opencode -> opencode2"
}

@test "pacman .PKGINFO declares the revision and the install script" {
    run tar -xOf "$PKG" .PKGINFO
    assert_success
    assert_contains "$output" "pkgname = opencode2"
    assert_contains "$output" "pkgver = 9.9.9-1"
    assert_contains "$output" "install = opencode2.install"
    assert_contains "$output" "depend = ripgrep"
}

@test "pacman install script is valid sh with install/upgrade/remove hooks" {
    local script="$BATS_FILE_TMPDIR/opencode2.install"
    tar -xOf "$PKG" opencode2.install > "$script"
    [ -s "$script" ]

    run sh -n "$script"
    assert_success

    local body
    body="$(cat "$script")"
    assert_contains "$body" "post_install()"
    assert_contains "$body" "pre_upgrade()"
    assert_contains "$body" "post_upgrade()"
    assert_contains "$body" "pre_remove()"
    assert_contains "$body" "post_remove()"
    assert_contains "$body" "service stop"
    assert_contains "$body" 'rm -rf "$PREFIX/libexec/opencode2"'
}

@test "SHA256SUMS lists exactly the three artifacts and verifies" {
    run awk 'NF >= 2 {print $2}' "$OUT/SHA256SUMS"
    assert_success
    assert_contains "$output" "opencode2-9.9.9-android-aarch64.zip"
    assert_contains "$output" "opencode2_9.9.9-1_aarch64.deb"
    assert_contains "$output" "opencode2-9.9.9-1-aarch64.pkg.tar.xz"
    [ "$(awk 'NF {n++} END {print n+0}' "$OUT/SHA256SUMS")" -eq 3 ]

    run bash -c "cd '$OUT' && sha256sum -c SHA256SUMS"
    assert_success
    assert_contains "$output" "opencode2-9.9.9-android-aarch64.zip: OK"
}
