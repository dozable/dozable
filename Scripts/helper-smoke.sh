#!/bin/bash
# helper-smoke.sh — 675 (H9): the HELPER build, as an app gets it, boots a sandbox from an EMPTY store with no kernel
# download. `make test-cli-helper` runs it (after `make release FLAVOUR=helper`); CI runs it on the VM runner.
#
#   Scripts/helper-smoke.sh [TARBALL]     default: dist/doz-<VERSION>-macos-arm64-helper.tar.gz
#
# What it does, in a scratch folder ($TMPDIR/doz-helper-smoke — removed first; never a real store or settings):
#   1. unpacks the tarball and checks the layout contract (docs/manual/33-bundling-doz-in-an-app.md);
#   2. copies libexec/doz WHOLE into Smoke.app/Contents/Resources/Helpers/doz/ (ditto, as an app does) and from there:
#      the signature still verifies, the entitlement is there, doz upgrade refuses naming the app, doz ui is not in it;
#   3. with an empty store and its own settings folder (no DOZ_KERNEL_CACHE): doz host start reports flavour "helper";
#      doz create --image lab --start boots a VM — the kernel copied from the copy the helper carries, never downloaded;
#      exec reports the pinned kernel's release; the store's kernels/ holds the pin;
#   4. removes the sandbox and stops the host.
# Network: the lab image and the guest init image are pulled from their registries (the first start of any store);
# nothing is fetched from kata-containers. The tarball must be signed with the virtualization entitlement (make
# release signs it, ad hoc for a local test build).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
TARBALL="${1:-$ROOT/dist/doz-$VERSION-macos-arm64-helper.tar.gz}"
KERNEL_NAME="$(sed -n 's/.*fileName: "\(vmlinux-[^"]*\)").*/\1/p' "$ROOT/Sources/DozableKit/KernelProvider.swift" | head -1)"
KERNEL_SHA="$(sed -n 's/.*kernelSHA256: "\([0-9a-f]\{64\}\)".*/\1/p' "$ROOT/Sources/DozableKit/KernelProvider.swift" | head -1)"
W="${TMPDIR:-/tmp/}doz-helper-smoke"

pass=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass + 1)); }
die() { printf 'FAIL %s\n' "$*"; exit 1; }

[[ -f "$TARBALL" ]] || die "no $TARBALL — make release VERSION=$VERSION FLAVOUR=helper first"
# A previous run's host, if one was left: stopped through its own socket before the folder goes.
if [[ -x "$W/Smoke.app/Contents/Resources/Helpers/doz/doz" ]]; then
    env XDG_CONFIG_HOME="$W/xdg" "$W/Smoke.app/Contents/Resources/Helpers/doz/doz" host stop --store "$W/store" >/dev/null 2>&1 || true
fi
rm -rf "$W"
mkdir -p "$W/unpacked"

# 1. The tarball and its layout.
tar -xzf "$TARBALL" -C "$W/unpacked"
TOP="$(ls "$W/unpacked")"
[[ "$TOP" == "doz-$VERSION-helper" ]] || die "the tarball's top folder is $TOP, not doz-$VERSION-helper"
L="$W/unpacked/$TOP/libexec/doz"
for f in doz VERSION RELEASE DozableKit_DozableKit.bundle "kernels/$KERNEL_NAME" licences/LICENSE licences/THIRD-PARTY-LICENSES.txt licences/kernel/PROVENANCE.md; do
    [[ -e "$L/$f" ]] || die "layout: no libexec/doz/$f"
done
[[ -s "$W/unpacked/$TOP/README.md" ]] || die "layout: no README.md"
[[ ! -e "$W/unpacked/$TOP/bin" ]] || die "layout: the helper has no bin/"
[[ ! -e "$L/DozableKit_DozableWeb.bundle" ]] || die "layout: the helper carries no dashboard bundle"
[[ ! -e "$L/deckhold-mac" ]] || die "layout: the helper carries no deckhold-mac (sessions on the Mac itself are the CLI's only)"
[[ "$(cat "$L/VERSION")" == "$VERSION" ]] || die "VERSION is $(cat "$L/VERSION")"
[[ "$(cat "$L/RELEASE")" == helper* ]] || die "RELEASE is $(cat "$L/RELEASE"), not helper"
[[ "$(shasum -a 256 "$L/kernels/$KERNEL_NAME" | cut -d' ' -f1)" == "$KERNEL_SHA" ]] || die "the carried kernel is not the pin"
ok "layout: libexec/doz/{doz, VERSION, RELEASE=helper, DozableKit_DozableKit.bundle, kernels/$KERNEL_NAME (the pin), licences/}, README.md; no bin/, no dashboard, no deckhold-mac"

