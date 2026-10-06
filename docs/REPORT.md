# Building pure-Android OpenCode for Termux: full report

Target: latest stable upstream OpenCode v2 running **natively** in Termux
(aarch64 Android, no proot), installed side-by-side as `opencode2`.
Result: `opencode v2.0.24-android-termux.1` with working TUI.

## 1. Environment

- Device: Galaxy S22 (SM-S901E), aarch64, 7.2 GB RAM + 8 GB swap, 60 GB free.
- Termux (F-Droid) + Debian proot-distro. All build work ran **inside proot**
  (fake uid 0 via `proot --change-id=0:0`, real kernel uid 10299); anything
  needing real Android behavior ran in native Termux. `pkg`/`apt` refuse
  fake-root, so Termux packages were installed with Termux's own
  `dpkg -i` on manually downloaded `.deb`s (works: real uid owns `$PREFIX`).

## 2. Why stock OpenCode cannot run on Termux

- Termux is bionic (Android libc), not glibc. Official `linux-arm64` binaries
  die with `SIGSYS`/missing glibc. Prior art (`guysoft/opencode-termux`,
  `dextune`, `Thr45hx`) confirms: v1 needed Bun+WebKit cross-compiled from
  source; glibc-runner/patchelf shims are fragile.
- Turning point: **Bun ≥1.4 ships official `android` targets**
  (`bun-linux-aarch64-android.zip`). OpenCode v2 builds with
  `bun build --compile`, which accepts an android base binary as
  `executablePath` — so the CLI needs no source-built Bun/WebKit anymore.
  Only the renderer (`libopentui.so`, Zig-built) still needs compiling.

## 3. Starting point (verified first)

Installed guysoft's prebuilt `opencode2 v1.0.2` (app `2.0.0-android-termux.1`,
Android linker `/system/bin/linker64`, SHA256-verified) via filesystem copy +
native `dpkg -i` for the `ripgrep` dependency. Proved the shape of a working
install: `$PREFIX/bin/opencode2` wrapper + `$PREFIX/libexec/opencode2/`.

## 4. Patches to upstream v2.0.24 (all in `patches/`)

Upstream repo: `anomalyco/opencode`, tag `v2.0.24`
(`@opentui/core 0.5.14`, `packageManager bun@1.4.2`).

1. `cli-build-android.patch` (`packages/cli/script/build.ts`,
   `packages/cli/script/opencode-pty.ts`):
   - allow `abi "android"`, add `{linux, arm64, android}` target
     (resolves to the `bun-linux-aarch64-android` base asset);
   - parcel-watcher binding: use official `@parcel/watcher-android-arm64`
     (not the `linux-arm64-android` name, which does not exist);
   - `resolveOpencodePty`: return undefined for android (no prebuilt binding);
   - `FFF_LIBC` and compile-time `process.env.OPENTUI_LIBC`: android→`"musl"`.
     Never `"android"`: the runtime loader **throws** for anything but
     unset/`glibc`/`musl`, so the first build's TUI was dead on arrival
     (`--version` doesn't touch the loader — that's why it looked fine).
