#!/bin/bash
# Build `dozchat-mac` — the chat-room member (dozchat.c, the same file as the guest's) for THIS Mac: a fenced session's
# `dozchat` (its shim in <session>/etc/bin execs it). Output: .build/dozchat-mac/dozchat-mac (arm64, NOT committed — a
# Mach-O is signed per release, and the Mac's clang does not promise the same bytes across Xcode versions).
#
# Needs only the Mac's own clang (`cc`); -mmacosx-version-min = Package.swift's platform. Nothing is downloaded.
# Usage: Guest/dozchat/build-mac.sh    (FORCE=1 rebuilds)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
OUT="$PKG/.build/dozchat-mac"
MIN_MACOS="$(sed -n 's/.*platforms: \[\.macOS("\([0-9.]*\)")\].*/\1/p' "$PKG/Package.swift")"
[ -n "$MIN_MACOS" ] || { echo "could not read the macOS minimum from Package.swift" >&2; exit 2; }

mkdir -p "$OUT"
BIN="$OUT/dozchat-mac"
if [ "${FORCE:-0}" = 1 ] || [ ! -x "$BIN" ] || [ "$HERE/dozchat.c" -nt "$BIN" ] || [ "$0" -nt "$BIN" ]; then
  echo "==> compiling dozchat-mac (arm64, macOS $MIN_MACOS)"
  # Into a scratch folder under its own name (the linker's ad hoc signature takes the file name as its identifier),
  # then renamed into place.
  mkdir -p "$OUT/new"
  cc -O2 -arch arm64 -mmacosx-version-min="$MIN_MACOS" -std=c11 \
    -Wall -Wextra -Wformat=2 -Wshadow -Wvla -Werror \
    -fstack-protector-strong -ftrivial-auto-var-init=zero -D_FORTIFY_SOURCE=2 \
    "$HERE/dozchat.c" -o "$OUT/new/dozchat-mac"
  mv -f "$OUT/new/dozchat-mac" "$BIN"
  echo "==> $BIN ($(wc -c < "$BIN" | tr -d ' ') bytes; $(cc --version | head -1))"
fi
echo "$BIN"
