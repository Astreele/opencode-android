# opencode-android

[![latest release](https://img.shields.io/github/v/release/astreele/opencode-android)](https://github.com/astreele/opencode-android/releases)
[![weekly build](https://github.com/astreele/opencode-android/actions/workflows/build-weekly.yml/badge.svg)](https://github.com/astreele/opencode-android/actions/workflows/build-weekly.yml)

Pure Android/aarch64 builds of upstream OpenCode, for native Termux.
Installs as `opencode2`; the installer also links `opencode` → `opencode2`,
so v2 becomes the default `opencode` (v1 is replaced, not kept alongside).

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
release, installs `opencode2` + `opencode2.bin` under `$PREFIX`, links
`opencode` → `opencode2`, and verifies with `opencode2 --version`.

To uninstall:

```sh
rm -f "$PREFIX/bin/opencode" "$PREFIX/bin/opencode2"
rm -rf "$PREFIX/libexec/opencode2"
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
- PTY: `opencode-pty` daemon + `librust_pty` cdylib cross-compiled for
  bionic with cargo + NDK r28 (**vendored per version**, swapped into the
  musl/bun-pty slots pre-build). Daemon carries the `TMPDIR` socket patch
  (`/tmp` is not writable on Android). Wrapper sets `LD_LIBRARY_PATH`
  for `libc++_shared.so`. Node-pty SEA path stays unused (Bun binary only).

Full story: [`docs/REPORT.md`](docs/REPORT.md).

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
- **@ff-labs** — the official bionic `libfff_c.so`
  (`@ff-labs/fff-bin-android-arm64`) behind the file finder.
- [**Zig**](https://ziglang.org) and the [**Android NDK**](https://developer.android.com/ndk) —
  cross-compiling the renderer and PTY natives for bionic.
- **The Termux community** — the packages, ports, and hard-won knowledge
  that make native builds like this possible.

## License

MIT — see [`LICENSE`](LICENSE).
