#!/usr/bin/env bash
# assemble-app.sh — the menu bar app's bundle, Dozable.app, from the SwiftPM executable `Dozable` and the templates in
# Resources/MenuBar/. It does NOT sign: `make app` signs ad hoc, Scripts/release.sh with the Developer ID (hardened
# runtime, timestamp, no entitlements, never --deep).
#
#   Scripts/assemble-app.sh --exe .build/debug/Dozable --version 0.50.7 --out .build/debug
#     → .build/debug/Dozable.app/Contents/{Info.plist, PkgInfo, MacOS/Dozable, Resources/,
#                                          Library/LaunchAgents/com.dozable.app.daemon.plist}
#
# The bundle is assembled beside its place and renamed into it (an old one is removed first). Every Info.plist value the
# release depends on is checked with plutil -extract — the identifier, the executable, LSUIElement, the minimum macOS
# (the package's platform) and both versions — so a wrong template stops here, not after notarisation. The login agent's
# plist (Start at Login: SMAppService.agent) is copied as is and checked by Scripts/check-agent-plist.py — exactly the
# design's keys, its label doz's reserved one. It is sealed by the signature that follows.
set -euo pipefail

PACKAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$PACKAGE/Resources/MenuBar/Info.plist"
AGENT="$PACKAGE/Resources/MenuBar/com.dozable.app.daemon.plist"
EXE=""; VERSION=""; OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --exe) EXE="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) printf 'x assemble-app: unknown argument %s\n' "$1" >&2; exit 64 ;;
    esac
done
fail() { printf 'x assemble-app: %s\n' "$*" >&2; exit 1; }
[[ -n "$EXE" && -n "$VERSION" && -n "$OUT" ]] || fail "usage: assemble-app.sh --exe PATH --version X.Y.Z --out DIR"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || fail "--version must be semver, not '$VERSION'"
[[ -f "$EXE" && -x "$EXE" ]] || fail "no executable at $EXE (swift build --product Dozable)"
[[ "$(file -b "$EXE")" == "Mach-O 64-bit executable arm64"* ]] || fail "$EXE is not an arm64 Mach-O executable ($(file -b "$EXE"))"
[[ -f "$TEMPLATE" ]] || fail "missing $TEMPLATE"
[[ -f "$AGENT" ]] || fail "missing $AGENT"
mkdir -p "$OUT"

APP="$OUT/Dozable.app"
TMP="$OUT/.Dozable.app.assemble-$$"
rm -rf "$TMP"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Resources" "$TMP/Contents/Library/LaunchAgents"
cp "$EXE" "$TMP/Contents/MacOS/Dozable"
chmod 755 "$TMP/Contents/MacOS/Dozable"
sed "s/__VERSION__/$VERSION/g" "$TEMPLATE" > "$TMP/Contents/Info.plist"
printf 'APPL????' > "$TMP/Contents/PkgInfo"
cp "$AGENT" "$TMP/Contents/Library/LaunchAgents/com.dozable.app.daemon.plist"
chmod 644 "$TMP/Contents/Library/LaunchAgents/com.dozable.app.daemon.plist"

# The values, as macOS will read them.
PL="$TMP/Contents/Info.plist"
plutil -lint -s "$PL" || fail "Info.plist does not parse"
want() {   # want KEY VALUE — plutil's raw value of KEY must be VALUE
    local got
    got="$(plutil -extract "$1" raw -o - "$PL" 2>/dev/null || true)"
    [[ "$got" == "$2" ]] || fail "Info.plist $1 is '$got', not '$2'"
}
want CFBundleIdentifier com.dozable.app
want CFBundleExecutable Dozable
want CFBundleName Dozable
want CFBundlePackageType APPL
want CFBundleShortVersionString "$VERSION"
want CFBundleVersion "$VERSION"
want LSUIElement true
want LSMinimumSystemVersion 26.0
grep -q '__' "$PL" && fail "Info.plist still carries a placeholder"
"$PACKAGE/Scripts/check-agent-plist.py" "$TMP/Contents/Library/LaunchAgents/com.dozable.app.daemon.plist" >/dev/null \
    || fail "$("$PACKAGE/Scripts/check-agent-plist.py" "$TMP/Contents/Library/LaunchAgents/com.dozable.app.daemon.plist")"

rm -rf "$APP"
mv "$TMP" "$APP"
trap - EXIT
printf 'assembled %s (%s)\n' "$APP" "$VERSION"
