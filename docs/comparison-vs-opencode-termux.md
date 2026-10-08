# Gap analysis: `Astreele/opencode-android` vs `Hope2333/opencode-termux`

Date: 2026-10-07 · Method: full local tree inspection (23 tracked files, 25 commits) vs
remote tree API (367 files, 369 commits, branch `native-android`) + raw file fetches of
their `Makefile`, `AGENTS.md`, `docs/README.md`, workflows, `tests/run.sh`.

**Context first:** your repo is 2 days old with 1 release; theirs is ~7.5 months old with
rolling releases. Most P2/P3 gaps are age, not design. P0/P1 gaps are real now regardless
of age.

---

## 1. Snapshot

| Metric | Yours | Reference | Gap |
|---|---|---|---|
| Created / commits | 2026-10-06 / **25** | 2026-02-17 / **369** | 15× history |
| Tracked files | **23** (16 non-vendor) | **367** (274 excl. `.omo/`) | — |
| Docs | **1** (`docs/REPORT.md`, 7.8 KB) | **49** docs files (~300 KB) + `docs/README.md` index | 38× |
| Tests | **0** | **17** files: 5 `.bats` suites, golden fixtures (`report.json` + `expected.sha256` per version), `tests/run.sh`, CI job | none |
| CI workflows | **1** (`build-weekly.yml`) | **4** + `.github/ACTIONS_DISABLED.md` scope policy | no test/lint job |
| Local build entry | **none** (scripts are CI-only) | 969-line `Makefile` (`make build-native VER=…`) + `tools/make-opencode` | can't rebuild locally |
| Releases | 1 tag, 4 assets | rolling `Push*` tags, **~360 assets in newest 5 releases** | 1 version vs 22 |
| v2 versions shipped | `2.0.24` only | `2.0.1`–`2.0.22` (v1: `1.18.30`–`.34`) | no backfill |
| Package families | **1** (`opencode2`) | **5** across 2 generations (native / wrapper / compressed × v1 / v2) | — |
| Architectures | aarch64 | aarch64 + armv7 prebuild line | no 32-bit |
| Installer digest check | **none** | per-file digest-verified | security |
| Maintainer scripts in pkgs | **none** | `postinst`/`post_upgrade` hooks (e.g. `stale-serve-kill`), pacman `.install` | upgrade bug |
| README languages | 1 | 5 (en, zh-CN, zh-TW, ja, es) | — |
| Stars / forks | 0 / 0 | 249 / 45 | — |
| Discussions / topics / description | no / none / **`null`** | enabled, 6 categories / banner assets / filled | discoverability |

---

## 2. P0 — affects users today

> **Status (2026-10-07): all four items below are fixed** in this repo —
> 1: `install.sh` step [7] fetches `SHA256SUMS` and verifies the zip digest before
> extract (fail-closed; `--no-verify` is the explicit escape hatch);
> 2: `scripts/package.sh` now writes executable `postinst`/`prerm`/`postrm` and a
> pacman `opencode2.install` (stop stale daemon on install/upgrade/removal,
> `--version` sanity check, purge cleanup);
> 3: the installer guards `$PREFIX/bin/opencode` (leaves foreign/v1 files alone with
> printed instructions unless `--force`), the package owns the link and declares
> `Conflicts`/`Replaces: opencode, opencode1`, and README gained a migration note;
> 4: README documents the `.deb`/`.pkg.tar.xz` install + upgrade + remove flow and the
> deb `Version:` now carries the `-1` revision. See items for the original analysis.

1. **`install.sh` never verifies `SHA256SUMS`.** You *publish* `SHA256SUMS` with every
   release but the installer goes `curl` → `unzip` → `cp` (`install.sh:64–96`) with zero
   digest check. The reference verifies every asset. Fix: fetch `SHA256SUMS` next to the
   zip, `sha256sum -c` before extract, fail loudly.

