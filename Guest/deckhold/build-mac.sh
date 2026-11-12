#!/bin/bash
# Build `deckhold-mac` — the same PTY holder as the guest's (deckhold.c, unchanged), for THIS Mac: sessions held on the
# Mac itself. Output: .build/deckhold-mac/deckhold-mac (arm64, NOT committed — a Mach-O is signed per release, and the
# Mac's clang does not promise the same bytes across Xcode versions).
#
# Inputs (the same pins as build.sh — run `make deckhold` once first; nothing is downloaded here):
#   GHOSTTY_SHA   build.sh's — the Mac's libghostty-vt is built from the SAME commit as the guest's.
#   libghostty-vt the macOS xcframework's fat static library ($TOOLS/ghostty-vt-macos/lib/ghostty-vt.xcframework/
#                 macos-arm64_x86_64/libghostty-vt.a), as Guest/deckhold/test/run.sh links it. (On a macOS 27 SDK the
#                 step after the xcframework — Zig's own libc++ for the plain .a — fails; the xcframework is complete
#                 before it, so a failed `zig build` exit is tolerated when the xcframework is there.)
#   the compiler  the Mac's own clang (`cc`), arm64, -mmacosx-version-min = Package.swift's platform.
#
# Usage: Guest/deckhold/build-mac.sh    (FORCE=1 rebuilds; DECKHOLD_TOOLS=<dir> as build.sh)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
TOOLS="${DECKHOLD_TOOLS:-$PKG/.tools}"
ZIG_DIR="$TOOLS/zig-0.16.0"
SRC="$TOOLS/ghostty-src"
VT="$TOOLS/ghostty-vt-macos"
XC="$VT/lib/ghostty-vt.xcframework/macos-arm64_x86_64"
OUT="$PKG/.build/deckhold-mac"
export ZIG_GLOBAL_CACHE_DIR="$TOOLS/zig-cache"
export PATH="$ZIG_DIR:$PATH"

GHOSTTY_SHA="$(sed -n 's/^GHOSTTY_SHA="\(.*\)"$/\1/p' "$HERE/build.sh")"
MIN_MACOS="$(sed -n 's/.*platforms: \[\.macOS("\([0-9.]*\)")\].*/\1/p' "$PKG/Package.swift")"
[ -n "$GHOSTTY_SHA" ] && [ -n "$MIN_MACOS" ] || { echo "could not read the ghostty pin or the macOS minimum" >&2; exit 2; }
[ -x "$ZIG_DIR/zig" ] && [ -d "$SRC/.git" ] || { echo "no pinned toolchain in $TOOLS — run make deckhold first" >&2; exit 2; }
[ "$(git -C "$SRC" rev-parse HEAD)" = "$GHOSTTY_SHA" ] || { echo "ghostty-src is not at the pinned $GHOSTTY_SHA — run make deckhold" >&2; exit 2; }

if [ ! -f "$XC/libghostty-vt.a" ]; then
  echo "==> building libghostty-vt for the Mac (once; a few minutes)"
  ( cd "$SRC" && zig build -Demit-lib-vt=true -Doptimize=ReleaseFast --prefix "$VT" -j8 ) || true
  [ -f "$XC/libghostty-vt.a" ] || { echo "no $XC/libghostty-vt.a — the Mac build of libghostty-vt failed" >&2; exit 2; }
fi

mkdir -p "$OUT"
BIN="$OUT/deckhold-mac"
if [ "${FORCE:-0}" = 1 ] || [ ! -x "$BIN" ] || [ "$HERE/deckhold.c" -nt "$BIN" ] || [ "$XC/libghostty-vt.a" -nt "$BIN" ]; then
  echo "==> compiling deckhold-mac (arm64, macOS $MIN_MACOS)"
  # Into a scratch folder under its own name (the linker's ad hoc signature takes the file name as its identifier),
  # then renamed into place.
  mkdir -p "$OUT/new"
  cc -O2 -arch arm64 -mmacosx-version-min="$MIN_MACOS" -Wall -Wextra -Wno-unused-parameter \
    -I"$XC/Headers" "$HERE/deckhold.c" "$XC/libghostty-vt.a" -lc++ -o "$OUT/new/deckhold-mac"
  mv -f "$OUT/new/deckhold-mac" "$BIN"
  echo "==> $BIN ($(wc -c < "$BIN" | tr -d ' ') bytes; ghostty $GHOSTTY_SHA; $(cc --version | head -1))"
fi
echo "$BIN"
