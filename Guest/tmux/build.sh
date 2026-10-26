#!/bin/bash
# Build tmux as ONE static aarch64-linux-musl binary for the guest: Guest/tmux/out/tmux — the tools layer copies
# it to /usr/local/lib/doz/bin/tmux when sessions.tmux is on, so every base runs the same tmux (Debian 12 and the
# images built on it ship 3.3a, Ubuntu 24.04 and Alpine 3.20 ship 3.4: probes/658-* in the workspace).
#
# The COMMITTED binary is Sources/DozableKit/Resources/tmux (the pin, like deckhold and dozview); `make tmux` runs
# this, installs the result there and refreshes PROVENANCE.md; `make tmux-verify` rebuilds from scratch and checks
# the committed bytes match.
#
# Inputs (all pinned here; nothing is installed system-wide, nothing comes from Homebrew):
#   Zig        0.16.0 — the SAME pinned toolchain as deckhold (Guest/deckhold/build.sh downloads it, checksum-verified,
#              into $TOOLS/zig-0.16.0 on first use). It is the C compiler, the archiver and musl libc.
#   tmux       3.8      https://github.com/tmux/tmux/releases/download/3.8/tmux-3.8.tar.gz
#   libevent   2.1.13-stable   https://github.com/libevent/libevent/releases/download/release-2.1.13-stable/…
#   ncurses    6.6      https://ftp.gnu.org/gnu/ncurses/ncurses-6.6.tar.gz
#              each tarball's sha256 pinned below (tmux's and libevent's equal the digests GitHub publishes for the
#              release assets; see PROVENANCE.md). A mismatch stops the build.
#   Network    first run only: the three tarballs (~5 MB) into $TOOLS/tmux-src (gitignored).
# What is built: ncurses (static, the C library only — no programs, no database, no C++), reading terminfo from
# /etc/terminfo, /lib/terminfo, /usr/share/terminfo and /usr/lib/terminfo (Alpine keeps xterm-256color in the first,
# Debian and Ubuntu in the third); libevent (static, no TLS); tmux linked statically against both and musl.
# Reproducible: every compile maps the build directory to "." (-ffile-prefix-map), the binary is stripped, and no
# step records a time (autoconf and the three makefiles add none; checked by `make tmux-verify`).
#
# Usage: Guest/tmux/build.sh    (FORCE=1 rebuilds everything from the tarballs)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
TOOLS="${DECKHOLD_TOOLS:-$PKG/.tools}"
ZIG="$TOOLS/zig-0.16.0/zig"
OUT="$HERE/out"

TMUX_VERSION="3.8"
TMUX_URL="https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/tmux-$TMUX_VERSION.tar.gz"
TMUX_SHA256="e79c699c7e949dccd0a4a125e17b8d1261e311b16979dbc8eb34542f3966d82e"
LIBEVENT_VERSION="2.1.13-stable"
LIBEVENT_URL="https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION/libevent-$LIBEVENT_VERSION.tar.gz"
LIBEVENT_SHA256="f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c"
NCURSES_VERSION="6.6"
NCURSES_URL="https://ftp.gnu.org/gnu/ncurses/ncurses-$NCURSES_VERSION.tar.gz"
NCURSES_SHA256="355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11"

TARGET="aarch64-linux-musl"
SRC="$TOOLS/tmux-src"            # the verified tarballs
WORK="$TOOLS/tmux-build"         # unpacked + built (the path every compile maps to ".")
PREFIX="$WORK/prefix"            # ncurses + libevent, installed for tmux's configure

if [ ! -x "$ZIG" ]; then
  echo "==> the pinned Zig is missing — running Guest/deckhold/build.sh once downloads it (checksum-verified)"
  exit 1
fi
export ZIG_GLOBAL_CACHE_DIR="$TOOLS/zig-cache" ZIG_LOCAL_CACHE_DIR="$TOOLS/zig-cache-local"
mkdir -p "$SRC" "$OUT"

fetch() {    # fetch NAME URL SHA256 → $SRC/NAME, verified
  local f="$SRC/$1"
  if [ -f "$f" ] && [ "$(shasum -a 256 "$f" | awk '{print $1}')" = "$3" ]; then return 0; fi
  echo "==> downloading $1"
  curl -fsSL --retry 3 -o "$f.part" "$2"
  local got; got="$(shasum -a 256 "$f.part" | awk '{print $1}')"
  if [ "$got" != "$3" ]; then echo "$1: sha256 mismatch: $got (pinned $3)" >&2; rm -f "$f.part"; exit 1; fi
  mv "$f.part" "$f"
}
fetch "tmux-$TMUX_VERSION.tar.gz" "$TMUX_URL" "$TMUX_SHA256"
fetch "libevent-$LIBEVENT_VERSION.tar.gz" "$LIBEVENT_URL" "$LIBEVENT_SHA256"
fetch "ncurses-$NCURSES_VERSION.tar.gz" "$NCURSES_URL" "$NCURSES_SHA256"