2. **Packages carry no maintainer scripts.** `scripts/package.sh` writes a bare
   `DEBIAN/control` (lines 83–96) — no `postinst`/`prerm`/`postrm`, and the pacman
   `.PKGINFO` (lines 101–112) has no `.install`. Consequences:
   - Upgrading via `dpkg -i`/`pacman -U` does **not** stop the running `serve` daemon —
     the exact stale-service timeout their `stale-serve-kill` hook (issue #17) exists to
     fix. Your `install.sh` does stop it (step 8), but only the zip path benefits.
   - No cleanup of `$PREFIX/libexec/opencode2` on removal.
   Fix: add `postinst`/`prerm` (stop service, verify `--version`), `postrm` (clean
   leftovers), and the pacman `opencode2.install` equivalent.

3. **`ln -sf opencode → opencode2` silently clobbers v1.** `install.sh:101` overwrites
   `$PREFIX/bin/opencode` *outside dpkg's knowledge*. If the v1 `opencode` package is
   installed, you now have a package-owned file replaced on disk; the next
   `pkg upgrade opencode` reverts it and your install half-breaks. Your control file has
   no `Conflicts:`/`Replaces:`/`Provides:`. The reference resolves this explicitly
   (provider conflict model + `docs/migration-v1-to-v2.md`, `docs/dual-track-install.md`).
   Fix: either declare the conflict, or refuse to overwrite an existing v1-owned binary
   without telling the user (`dpkg -S "$PREFIX/bin/opencode"` check + printed instructions).

4. **You publish `.deb`/`.pkg.tar.xz` but never offer them as an install path.** README
   documents only the raw `curl | bash` zip route; there is no "install the package" /
   `pkg upgrade opencode2` section, and hand-copied files are invisible to apt/pacman, so
   users can never `pkg upgrade` or `apt remove` cleanly. The reference's headline flow is
   package-manager-native (`pkg upgrade opencode`, `pacman -Syu opencode`).
   Related: your deb `Version:` is bare `2.0.24` with **no Debian revision** (`package.sh:87`),
   so a packaging-only fix cannot be expressed as `2.0.24-1` → `2.0.24-2`; apt will treat it
   as the same version. (Pacman side does use `${VER}-1`, so the two disagree.)

---

## 3. P1 — engineering maturity

> **Status (2026-10-08): item 5 fixed** — `tests/` now holds four bats suites
> (`install.bats`, `package.bats`, `wrapper.bats`, `vendor.bats`) plus a
> `tests/run.sh` runner (bootstraps a pinned bats-core when absent) and a
> `tests.yml` CI job on every push/PR. Coverage matches the three bullets below:
> installer + `package.sh` tests, an artifact-shape suite (wrapper `.bin`
> resolution, deb/pacman/SHA256SUMS shape), and a golden checksum for the
> vendored natives. The inline `readelf`/`nm` gates were factored into
> `scripts/check-elf.sh` so they are assertable and re-runnable locally.

5. **Zero automated tests.** No `tests/`, no test job in the workflow (grep confirms the
   only `test` in `build-weekly.yml` is the Bun version assertion, line 181). Their setup:
   `tests/unit/*.bats` (5 suites), golden regression (`tests/transplant/test_golden.py`
   with pinned `report.json`/`expected.sha256` fixtures), `tests/run.sh`, and a
   `tests.yml` job on every push/PR. Even without their scale, add:
   - `bats` tests for `install.sh` (asset-name parsing, failure paths) and `package.sh`;
   - a CI "artifact shape" test: wrapper resolves the `.bin`, `readelf -d` gates (you
     already run these inline — make them assertable and re-runnable);
   - a golden checksum for the vendored natives.

6. **No local build path.** `scripts/*.sh` are explicitly CI-only (`package.sh:2`:
   "RUNS ON: Linux x86_64 CI runner"), there is no `Makefile`, and the README has **no
   "Building from source" section** at all — a contributor must reverse-engineer a
   405-line workflow. Their README ships five copy-paste build commands backed by
   `docs/make-maintainer.md`. Fix: a `Makefile` (or `scripts/build.sh`) that reproduces
   the CI sequence locally, documented in the README.

7. **No on-device acceptance record.** Your only runtime check is `opencode2 --version`
   at install time (`install.sh:111`). TUI reachability, watcher `subscribe`, and PTY
   spawn are claimed in the README but nothing in-repo proves them per release. Their
   model: `make selfcheck`, `tui_probe` gate written into `report.json`,
   `tools/upgrade-matrix.sh` against a real device, plus
   `docs/30-ci-local-build-matrix.md` and `handover/release-runbook.md`. Fix: a
   `tests/smoke-device.sh` the maintainer runs before publishing, with results pasted
   into the release body.

8. **Dead external reference — fixed.** `docs/REPORT.md` previously pointed at an
   unpublished failure-log file outside the repo (split out in `5e77b66` but never
   published), leaving the entries 7–9 justification for the current architecture
   unverifiable by readers. The external pointer has been removed; the architecture
   rationale now stands on its own in `docs/REPORT.md`.

9. **No `.gitignore`.** `work/`, `out/`, `upstream/` are all created by the scripts; a
   local run makes the tree dirty with gigabytes of candidates to commit accidentally.
   Trivial fix.

10. **No lint job.** 405 lines of workflow YAML + 4 scripts, no `shellcheck`/`actionlint`.
    Their `make selfcheck` + bats at least gate shell changes.

---

## 4. P2 — documentation

11. **Docs volume/structure: 1 file vs an indexed 49-file tree.** They have
    `docs/README.md` as a canonical index with an explicit "update docs first" rule.
    Highest-value docs you have **no equivalent for**:
    | Their doc | What it covers | You |
    |---|---|---|
    | `execution-checklist.md` | install/test runbook | none |
    | `20-packaging-deb.md`, `21-packaging-pkg-tar-xz.md` | package layout/outputs | described only in script comments |
    | `migration-v1-to-v2.md`, `dual-track-install.md` | upgrade/downgrade/provider choice | none (you overwrite v1!) |
    | `patch-coverage-audit.md` | which upstream paths each patch covers | your 6 patches have no coverage audit |
    | `99-open-issues-and-upstream-sync.md`, `handover/open-items.md` | known-broken state | only "Known future breakage" (3 bullets) |
    | `performance-optimization.md`, `docs/measurements/*.json` | measured baselines | none |
    | `22-termux-services-opencode-web.md` | runit service / `opencode web` | none |
    | `incidents/*.md` | postmortems | none |

12. **README gaps.**
    - **No minimum Android version.** Neither README nor REPORT states an API level, even
      though `build-*-ci.sh` target **API 29**. Their README: "Android API >= 28
      (Android 9.0+)". Users on old devices get a confusing runtime failure.
    - **No "Building from source"** section (see §3.6).
    - **No size/storage requirement** (theirs: "~200 MB free"), no screenshot (theirs has
      a TUI screenshot + discussion banner), no troubleshooting/FAQ, no license badge.
    - **No changelog/what's-new** beyond the auto-generated release body.

13. **Single-language README** vs 5 languages. Cheapest wins: zh-CN + es.

---

## 5. P3 — breadth & community (age-driven; sequence after P0–P2)

14. **One version, one family, one arch.** You ship only the newest `v2.*` weekly; they
    backfill every `2.0.x` (22 versions), keep a v1 maintenance line, and offer
    native/wrapper/compressed variants (their compressed line is ~56 MB vs your ~74 MB
    zip — meaningful on low-storage devices). They also run an armv7 prebuild line
    (`.github/workflows/prebuild-armv7.yml`); you are aarch64-only.
15. **No ecosystem surface:** no plugin/skills/hook tooling
    (`tools/plugin-manager.sh`, system-skills hooks, 8 plugin docs), no service/runit
    integration docs, no benchmarks (`scripts/bench/bench-opencode.sh`), no release
    staging/index generation (`tools/gen-packages-index.py`, `tools/maintain.sh`).
16. **Repo metadata is empty:** `description: null`, no topics, no homepage, no
    screenshots/assets, `has_discussions: false`, no wiki. This is most of why 0 stars —
    the repo is currently unsearchable ("opencode" + no topics + no description).
17. **No contributor surfaces:** no `AGENTS.md` / `CONTRIBUTING.md` / issue templates /
    SECURITY.md. (Fairness note: they also lack `CONTRIBUTING.md` and issue templates —
    their knowledge lives in `AGENTS.md` + `docs/`, which you also lack.)

---

## 6. Where you are already ahead (don't spend effort here)

- **Releases are CI-built and reproducible.** Their `.github/ACTIONS_DISABLED.md` states
  Actions is *not* a release path — final packages are built manually on a device. Your
  `softprops/action-gh-release` pipeline (resolve → patch → build → verify → package →
  publish) is strictly better engineering, with force-rebuild dispatch and
  skip-if-exists logic.
- **Upstream freshness:** you track `v2.0.24`; their newest v2 asset is `2.0.22`.
- **Architecture cleanliness:** fully embedded bionic (`opencode2` + `opencode2.bin`,
  no sidecar `.so`, no `LD_PRELOAD`, no patchelf) vs their multi-line
  wrapper/transplant/seccomp-shim zoo.
- **Hard CI gates:** `readelf`/`nm` assertions that glibc-isms never leak into the
  shipped libs (`build-weekly.yml:325–357`), vendored natives with `.sha256` +
  self-committing cache — they have nothing equivalent.
- **One-page narrative:** `docs/REPORT.md` is a genuinely good architecture document;
  their docs are 300 KB of accreted runbooks, some only in Chinese, and mix generated
  `packing/` outputs into the tree.
- Do **not** copy: their `.omo/evidence/` agent artifacts, `packing/` generated outputs,
  or the "Actions disabled" policy.

---

## 7. Recommended order of work

| # | Action | Size | Closes |
|---|---|---|---|
| 1 | Verify `SHA256SUMS` in `install.sh` | S | §2.1 |
| 2 | `postinst`/`prerm`/`postrm` + pacman `.install` (stop stale service, cleanup) | S–M | §2.2 |
| 3 | `Conflicts`/`Replaces` + v1-overwrite guard + migration note | S | §2.3 |
| 4 | Document `.deb`/`.pkg.tar.xz` install + `pkg upgrade`; add deb revision `-1` | S | §2.4 |
| 5 | `tests/` (bats for shell, artifact-shape golden test) + test job in CI | M | §3.5 |
| 6 | `Makefile`/`build.sh` local entry + README "Building from source" | M | §3.6 |
| 7 | Publish the failure log in-repo; fix `REPORT.md:88` link | S | §3.8 |
| 8 | Device smoke script + paste results into release notes | M | §3.7 |
| 9 | README: API level (29), storage, screenshot, troubleshooting; `docs/index` | S–M | §4.11–12 |
| 10 | Repo description + topics (`termux`, `opencode`, `android`, `bionic`) + screenshot | S | §5.16 |
| 11 | `.gitignore` + `shellcheck`/`actionlint` job | S | §3.9–10 |
| 12 | Backfill older `v2.x` builds (workflow input already supports it) | M | §5.14 |
| 13 | armv7 / compressed variants / v1 coexistence | L | §5.14 |

Items 1–4 and 10 are the highest value per effort: they fix real user-facing bugs and
make the repo findable, and none of them require matching the reference's 8 months of
bulk.
