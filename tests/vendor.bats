# Golden + ELF-gate tests for the vendored Android natives in vendor/.
# The golden checksum pins what CI committed; check-elf.sh is the same gate
# build-weekly.yml runs inline during builds.

load helpers

GOLDEN="$REPO_ROOT/tests/golden/vendor.sha256"

# The three shipped natives (globs deliberately exclude *.sha256 sidecars).
VENDORED=(
    "$REPO_ROOT"/vendor/libopentui-*android-aarch64.so
    "$REPO_ROOT"/vendor/librust_pty-*android-aarch64.so
    "$REPO_ROOT"/vendor/opencode-pty-*android-aarch64
)

require_elf_tools() {
    local c
    for c in readelf greadelf llvm-readelf; do
        command -v "$c" >/dev/null 2>&1 && return 0
    done
    skip "readelf missing — Termux: pkg install binutils; CI: apt install binutils"
}

@test "vendored natives match the golden checksum" {
    [ -f "$GOLDEN" ]
    run bash -c "cd '$REPO_ROOT/vendor' && sha256sum -c '$GOLDEN'"
    if [ "$status" -ne 0 ]; then
        echo "$output"
        echo "If the vendor bump is intentional, refresh the golden:"
        echo "    bash tests/run.sh --update-golden"
        return 1
    fi
}

@test "golden file lists every vendored native (nothing added or dropped)" {
    local actual expected
    actual="$(cd "$REPO_ROOT/vendor" && ls | grep -vE '\.sha256$|^README\.md$' | sort)"
    expected="$(awk 'NF >= 2 {print $2}' "$GOLDEN" | sort)"
    [ -n "$expected" ] || { echo "golden file is empty"; return 1; }
    if [ "$actual" != "$expected" ]; then
        echo "vendor/ and tests/golden/vendor.sha256 disagree:"
        echo "--- vendor/ ---"
        echo "$actual"
        echo "--- golden ---"
        echo "$expected"
        return 1
    fi
}

@test "vendor .sha256 sidecars are self-consistent (what CI re-checks per build)" {
    run bash -c "cd '$REPO_ROOT/vendor' && sha256sum -c ./*.sha256"
    assert_success
    assert_contains "$output" ": OK"
}

@test "vendored natives are bionic aarch64 ELFs — no glibc, no musl, no errno shim" {
    require_elf_tools
    run bash "$REPO_ROOT/scripts/check-elf.sh" \
        --no-glibc --no-musl --no-errno-location --arch aarch64 "${VENDORED[@]}"
    assert_success
    assert_contains "$output" "all gates passed"
}

@test "check-elf rejects a wrong architecture" {
    require_elf_tools
    run bash "$REPO_ROOT/scripts/check-elf.sh" --arch armv7 "${VENDORED[0]}"
    assert_failure
    assert_contains "$output" "wrong ELF machine"
}

@test "check-elf rejects non-ELF input" {
    require_elf_tools
    run bash "$REPO_ROOT/scripts/check-elf.sh" --no-glibc "$REPO_ROOT/vendor/README.md"
    assert_failure
    assert_contains "$output" "not an ELF file"
}
