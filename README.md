# opencode-android

[![latest release](https://img.shields.io/github/v/release/astreele/opencode-android)](https://github.com/astreele/opencode-android/releases)
[![weekly build](https://github.com/astreele/opencode-android/actions/workflows/build-weekly.yml/badge.svg)](https://github.com/astreele/opencode-android/actions/workflows/build-weekly.yml)

Pure Android/aarch64 builds of upstream OpenCode, for native Termux.
Installs as `opencode2`; the installer also links `opencode` → `opencode2`,
so v2 becomes the default `opencode` (v1 is replaced, not kept alongside).
Prefer a single command? Install with `--cmd opencode` and the program runs
from just `opencode` — no `opencode2` name, no symlink.

- True bionic build — no proot, no glibc runners, no patchelf shims.
- Everything embedded: `opencode2` + `opencode2.bin`, no sidecar libraries.
- TUI, recursive file watching, and PTY/shell execution verified on-device.
- Updates through `pkg upgrade`, like any other program.

## Prerequisites

- **Termux** (get it from [F-Droid](https://f-droid.org/packages/com.termux/)
  or [GitHub](https://github.com/termux/termux-app/releases) — the Play
  Store build is outdated), running natively (no proot).
- **Android 10 or newer** (API 29+) on **aarch64** (`uname -m` must print
  `aarch64`; there is no 32-bit build).
- **~500 MB free** while installing (~200 MB once installed: the
  single-binary build plus its `ripgrep`/`libc++` dependencies).
- **Network access** to `astreele.github.io` (package repository),
  `raw.githubusercontent.com` and `github.com` (installer/key fallback),
  plus your provider's API endpoints at runtime.
- No root needed. The installer fetches its own dependencies (`curl`;
  the package pulls in `ripgrep` and `libc++` automatically).

## Installation

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/astreele/opencode-android/master/install.sh)
```

Then:

```sh
opencode auth   # connect a provider
opencode        # TUI
```

The installer registers the signed APT repository
(`https://astreele.github.io/opencode-android`), installs the `opencode2`
package with the system package manager (linking `opencode` → `opencode2`),
and verifies with `opencode2 --version`. Later updates arrive through
`pkg upgrade`, like any other program.

### Installer options

Append options to the command:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/astreele/opencode-android/master/install.sh) --cmd opencode
```

| Option | Effect |
| --- | --- |
| `--cmd opencode` | **Run from just the `opencode` command.** Installs `opencode` + `libexec/opencode/opencode.bin` only — no `opencode2` name, no symlink (uses `--zip`; the deb always ships both names). |
| `--cmd opencode2` | Default: install `opencode2` and link `opencode` → `opencode2`. |
| `--no-link` | Install `opencode2` but never touch an existing `$PREFIX/bin/opencode` (keeps a v1 command working; uses `--zip`). |
| `--force` | Replace an existing `opencode` that this installer does not manage (it names the package owner if one is found). |
| `--apt` | Force the package-manager path (default unless `--cmd opencode` / `--no-link` imply `--zip`). |
| `--zip` | Legacy path: download the release zip, **verify it against `SHA256SUMS`**, and copy the files by hand. |
| `--no-verify` | (zip only) Skip the `SHA256SUMS` check — emergency use only; verification is on by default. |

`OPENCODE_CMD` / `OPENCODE_FORCE=1` are the environment equivalents of
`--cmd` / `--force`.

If `$PREFIX/bin/opencode` already exists from a hand install (not owned by
any package) and is not managed by this installer, the default run **leaves
it alone** and tells you: v2 stays available as `opencode2`, and you choose
explicitly whether to take over the `opencode` command (`--force`, or
`--cmd opencode`). A dpkg-installed v1 is removed cleanly by apt instead
(see Migrating from v1).

### Uninstall

Package install (the default):

```sh
pkg uninstall opencode2   # or: apt remove opencode2
```

This also removes the `opencode` → `opencode2` link (owned by the package).
To drop the repository itself as well:

```sh
rm -f "$PREFIX/etc/apt/sources.list.d/opencode-android.list" \
      "$PREFIX/etc/apt/trusted.gpg.d/opencode-android.gpg"
pkg update
```

Zip install (adjust to the command you chose):

```sh
rm -f  "$PREFIX/bin/opencode2" "$PREFIX/bin/opencode"   # drop the ones you have
rm -rf "$PREFIX/libexec/opencode2" "$PREFIX/libexec/opencode"
rm -f  "$PREFIX/share/doc/opencode2/LICENSE" "$PREFIX/share/doc/opencode/LICENSE"
```

## Install and update via the package manager

The installer registers a signed APT repository and installs `opencode2`
through `pkg`, so updates behave like any other program:

```sh
pkg upgrade            # updates opencode2 together with everything else
```

Manual setup (if you ever need to redo it by hand — the installer does this):

```sh
curl -fsSL https://astreele.github.io/opencode-android/opencode-android.gpg \
  -o "$PREFIX/etc/apt/trusted.gpg.d/opencode-android.gpg"
echo "deb https://astreele.github.io/opencode-android stable main" \
  > "$PREFIX/etc/apt/sources.list.d/opencode-android.list"
pkg update
pkg install opencode2
```

The repository is published from every `*-android` release by
`.github/workflows/apt-repo.yml` (see `apt/README.md`); `InRelease` is
signed with `EA8359E6A86DA8CBCE556301BE6950114D74B7B5`
(`opencode-android <noreply@example.com>`).

Prefer the legacy path? `install.sh --zip` downloads the release zip
directly (SHA256SUMS-verified) and copies the files by hand — same layout,
but `pkg upgrade` will not update it. Every release also still ships a
pacman `.pkg.tar.xz` for direct download:

```sh
# pacman (direct file install, not a repository)
pacman -U ./opencode2-2.0.24-1-aarch64.pkg.tar.xz
pacman -R opencode2     # uninstall (runs the remove hooks, stops the service)
```

The packages carry maintainer scripts the zip path cannot: they stop a
stale background daemon on install/upgrade (otherwise the new TUI times out
waiting for the old service), verify `--version`, and clean up on removal.
They also ship the `opencode` → `opencode2` link, so dpkg/pacman own it —
no out-of-band `ln -sf` over another package's file.

Upgrades: the `.deb` is published to the APT repository above, so
`pkg upgrade` fetches new versions automatically — no need to revisit the
release page. (The pacman archive is still a direct download: re-run
`pacman -U …` per release.) The package manager tracks ownership, so
`pkg uninstall` / `pacman -R` fully uninstall.

## Migrating from v1

- **Package path (default):** `opencode2` declares
  `Conflicts: opencode, opencode1` and `Replaces: opencode, opencode1`, so
  apt removes a dpkg-installed v1 cleanly before installing. A
  hand-installed (non-dpkg) `opencode` is never silently overwritten: the
  installer stops and tells you to pick `--zip --no-link` or `--force`.
- **Zip path (`--zip`):** never silently overwrites an existing, non-managed
  `opencode` command. You get an explicit note plus v2 as `opencode2`, and
  decide: `--force` to take over, `--no-link` to keep both untouched, or
  `--cmd opencode` to install v2 directly under that name.

## Releases

Built every Monday 03:00 UTC from the latest stable upstream `v2.*` tag
(`anomalyco/opencode`), plus manual runs. Each release publishes:
`opencode2-<ver>-android-aarch64.zip`, Termux `.deb`
(`opencode2_<ver>-1_aarch64.deb`), pacman `.pkg.tar.xz`, `SHA256SUMS`
(zip-verified by the `--zip` installer). The `.deb` is additionally
published to the APT repository, so `pkg upgrade` picks it up. A release is
created only when upstream moved.

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
make package UPSTREAM_TAG=v2.0.24   # zip/deb/pacman from a prebuilt CLI (SUFFIX=2 for a packaging-only rebuild)
make apt-repo           # signed APT repo from out/*.deb (SIGN=0 skips gpg)
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
