# Building pure-Android OpenCode for Termux: full report

Target: latest stable upstream OpenCode v2 running **natively** in Termux
(aarch64 Android, no proot), installed as `opencode2` (the installer links
`opencode` → `opencode2`, so v2 replaces v1 as the default).
Result: `opencode v2.0.24-android-termux.1` with working TUI.

## 1. Why stock OpenCode cannot run on Termux

- Termux is bionic (Android libc), not glibc. Official `linux-arm64` binaries
  die with `SIGSYS`/missing glibc. Prior art (`guysoft/opencode-termux`,
  `dextune`, `Thr45hx`) confirms: v1 needed Bun+WebKit cross-compiled from
  source; glibc-runner/patchelf shims are fragile.
- Turning point: **Bun ≥1.4 ships official `android` targets**
  (`bun-linux-aarch64-android.zip`). OpenCode v2 builds with
  `bun build --compile`, which accepts an android base binary as
  `executablePath` — so the CLI needs no source-built Bun/WebKit anymore.
  Only the renderer (`libopentui.so`, Zig-built) still needs compiling.

## 2. Starting point (verified first)

Installed guysoft's prebuilt `opencode2 v1.0.2` (app `2.0.0-android-termux.1`,
Android linker `/system/bin/linker64`, SHA256-verified) via filesystem copy +
native `dpkg -i` for the `ripgrep` dependency. Proved the shape of a working
install: `$PREFIX/bin/opencode2` wrapper + `$PREFIX/libexec/opencode2/`.

## 3. Patches to upstream v2.0.24 (all in `patches/`)

Upstream repo: `anomalyco/opencode`, tag `v2.0.24`
(`@opentui/core 0.5.14`, `packageManager bun@1.4.2`).

1. `cli-build-android.patch` (`packages/cli/script/build.ts`,
   `packages/cli/script/opencode-pty.ts`):
   - allow `abi "android"`, add `{linux, arm64, android}` target
     (resolves to the `bun-linux-aarch64-android` base asset);
   - parcel-watcher binding: use official `@parcel/watcher-android-arm64`
     (not the `linux-arm64-android` name, which does not exist);
   - `resolveOpencodePty`: android→`musl` slot (CI swaps the android-built
     daemon into `@opencode-ai/pty-linux-arm64-musl`; the musl static binary
     runs on Android, but a rebuild is still needed for the TMPDIR socket fix);
   - `FFF_LIBC`: android→`"musl"` (harmless: the linux branch is dead on
     android at runtime; the real fix is the fff embedded patch below).
   - `FFF_LIBC` and compile-time `process.env.OPENTUI_LIBC`: android→`"musl"`.
     Never `"android"`: the runtime loader **throws** for anything but
     unset/`glibc`/`musl`, so the first build's TUI was dead on arrival
     (`--version` doesn't touch the loader — that's why it looked fine).