if [ "${FORCE:-0}" != 1 ] && [ -x "$OUT/tmux" ] && [ "$OUT/tmux" -nt "$HERE/build.sh" ]; then
  echo "$OUT/tmux"; exit 0
fi

# Always from clean sources: a configure cache or an object from another run must not reach the binary.
rm -rf "$WORK"
mkdir -p "$WORK" "$PREFIX"
for t in "tmux-$TMUX_VERSION" "libevent-$LIBEVENT_VERSION" "ncurses-$NCURSES_VERSION"; do
  tar -xzf "$SRC/$t.tar.gz" -C "$WORK"
done

# The cross toolchain: zig for the guest, zig (native) for the helper programs ncurses runs while it builds.
export CC="$ZIG cc -target $TARGET" AR="$ZIG ar" RANLIB="$ZIG ranlib"
export BUILD_CC="$ZIG cc"
export CFLAGS="-O2 -ffile-prefix-map=$WORK=."
export CPPFLAGS="-I$PREFIX/include -I$PREFIX/include/ncursesw"
export LDFLAGS="-L$PREFIX/lib -static -s"
export PKG_CONFIG=false SOURCE_DATE_EPOCH=0
HOSTFLAGS=(--build=aarch64-apple-darwin --host="$TARGET" --prefix="$PREFIX")

echo "==> ncurses $NCURSES_VERSION"
( cd "$WORK/ncurses-$NCURSES_VERSION" && ./configure "${HOSTFLAGS[@]}" \
    --without-shared --with-normal --without-debug --without-profile --without-cxx --without-cxx-binding \
    --without-ada --without-progs --without-tests --without-manpages --without-pkg-config --disable-db-install \
    --enable-widec --disable-stripping --without-gpm --without-dlsym \
    --with-terminfo-dirs=/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo \
    --with-default-terminfo-dir=/usr/share/terminfo >"$WORK/ncurses.log" 2>&1 \
  && make -j8 libs >>"$WORK/ncurses.log" 2>&1 && make install.libs install.includes >>"$WORK/ncurses.log" 2>&1 ) \
  || { echo "ncurses failed — see $WORK/ncurses.log" >&2; tail -30 "$WORK/ncurses.log" >&2; exit 1; }

echo "==> libevent $LIBEVENT_VERSION"
( cd "$WORK/libevent-$LIBEVENT_VERSION" && ./configure "${HOSTFLAGS[@]}" \
    --disable-shared --enable-static --disable-openssl --disable-mbedtls --disable-samples \
    --disable-libevent-regress --disable-debug-mode --disable-dependency-tracking >"$WORK/libevent.log" 2>&1 \
  && make -j8 >>"$WORK/libevent.log" 2>&1 && make install >>"$WORK/libevent.log" 2>&1 ) \
  || { echo "libevent failed — see $WORK/libevent.log" >&2; tail -30 "$WORK/libevent.log" >&2; exit 1; }

echo "==> tmux $TMUX_VERSION"
( cd "$WORK/tmux-$TMUX_VERSION" && ./configure "${HOSTFLAGS[@]}" --enable-static --disable-dependency-tracking \
    LIBEVENT_CORE_CFLAGS="-I$PREFIX/include" LIBEVENT_CORE_LIBS="-L$PREFIX/lib -levent_core" \
    LIBEVENT_CFLAGS="-I$PREFIX/include" LIBEVENT_LIBS="-L$PREFIX/lib -levent" \
    LIBTINFO_CFLAGS="-I$PREFIX/include/ncursesw" LIBTINFO_LIBS="-L$PREFIX/lib -lncursesw" \
    LIBNCURSES_CFLAGS="-I$PREFIX/include/ncursesw" LIBNCURSES_LIBS="-L$PREFIX/lib -lncursesw" \
    >"$WORK/tmux.log" 2>&1 \
  && make -j8 >>"$WORK/tmux.log" 2>&1 ) \
  || { echo "tmux failed — see $WORK/tmux.log" >&2; tail -40 "$WORK/tmux.log" >&2; exit 1; }

install -m 0755 "$WORK/tmux-$TMUX_VERSION/tmux" "$OUT/tmux"
echo "==> $OUT/tmux ($(wc -c < "$OUT/tmux" | tr -d ' ') bytes)"
echo "$OUT/tmux"
