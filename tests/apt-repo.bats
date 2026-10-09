# Tests for scripts/apt-repo.sh: pool staging, --keep pruning, Packages +
# Release generation, and (when gpg is available) detached/clearsigned output.
# Fake .debs are built with dpkg-deb from scratch — no network, no fixtures.

load helpers

have_apt_repo_deps() {
    command -v dpkg-deb >/dev/null 2>&1 &&
        command -v gzip >/dev/null 2>&1 &&
        command -v xz >/dev/null 2>&1
}

setup() {
    have_apt_repo_deps || skip "apt-repo test deps missing — Termux: pkg install dpkg xz-utils; CI installs them"
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/opencode-apt-repo-test.XXXXXX")"
}

teardown() {
    rm -rf "$SCRATCH"
}

# Minimal but well-formed deb with the requested version.
make_fake_deb() {
    local ver="$1" out="$2"
    local root="$SCRATCH/deb-$ver"
    rm -rf "$root"
    mkdir -p "$root/DEBIAN" "$root/data"
    # dpkg-deb rejects control dirs that are not 0755..0775 (umask-077 shells).
    chmod 755 "$root/DEBIAN"
    cat > "$root/DEBIAN/control" <<EOF
Package: opencode2
Version: $ver-1
Architecture: aarch64
Maintainer: opencode-android <noreply@example.com>
Installed-Size: 42
Depends: ripgrep, libc++
Conflicts: opencode, opencode1
Replaces: opencode, opencode1
Section: utils
Priority: optional
Description: test deb $ver
 Test payload.
EOF
    printf '%s\n' "$ver" > "$root/data/f"
    dpkg-deb -b "$root" "$out" >/dev/null
}

run_apt_repo() {
    run env GNUPGHOME="${GNUPGHOME:-$HOME/.gnupg}" \
        bash "$REPO_ROOT/scripts/apt-repo.sh" "$@"
}

@test "--help prints usage and exits 0" {
    run_apt_repo --help
    assert_success
    assert_contains "$output" "Usage: apt-repo.sh --repo DIR"
}

@test "fails without --repo" {
    run_apt_repo --no-sign
    assert_failure
    assert_contains "$output" "--repo DIR is required"
}

@test "stages debs, prunes to --keep, and writes Packages + Release" {
    make_fake_deb 9.9.8 "$SCRATCH/opencode2_9.9.8-1_aarch64.deb"
    make_fake_deb 9.9.9 "$SCRATCH/opencode2_9.9.9-1_aarch64.deb"

    run_apt_repo --repo "$SCRATCH/repo" --no-sign --keep 1 \
        "$SCRATCH/opencode2_9.9.8-1_aarch64.deb" \
        "$SCRATCH/opencode2_9.9.9-1_aarch64.deb"
    assert_success
    assert_contains "$output" "prune: opencode2_9.9.8-1_aarch64.deb"

    local bindir="$SCRATCH/repo/dists/stable/main/binary-aarch64"
    # only the newest deb survived pruning
    assert_file_exists "$SCRATCH/repo/pool/main/opencode2/opencode2_9.9.9-1_aarch64.deb"
    assert_file_absent "$SCRATCH/repo/pool/main/opencode2/opencode2_9.9.8-1_aarch64.deb"

    # one stanza, with pool-relative Filename and matching Size/SHA256
    [ "$(grep -c '^Package: ' "$bindir/Packages")" = 1 ]
    assert_contains "$(cat "$bindir/Packages")" \
        "Filename: pool/main/opencode2/opencode2_9.9.9-1_aarch64.deb"
    local deb="$SCRATCH/repo/pool/main/opencode2/opencode2_9.9.9-1_aarch64.deb"
    assert_contains "$(cat "$bindir/Packages")" "Size: $(stat -c%s "$deb")"
    assert_contains "$(cat "$bindir/Packages")" "SHA256: $(sha256sum < "$deb" | awk '{print $1}')"

    # compressed indexes exist and Release pins their digests
    assert_file_exists "$bindir/Packages.gz"
    assert_file_exists "$bindir/Packages.xz"
    local release
    release="$(cat "$SCRATCH/repo/dists/stable/Release")"
    assert_contains "$release" "SHA256:" # section header (deb822: no leading space)
    for f in Packages Packages.gz Packages.xz; do
        assert_contains "$release" "$(sha256sum < "$bindir/$f" | awk '{print $1}')"
        assert_contains "$release" "main/binary-aarch64/$f"
    done

    # unsigned preview carries no signatures
    assert_file_absent "$SCRATCH/repo/dists/stable/InRelease"
    assert_file_absent "$SCRATCH/repo/dists/stable/Release.gpg"
}