2. `v2-android.patch` (guysoft's, applies cleanly to 0.5.14): bionic include
   handling, `pthread`/`m` link fixes, miniaudio/Yoga translate shims.
3. Loader mapping (`scripts/patch-opentui-loader.py`, anchor-based so chunk
   filename hashes don't matter): Bun's Android runtime reports
   `process.platform === "android"`, unknown to stock `@opentui/core`
   (`Unsupported OpenTUI Node asset target: android-arm64`). Map android →
   `{linux, arm64, musl}` and widen the linux branch. Verified byte-identical
   output against a hand patch.

## 5. Failure log (every dead end, with root cause)

1. **`bun install` truncated under proot.** `Bun.build` failed resolving
   `./export/AggregationTemporality` etc. Root cause: extracted packages
   missing `.js` files (npm tarball has 198). Fix: overlay the two
   `@opentelemetry/*` tarballs over the install. Lesson: verify, don't assume
   package-manager success.
2. **Zig 0.16 build-runner crash under proot** (`clone`/`linkat` `INVAL`
   panic in `File.Atomic.link`). proot can't emulate `linkat(AT_EMPTY_PATH)`.
   Moved the Zig step to native Termux.
3. **`prepare-zig-deps.sh` 10-minute hang (native).** Its `ln`-hardlink lock
   spins forever when `link()` fails; plus its `.ready` marker embeds the
   tarball path, so a copied tree never hits the cache. Fix: skip when deps
   exist, absolute-path marker, stale-lock cleanup, timeout.
4. **translate-c shim headers missing.** Shims include `../miniaudio.h` /
   `../yoga/yoga/Yoga.h`, resolved under the merged sysroot — staged
   `src/vendor/miniaudio/miniaudio.h` + symlinked `zig-deps/yoga` there.
5. **Unversioned triple rejected by Termux sysroot** (`Unversioned target
   triples are not supported!` from newer bionic `cdefs.h`). Native builds
   use `aarch64-linux-android.29`; CI with NDK r28 uses the unversioned triple
   (accepted there) plus an `__ANDROID_MIN_SDK_VERSION__` belt in the shims.
6. **Zig cache `AccessDenied`.** Root cause, proven by self-test: this
   device's policy denies `link()` (`EACCES`) — the same denial caused failure
   #3. Dead ends: `LD_PRELOAD` link→copy shim (works for `ln`, useless for Zig
   — Zig's std makes **raw syscalls**, bypassing libc entirely), fresh
   `--cache-dir` (same denial). Verdict: on-device Zig builds are impossible
   here; the renderer must be cross-compiled off-device.
7. **musl `.so` on bionic (stopgap that worked).** Methodology that mattered:
   strip `@LIBC` version suffixes before `nm` comparison (else everything
   looks missing). Truly missing: only `__errno_location`,
   `pthread_tryjoin_np`, `shm_open`, `shm_unlink` → 6.7K `libmusl-shim.so`
   (tryjoin as always-`EBUSY` mirrors upstream's own Android fallback in
   `clipboard/host.zig`), plus `patchelf --add-needed libm.so` (musl folds
   libm into libc; bionic doesn't). struct-layout risk checked by measurement
   (mutex/cond/attr/stat = 40/48/56/128 on **both** sides).
8. **`OPENTUI_LIB_PATH` red herring.** Nothing in v2 reads it (v1 leftover in
   wrappers). The real override is `OTUI_ASSET_ROOT/<asset-key>`, checked
   first by `resolveNativeLibraryPath` — enables lib A/B testing with zero
   rebuilds.
9. **guysoft 0.5.10 lib rejected.** Bun resolves all 425 dlopen symbols
   eagerly; 0.5.10 lacks 2 (`embeddedTerminalSetTransparentBackground`,
   `textBufferViewSetTextAlign`). No stubbing possible across dlopen handles.
10. **CI teething (all fixed):** `GITHUB_PATH` is next-step-only (export
    `PATH` in-step too); missing `actions/checkout` (workspace empty);
    `check && apply` silently skips under `set -e` (split commands); yoga
    link verified before extraction (moved after prep); **Zig has no bundled
    Android libc** — pass `zig build --libc <ndk-based-libc.txt>`
    (guysoft's script creates that file but never passes it).

## 6. Final architecture (pure bionic, no shims)

```
opencode2 (wrapper, sh)
  env: LD_LIBRARY_PATH=$PREFIX/lib (for parcel watcher libc++_shared.so)
  └─ opencode2.bin (bionic, Bun android base)
       ├─ JS/TS app + @parcel/watcher-android-arm64 + android→musl loader mapping
       └─ EMBEDDED renderer: CI-built true-bionic libopentui.so
            (swapped into the npm musl slot pre-build, so the bundler
             picks it up; NEEDED libm/libc/libdl, 425/425 symbols)
```

No sidecar `.so`, no `LD_PRELOAD`, no `OTUI_ASSET_ROOT`, no patchelf in the
shipped packages: `opencode2` + `opencode2.bin` only. (An earlier revision
used an `OTUI_ASSET_ROOT` override with a musl lib + 4-symbol shim; retired
once the CI bionic lib proved out — see failure log §5.7–5.9.)

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

## 7. Maintenance

`.github/workflows/build-weekly.yml` runs Mondays 03:00 UTC (plus manual):
resolve latest `v2.*` → skip if release exists → pin host Bun from upstream
`packageManager` → verify Bun android base exists → clone/patch/install →
patch loader → build CLI → build lib (Zig 0.16 + NDK r28) → verify bionic
(no `__errno_location`) → package zip/deb/pacman + SHA256SUMS → release.
Known future breakage: opentui chunk rewrites (loader patch asserts anchors),
`v2-android.patch` drift (fails loudly), Bun dropping the android base asset
(pre-checked with a clear error).
