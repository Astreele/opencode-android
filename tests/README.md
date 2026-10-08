# Tests

Automated tests for the installer, packaging and shipped artifacts. Everything
runs locally or in CI (`.github/workflows/tests.yml`) with **no device, no
upstream checkout and no network access**: `curl`, `pkg`, `pkill` and `sleep`
are stubbed inside a throw-away sandbox (`tests/helpers.bash`), so a test run
never touches the real `$PREFIX` and never kills a running `serve` daemon.

## Run

```sh
bash tests/run.sh                  # syntax checks + all suites
bash tests/run.sh install          # one suite (install, package, wrapper, vendor)
bash tests/run.sh --update-golden  # refresh tests/golden/vendor.sha256
```

The runner uses `bats` from `PATH`; if it is missing it clones a pinned
bats-core into `${XDG_CACHE_HOME:-~/.cache}/opencode-android-tests` once.
CI installs it with `apt-get install bats`.

## Suites

| Suite | Covers | Needs |
|---|---|---|
| `install.bats` | `install.sh`: release/asset parsing, checksum verification (fail + `--no-verify`), v1-clobber guard, `--cmd` rewriting, full install into a sandbox `$PREFIX` | bash, curl-unrelated stubs (built in) |
| `package.bats` | `scripts/package.sh`: artifact names, deb fields (Debian revision, `Conflicts`/`Replaces`), maintainer scripts, pacman `.PKGINFO`/install hooks, `SHA256SUMS` | `zip`, `dpkg-deb`, `xz`, `unzip` |
| `wrapper.bats` | The shipped wrapper: `.bin` resolution in flat/installed/`$PREFIX` layouts, exit-127 failure mode, no sidecar `.so`, no `LD_PRELOAD`/`patchelf` | same as `package.bats` |
| `vendor.bats` | Vendored natives: golden checksum, sidecar consistency, `scripts/check-elf.sh` gates (bionic aarch64, no glibc/musl/errno shim) + negative gate tests | `readelf`/`nm` (`binutils`) |
| `build-vendors.bats` | `scripts/build-vendors.sh`: `--plan` output, cache-hit staging into `out/`, `--vendors` selection, usage errors, missing-toolchain failure | none (vendor cache only) |

Missing optional dependencies cause those tests to be **skipped** with an
install hint (Termux: `pkg install zip xz-utils binutils`; CI installs
everything explicitly).

## Golden checksums

`tests/golden/vendor.sha256` pins the exact bytes of `vendor/*-android-aarch64*`
that CI committed. Any change to a vendored native fails `vendor.bats` until
the change is acknowledged:

```sh
bash tests/run.sh --update-golden
```