2. `v2-android.patch` (guysoft's, applies cleanly to 0.5.14): bionic include
   handling, `pthread`/`m` link fixes, miniaudio/Yoga translate shims.
3. `watcher-android.patch` (`packages/core/src/filesystem/watcher.ts`):
   `getBackend()` had no `android` case; map `android→inotify`
   (`@parcel/watcher-android-arm64` uses inotify).
4. `opencode-pty-socket-tmpdir.patch` (applied to `anomalyco/opencode-pty`,
   not the monorepo): `socket_root()` hardcoded `/tmp`, which is not writable
   on Android (owned `shell`, mode `0711`). Respect absolute `$TMPDIR`
   (Termux sets `$PREFIX/tmp`); socket path still fits `sun_path` (~89 chars).
5. `patch-fff-embedded.py` (rewrite of installed `@ff-labs/fff-bun`, like the
   loader patch): `src/embedded.ts` had no android branch, so the build fell
   back to the musl `libfff_c.so` — whose undefined `__errno_location`/`bcmp`
   fail `dlopen` on bionic (file finder silently dead). Points the android
   branch at the official `@ff-labs/fff-bin-android-arm64` (pure bionic,
   loads clean) by absolute path.
6. Loader mapping (`scripts/patch-opentui-loader.py`, anchor-based so chunk
   filename hashes don't matter): Bun's Android runtime reports
   `process.platform === "android"`, unknown to stock `@opentui/core`
   (`Unsupported OpenTUI Node asset target: android-arm64`). Map android →
   `{linux, arm64, musl}` and widen the linux branch. Verified byte-identical
   output against a hand patch.

## 4. Final architecture (pure bionic, no shims)

```
opencode2 (wrapper, sh)
  env: LD_LIBRARY_PATH=$PREFIX/lib (parcel watcher + rust_pty libc++_shared.so)
  └─ opencode2.bin (bionic, Bun android base)
       ├─ JS/TS app + @parcel/watcher-android-arm64 + android→musl loader mapping
       ├─ EMBEDDED renderer: CI-built true-bionic libopentui.so
       │    (swapped into the npm musl slot pre-build; NEEDED libm/libc/libdl)
       ├─ EMBEDDED pty daemon: CI-built bionic opencode-pty
       │    (swapped into the pty-linux-arm64-musl npm slot; TMPDIR-patched)
       └─ EMBEDDED inline pty: CI-built bionic librust_pty_arm64.so
            (overwrites bun-pty's glibc .so pre-build; dlopen via bun:ffi)
```

No sidecar `.so`, no `LD_PRELOAD`, no `OTUI_ASSET_ROOT`, no patchelf in the
shipped packages: `opencode2` + `opencode2.bin` only. (An earlier revision
used an `OTUI_ASSET_ROOT` override with a musl lib + 4-symbol shim; retired
once the CI bionic lib proved out — see failure log entries 7–9 in
`~/opencode-android-failure-logs.md`.)

Watcher notes (`patches/watcher-android.patch`): upstream
`getBackend()` had no `android` case, so directory watches returned empty
even with the binding present. Map `android→inotify`. Verified on-device:
Node + Bun-android both `subscribe`/`unsubscribe` with `inotify` backend;
Bun needs `LD_LIBRARY_PATH` (official base has no RUNPATH to `$PREFIX/lib`,
unlike Termux-built node). `Depends: libc++` provides `libc++_shared.so`.
File/dir `file`+`entries` watches already used `node:fs` and never needed
parcel; only recursive `directory` watches needed this fix. The old
`OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER` wrapper var was stale (v2 reads
`OPENCODE_FILEWATCHER_DISABLE`/`OPENCODE_DISABLE_FILEWATCHER`) and is now
unset.

PTY notes: neither `@opencode-ai/pty` (0.2.0) nor `bun-pty` (0.4.9) ships
Android prebuilds (npm registry + `greadelf`: node-pty needs `libc.so.6`,
`librust_pty_arm64.so` needs `libc.so.6`). Actual errors, all fixed in-repo:
- Daemon dies at startup: `socket_root()` hardcodes `/tmp` (unwritable on
  Android) → `Permission denied (os error 13)`. The musl-static binary
  itself runs (`--help`/`--version` OK).
  Fix: `patches/opencode-pty-socket-tmpdir.patch` respects absolute `$TMPDIR`.
  Verified by executing the patched function: `TMPDIR` set → writable path
  fitting `sun_path`; unset → the same `EACCES`.
- `build.rs` has no `aarch64-linux-android` zig-target mapping (panics on
  `unsupported Ghostty target`), required for the Android cross-compile.
  Fix: `patches/opencode-pty-buildrs-android.patch`.
- `rust-pty` depends on `portable-pty 0.8`, whose `termios` dep has no Android
  target (hard compile failure). 0.9 (via `serial2`) builds unchanged.
  Fix: `patches/bun-pty-portable09.patch`. Verified: rebuilt `.so` is pure
  bionic and spawns shells with working IO under the Bun android runtime.
Both natives are cargo+NDK cross-compiled in CI and vendored under `vendor/`
like libopentui. Node-pty SEA path stays unused (Bun binary only).

## 5. Maintenance

`.github/workflows/build-weekly.yml` runs Mondays 03:00 UTC (plus manual):
resolve latest `v2.*` → skip if release exists → pin host Bun from upstream
`packageManager` + pty/bun-pty versions from `packages/core/package.json` →
verify Bun android base exists → clone/patch/install → patch loader →
build lib (Zig 0.16 + NDK r28) + build pty (cargo + NDK r28) → verify bionic
(no `__errno_location`, no `libc.so.6`) → package zip/deb/pacman + SHA256SUMS
→ release.
Known future breakage: opentui chunk rewrites (loader patch asserts anchors),
`v2-android.patch` drift (fails loudly), Bun dropping the android base asset
(pre-checked with a clear error).
