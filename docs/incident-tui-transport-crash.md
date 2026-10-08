# Incident: TUI `Transport: Unable to connect` in project directories

Date: 2026-10-08 · Status: ROOT CAUSE CONFIRMED + FIX SHIPPED
(fff native indexer segfaults on vcs-project content; disabled via
`OPENCODE_DISABLE_FFF=1` in the wrapper).
Affects: `opencode`/`opencode2` v2.0.24-android-termux.1 on-device (Termux).

## 1. Symptoms (verbatim user report)

```
~/DroidDeck $ opencode
UnknownError: An error occurred in Effect.tryPromise
    at Tui.run (chunk-jx27x3y2.js:98:643)
  [cause]: ClientError: Transport: Unable to connect. Is the computer able to access the url?
      [cause]: TypeError: Unable to connect. Is the computer able to access the url?
```

- Instant death (~260 ms, exit code 1, byte-identical 923-byte output on
  every run), zero TUI frames, in `~/DroidDeck` and `~/opencode-android`.
- `~/t` (near-empty dir) renders full TUI frames (11–12 KB) every time.
- Same failure with `--standalone` (private server, no background service).
- `service status` shows a live server before/after; `api` works everywhere.

## 2. Proven facts

- **Server segfaults.** Disposable `serve --port …` instances die with
  `panic: Segmentation fault at address 0x0` (Bun v1.4.2, RSS only
  ~0.16 GB — not OOM) when a TUI boots in the failing directory.
- **Crash precedes logging.** No request/response lines from the killing
  call exist in any server log (native abort loses buffered log lines), so
  the client sees a bare ECONNREFUSED as `Transport: Unable to connect`.
- **Background-service deaths are the same crash.** They are silent
  (stderr discarded on daemonize) with no panic/error lines — previously
  misattributed to memory pressure and flapping.
- **TUI's first project call.** `Tui.run` source (v2.0.24,
  `packages/tui/src/app.tsx:212`) awaits
  `api.file.list({ location: { directory: process.cwd() } })` before
  anything project-scoped; strace confirms localhost:28570 dials plus
  parallel Cloudflare 443s (update check) at boot, and zero opens of any
  project file by the client.
- **Content trigger, bisected live** (TUI-against-disposable per
  directory; server panic = positive):
  `DroidDeck/` → `app/` → `app/src/main/assets/` → `directaudio/` crash.
  Clean: `steam-startup/` (incl. `.webm`), `graphics_driver/` (incl.
  `.tzst` archives), the lone ELF `.so` (68 KiB).
- **Root cause: fff native indexer.** Same `app/` content WITHOUT `.git`
  above it renders fine; fff-disabled server + full `DroidDeck/` renders
  fine (11 KB frames, zero errors). So the crash needs vcs-context AND
  fff enabled — no single file is at fault. `Fff.create({basePath})`
  (content indexing/mmap, selected for vcs projects per
  `packages/core/src/filesystem/search.ts`) segfaults deterministically
  (SIGSEGV @ 0x0) while indexing this tree. Fix: `OPENCODE_DISABLE_FFF=1`
  (ripgrep fallback keeps the same UX); upstream prebuilt native lib,
  not patchable here.

## 3. Eliminated causes (with evidence)

- **Project config**: no `opencode.json`/`.opencode` in failing dirs, no
  global config, no `.env`/`bunfig.toml`.
- **General transport**: `api` answers identically in all dirs (same
  server pid); `session.create` with the failing directory succeeds.
- **Stale service record**: wrapper now drops dead-pid records (shipped);
  failures persist with fresh records (`kill -0` + `/proc` cmdline
  verified live).
- **Boot-time external fetches**: `OPENCODE_DISABLE_AUTOUPDATE=1` (proven
  skip-knob in binary) and `OPENCODE_DISABLE_MODELS_FETCH=1`, alone and
  combined, change nothing; `~/t` renders while the route is down.
- **Client OOM**: detached RSS sampling shows the TUI flat at ~260 MB.
- **Tree size**: failing trees modest (877/164 files); `fs.list` on
  `$HOME` succeeds; biggest single files only ~3 MB.
- **Sessions**: zero sessions in failing dirs (no resume path).
- **Sockets/fifos/symlinks/weird filenames**: none in the failing tree.
- **ELF `.so` / `.webm` / `.tzst`**: each renders clean in isolation.

## 4. Environment notes (contributing, not causal)

- Device under memory pressure (77% RAM, ~3 GB swap used); service RSS
  ~300 MB; each CLI boot adds a transient ~200 MB runtime. Unrelated
  kills happen under load — keep headroom, `service stop` when idle.
- Server log shows `update check failed … HTTP 404` noise: the custom
  `android-termux` channel is unknown to upstream's update endpoint.
  Cosmetic; `OPENCODE_DISABLE_AUTOUPDATE=1` silences it.
- `opencode service status` auto-starts a missing service; any `api`
  call does too. `service stop`/`start` round-trips cleanly.

## 5. Mitigations shipped (opencode-android, all tested)

- Wrapper drops stale `service-*.json` records (dead pid), converting
  instant-fatal into auto-start (`scripts/package.sh` template + live
  on-device install; 4 bats tests).
- Wrapper retries a fast-failing interactive TUI once after restarting a
  missing service. Never fires for `service`/`serve`/`upgrade`/`update`/
  `uninstall`/`acp`, `--standalone`, `--server`, slow failures, signals,
  exit 127, or when a live service exists — so scripted use can never
  double-execute (10 bats tests green, 51/51 full suite).
- Wrapper exports `OPENCODE_DISABLE_FFF=1` (template + live install):
  the native file indexer stays off everywhere; ripgrep fallback.
- `set -e` post-mortem: replacing `exec` with a waiting call silently
  disabled everything until guarded with if/else — covered in tests.

## 6. To finish (in order)

1. Narrow the fff trigger if cheap (single `.drv` file? `.git` objects?):
   useful for the upstream issue, not required for the fix.
2. File upstream issue (opencode `fff-bun`/`libfff_c` SIGSEGV on this
   tree) with the minimal reproducer.
3. ~~After `opencode service restart` picks up the new env, verify the TUI
   opens in `~/DroidDeck` and `~/opencode-android`.~~ DONE 2026-10-08:
   TUI in `~/DroidDeck` renders full frames (12 KB, exit 124 = healthy
   timeout) with the fff-disabled service; daemon survives.
   `service status` / any `api` call revives a crashed daemon.
