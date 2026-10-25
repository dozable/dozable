#!/bin/bash
# Run deckhold's snapshot check (snapshot-check.c) on the Mac: deckhold's own code against libghostty-vt
# built for aarch64-macos from the SAME pinned ghostty commit and Zig as the guest binary (build.sh's
# toolchain in .tools/, run that first — `make deckhold`). Nothing here goes into the guest binary.
#
# Also its OSC 7501 consumer (status-check.c, 612): the query answered, the records' rules and limits, invalid
# input discarded, the same state however the reads are cut — run first, it takes a second.
#
# And its GRID (grid-check.c, 648): the screen as cells — every row's text the holder's own, colours, flags, the
# cursor, the gen, the limits, the announcement on the wire, a seeded fuzz.
#
# Usage: Guest/deckhold/test/run.sh [fuzz-iterations] [seed]      (make deckhold-snapshot-check)
#        ONLY=status Guest/deckhold/test/run.sh                    (make deckhold-status-check)
#        ONLY=grid Guest/deckhold/test/run.sh [fuzz-iterations]    (make deckhold-grid-check)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/../../.." && pwd)"
TOOLS="${DECKHOLD_TOOLS:-$PKG/.tools}"
ZIG_DIR="$TOOLS/zig-0.16.0"
SRC="$TOOLS/ghostty-src"
VT="$TOOLS/ghostty-vt-macos"
export ZIG_GLOBAL_CACHE_DIR="$TOOLS/zig-cache"
export PATH="$ZIG_DIR:$PATH"
[ -x "$ZIG_DIR/zig" ] && [ -d "$SRC/.git" ] || { echo "no pinned toolchain in $TOOLS — run make deckhold first" >&2; exit 2; }
GHOSTTY_SHA="$(sed -n 's/^GHOSTTY_SHA="\(.*\)"$/\1/p' "$HERE/../build.sh")"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$GHOSTTY_SHA" ] || { echo "ghostty-src is not at the pinned $GHOSTTY_SHA — run make deckhold" >&2; exit 2; }
# The Mac build's xcframework (headers + a fat static library) is what is used. (On a macOS 27 SDK the
# step after it — Zig's own libc++ for the plain .a — fails; the xcframework is complete before that.)
XC="$VT/lib/ghostty-vt.xcframework/macos-arm64_x86_64"
if [ ! -f "$XC/libghostty-vt.a" ]; then
  echo "==> building libghostty-vt for the Mac (once; a few minutes)"
  ( cd "$SRC" && zig build -Demit-lib-vt=true -Doptimize=ReleaseFast --prefix "$VT" -j8 ) || true
  [ -f "$XC/libghostty-vt.a" ] || { echo "no $XC/libghostty-vt.a — the Mac build of libghostty-vt failed" >&2; exit 2; }
fi
OUT="$HERE/out"
mkdir -p "$OUT"
# The Mac's own clang and libc++: this harness runs here, nothing of it goes into the guest binary.
if [ "${ONLY:-}" = grid ]; then
  cc -O1 -g -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -I"$XC/Headers" \
    "$HERE/grid-check.c" "$XC/libghostty-vt.a" -lc++ -o "$OUT/grid-check"
  exec "$OUT/grid-check" "$@"
fi
cc -O1 -g -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -I"$XC/Headers" \
  "$HERE/status-check.c" "$XC/libghostty-vt.a" -lc++ -o "$OUT/status-check"
"$OUT/status-check"
[ "${ONLY:-}" = status ] && exit 0
cc -O1 -g -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -I"$XC/Headers" \
  "$HERE/snapshot-check.c" "$XC/libghostty-vt.a" -lc++ -o "$OUT/snapshot-check"
"$OUT/snapshot-check" "$@"
