#!/usr/bin/env bash
# Build or update a minimal signed APT repository from .deb files.
#
#   bash scripts/apt-repo.sh --repo DIR [--dist stable] [--component main]
#       [--key KEYID] [--key-file KEY.GPG] [--keep N] [--no-sign] foo.deb ...
#
# Layout produced under DIR:
#   pool/main/opencode2/*.deb
#   dists/stable/main/binary-aarch64/{Packages,Packages.gz,Packages.xz}
#   dists/stable/{Release,InRelease,Release.gpg}
#
# Only needs dpkg-deb, gzip, xz and coreutils (+ gpg for signing).
# Pool keeps the newest --keep debs per package (default 4); older ones are
# deleted so the published branch stays small.
set -euo pipefail

REPO_DIR=""
DIST="stable"
COMPONENT="main"
KEY=""
KEY_FILE=""
KEEP=4
SIGN=1

usage() {
    cat <<'EOF'
Usage: apt-repo.sh --repo DIR [options] [foo.deb ...]

Options:
  --repo DIR       Repository root to create/update (required).
  --dist NAME      Distribution codename (default: stable).
  --component C    Component name (default: main).
  --key KEYID      GPG key to sign with (default: first secret key in GNUPGHOME).
  --key-file FILE  Public key to copy to the repo root as opencode-android.gpg.
  --keep N         Keep the newest N debs per package in pool/ (default: 4).
  --no-sign        Skip InRelease/Release.gpg (local previews).
  -h, --help       Show this help.
EOF
}

die() {
    echo "FAILED: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO_DIR="${2:?--repo needs a directory}"; shift 2 ;;
        --repo=*) REPO_DIR="${1#--repo=}"; shift ;;
        --dist) DIST="${2:?--dist needs a name}"; shift 2 ;;
        --dist=*) DIST="${1#--dist=}"; shift ;;
        --component) COMPONENT="${2:?--component needs a name}"; shift 2 ;;
        --component=*) COMPONENT="${1#--component=}"; shift ;;
        --key) KEY="${2:?--key needs a key id}"; shift 2 ;;
        --key=*) KEY="${1#--key=}"; shift ;;
        --key-file) KEY_FILE="${2:?--key-file needs a file}"; shift 2 ;;
        --key-file=*) KEY_FILE="${1#--key-file=}"; shift ;;
        --keep) KEEP="${2:?--keep needs a number}"; shift 2 ;;
        --keep=*) KEEP="${1#--keep=}"; shift ;;
        --no-sign) SIGN=0; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
        *) break ;;
    esac
done

[ -n "$REPO_DIR" ] || die "--repo DIR is required"
case "$KEEP" in ''|*[!0-9]*|0) die "--keep must be a positive integer" ;; esac
for cmd in dpkg-deb gzip xz sha256sum md5sum sha1sum stat sort; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required tool: $cmd"
done
if [ "$SIGN" = 1 ]; then
    command -v gpg >/dev/null 2>&1 || die "missing required tool: gpg (or pass --no-sign)"
fi

POOL="$REPO_DIR/pool/$COMPONENT"
BINDIR="$REPO_DIR/dists/$DIST/$COMPONENT/binary-aarch64"
mkdir -p "$POOL" "$BINDIR"

# Pool subdir per package (pool/main/opencode2/*.deb).
pool_subdir() {
    mkdir -p "$POOL/$1"
    printf '%s' "$POOL/$1"
}

# ── 1. stage new debs ────────────────────────────────────────────────
STAGED=0
for deb in "$@"; do
    [ -f "$deb" ] || die "not a file: $deb"
    base="$(basename "$deb")"
    dest="$(pool_subdir "$(dpkg-deb -f "$deb" Package)")/$base"
    if [ -f "$dest" ] && cmp -s "$deb" "$dest"; then
        echo "keep: $base (identical)"
    else
        cp -f "$deb" "$dest"
        echo "stage: $base"
    fi
    STAGED=$((STAGED + 1))
done

