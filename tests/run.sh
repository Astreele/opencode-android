#!/usr/bin/env bash
# Test runner for opencode-android.
#
#   bash tests/run.sh                    # syntax checks + every suite
#   bash tests/run.sh install            # only tests/install.bats
#   bash tests/run.sh tests/vendor.bats  # an explicit path works too
#   bash tests/run.sh --update-golden    # refresh tests/golden/vendor.sha256
#
# Uses `bats` from PATH when present; otherwise a pinned bats-core is cloned
# once into ${XDG_CACHE_HOME:-~/.cache}/opencode-android-tests (git + network
# needed the first time only; set BATS_BIN to override).
#
# The suites stub the network and the package manager, so no device, no
# upstream checkout and no GitHub access is needed. Per-suite dependencies are
# listed in tests/README.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BATS_PIN="${BATS_PIN:-v1.11.1}"
BATS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/opencode-android-tests/bats-core"

update_golden() {
    echo "==> refreshing tests/golden/vendor.sha256"
    mkdir -p "$REPO_ROOT/tests/golden"
    local natives=() f
    for f in "$REPO_ROOT"/vendor/*; do
        case "$f" in *.sha256|*/README.md) continue ;; esac
        natives+=("$(basename "$f")")
    done
    (cd "$REPO_ROOT/vendor" &&
        sha256sum "${natives[@]}" > "$REPO_ROOT/tests/golden/vendor.sha256")
    cat "$REPO_ROOT/tests/golden/vendor.sha256"
}

if [ "${1:-}" = "--update-golden" ]; then
    update_golden
    exit 0
fi

echo "==> syntax check (bash -n)"
for f in "$REPO_ROOT/install.sh" "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/tests/*.sh; do
    bash -n "$f"
    echo "    ok: ${f#"$REPO_ROOT"/}"
done

resolve_bats() {
    if [ -n "${BATS_BIN:-}" ]; then
        echo "$BATS_BIN"
        return 0
    fi
    if command -v bats >/dev/null 2>&1; then
        command -v bats
        return 0
    fi
    if [ ! -x "$BATS_CACHE/bin/bats" ]; then
        echo "==> bats not found; cloning bats-core $BATS_PIN into $BATS_CACHE" >&2
        rm -rf "$BATS_CACHE"
        git clone --quiet --depth 1 --branch "$BATS_PIN" \
            https://github.com/bats-core/bats-core "$BATS_CACHE" >&2
    fi
    echo "$BATS_CACHE/bin/bats"
}

BATS="$(resolve_bats)"
if ! "$BATS" --version >/dev/null 2>&1; then
    echo "FAILED: bats is not runnable at: $BATS" >&2
    exit 1
fi
echo "==> bats: $("$BATS" --version 2>/dev/null || echo "$BATS")"

TARGETS=()
if [ $# -gt 0 ]; then
    for a in "$@"; do
        # suite name first: `vendor` must map to tests/vendor.bats, not the
        # repo's own vendor/ directory
        if [ -e "$REPO_ROOT/tests/$a.bats" ]; then
            TARGETS+=("$REPO_ROOT/tests/$a.bats")
        elif [ -e "$a" ]; then
            TARGETS+=("$a")
        else
            echo "FAILED: no such test: $a (try: install, package, wrapper, vendor)" >&2
            exit 1
        fi
    done
else
    TARGETS+=("$REPO_ROOT/tests")
fi

# Refuse a directory with no suites instead of letting bats exit 0 on 0 tests.
for t in "${TARGETS[@]}"; do
    if [ -d "$t" ] && ! find "$t" -name '*.bats' -print -quit | grep -q .; then
        echo "FAILED: no .bats files under: $t" >&2
        exit 1
    fi
done

exec "$BATS" --print-output-on-failure --recursive "${TARGETS[@]}"
