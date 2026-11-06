# doz __VERSION__ — the helper build

This is the **helper build** of `doz`: the build an app carries inside its own bundle and drives over
`<store>/host.sock`. If you want Dozable on your Mac, you want the command-line release instead —
`brew install dozable/tap/doz`, or `doz-__VERSION__-macos-arm64.tar.gz` from the same releases page.

The whole story — what this build is, what it leaves out, how to verify it, and the rules an app must follow — is
the manual's chapter **Bundling doz in an app**:
https://github.com/dozable/dozable/blob/main/docs/manual/33-bundling-doz-in-an-app.md

## What is in it

```
doz-__VERSION__-helper/
  README.md                      this file
  libexec/doz/                   copy this folder WHOLE into your app: Contents/Resources/Helpers/doz/
    doz                          the program — Developer ID (team KJ8QMLWB97), notarised, the virtualization entitlement
    VERSION                      __VERSION__
    RELEASE                      helper — this doz never updates itself; your app updates it
    DozableKit_DozableKit.bundle the small Linux programs each sandbox uses
    kernels/vmlinux-6.18.15-186  the pinned Linux kernel (GPL-2.0, unmodified) — no download on a new Mac
    licences/                    LICENSE, NOTICE, every dependency's licence; kernel/: the kernel's source offer
```

The layout is a contract: within a minor version (`0.37.x`) nothing in it moves or is renamed.

## Verify it

```sh
shasum -a 256 -c doz-__VERSION__-macos-arm64-helper.tar.gz.sha256
codesign --verify --strict doz-__VERSION__-helper/libexec/doz/doz
codesign -dv doz-__VERSION__-helper/libexec/doz/doz 2>&1 | grep TeamIdentifier=KJ8QMLWB97
```

Never re-sign it (and never sign your app with `--deep`, which would): its signature carries the entitlement that lets
it run virtual machines. Its symbols are in `doz-__VERSION__-macos-arm64-helper.dSYM.zip` beside this tarball.