# ── 2. prune to the newest $KEEP per package ─────────────────────────
# Group pool debs by (Package, Version); sort -V keeps ordering sane even
# when upstream jumps e.g. 2.0.24 -> 2.0.100.
prune() {
    local rows="$1/prune.rows" pkg ver file last_pkg="" count=0
    : > "$rows"
    for file in "$POOL"/*/*.deb; do
        [ -e "$file" ] || continue
        pkg="$(dpkg-deb -f "$file" Package)"
        ver="$(dpkg-deb -f "$file" Version)"
        printf '%s\t%s\t%s\n' "$pkg" "$ver" "$file" >> "$rows"
    done
    if [ -s "$rows" ]; then
        # Newest first per package; keep the first $KEEP of each group.
        while IFS="$(printf '\t')" read -r pkg ver file; do
            if [ "$pkg" != "$last_pkg" ]; then
                last_pkg="$pkg"
                count=0
            fi
            count=$((count + 1))
            if [ "$count" -gt "$KEEP" ]; then
                echo "prune: $(basename "$file") (older than newest $KEEP)"
                rm -f "$file"
            fi
        done < <(sort -t "$(printf '\t')" -k1,1 -k2,2Vr "$rows")
    fi
    rm -f "$rows"
}
prune "$REPO_DIR"

# ── 3. Packages index (dpkg-deb only — no dpkg-dev needed) ───────────
# One stanza per deb, concatenated in byte-sorted filename order so output
# is deterministic regardless of locale.
mapfile -t SORTED_DEBS < <(for deb in "$POOL"/*/*.deb; do
    [ -e "$deb" ] && printf '%s\n' "$deb"
done | LC_ALL=C sort)
{
    if [ "${#SORTED_DEBS[@]}" -gt 0 ]; then
        for deb in "${SORTED_DEBS[@]}"; do
            # Filename is pool-relative: pool/main/opencode2/foo.deb
            rel="pool/$COMPONENT/$(basename "$(dirname "$deb")")/$(basename "$deb")"
            for field in Package Version Architecture Maintainer Installed-Size \
                    Depends Conflicts Replaces Section Priority Homepage Description; do
                val="$(dpkg-deb -f "$deb" "$field" 2>/dev/null || true)"
                [ -n "$val" ] || continue
                # Multi-line Description comes last in practice; dpkg-deb -f
                # emits continuation lines with a leading space, which the
                # Packages format allows.
                printf '%s: %s\n' "$field" "$val"
            done
            printf 'Filename: %s\n' "$rel"
            printf 'Size: %s\n' "$(stat -c%s "$deb")"
            printf 'MD5sum: %s\n' "$(md5sum < "$deb" | awk '{print $1}')"
            printf 'SHA1: %s\n' "$(sha1sum < "$deb" | awk '{print $1}')"
            printf 'SHA256: %s\n' "$(sha256sum < "$deb" | awk '{print $1}')"
            printf '\n'
        done
    fi
} > "$BINDIR/Packages"
gzip -9 -k -f "$BINDIR/Packages"
xz -9 -k -f "$BINDIR/Packages"

# ── 4. Release file ──────────────────────────────────────────────────
checksums() {
    local algo="$1" cmd="$2" f size sum
    printf '%s:\n' "$algo"
    for f in Packages Packages.gz Packages.xz; do
        size="$(stat -c%s "$BINDIR/$f")"
        sum="$("$cmd" < "$BINDIR/$f" | awk '{print $1}')"
        printf '  %s %16s %s/binary-aarch64/%s\n' \
            "$sum" "$size" "$COMPONENT" "$f"
    done
}
{
    printf 'Origin: opencode-android\n'
    printf 'Label: opencode-android\n'
    printf 'Suite: %s\n' "$DIST"
    printf 'Codename: %s\n' "$DIST"
    printf 'Date: %s\n' "$(date -u +'%a, %d %b %Y %H:%M:%S UTC')"
    printf 'Architectures: aarch64\n'
    printf 'Components: %s\n' "$COMPONENT"
    printf 'Description: OpenCode for Android/Termux\n'
    checksums MD5Sum md5sum
    checksums SHA1 sha1sum
    checksums SHA256 sha256sum
} > "$REPO_DIR/dists/$DIST/Release.tmp"
mv "$REPO_DIR/dists/$DIST/Release.tmp" "$REPO_DIR/dists/$DIST/Release"

# ── 5. sign ──────────────────────────────────────────────────────────
if [ "$SIGN" = 1 ]; then
    # --pinentry-mode loopback: no TTY on CI; the repo key has no passphrase.
    if [ -n "$KEY" ]; then
        gpg --batch --yes --pinentry-mode loopback --local-user "$KEY" \
            --clearsign -o "$REPO_DIR/dists/$DIST/InRelease" \
            "$REPO_DIR/dists/$DIST/Release"
        gpg --batch --yes --pinentry-mode loopback --local-user "$KEY" \
            --armor --detach-sign -o "$REPO_DIR/dists/$DIST/Release.gpg" \
            "$REPO_DIR/dists/$DIST/Release"
    else
        gpg --batch --yes --pinentry-mode loopback \
            --clearsign -o "$REPO_DIR/dists/$DIST/InRelease" \
            "$REPO_DIR/dists/$DIST/Release"
        gpg --batch --yes --pinentry-mode loopback \
            --armor --detach-sign -o "$REPO_DIR/dists/$DIST/Release.gpg" \
            "$REPO_DIR/dists/$DIST/Release"
    fi
    echo "signed: InRelease + Release.gpg"
fi

# ── 6. publish the public key at the repo root ───────────────────────
if [ -n "$KEY_FILE" ]; then
    [ -f "$KEY_FILE" ] || die "key file not found: $KEY_FILE"
    cp -f "$KEY_FILE" "$REPO_DIR/opencode-android.gpg"
    echo "key: opencode-android.gpg"
fi

echo "STAGED=$STAGED pool=$(find "$POOL" -name '*.deb' | wc -l)"
