// APT pool redirect for opencode-android.
//
// apt can only fetch files from inside its own repository root, so the
// Packages index keeps pool-relative Filenames while the large .debs live
// only as GitHub release assets. This worker bridges the two:
//   /pool/.../*.deb  -> 302 to the matching release asset (apt follows it)
//   everything else  -> proxied from the gh-pages branch (dists/, key)
//
// Mapping: pool/main/opencode2/opencode2_<ver>-<rev>_aarch64.deb comes from
// release tag v<ver>-android, e.g. opencode2_2.0.26-1_aarch64.deb lives on
// v2.0.26-android under the identical filename.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const m = url.pathname.match(
      /^\/pool\/[^/]+\/[^/]+\/(opencode2_(.+)-(\d+)_aarch64\.deb)$,
    );
    if (m) {
      const file = m[1];
      const ver = m[2];
      const tag = `v${ver}-android`;
      return Response.redirect(
        `https://github.com/${env.REPO}/releases/download/${tag}/${file}`,
        302,
      );
    }
    return fetch(env.ORIGIN + url.pathname + url.search, request);
  },
};
