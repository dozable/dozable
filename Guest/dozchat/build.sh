#!/bin/bash
# Build `dozchat` — the chat-room member every sandbox carries — as ONE static aarch64-linux-musl binary:
# Guest/dozchat/out/dozchat. libc only (no third-party code), with the SAME pinned Zig as the other guest helpers. Unlike
# doznet's build this one fetches that Zig itself when it is missing (the same URL and sha256 as Guest/deckhold/build.sh),
# so it needs nothing else — no ghostty clone.
#
# The COMMITTED binary is Sources/DozableKit/Resources/dozchat; `make dozchat` runs this, installs the result there and
# refreshes PROVENANCE.md; `make dozchat-verify` rebuilds from scratch and compares the bytes.
#
# Usage: Guest/dozchat/build.sh           (FORCE=1 rebuilds; DECKHOLD_TOOLS=<dir> as the other guest builds)
#        Guest/dozchat/build.sh x86_64    the same source, flags and Zig for x86_64-linux-musl, for agents OUTSIDE Dozable
#                                         on an x86_64 Linux machine: .build/dozchat-linux-x86_64/dozchat — never committed,
#                                         never put in a sandbox (they are arm64); `make release` attaches it to the release
#                                         as dozchat-linux-x86_64 (+ .sha256).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
TOOLS="${DECKHOLD_TOOLS:-$PKG/.tools}"

ZIG_VERSION="0.16.0"
# The Zig for THIS machine: the Mac's (Guest/deckhold/build.sh's pin), or — for CI's x86_64 Linux runner, which builds
# and runs the x86_64 binary — Zig's own x86_64-linux tarball of the same version (sha256 from ziglang.org/download).
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) HOST=aarch64-macos; ZIG_SHA256="b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"
    # The Mac's pin must stay Guest/deckhold/build.sh's (one toolchain for every guest helper).
    [ "$(sed -n 's/^ZIG_SHA256="\(.*\)"$/\1/p' "$PKG/Guest/deckhold/build.sh")" = "$ZIG_SHA256" ] \
      || { echo "dozchat: the Zig pin differs from Guest/deckhold/build.sh's" >&2; exit 2; } ;;
  Linux-x86_64) HOST=x86_64-linux; ZIG_SHA256="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" ;;
  *) echo "dozchat: no pinned Zig for $(uname -s) $(uname -m)" >&2; exit 2 ;;
esac
ZIG_TARBALL="zig-$HOST-$ZIG_VERSION.tar.xz"
ZIG_URL="https://ziglang.org/download/$ZIG_VERSION/$ZIG_TARBALL"
ZIG_DIR="$TOOLS/zig-$ZIG_VERSION"
[ "$HOST" = aarch64-macos ] || ZIG_DIR="$TOOLS/zig-$HOST-$ZIG_VERSION"
ZIG="$ZIG_DIR/zig"
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }

mkdir -p "$TOOLS"
if [ ! -x "$ZIG" ]; then
  echo "==> downloading Zig $ZIG_VERSION"
  tmp="$TOOLS/.dozchat-zig.$$"
  rm -rf "$tmp" && mkdir -p "$tmp"
  curl -fsSL --max-time 600 -o "$tmp/$ZIG_TARBALL" "$ZIG_URL"
  GOT="$(sha256 "$tmp/$ZIG_TARBALL")"
  [ "$GOT" = "$ZIG_SHA256" ] || { echo "Zig tarball sha256 mismatch: $GOT" >&2; rm -rf "$tmp"; exit 1; }
  tar -xJf "$tmp/$ZIG_TARBALL" -C "$tmp"
  [ -x "$ZIG" ] || mv "$tmp/zig-$HOST-$ZIG_VERSION" "$ZIG_DIR"
  rm -rf "$tmp"
fi
export ZIG_GLOBAL_CACHE_DIR="$TOOLS/zig-cache" ZIG_LOCAL_CACHE_DIR="$TOOLS/zig-cache-local"

case "${1:-aarch64}" in
  aarch64) TARGET=aarch64-linux-musl; OUTDIR="$HERE/out" ;;
  x86_64)  TARGET=x86_64-linux-musl;  OUTDIR="$PKG/.build/dozchat-linux-x86_64" ;;
  *) echo "usage: $0 [aarch64|x86_64]" >&2; exit 2 ;;
esac
mkdir -p "$OUTDIR"
BIN="$OUTDIR/dozchat"
if [ "${FORCE:-0}" = 1 ] || [ ! -x "$BIN" ] || [ "$HERE/dozchat.c" -nt "$BIN" ] || [ "$0" -nt "$BIN" ]; then
  echo "==> compiling dozchat ($TARGET, static)"
  # Run from this folder with a relative source path, so no absolute path of this checkout can reach the binary.
  ( cd "$HERE" && "$ZIG" cc -target "$TARGET" -static -O2 -s -std=c11 \
      -Wall -Wextra -Wformat=2 -Wshadow -Wvla -Werror \
      -fstack-protector-strong -ftrivial-auto-var-init=zero \
      dozchat.c -o "$OUTDIR/dozchat.new" )
  mv -f "$OUTDIR/dozchat.new" "$BIN"
  echo "==> $BIN ($(wc -c < "$BIN" | tr -d ' ') bytes)"
fi
echo "$BIN"
