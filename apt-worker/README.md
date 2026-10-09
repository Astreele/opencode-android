# APT pool redirect worker (Cloudflare)

`apt` only fetches files from inside its own repository root, so without
this worker every `.deb` (~57 MB each) would have to be committed to the
`gh-pages` branch. Instead the branch holds only metadata (KBs) and this
worker 302-redirects `pool/…/*.deb` to the identical file on the GitHub
release page — which `apt` follows, then verifies size/hash from `Release`
as usual.

Mapping: `pool/main/opencode2/opencode2_<ver>-<rev>_aarch64.deb` comes from
release tag `v<ver>-android` (verified: both live 2.0.25/2.0.26 assets
resolve). Non-pool paths are proxied straight to the Pages origin, so the
worker's own domain serves the whole repository from a single `deb` line.

## Deploy (one time, maintainer) — DONE

Live at `https://opencode-android-apt.psmsword148.workers.dev` (deployed
via `wrangler deploy` from this directory; redeploy the same way after any
`worker.js` change).

## Go live checklist

1. ~~Deploy the worker~~ — done, URL above.
2. ~~Set `APT_POOL_MODE: none`~~ — done in `.github/workflows/apt-repo.yml`.
3. ~~Point clients at the worker URL~~ — `install.sh` (`APT_ROOT`),
   `apt/opencode-android.list`, and `README.md` all use it.
4. Dispatch the `apt-repo` workflow with `reset: true`: the branch is
   recreated metadata-only, evicting the stored debs (and their history).
   Until this runs, the branch still serves its stored pool — harmless.
5. Verify on a device: fresh `install.sh` run, `apt-cache policy opencode2`,
   and a `--download-only` install.

To revert, flip `APT_POOL_MODE` back to `pool`, restore the old root URL in
the same files, and re-run the workflow (it re-seeds `pool/` from releases).
