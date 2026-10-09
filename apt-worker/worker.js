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
//
// Note: this file deliberately uses no regular-expression literals.
// Wrangler's bundler misparses them in this project, so all matching is
// plain string operations (same greedy-last-dash semantics as before).
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    let target = null;
    if (url.pathname.startsWith("/pool/")) {
      const file = url.pathname.slice(url.pathname.lastIndexOf("/") + 1);
      const head = "opencode2_";
      const tail = "_aarch64.deb";
      if (file.startsWith(head) && file.endsWith(tail)) {
        const inner = file.slice(head.length, file.length - tail.length);
        const dash = inner.lastIndexOf("-");
        const ver = inner.slice(0, dash);
        const rev = inner.slice(dash + 1);
        let revDigits = rev.length > 0;
        for (let i = 0; i < rev.length; i++) {
          const c = rev.charCodeAt(i);
          if (c < 48 || c > 57) {
            revDigits = false;
            break;
          }
        }
        if (dash > 0 && ver.length > 0 && revDigits) {
          target =
            "https://github.com/" +
            env.REPO +
            "/releases/download/v" +
            ver +
            "-android/" +
            file;
        }
      }
    }
    if (target) {
      return Response.redirect(target, 302);
    }
    return fetch(env.ORIGIN + url.pathname + url.search, request);
  },
};