# 2. Copied whole into an app, as an app does.
H="$W/Smoke.app/Contents/Resources/Helpers/doz"
mkdir -p "$(dirname "$H")"
ditto "$L" "$H"
DOZ="$H/doz"
codesign --verify --strict "$DOZ" || die "the copied helper's signature does not verify"
codesign -d --entitlements - --xml "$DOZ" 2>/dev/null | grep -q com.apple.security.virtualization || die "no virtualization entitlement"
ok "copied whole into Smoke.app/Contents/Resources/Helpers/doz: the signature verifies, the entitlement is there"

export XDG_CONFIG_HOME="$W/xdg"
export DOZ_STORE="$W/store"
unset DOZ_KERNEL_CACHE DOZ_KERNEL DOZ_TEST_HELPER_BUILD DOZ_TEST_UPDATE_FEED
d() { "$DOZ" "$@"; }   # the store: DOZ_STORE above

[[ "$("$DOZ" --version)" == "$VERSION" ]] || die "doz --version"
said="$(d upgrade --check 2>&1 || true)"
grep -q "belongs to Smoke; Smoke updates it" <<<"$said" || die "doz upgrade did not refuse for the app: $said"
said="$(d ui 2>&1 || true)"
grep -q "not in this build" <<<"$said" || die "doz ui: $said"
said="$(d onboard 2>&1 || true)"
grep -q "not in this build" <<<"$said" || die "doz onboard: $said"
ok "doz upgrade refuses (\"this doz belongs to Smoke; Smoke updates it\"); doz ui and doz onboard are not in this build"

# 3. An empty store: the host, then a VM.
[[ ! -e "$W/store" ]] || die "the store is not empty"
st="$(d host start --json)"
flavour="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("flavour"))' <<<"$st")"
[[ "$flavour" == helper ]] || die "host status flavour is $flavour: $st"
ok "doz host start: the host runs, its status (the ping answer) says flavour \"helper\""
d account default none >/dev/null
out="$W/create.log"
t0=$(date +%s)
# The guest init image's FIRST pull into a fresh store can fail with a registry stream reset (NIOHTTP2 StreamClosed —
# seen 2026-11-04 with the CLI build too; the next attempt succeeds): a create that failed has deleted its sandbox, so
# the start (which prepares the image) is tried again, at most 3 times, and every attempt's output is kept in the log.
d create smoke --image lab --memory 512M --isolated -v >>"$out" 2>&1 || { tail -30 "$out"; die "doz create smoke --image lab failed"; }
attempt=1
until d start smoke -v >>"$out" 2>&1; do
    if (( attempt >= 3 )) || ! grep -q "StreamClosed\|The network connection was lost\|timed out" "$out"; then
        tail -30 "$out"; die "doz start smoke failed (log: $out)"
    fi
    printf 'note: attempt %d failed pulling an image (a registry stream reset) — trying again\n' "$attempt"
    attempt=$((attempt + 1))
done
grep -q "Smoke.app/Contents/Resources/Helpers/doz/kernels/$KERNEL_NAME (the copy this doz carries) — no download" "$out" \
    || { grep -i kernel "$out"; die "the kernel was not seeded from the helper's own copy"; }
grep -q "downloading the pinned kernel" "$out" && die "the kernel was DOWNLOADED"
ok "doz create --image lab, then start, from an empty store: booted in $(( $(date +%s) - t0 )) s; the kernel copied from the helper's own copy, no download"
rel="$(d exec smoke -- uname -r)"
[[ "$rel" == 6.18.15* ]] || die "the guest's kernel is $rel"
[[ "$(shasum -a 256 "$W/store/kernels/$KERNEL_NAME" | cut -d' ' -f1)" == "$KERNEL_SHA" ]] || die "the store's kernel is not the pin"
ls "$W/store/kernels" | grep -q partial && die "a partial download is in the store's kernels/"
ok "the guest runs Linux $rel; the store's kernels/$KERNEL_NAME is the pin"

# 4. Clean up.
d rm smoke --yes >/dev/null
d host stop >/dev/null
ok "removed the sandbox, stopped the host"
printf 'helper-smoke: ALL PASS (%d checks)\n' "$pass"
