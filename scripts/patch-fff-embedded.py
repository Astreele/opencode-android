#!/usr/bin/env python3
# RUNS ON: Linux x86_64 CI runner (NOT on Termux, NOT on device).
"""Embed the official Android fff native lib instead of the musl one.

@ff-labs/fff-bun ships @ff-labs/fff-bin-android-arm64 (pure bionic), and its
own platform.ts maps android -> aarch64-linux-android. But src/embedded.ts
(the `bun build --compile` path) only handles darwin/win32/linux and returns
null otherwise, so android builds fall back to the FFF_LIBC musl .so — whose
undefined __errno_location/bcmp make dlopen fail on bionic (fff silently dead).

This adds an android branch importing the bin package's libfff_c.so by
absolute path (Bun will not resolve the os:android package name on a linux
host; same reason as the parcel watcher). Idempotent.

Usage: patch-fff-embedded.py <upstream-checkout-dir>
"""
import glob
import os
import sys

root = os.path.abspath(sys.argv[1])

cands = []
for pattern in (
    os.path.join(root, "node_modules", ".bun", "@ff-labs+fff-bun@*",
                 "node_modules", "@ff-labs", "fff-bun", "src", "embedded.ts"),
    os.path.join(root, "node_modules", "@ff-labs", "fff-bun", "src", "embedded.ts"),
):
    cands += glob.glob(pattern)
cands = sorted(set(cands))
if not cands:
    sys.exit("no fff-bun src/embedded.ts found under " + root)
print("fff embedded candidates: " + str(cands))

bin_cands = []
for pattern in (
    os.path.join(root, "node_modules", ".bun", "@ff-labs+fff-bin-android-arm64@*",
                 "node_modules", "@ff-labs", "fff-bin-android-arm64", "libfff_c.so"),
    os.path.join(root, "node_modules", "@ff-labs", "fff-bin-android-arm64", "libfff_c.so"),
):
    bin_cands += glob.glob(pattern)
bin_cands = sorted(set(bin_cands))
if not bin_cands:
    sys.exit("no fff-bin-android-arm64/libfff_c.so found under " + root)
lib = bin_cands[0]
print("android fff lib: " + lib)

anchor = "  return null;\n}"
assert lib.endswith(".so")
branch = (
    '  if (process.platform === "android") {\n'
    '    return importFile(\n'
    '      import(' + repr(lib) + ', {\n'
    '        with: { type: "file" },\n'
    '      }),\n'
    '    );\n'
    '  }\n\n'
    '  return null;\n}'
)

for path in cands:
    src = open(path).read()
    if 'process.platform === "android"' in src:
        print("already patched: " + path)
        continue
    assert src.count(anchor) == 1, f"anchor not found exactly once in {path}"
    open(path, "w").write(src.replace(anchor, branch))
    print("patched " + path)
