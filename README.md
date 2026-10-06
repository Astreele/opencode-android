# opencode-android

Pure Android/aarch64 builds of upstream OpenCode, for native Termux.
Installs side-by-side as `opencode2` (v1 `opencode` untouched).

## Which script runs where

- **CI runner** (Linux x86_64, weekly workflow): everything under
  `.github/` and `scripts/` — each file says `RUNS ON` in its header.
  Termux paths there are install *targets*, never the build host.
- **Device** (native Termux, never proot): `install.sh` only.

## Install (native Termux, NOT inside proot)

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/OWNER/opencode-android/main/install.sh)
```

First set `OWNER` to your repo path in `install.sh` (the `REPO` default),
or run with `REPO=you/opencode-android`.

Then:

```sh
opencode2 auth   # connect a provider
opencode2        # TUI
```

## Releases

Built every Monday 03:00 UTC from the latest stable upstream `v2.*` tag
(`anomalyco/opencode`), plus manual runs. Each release publishes:
`opencode2-<ver>-android-aarch64.zip`, Termux `.deb`, pacman `.pkg.tar.xz`,
`SHA256SUMS`. A release is created only when upstream moved.

## How it works

- CLI: `bun build --compile` with Bun's official `android` base binary,
  plus small patches (`patches/`) mapping the build onto Android
  (watcher `android-arm64` binding, pty skip, musl `fff`/opentui selection,
  loader android→linux-musl mapping, `getBackend` android→inotify).
- Renderer: `libopentui.so` cross-compiled for bionic with Zig 0.16 + NDK
  r28, **vendored per version** under `vendor/` and embedded into the CLI
  (source builds run only when a new opentui version has no vendored lib —
  see `vendor/README.md`).
- File watcher enabled via official `@parcel/watcher-android-arm64`
  (inotify); wrapper sets `LD_LIBRARY_PATH` for `libc++_shared.so`.
  Only pty stays disabled (upstream ships no Android build).

Full story: [`docs/REPORT.md`](docs/REPORT.md).
