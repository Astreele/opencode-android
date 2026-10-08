# opencode-android

[![latest release](https://img.shields.io/github/v/release/astreele/opencode-android)](https://github.com/astreele/opencode-android/releases)
[![weekly build](https://github.com/astreele/opencode-android/actions/workflows/build-weekly.yml/badge.svg)](https://github.com/astreele/opencode-android/actions/workflows/build-weekly.yml)

Pure Android/aarch64 builds of upstream OpenCode, for native Termux.
Installs as `opencode2`; the installer also links `opencode` → `opencode2`,
so v2 becomes the default `opencode` (v1 is replaced, not kept alongside).
Prefer a single command? Install with `--cmd opencode` and the program runs
from just `opencode` — no `opencode2` name, no symlink.

- True bionic build — no proot, no glibc runners, no patchelf shims.
- Everything embedded: `opencode2` + `opencode2.bin`, nothing else to install.
- TUI, recursive file watching, and PTY/shell execution verified on-device.

## Installation

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/astreele/opencode-android/master/install.sh)
```

Then:

```sh
opencode auth   # connect a provider
opencode        # TUI
```

Requires Termux on aarch64. The installer fetches the latest
release, **verifies it against `SHA256SUMS`**, installs the wrapper +
binary under `$PREFIX`, links `opencode` → `opencode2`, and verifies with
`opencode2 --version`.

### Installer options

Append options to the command:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/astreele/opencode-android/master/install.sh) --cmd opencode
```

| Option | Effect |
| --- | --- |
| `--cmd opencode` | **Run from just the `opencode` command.** Installs `opencode` + `libexec/opencode/opencode.bin` only — no `opencode2` name, no symlink. |
| `--cmd opencode2` | Default: install `opencode2` and link `opencode` → `opencode2`. |
| `--no-link` | Install `opencode2` but never touch an existing `$PREFIX/bin/opencode` (keeps a v1 command working). |
| `--force` | Replace an existing `opencode` that this installer does not manage (it names the package owner if one is found). |
| `--no-verify` | Skip the `SHA256SUMS` check — emergency use only; verification is on by default. |

`OPENCODE_CMD` / `OPENCODE_FORCE=1` are the environment equivalents of
`--cmd` / `--force`.

If `$PREFIX/bin/opencode` already exists and is not managed by this
installer, the default run **leaves it alone** and tells you: v2 stays
available as `opencode2`, and you choose explicitly whether to take over
the `opencode` command (`--force`, or `--cmd opencode`).

### Uninstall

Zip install (adjust to the command you chose):

```sh
rm -f  "$PREFIX/bin/opencode2" "$PREFIX/bin/opencode"   # drop the ones you have
rm -rf "$PREFIX/libexec/opencode2" "$PREFIX/libexec/opencode"
rm -f  "$PREFIX/share/doc/opencode2/LICENSE" "$PREFIX/share/doc/opencode/LICENSE"
```

Package install:

```sh
apt remove opencode2      # deb (runs prerm/postrm, stops the service)
pacman -R opencode2       # pacman
```

## Install via package manager (deb / pacman)

Every release also ships a Termux `.deb` and a pacman `.pkg.tar.xz`
(`opencode2_<ver>-1_aarch64.deb`, `opencode2-<ver>-1-aarch64.pkg.tar.xz` —
the `-1` is the package revision, bumped for packaging-only fixes):

```sh
# deb
apt install ./opencode2_2.0.24-1_aarch64.deb     # or: dpkg -i <file>
# pacman
pacman -U ./opencode2-2.0.24-1-aarch64.pkg.tar.xz
```

The packages carry maintainer scripts the zip path cannot: they stop a
stale background daemon on install/upgrade (otherwise the new TUI times out
waiting for the old service), verify `--version`, and clean up on removal.
They also ship the `opencode` → `opencode2` link, so dpkg/pacman own it —
no out-of-band `ln -sf` over another package's file.

Upgrades: the packages are published on GitHub Releases, not in a repo
endpoint, so `pkg upgrade opencode2` will not fetch them — download the
newer asset from the release page and re-run the same `apt install ./…` /
`pacman -U …` command. The package manager still tracks ownership, so
`apt remove` / `pacman -R` fully uninstall.

## Migrating from v1

- **Zip installer:** never silently overwrites an existing, non-managed
  `opencode` command. You get an explicit note plus v2 as `opencode2`, and
  decide: `--force` to take over, `--no-link` to keep both untouched, or
  `--cmd opencode` to install v2 directly under that name.
- **Package:** `opencode2` declares `Conflicts: opencode, opencode1` and
  `Replaces: opencode, opencode1`, so apt removes the v1 package cleanly
  before installing (raw `dpkg -i` fails loudly with the same message
  instead of half-overwriting v1).

## Releases

Built every Monday 03:00 UTC from the latest stable upstream `v2.*` tag
(`anomalyco/opencode`), plus manual runs. Each release publishes:
`opencode2-<ver>-android-aarch64.zip`, Termux `.deb`
(`opencode2_<ver>-1_aarch64.deb`), pacman `.pkg.tar.xz`, `SHA256SUMS`
(verified by the installer). A release is created only when upstream moved.

## How it works

- CLI: `bun build --compile` with Bun's official `android` base binary,
  plus small patches (`patches/`) mapping the build onto Android
  (watcher `android-arm64` binding, pty `android→musl` slot mapping,
  musl opentui selection, loader android→linux-musl mapping,
  `getBackend` android→inotify).
- Renderer: `libopentui.so` cross-compiled for bionic with Zig 0.16 + NDK
  r28, **vendored per version** under `vendor/` and embedded into the CLI
  (source builds run only when a new opentui version has no vendored lib —
  see `vendor/README.md`). No android asset exists upstream, so the musl
  slot + loader mapping is the only embedding path (by design).
- PTY: `opencode-pty` daemon + `librust_pty` cdylib cross-compiled for
  bionic with cargo + NDK r28 (**vendored per version**, swapped into the
  musl/bun-pty slots pre-build). Daemon carries the `TMPDIR` socket patch
  (`/tmp` is not writable on Android). Wrapper sets `LD_LIBRARY_PATH`
  for `libc++_shared.so`. Node-pty SEA path stays unused (Bun binary only).

Full story: [`docs/REPORT.md`](docs/REPORT.md).

## Testing

Automated tests (bats) cover the installer, packaging and the shipped
artifacts — no device or network needed:

```sh
bash tests/run.sh                  # syntax checks + all suites
bash tests/run.sh install          # one suite
bash tests/run.sh --update-golden  # refresh vendor golden checksums
```

CI runs them on every push and PR (`.github/workflows/tests.yml`).
See [`tests/README.md`](tests/README.md) for details.

On-device acceptance (`tests/smoke-device.sh`) is separate: the maintainer
runs it on a real Termux device before publishing a release — it probes the
installed build (service lifecycle, PTY spawn, session CRUD, TUI frames,
watcher subscribe + inotify, native-load signature scan) with no provider
auth needed, and prints a report block to paste into the release notes:

```sh
bash tests/smoke-device.sh          # --cmd NAME to probe another command
```

## Building from source

Fast, local stages work anywhere via `make` (`make help` lists targets):

```sh
make test               # bats suite (TEST=install for one suite)
make lint               # shellcheck (+ actionlint if installed)
make check-vendor       # golden checksum + ELF gates for vendor/
make vendors            # verify vendor cache, stage natives into out/
make package UPSTREAM_TAG=v2.0.24   # zip/deb/pacman from a prebuilt CLI
make clean              # remove work/, out/, upstream/, dist/
```

`make package` needs the CI-built CLI at
`dist/cli/cli-linux-arm64-android/bin/opencode`
(override the workspace with `WORKSPACE=...`), plus `zip`, `dpkg-deb` and
`xz` (`pkg install zip dpkg xz-utils` on Termux, `apt install zip
dpkg-dev xz-utils` on Debian/Ubuntu). It fails clearly when the binary or
`UPSTREAM_TAG` is missing.

Vendor rebuilds (`scripts/build-vendors.sh`, also via `make vendors`) reuse
the `vendor/` cache per native version and only build what is missing:

```sh
make vendors VENDORS=pty FORCE=1   # rebuild pty natives (needs cargo + NDK)
```

Rebuilding from source needs Zig 0.16 + NDK r28 (renderer) or cargo +
NDK r28 (PTY); without `--commit` nothing is written back. Committing new
vendor files happens in CI: the release workflow builds missing natives
itself, and `.github/workflows/build-vendors.yml` (manual dispatch: pick
`vendors`, set `force`, optionally resolve versions from `upstream_tag`)
is the manual counterpart.

The full native build (upstream clone → patches → Zig/NDK renderer +
cargo/NDK PTY natives → Bun compile → package → release) runs in CI on
Linux x86_64 — see [`.github/workflows/build-weekly.yml`](.github/workflows/build-weekly.yml).
To reproduce it by hand you need Zig 0.16, Android NDK r28b, Rust with the
`aarch64-linux-android` target, and the Bun version pinned per release;
`vendor/` caches the resulting natives per version so repeat builds skip
the toolchain entirely (see `vendor/README.md`).

## Credits

This project builds on the work of many:

- [**anomalyco/opencode**](https://github.com/anomalyco/opencode) —
  upstream OpenCode v2, and its `bun build --compile` pipeline that made an
  Android base binary possible in the first place.
- [**guysoft/opencode-termux**](https://github.com/guysoft/opencode-termux) —
  prior art for OpenCode on Termux: the `opencode2` wrapper layout this
  installer reuses, the `v2-android.patch` used here (bionic includes,
  pthread/miniaudio/Yoga shims), and the Zig dependency prep notes.
- **dextune** and **Thr45hx** — earlier attempts (v1 with Bun + WebKit
  cross-compiled from source) that mapped out what breaks on Termux.
- [**Bun**](https://bun.sh) — the official `android` base binary that
  removed the need for a source-built runtime.
- [**anomalyco/opentui**](https://github.com/anomalyco/opentui) — the TUI
  renderer; its sources cross-compile cleanly to a bionic `libopentui.so`.
- [**anomalyco/opencode-pty**](https://github.com/anomalyco/opencode-pty)
  and [**sursaone/bun-pty**](https://github.com/sursaone/bun-pty) — the PTY
  daemon and `rust-pty` cdylib cross-compiled for Android.
- [**@parcel/watcher**](https://github.com/parceljs/watcher) — directory
  watching via its official `android-arm64` (inotify) binding.
- [**ripgrep**](https://github.com/BurntSushi/ripgrep) — file finding via
  the ripgrep fallback (the fff native indexer is disabled: it segfaults
  the server on some project trees).
- [**Zig**](https://ziglang.org) and the [**Android NDK**](https://developer.android.com/ndk) —
  cross-compiling the renderer and PTY natives for bionic.
- **The Termux community** — the packages, ports, and hard-won knowledge
  that make native builds like this possible.

## License

MIT — see [`LICENSE`](LICENSE).
