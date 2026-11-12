#!/usr/bin/env bash
# release.sh — 598 (H1): the prebuilt `doz` a release ships, and what Homebrew installs.
#
#   make release VERSION=0.12.0            # → dist/doz-0.12.0-macos-arm64.tar.gz (+ .sha256)
#   make release VERSION=0.12.0 DRY_RUN=1  # print every command, run none (the Developer ID plan)
#   make release VERSION=0.31.0-dev.1 TEST_BUILD=1  # a local test of the pipeline: signing/notarising optional (never published)
#
# The tarball holds the install layout `make install-cli` makes, under one top directory:
#
#   doz-<version>/bin/doz                    → ../libexec/doz/doz   (a relative link)
#   doz-<version>/libexec/doz/doz            the executable, signed with Scripts/doz.entitlements
#   doz-<version>/libexec/doz/VERSION        the version it was built for (DozableCommand.version reads it)
#   doz-<version>/libexec/doz/DozableKit_*.bundle   its resources (guest binaries, web assets)
#   doz-<version>/libexec/doz/deckhold-mac   the PTY holder for sessions on this Mac (Guest/deckhold/build-mac.sh) — signed
#                                            like doz, no entitlements; its provenance in licences/deckhold/. CLI only.
#   doz-<version>/libexec/doz/kernels/vmlinux-6.18.15-186        675: the pinned kernel (both flavours) — no download
#   doz-<version>/libexec/doz/licences/kernel/   with it: its provenance and GPL-2.0 source offer (Guest/kernel/)
#   doz-<version>/libexec/doz/kernels/vmlinux-6.18.15-186-sound2  PRIVATE builds only: the sound sandboxes' kernel
#   doz-<version>/libexec/doz/licences/sound-kernel/   with it: its source offer (Guest/sound-kernel/)
#
# 675 — FLAVOUR=helper builds the HELPER build instead: the doz an app carries inside its bundle (docs/manual/33-*):
#   dist/doz-<v>-macos-arm64-helper.tar.gz (+ .sha256) with ONE top folder doz-<v>-helper/ holding README.md and
#   libexec/doz/{doz, VERSION, RELEASE ("helper"), DozableKit_DozableKit.bundle, kernels/, licences/} — no bin/, no
#   dashboard bundle. Built with DOZ_HELPER_BUILD=1 (Package.swift) in its own scratch folder (.build-helper), so the
#   two flavours never share build products. Same version, signing, notarisation and checks as the CLI release.
# Both flavours are STRIPPED before signing (H1/H1b): the symbols go to dist/<name>.dSYM.zip, published beside the
# tarball (its UUID is checked against the stripped binary's), so crash reports still symbolicate.
#
# The pinned kernel comes from KERNEL_FILE, else $DOZ_KERNEL_CACHE/<file> (the Makefile's KERNEL_CACHE), else
# ~/Library/Caches/DozableKit/kernels/<file> — fetched there once by `make kernel` when missing (a byte-identical seed
# when this Mac has one, else kata's release archive). Whatever the source, its sha256 must be the pin.
#
# PUBLIC=1 (the default — every real release from 0.31.0 on) builds the PUBLIC flavor (`-DDOZ_PUBLIC_BUILD`,
# Sources/DozableHost/BuildFlavor.swift): no sound kernel in the tarball (doz create --sound says this build does not
# include it) and no Dozable's own ChatGPT sign-in (doz account add --chatgpt says so; the Mac's Codex login and OpenAI
# API keys stay). It checks both in the packed tarball.
#
# PUBLIC=0 (a private rc only) builds the full flavor. Its sound kernel (kata 6.18.15-186 + Guest/sound-kernel/sound.conf,
# built reproducibly by Guest/sound-kernel/build-in-guest.sh) is NOT in git (16 MB): SOUND_KERNEL=<file> names it and it
# must have the sha256 pinned in Sources/DozableKit/Audio.swift (SoundKernel.sha256) or the release stops;
# NO_SOUND_KERNEL=1 ships without it.
#
# SIGNING. With SIGN_IDENTITY (a "Developer ID Application: …" identity, from a gitignored
# Makefile.config — see Makefile.config.example) the executable and every Mac (Mach-O) binary in its
# resources are signed with it, the hardened runtime and a secure timestamp; the guest binaries are
# Linux ELF and are left alone. With NOTARY_PROFILE too (`xcrun notarytool store-credentials`, once),
# the signed tree is submitted to Apple's notary service and waited for. A bare command-line tool
# cannot be stapled (only bundles, disk images and packages can): Gatekeeper looks its ticket up
# online the first time. Without SIGN_IDENTITY it signs ad hoc, as today, and says so — which is
# enough for Homebrew (a formula's download is never quarantined).
#
# THE OFFICIAL BUILD. DOZ_CLOUD_PACKAGE (Makefile.config) names the closed package of anonymous usage statistics and
# the sign-up (a path, or a git URL + DOZ_CLOUD_REF); Package.swift adds it to this build only. A PUBLIC release refuses
# to build without it (TEST_BUILD=1 excepted), the packed doz must say `"official": true` in `doz telemetry show --json`
# (run in a scratch settings folder and store; looking never sends), and the RELEASE marker records `public+cloud`.
#
# Inputs (environment; the Makefile passes them): FLAVOUR (cli, the default, or helper), KERNEL_FILE, DOZ_KERNEL_CACHE,
# PUBLIC (default 1), VERSION (default: the exact vX.Y.Z tag at HEAD),
# OUT (default dist), JOBS (default 4), SWIFT_BUILD_SYSTEM, SIGN_IDENTITY, NOTARY_PROFILE,
# DOZ_CLOUD_PACKAGE, DOZ_CLOUD_REF, HARDENED=1 (the hardened runtime even when signing ad hoc — to test the entitlement under it),
# DRY_RUN=1, SKIP_BUILD=1 (package the release build already in .build/release).
# It never reads, prints or stores a password, and never calls notarytool without a profile.
set -euo pipefail

PACKAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PACKAGE"
OUT="${OUT:-dist}"
JOBS="${JOBS:-4}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DRY_RUN="${DRY_RUN:-}"
ENTITLEMENTS="Scripts/doz.entitlements"
PUBLIC="${PUBLIC:-1}"
[[ "$PUBLIC" == 1 || "$PUBLIC" == 0 ]] || { printf 'x release: PUBLIC is 1 (a public release, the default) or 0 (a private rc), not %s\n' "$PUBLIC" >&2; exit 1; }
SOUND_KERNEL="${SOUND_KERNEL:-}"
DOZ_CLOUD_PACKAGE="${DOZ_CLOUD_PACKAGE:-}"
DOZ_CLOUD_REF="${DOZ_CLOUD_REF:-}"
# A public build never carries the sound kernel.
if [[ "$PUBLIC" == 1 ]]; then NO_SOUND_KERNEL=1; fi
SOUND_KERNEL_NAME="$(sed -n 's/.*static let fileName = "\(vmlinux-[^"]*\)".*/\1/p' Sources/DozableKit/Audio.swift)"
SOUND_KERNEL_SHA="$(sed -n 's/.*static let sha256 = "\([0-9a-f]\{64\}\)".*/\1/p' Sources/DozableKit/Audio.swift)"
# 675: the flavour, and the pinned kernel every release carries (read from the pin itself — KernelArtifact.recommended).
FLAVOUR="${FLAVOUR:-cli}"
[[ "$FLAVOUR" == cli || "$FLAVOUR" == helper ]] || { printf 'x release: FLAVOUR is cli (the default) or helper, not %s\n' "$FLAVOUR" >&2; exit 1; }
KERNEL_NAME="$(sed -n 's/.*fileName: "\(vmlinux-[^"]*\)").*/\1/p' Sources/DozableKit/KernelProvider.swift | head -1)"
KERNEL_SHA="$(sed -n 's/.*kernelSHA256: "\([0-9a-f]\{64\}\)".*/\1/p' Sources/DozableKit/KernelProvider.swift | head -1)"
KERNEL_FILE="${KERNEL_FILE:-}"
KERNEL_HOME_CACHE="$HOME/Library/Caches/DozableKit/kernels"

say() { printf '%s\n' "$*"; }
fail() { printf 'x release: %s\n' "$*" >&2; exit 1; }
# Run a command — or, in a dry run, print it (quoted, so it can be pasted) and run nothing.
run() {
    if [[ -n "$DRY_RUN" ]]; then printf '  [dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}

if [[ -z "${VERSION:-}" ]]; then
    tag="$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || true)"
    [[ -n "$tag" ]] || fail "which version? make release VERSION=X.Y.Z (HEAD carries no vX.Y.Z tag)"
    VERSION="${tag#v}"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || fail "VERSION must be semver (X.Y.Z), not '$VERSION'"
[[ "$(uname -m)" == "arm64" ]] || fail "doz is Apple silicon only (this is $(uname -m))"

if [[ -z "${NO_SOUND_KERNEL:-}" ]]; then
    [[ -n "$SOUND_KERNEL_NAME" && -n "$SOUND_KERNEL_SHA" ]] || fail "cannot read SoundKernel.fileName/sha256 from Sources/DozableKit/Audio.swift"
    [[ -n "$SOUND_KERNEL" && -f "$SOUND_KERNEL" ]] || fail "a private build (PUBLIC=0) needs SOUND_KERNEL=<the sound kernel file> (or NO_SOUND_KERNEL=1 to ship without — doz create --audio then refuses)"
    got="$(shasum -a 256 "$SOUND_KERNEL" | cut -d' ' -f1)"
    [[ "$got" == "$SOUND_KERNEL_SHA" ]] || fail "the sound kernel at $SOUND_KERNEL has sha256 $got, not the pinned $SOUND_KERNEL_SHA"
fi

# 675: the pinned kernel both flavours carry — an explicit file, the configured cache, or this Mac's DozableKit cache
# (filled once by `make kernel`: a byte-identical seed when this Mac has one, else kata's release archive).
[[ -n "$KERNEL_NAME" && -n "$KERNEL_SHA" ]] || fail "cannot read the pinned kernel's fileName/kernelSHA256 from Sources/DozableKit/KernelProvider.swift"
if [[ -z "$KERNEL_FILE" ]]; then
    for c in ${DOZ_KERNEL_CACHE:+"$DOZ_KERNEL_CACHE/$KERNEL_NAME"} "$KERNEL_HOME_CACHE/$KERNEL_NAME"; do
        if [[ -f "$c" ]]; then KERNEL_FILE="$c"; break; fi
    done
fi
if [[ -z "$KERNEL_FILE" && -z "$DRY_RUN" ]]; then
    say "release: the pinned kernel is not cached on this Mac — fetching it once into $KERNEL_HOME_CACHE (make kernel)"
    "${MAKE:-make}" kernel KERNEL_CACHE="$KERNEL_HOME_CACHE" >&2 || fail "make kernel KERNEL_CACHE=$KERNEL_HOME_CACHE failed"
    KERNEL_FILE="$KERNEL_HOME_CACHE/$KERNEL_NAME"
fi
if [[ -z "$DRY_RUN" ]]; then
    [[ -f "$KERNEL_FILE" ]] || fail "no pinned kernel at $KERNEL_FILE (KERNEL_FILE=<file>, or make kernel KERNEL_CACHE=<dir> then KERNEL_CACHE=<dir>)"
    got="$(shasum -a 256 "$KERNEL_FILE" | cut -d' ' -f1)"
    [[ "$got" == "$KERNEL_SHA" ]] || fail "the kernel at $KERNEL_FILE has sha256 $got, not the pinned $KERNEL_SHA"
fi

if [[ "$FLAVOUR" == helper ]]; then
    NAME="doz-${VERSION}-macos-arm64-helper"
    TOP="doz-${VERSION}-helper"
    BUILD_DIR=".build-helper"
else
    NAME="doz-${VERSION}-macos-arm64"
    TOP="doz-${VERSION}"
    BUILD_DIR=".build"
fi
STAGE="$OUT/stage/$TOP"
TARBALL="$OUT/${NAME}.tar.gz"
DSYM_ZIP="$OUT/${NAME}.dSYM.zip"

MODE="ad hoc"
SIGN_ARGS=(--force --sign -)
if [[ -n "$SIGN_IDENTITY" ]]; then
    [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] || fail "SIGN_IDENTITY must be a \"Developer ID Application: …\" identity (it is '$SIGN_IDENTITY')"
    MODE="Developer ID"
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
elif [[ -n "${HARDENED:-}" ]]; then
    MODE="ad hoc, hardened runtime"
    SIGN_ARGS=(--force --sign - --options runtime)
fi
if [[ -n "$NOTARY_PROFILE" && -z "$SIGN_IDENTITY" ]]; then
    fail "NOTARY_PROFILE is set but SIGN_IDENTITY is not — Apple notarises Developer ID signatures only"
fi
# 611: a PUBLIC release is Developer ID signed AND notarised — always. TEST_BUILD=1 is the explicit way to make an
# unsigned or unnotarised build that is never distributed (a local test of the pipeline).
if [[ "$PUBLIC" == 1 && -z "${TEST_BUILD:-}" && ( -z "$SIGN_IDENTITY" || -z "$NOTARY_PROFILE" ) ]]; then
    fail "a public release is signed with a Developer ID and notarised: set SIGN_IDENTITY and NOTARY_PROFILE in Makefile.config (see Makefile.config.example), or TEST_BUILD=1 for a local test build that is never published"
fi
# 611: a public release can verify its own updates: the update public key must be compiled in (make doz-update-keys).
if [[ "$PUBLIC" == 1 && -z "${TEST_BUILD:-}" ]]; then
    upk="$(sed -n 's/.*static let updatePublicKey = "\([^"]*\)".*/\1/p' Sources/DozableHost/Updates.swift | head -1)"
    [[ -n "$upk" ]] || fail "doz carries no update public key (Distribution.updatePublicKey is empty) — make doz-update-keys once, commit the key it prints"
fi
# 675: the helper NEVER carries the statistics/sign-up package (owner, 2026-11-04: "no telemetry in the helper") — the
# app that bundles it decides what it sends; the packed helper is checked below to say `official: false`.
if [[ "$FLAVOUR" == helper && -n "$DOZ_CLOUD_PACKAGE" ]]; then
    say "release: the helper build never includes the statistics package — DOZ_CLOUD_PACKAGE ignored for this flavour"
    DOZ_CLOUD_PACKAGE=""
fi
# 614: an official public release (the CLI) carries the statistics/sign-up package. A local path must be a package.
if [[ "$FLAVOUR" == cli && "$PUBLIC" == 1 && -z "${TEST_BUILD:-}" && -z "$DOZ_CLOUD_PACKAGE" ]]; then
    fail "a public release is the official build: set DOZ_CLOUD_PACKAGE in Makefile.config (see Makefile.config.example), or TEST_BUILD=1 for a local test build"
fi
if [[ -n "$DOZ_CLOUD_PACKAGE" && "$DOZ_CLOUD_PACKAGE" != *://* && "$DOZ_CLOUD_PACKAGE" != git@* && ! -f "$DOZ_CLOUD_PACKAGE/Package.swift" ]]; then
    fail "DOZ_CLOUD_PACKAGE ($DOZ_CLOUD_PACKAGE) is not a Swift package (no Package.swift)"
fi
# The team the identity belongs to — "Developer ID Application: Name (TEAMID)" — checked on the signed binary.
TEAM_ID="$(sed -n -E 's/^Developer ID Application: .* \(([A-Z0-9]{10})\)$/\1/p' <<<"$SIGN_IDENTITY")"
if [[ -n "$SIGN_IDENTITY" && -z "$DRY_RUN" ]]; then
    # Preflight, before a 10-minute build: the identity is in the keychain, and the notary profile authenticates.
    # (Only names are read: `find-identity` lists certificates; `notarytool history` uses the profile's stored
    # credential itself — nothing secret is printed or kept.)
    identities="$(security find-identity -v -p codesigning)"   # not piped into grep -q: SIGPIPE under pipefail
    grep -qF "\"$SIGN_IDENTITY\"" <<<"$identities" \
        || fail "the identity \"$SIGN_IDENTITY\" is not in the keychain (security find-identity -v -p codesigning)"
    if [[ -n "$NOTARY_PROFILE" ]]; then
        xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1 \
            || fail "the notarytool profile '$NOTARY_PROFILE' does not authenticate (xcrun notarytool store-credentials '$NOTARY_PROFILE' … creates it once)"
    fi
fi

FLAVOR="$([[ "$PUBLIC" == 1 ]] && echo public || echo private)"
# 675: the helper's marker says `helper` (InstallMethod: it never updates itself; publish.sh never feeds it).
[[ "$FLAVOUR" == helper ]] && FLAVOR="helper"
# The marker says when the closed package is in (publish.sh accepts public and public+cloud).
[[ -n "$DOZ_CLOUD_PACKAGE" ]] && FLAVOR="$FLAVOR+cloud"
say "release: doz $VERSION ($FLAVOR build, $FLAVOUR flavour) → $TARBALL ($MODE signature${NOTARY_PROFILE:+, notarised with profile $NOTARY_PROFILE})"
[[ -n "$DRY_RUN" ]] && say "release: DRY RUN — every command is printed, none is run"

# 1. Build (release).
if [[ -z "${SKIP_BUILD:-}" ]]; then
    # shellcheck disable=SC2086 — SWIFT_BUILD_SYSTEM is empty or two words, on purpose.
    PUBLIC_FLAGS=()
    [[ "$PUBLIC" == 1 ]] && PUBLIC_FLAGS=(-Xswiftc -DDOZ_PUBLIC_BUILD)
    resolved_before="$(git status --porcelain -- Package.resolved)"
    # 675: the helper — DOZ_HELPER_BUILD=1 (Package.swift: no dashboard, no wizards, no self-update) in its own
    # scratch folder; the CLI explicitly NOT (a stray DOZ_HELPER_BUILD in the environment never makes a CLI release).
    HELPER_ENV="$([[ "$FLAVOUR" == helper ]] && echo 1 || echo 0)"
    run env DOZ_CLOUD_PACKAGE="$DOZ_CLOUD_PACKAGE" DOZ_CLOUD_REF="$DOZ_CLOUD_REF" DOZ_HELPER_BUILD="$HELPER_ENV" DOZ_HELPER_WEB= \
        swift build ${SWIFT_BUILD_SYSTEM:-} -j "$JOBS" -c release --scratch-path "$BUILD_DIR" --product doz ${PUBLIC_FLAGS[@]+"${PUBLIC_FLAGS[@]}"}
    # deckhold-mac — the PTY holder for sessions on the Mac itself, the CLI flavour only (an app embedding the helper
    # would inherit a feature with no isolation). Built fresh from deckhold.c + the pinned ghostty's Mac library;
    # needs the toolchain `make deckhold` puts in .tools/.
    [[ "$FLAVOUR" == cli ]] && run env FORCE=1 Guest/deckhold/build-mac.sh
    # A git URL pins the private package in Package.resolved: that pin never belongs in the public repository.
    if [[ -z "$DRY_RUN" && -z "$resolved_before" && -n "$(git status --porcelain -- Package.resolved)" ]]; then
        git checkout -- Package.resolved
        say "  Package.resolved restored (the closed package's pin is not committed)"
    fi
fi

# 2. The install layout.
run rm -rf "$STAGE" "$OUT/stage/$NAME.dSYM"
run mkdir -p "$STAGE/libexec/doz"
[[ "$FLAVOUR" == cli ]] && run mkdir -p "$STAGE/bin"
# The CLI carries every resource bundle; the helper only the guest binaries' (no dashboard — and never a stale
# DozableWeb bundle another build left in a scratch folder).
if [[ "$FLAVOUR" == helper ]]; then BUNDLES=("$BUILD_DIR/release/DozableKit_DozableKit.bundle"); else BUNDLES=("$BUILD_DIR"/release/DozableKit_*.bundle); fi
for b in "${BUNDLES[@]}"; do
    [[ -n "$DRY_RUN" || -d "$b" ]] || fail "missing $b — build first"
    run cp -R "$b" "$STAGE/libexec/doz/"
done
# H1/H1b (675): the symbols go to a dSYM (published beside the tarball), then the executable is stripped — BEFORE it
# is signed (a signed binary cannot be stripped; an app must never touch the helper's signature).
run dsymutil "$BUILD_DIR/release/doz" -o "$OUT/stage/$NAME.dSYM"
run cp "$BUILD_DIR/release/doz" "$STAGE/libexec/doz/doz"
run strip "$STAGE/libexec/doz/doz"
if [[ -z "$DRY_RUN" ]]; then
    exe_uuid="$(dwarfdump --uuid "$STAGE/libexec/doz/doz" | awk '{print $2}')"
    sym_uuid="$(dwarfdump --uuid "$OUT/stage/$NAME.dSYM" | awk '{print $2}')"
    [[ -n "$exe_uuid" && "$exe_uuid" == "$sym_uuid" ]] || fail "the dSYM ($sym_uuid) does not match the stripped doz ($exe_uuid)"
    say "  stripped: $(( $(stat -f %z "$BUILD_DIR/release/doz") / 1048576 )) MiB → $(( $(stat -f %z "$STAGE/libexec/doz/doz") / 1048576 )) MiB; symbols in $NAME.dSYM.zip (UUID $exe_uuid)"
fi
# 675: the pinned kernel (both flavours) and its GPL-2.0 source offer — the first start copies it into the store.
run mkdir -p "$STAGE/libexec/doz/kernels"
run cp "$KERNEL_FILE" "$STAGE/libexec/doz/kernels/$KERNEL_NAME"
# The helper's own README (what it is, the layout, how to verify it, the manual's chapter) at the top of its tarball.
if [[ "$FLAVOUR" == helper ]]; then
    if [[ -n "$DRY_RUN" ]]; then say "  [dry-run] Scripts/helper-README.md → $STAGE/README.md"; else sed "s/__VERSION__/$VERSION/g" Scripts/helper-README.md > "$STAGE/README.md"; fi
fi
if [[ -z "${NO_SOUND_KERNEL:-}" ]]; then
    run mkdir -p "$STAGE/libexec/doz/kernels"
    run cp "$SOUND_KERNEL" "$STAGE/libexec/doz/kernels/$SOUND_KERNEL_NAME"
fi
if [[ -n "$DRY_RUN" ]]; then say "  [dry-run] echo $VERSION > $STAGE/libexec/doz/VERSION"; else printf '%s\n' "$VERSION" > "$STAGE/libexec/doz/VERSION"; fi
# 611: the release marker — what tells an installed release (Homebrew, or the tarball unpacked by hand: `doz update`
# swaps it) from a development build (`make install-cli`, which has VERSION but no marker, and is never updated).
if [[ -n "$DRY_RUN" ]]; then say "  [dry-run] echo $FLAVOR > $STAGE/libexec/doz/RELEASE"; else printf '%s\n' "$FLAVOR" > "$STAGE/libexec/doz/RELEASE"; fi
[[ "$FLAVOUR" == cli ]] && run ln -s ../libexec/doz/doz "$STAGE/bin/doz"
# deckhold-mac beside doz (the CLI flavour only), stripped before it is signed; its provenance in licences/.
if [[ "$FLAVOUR" == cli ]]; then
    [[ -n "$DRY_RUN" || -x .build/deckhold-mac/deckhold-mac ]] || fail "missing .build/deckhold-mac/deckhold-mac — Guest/deckhold/build-mac.sh (make deckhold first, for the toolchain)"
    run cp .build/deckhold-mac/deckhold-mac "$STAGE/libexec/doz/deckhold-mac"
    run strip -x "$STAGE/libexec/doz/deckhold-mac"
fi
# 611: the licences a binary distribution must carry — LICENSE, NOTICE and every dependency's licence + NOTICE, from
# the exact checkouts this build used (it fails when a resolved package has no licence file).
run env CHECKOUTS="$BUILD_DIR/checkouts" Scripts/third-party-licences.sh "$STAGE/libexec/doz/licences"
# 675: the pinned kernel's provenance and GPL-2.0 source offer, beside it in every release: the written offer, the
# complete config, kata's patch and the script that reads the config out of the kernel.
run mkdir -p "$STAGE/libexec/doz/licences/kernel"
for f in Guest/kernel/PROVENANCE.md Guest/kernel/kernel.config Guest/sound-kernel/patches Guest/sound-kernel/extract-config.py; do
    run cp -R "$f" "$STAGE/libexec/doz/licences/kernel/"
done
# deckhold (guest and Mac): what each binary is built from (ghostty is MIT, in the licences above).
if [[ "$FLAVOUR" == cli ]]; then
    run mkdir -p "$STAGE/libexec/doz/licences/deckhold"
    run cp Guest/deckhold/PROVENANCE.md "$STAGE/libexec/doz/licences/deckhold/"
fi
# 667: a release that carries the sound kernel (GPL-2.0, built by Dozable) carries its source offer beside the other
# notices: the provenance and written offer, the recipe, the config fragment, the complete config and kata's patch.
if [[ -z "${NO_SOUND_KERNEL:-}" ]]; then
    run mkdir -p "$STAGE/libexec/doz/licences/sound-kernel"
    for f in PROVENANCE.md sound.conf sound.config build-in-guest.sh extract-config.py patches; do
        run cp -R "Guest/sound-kernel/$f" "$STAGE/libexec/doz/licences/sound-kernel/"
    done
fi

# 3. Sign: every Mac binary in the resources first (none today — the guest binaries are Linux ELF and
#    are left alone), then the executable with the virtualization entitlement.
if [[ -z "$DRY_RUN" ]]; then
    while IFS= read -r -d '' f; do
        if [[ "$(file -b "$f")" == Mach-O* ]]; then
            say "  signing $f (Mach-O)"
            codesign "${SIGN_ARGS[@]}" "$f"
        fi
    done < <(find "$STAGE/libexec/doz" -path '*.bundle/*' -type f -print0)
else
    say "  [dry-run] for each Mach-O file under $STAGE/libexec/doz/*.bundle: codesign ${SIGN_ARGS[*]} <file>"
fi
run codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$STAGE/libexec/doz/doz"
# deckhold-mac: the same identity, hardened runtime and timestamp — and NO entitlements (it needs none).
[[ "$FLAVOUR" == cli ]] && run codesign "${SIGN_ARGS[@]}" "$STAGE/libexec/doz/deckhold-mac"

# 4. Verify the signature and the entitlement.
run codesign --verify --strict --verbose=2 "$STAGE/libexec/doz/doz"
[[ "$FLAVOUR" == cli ]] && run codesign --verify --strict --verbose=2 "$STAGE/libexec/doz/deckhold-mac"
if [[ -z "$DRY_RUN" ]]; then
    ents="$(codesign -d --entitlements - --xml "$STAGE/libexec/doz/doz" 2>/dev/null || true)"
    for e in com.apple.security.virtualization com.apple.security.device.audio-input; do
        grep -q "$e" <<<"$ents" || fail "the signed doz does not carry $e"
    done
    say "  entitlements: com.apple.security.virtualization, com.apple.security.device.audio-input"
    if [[ -n "$SIGN_IDENTITY" ]]; then
        info="$(codesign -dv --verbose=4 "$STAGE/libexec/doz/doz" 2>&1)"
        grep -q "^Authority=$SIGN_IDENTITY\$" <<<"$info" || fail "the doz is not signed by $SIGN_IDENTITY"
        [[ -z "$TEAM_ID" ]] || grep -q "^TeamIdentifier=$TEAM_ID\$" <<<"$info" || fail "the doz's TeamIdentifier is not $TEAM_ID"
        grep -qE '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime.*\)' <<<"$info" || fail "the doz is not signed with the hardened runtime"
        grep -q '^Timestamp=' <<<"$info" || fail "the doz's signature has no secure timestamp"
        say "  signed: $SIGN_IDENTITY · hardened runtime · secure timestamp"
    fi
    # deckhold-mac: a Mach-O for this Mac, signed like doz (identity, runtime, timestamp) but with no entitlements, and
    # it runs (its usage line); the helper flavour never carries it.
    DHM="$STAGE/libexec/doz/deckhold-mac"
    if [[ "$FLAVOUR" == cli ]]; then
        [[ "$(file -b "$DHM")" == "Mach-O 64-bit executable arm64"* ]] || fail "deckhold-mac is not an arm64 Mach-O ($(file -b "$DHM"))"
        [[ -z "$(codesign -d --entitlements - --xml "$DHM" 2>/dev/null | grep -o '<key>' || true)" ]] || fail "deckhold-mac carries entitlements — it must carry none"
        if [[ -n "$SIGN_IDENTITY" ]]; then
            dinfo="$(codesign -dv --verbose=4 "$DHM" 2>&1)"
            grep -q "^Authority=$SIGN_IDENTITY\$" <<<"$dinfo" || fail "deckhold-mac is not signed by $SIGN_IDENTITY"
            grep -qE '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime.*\)' <<<"$dinfo" || fail "deckhold-mac is not signed with the hardened runtime"
            grep -q '^Timestamp=' <<<"$dinfo" || fail "deckhold-mac's signature has no secure timestamp"
        fi
        dusage="$("$DHM" 2>&1 || true)"
        grep -q "usage: deckhold serve" <<<"$dusage" || fail "the packed deckhold-mac does not run ($dusage)"
        say "  deckhold-mac: arm64 Mach-O, signed ($MODE), no entitlements, runs"
    else
        [[ ! -e "$DHM" ]] || fail "the helper carries deckhold-mac — it must not"
        say "  deckhold-mac: not in the helper (as it must be)"
    fi
    DOZ="$STAGE/libexec/doz/doz"
    [[ "$("$DOZ" --version)" == "$VERSION" ]] || fail "the packed doz says $("$DOZ" --version), not $VERSION"
    say "  doz --version: $VERSION"
    # 675: the pinned kernel, carried by both flavours, is the pin.
    [[ "$(shasum -a 256 "$STAGE/libexec/doz/kernels/$KERNEL_NAME" | cut -d' ' -f1)" == "$KERNEL_SHA" ]] || fail "the staged kernel's sha256 is not the pin"
    say "  kernel: kernels/$KERNEL_NAME, sha256 ${KERNEL_SHA:0:12}… (its source offer in licences/kernel/)"
    # 675: the flavour, as the binary itself says it (scratch folders; neither command touches a store or the network).
    chk="$(mktemp -d "${TMPDIR:-/tmp/}doz-release-check.XXXXXX")"
    if [[ "$FLAVOUR" == helper ]]; then
        # (the helper refuses doz upgrade before any feed is asked)
        up="$(env -u DOZ_TEST_HELPER_BUILD XDG_CONFIG_HOME="$chk/xdg" DOZ_STORE="$chk/store" "$DOZ" upgrade --check 2>&1 </dev/null || true)"
        ui="$(env -u DOZ_TEST_HELPER_BUILD XDG_CONFIG_HOME="$chk/xdg" DOZ_STORE="$chk/store" "$DOZ" ui 2>&1 </dev/null || true)"
        rm -rf "$chk"
        grep -q "is not in this build" <<<"$ui" || fail "the packed helper has a dashboard (doz ui: $ui)"
        grep -q "never updates itself" <<<"$up" || fail "the packed helper does not refuse doz upgrade ($up)"
        [[ -z "$(find "$STAGE/libexec/doz" -maxdepth 1 -name 'DozableKit_DozableWeb.bundle')" ]] || fail "the helper carries the dashboard's bundle"
        [[ ! -e "$STAGE/bin" && -s "$STAGE/README.md" ]] || fail "the helper's top folder is README.md and libexec/ only"
        say "  flavour: helper (no dashboard, no setup wizards, never updates itself)"
    else
        ui="$(env -u DOZ_TEST_HELPER_BUILD XDG_CONFIG_HOME="$chk/xdg" DOZ_STORE="$chk/store" "$DOZ" ui --help 2>&1 </dev/null || true)"
        rm -rf "$chk"
        grep -q -- "--lan" <<<"$ui" || fail "the packed CLI has no dashboard (doz ui --help: $ui)"
        [[ -d "$STAGE/libexec/doz/DozableKit_DozableWeb.bundle" ]] || fail "the CLI does not carry the dashboard's bundle"
        say "  flavour: cli"
    fi
    # The flavor, as the binary itself says it. Public: `doz account add x --chatgpt` is refused in argument
    # validation — before any store, host or browser is touched (a scratch store and settings dir all the same) —
    # and there is no sound kernel. Private: --chatgpt is in `doz account add --help` (never RUN: it would sign in).
    chk="$(mktemp -d "${TMPDIR:-/tmp/}doz-release-check.XXXXXX")"
    if [[ "$PUBLIC" == 1 ]]; then
        said="$(env -u DOZ_TEST_PUBLIC_BUILD XDG_CONFIG_HOME="$chk/xdg" DOZ_STORE="$chk/store" "$DOZ" account add x --chatgpt --store "$chk/store" 2>&1 </dev/null || true)"
        rm -rf "$chk"
        grep -q "does not include Dozable's own ChatGPT sign-in" <<<"$said" || fail "the packed doz is not the public flavor (doz account add --chatgpt did not refuse: $said)"
        [[ ! -e "$STAGE/libexec/doz/kernels/$SOUND_KERNEL_NAME" ]] || fail "a public build carries no sound kernel"
        say "  flavor: public (no ChatGPT sign-in of its own, no sound kernel)"
    else
        help="$(env -u DOZ_TEST_PUBLIC_BUILD XDG_CONFIG_HOME="$chk/xdg" "$DOZ" account add --help 2>&1 || true)"
        rm -rf "$chk"
        grep -q -- "--chatgpt" <<<"$help" || fail "PUBLIC=0 but the packed doz is the public flavor (no --chatgpt in doz account add --help)"
        say "  flavor: private"
    fi
    # 614: the official build — as the binary itself says it (`doz telemetry show` never sends; scratch folders).
    chk="$(mktemp -d "${TMPDIR:-/tmp/}doz-release-check.XXXXXX")"
    shown="$(env -u DOZ_TEST_GUARD XDG_CONFIG_HOME="$chk/xdg" DOZ_STORE="$chk/store" "$DOZ" telemetry show --json --store "$chk/store" 2>&1 </dev/null || true)"
    rm -rf "$chk"
    official="$(python3 -c 'import json,sys; print(str(json.loads(sys.stdin.read()).get("official")).lower())' <<<"$shown" 2>/dev/null || echo unreadable)"
    if [[ -n "$DOZ_CLOUD_PACKAGE" ]]; then
        [[ "$official" == true ]] || fail "DOZ_CLOUD_PACKAGE is set but the packed doz is not the official build (doz telemetry show --json: official=$official)"
        say "  official build: the statistics and sign-up package is in (doz telemetry show: official true)"
    else
        [[ "$official" == false ]] || fail "the packed doz should send nothing without DOZ_CLOUD_PACKAGE (official=$official)"
        say "  not the official build: no statistics or sign-up package (it sends nothing)"
    fi
    if [[ -z "${NO_SOUND_KERNEL:-}" ]]; then
        [[ "$(shasum -a 256 "$STAGE/libexec/doz/kernels/$SOUND_KERNEL_NAME" | cut -d' ' -f1)" == "$SOUND_KERNEL_SHA" ]] || fail "the staged sound kernel's sha256 is wrong"
        say "  sound kernel: kernels/$SOUND_KERNEL_NAME, sha256 ${SOUND_KERNEL_SHA:0:12}… (its source offer in licences/sound-kernel/)"
    fi
fi

# 5. Notarise (Developer ID with a profile only).
if [[ -n "$SIGN_IDENTITY" && -n "$NOTARY_PROFILE" ]]; then
    ZIP="$OUT/${NAME}-notarize.zip"
    run ditto -c -k --keepParent "$STAGE/libexec/doz" "$ZIP"
    if [[ -n "$DRY_RUN" ]]; then
        run xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json
        run Scripts/notary-ticket.sh "$STAGE/libexec/doz/doz" 600
    else
        say "  notarising (Apple's notary service; usually a few minutes)…"
        result="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json 2>"$OUT/notarytool.err" || true)"
        status="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("status",""))' <<<"$result" 2>/dev/null || true)"
        sid="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("id",""))' <<<"$result" 2>/dev/null || true)"
        if [[ "$status" != "Accepted" ]]; then
            [[ -n "$sid" ]] && xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" "$OUT/notarytool-$sid.json" >/dev/null 2>&1 || true
            fail "notarisation: ${status:-no answer} (submission ${sid:-?}; $(head -c 300 "$OUT/notarytool.err" 2>/dev/null)) — the log, when Apple gave one: $OUT/notarytool-$sid.json"
        fi
        rm -f "$OUT/notarytool.err"
        say "  notarised: Accepted (submission $sid)"
        # A bare CLI cannot be stapled, so spctl answers from a stapled ticket or its local cache ("Unnotarized
        # Developer ID" for a freshly notarised tool — 0.31.0). Gatekeeper's first run looks the ticket up online by
        # CDHash: prove exactly that (Scripts/notary-ticket.sh).
        Scripts/notary-ticket.sh "$STAGE/libexec/doz/doz" 600 >/dev/null \
            || fail "Apple's ticket service has no ticket for the notarised doz (submission $sid) after 10 minutes"
        if [[ "$FLAVOUR" == cli ]]; then
            Scripts/notary-ticket.sh "$STAGE/libexec/doz/deckhold-mac" 600 >/dev/null \
                || fail "Apple's ticket service has no ticket for the notarised deckhold-mac (submission $sid) after 10 minutes"
        fi
        say "  notary ticket: published for each binary (what Gatekeeper checks on first run)"
    fi
    run rm -f "$ZIP"
    say "  ${DRY_RUN:+[dry-run] would be }notarised (a command-line tool cannot be stapled: Gatekeeper checks its ticket online on first run)"
elif [[ -n "$SIGN_IDENTITY" ]]; then
    say "note: signed with $SIGN_IDENTITY but NOT notarised — set NOTARY_PROFILE (see Makefile.config.example)"
else
    say "note: signed ad hoc (no SIGN_IDENTITY in Makefile.config) — fine for Homebrew, not for a download outside it"
fi

# 6. Pack + checksum (no macOS metadata files in the archive).
run env COPYFILE_DISABLE=1 tar --no-mac-metadata -C "$OUT/stage" -czf "$TARBALL" "$TOP"
# H1/H1b: the symbols, published beside the tarball (a zip of the dSYM bundle).
run rm -f "$DSYM_ZIP"
run ditto -c -k --keepParent "$OUT/stage/$NAME.dSYM" "$DSYM_ZIP"
if [[ -z "$DRY_RUN" ]]; then
    # 611: what people install is the TARBALL — unpack it afresh and check what comes out of it.
    unpack="$(mktemp -d "${TMPDIR:-/tmp/}doz-release-unpack.XXXXXX")"
    tar -xzf "$TARBALL" -C "$unpack"
    packed="$unpack/$TOP"
    codesign --verify --strict "$packed/libexec/doz/doz" || fail "the doz unpacked from the tarball does not verify"
    [[ "$("$packed/libexec/doz/doz" --version)" == "$VERSION" ]] || fail "the doz unpacked from the tarball says $("$packed/libexec/doz/doz" --version), not $VERSION"
    if [[ "$FLAVOUR" == cli ]]; then
        [[ -L "$packed/bin/doz" ]] || fail "bin/doz in the tarball is not a link"
        [[ "$("$packed/bin/doz" --version)" == "$VERSION" ]] || fail "bin/doz in the tarball does not run the packed doz"
    fi
    # 675 (H8): the layout contract — docs/manual/33-bundling-doz-in-an-app.md. Checked on what people download.
    for f in doz VERSION RELEASE DozableKit_DozableKit.bundle/deckhold "kernels/$KERNEL_NAME" licences/kernel/PROVENANCE.md licences/kernel/kernel.config; do
        [[ -e "$packed/libexec/doz/$f" ]] || fail "the tarball has no libexec/doz/$f (the layout contract)"
    done
    [[ "$(cat "$packed/libexec/doz/RELEASE")" == "$FLAVOR" ]] || fail "the tarball's RELEASE is not $FLAVOR"
    [[ "$FLAVOUR" == cli ]] || [[ -s "$packed/README.md" ]] || fail "the helper tarball has no README.md"
    for f in LICENSE NOTICE THIRD-PARTY-LICENSES.txt; do [[ -s "$packed/libexec/doz/licences/$f" ]] || fail "the tarball has no licences/$f"; done
    if [[ -z "${NO_SOUND_KERNEL:-}" ]]; then   # 667: the sound kernel's source offer goes with it
        for f in PROVENANCE.md sound.conf sound.config build-in-guest.sh; do
            [[ -s "$packed/libexec/doz/licences/sound-kernel/$f" ]] || fail "the tarball carries the sound kernel but not licences/sound-kernel/$f (its source offer)"
        done
    fi
    installed="$(du -sk "$packed" | cut -f1)"
    rm -rf "$unpack"
    say "  from the tarball: codesign --verify --strict ok, doz --version $VERSION, the layout contract holds"
    (cd "$OUT" && shasum -a 256 "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256")
    say "release: $TARBALL"
    say "         sha256 $(cut -d' ' -f1 "$TARBALL.sha256")  ($(( $(stat -f %z "$TARBALL") / 1048576 )) MiB compressed, $(( installed / 1024 )) MiB installed)"
    say "         symbols: $DSYM_ZIP ($(( $(stat -f %z "$DSYM_ZIP") / 1048576 )) MiB)"
else
    say "  [dry-run] (cd $OUT && shasum -a 256 ${NAME}.tar.gz > ${NAME}.tar.gz.sha256)"
fi