@test "--no-pool indexes staged versions without storing them" {
    make_fake_deb 9.9.8 "$SCRATCH/opencode2_9.9.8-1_aarch64.deb"
    make_fake_deb 9.9.9 "$SCRATCH/opencode2_9.9.9-1_aarch64.deb"
    make_fake_deb 9.9.7 "$SCRATCH/opencode2_9.9.7-1_aarch64.deb"

    run_apt_repo --repo "$SCRATCH/repo" --no-sign --no-pool --keep 2 \
        "$SCRATCH"/opencode2_*.deb
    assert_success

    # nothing stored: the redirector serves pool/ from the release page
    assert_file_absent "$SCRATCH/repo/pool"

    # ...but the index pins the newest two with pool-relative Filenames
    local bindir="$SCRATCH/repo/dists/stable/main/binary-aarch64"
    [ "$(grep -c '^Package: ' "$bindir/Packages")" = 2 ]
    [ "$(grep -c '^Version: ' "$bindir/Packages")" = 2 ]
    assert_contains "$(cat "$bindir/Packages")" \
        "Filename: pool/main/opencode2/opencode2_9.9.9-1_aarch64.deb"
    assert_contains "$(cat "$bindir/Packages")" \
        "Filename: pool/main/opencode2/opencode2_9.9.8-1_aarch64.deb"
    local deb="$SCRATCH/opencode2_9.9.9-1_aarch64.deb"
    assert_contains "$(cat "$bindir/Packages")" "SHA256: $(sha256sum < "$deb" | awk '{print $1}')"
    assert_file_absent "$SCRATCH/repo/dists/stable/InRelease"
}

@test "--no-pool without debs fails fast" {
    run_apt_repo --repo "$SCRATCH/repo" --no-sign --no-pool
    assert_failure
    assert_contains "$output" "--no-pool needs at least one .deb"
}

@test "re-running with identical debs changes nothing" {
    make_fake_deb 9.9.9 "$SCRATCH/opencode2_9.9.9-1_aarch64.deb"
    run_apt_repo --repo "$SCRATCH/repo" --no-sign \
        "$SCRATCH/opencode2_9.9.9-1_aarch64.deb"
    assert_success
    before="$(sha256sum "$SCRATCH/repo/dists/stable/main/binary-aarch64/Packages")"
    run_apt_repo --repo "$SCRATCH/repo" --no-sign \
        "$SCRATCH/opencode2_9.9.9-1_aarch64.deb"
    assert_success
    assert_contains "$output" "identical"
    after="$(sha256sum "$SCRATCH/repo/dists/stable/main/binary-aarch64/Packages")"
    [ "$before" = "$after" ]
}

@test "signs InRelease + Release.gpg with a throwaway key" {
    command -v gpg >/dev/null 2>&1 || skip "gpg not installed"
    export GNUPGHOME="$SCRATCH/gnupg"
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    cat > "$SCRATCH/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: apt-repo test
Name-Email: test@example.com
Expire-Date: 0
%no-protection
%commit
EOF
    gpg --batch --gen-key "$SCRATCH/batch" 2>/dev/null
    gpg --export test@example.com > "$SCRATCH/pubkey.gpg"

    make_fake_deb 9.9.9 "$SCRATCH/opencode2_9.9.9-1_aarch64.deb"
    run_apt_repo --repo "$SCRATCH/repo" --key-file "$SCRATCH/pubkey.gpg" \
        "$SCRATCH/opencode2_9.9.9-1_aarch64.deb"
    assert_success
    assert_contains "$output" "signed: InRelease + Release.gpg"

    local dist="$SCRATCH/repo/dists/stable"
    assert_file_exists "$dist/InRelease"
    assert_file_exists "$dist/Release.gpg"
    assert_file_exists "$SCRATCH/repo/opencode-android.gpg"

    # both signatures verify against the exported public key
    run gpgv --keyring "$SCRATCH/pubkey.gpg" "$dist/InRelease"
    assert_success
    run bash -c "cd '$dist' && gpgv --keyring '$SCRATCH/pubkey.gpg' Release.gpg Release"
    assert_success
}
