#!/bin/bash
# Build `dozchat` — the chat-room member every sandbox carries — as ONE static aarch64-linux-musl binary:
# Guest/dozchat/out/dozchat. libc only (no third-party code), with the SAME pinned Zig as the other guest helpers. Unlike
# doznet's build this one fetches that Zig itself when it is missing (the same URL and sha256 as Guest/deckhold/build.sh),
# so it needs nothing else — no ghostty clone.
#
# The COMMITTED binary is Sources/DozableKit/Resources/dozchat; `make dozchat` runs this, installs the result there and
# refreshes PROVENANCE.md; `make dozchat-verify` rebuilds from scratch and compares the bytes.
#
# Usage: Guest/dozchat/build.sh    (FORCE=1 rebuilds; DECKHOLD_TOOLS=<dir> as the other guest builds)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
TOOLS="${DECKHOLD_TOOLS:-$PKG/.tools}"

ZIG_VERSION="0.16.0"
ZIG_TARBALL="zig-aarch64-macos-$ZIG_VERSION.tar.xz"
ZIG_URL="https://ziglang.org/download/$ZIG_VERSION/$ZIG_TARBALL"
ZIG_SHA256="b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"
ZIG_DIR="$TOOLS/zig-$ZIG_VERSION"
ZIG="$ZIG_DIR/zig"

# The pins must stay Guest/deckhold/build.sh's (one toolchain for every guest helper).
[ "$(sed -n 's/^ZIG_SHA256="\(.*\)"$/\1/p' "$PKG/Guest/deckhold/build.sh")" = "$ZIG_SHA256" ] \
  || { echo "dozchat: the Zig pin differs from Guest/deckhold/build.sh's" >&2; exit 2; }

mkdir -p "$TOOLS"
if [ ! -x "$ZIG" ]; then
  echo "==> downloading Zig $ZIG_VERSION"
  tmp="$TOOLS/.dozchat-zig.$$"
  rm -rf "$tmp" && mkdir -p "$tmp"
  curl -fsSL --max-time 600 -o "$tmp/$ZIG_TARBALL" "$ZIG_URL"
  GOT="$(shasum -a 256 "$tmp/$ZIG_TARBALL" | awk '{print $1}')"
  [ "$GOT" = "$ZIG_SHA256" ] || { echo "Zig tarball sha256 mismatch: $GOT" >&2; rm -rf "$tmp"; exit 1; }
  tar -xJf "$tmp/$ZIG_TARBALL" -C "$tmp"
  [ -x "$ZIG" ] || mv "$tmp/zig-aarch64-macos-$ZIG_VERSION" "$ZIG_DIR"
  rm -rf "$tmp"
fi
export ZIG_GLOBAL_CACHE_DIR="$TOOLS/zig-cache" ZIG_LOCAL_CACHE_DIR="$TOOLS/zig-cache-local"

mkdir -p "$HERE/out"
BIN="$HERE/out/dozchat"
if [ "${FORCE:-0}" = 1 ] || [ ! -x "$BIN" ] || [ "$HERE/dozchat.c" -nt "$BIN" ] || [ "$0" -nt "$BIN" ]; then
  echo "==> compiling dozchat (aarch64-linux-musl, static)"
  # Run from this folder with a relative source path, so no absolute path of this checkout can reach the binary.
  ( cd "$HERE" && "$ZIG" cc -target aarch64-linux-musl -static -O2 -s -std=c11 \
      -Wall -Wextra -Wformat=2 -Wshadow -Wvla -Werror \
      -fstack-protector-strong -ftrivial-auto-var-init=zero \
      dozchat.c -o out/dozchat.new )
  mv -f "$HERE/out/dozchat.new" "$BIN"
  echo "==> $BIN ($(wc -c < "$BIN" | tr -d ' ') bytes)"
fi
echo "$BIN"
