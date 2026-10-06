# opencode-android

Pure Android/aarch64 builds of upstream OpenCode, for native Termux.
Installs as `opencode2`; the installer also links `opencode` → `opencode2`,
so v2 becomes the default `opencode` (v1 is replaced, not kept alongside).

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
or run with `REPO=you/opencode-android`. For a private repo, export a token:
`GITHUB_TOKEN=ghp_... bash install.sh` (or `GH_TOKEN`). Needs only base
Termux tools (`curl`, `unzip`, `awk`) — no python/jq.

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
  (watcher `android-arm64` binding, pty `android→musl` slot mapping,
  official android `libfff_c.so`, musl opentui selection,
  loader android→linux-musl mapping, `getBackend` android→inotify).
- Renderer: `libopentui.so` cross-compiled for bionic with Zig 0.16 + NDK
  r28, **vendored per version** under `vendor/` and embedded into the CLI
  (source builds run only when a new opentui version has no vendored lib —
  see `vendor/README.md`). No android asset exists upstream, so the musl
  slot + loader mapping is the only embedding path (by design).
- Renderer: `libopentui.so` cross-compiled for bionic with Zig 0.16 + NDK
  r28, **vendored per version** under `vendor/` and embedded into the CLI
  (source builds run only when a new opentui version has no vendored lib —
  see `vendor/README.md`).
- PTY: `opencode-pty` daemon + `librust_pty` cdylib cross-compiled for
  bionic with cargo + NDK r28 (**vendored per version**, swapped into the
  musl/bun-pty slots pre-build). Daemon carries the `TMPDIR` socket patch
  (`/tmp` is not writable on Android). Wrapper sets `LD_LIBRARY_PATH`
  for `libc++_shared.so`. Node-pty SEA path stays unused (Bun binary only).

Full story: [`docs/REPORT.md`](docs/REPORT.md).
