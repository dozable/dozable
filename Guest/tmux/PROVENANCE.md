# tmux — provenance of the committed binary

`Sources/DozableKit/Resources/tmux` is a **committed build artefact**: tmux 3.8, one static aarch64-linux-musl
executable. When a sandbox's `sessions.tmux` is on, the tools layer copies it to `/usr/local/lib/doz/bin/tmux` (no
guest network) and doz's sessions run in it — on every base, whatever tmux the distro ships (Debian 12 and the images
built on it 3.3a, Ubuntu 24.04 and Alpine 3.20 3.4, eclipse-temurin's Ubuntu 26.04 3.6a — the workspace probe
`probes/658-*/base-tmux-versions.py`, 2026-10-27). It is the pin, like `deckhold`, `doznet` and `dozview`; consumers
never need Zig. `make tmux` rewrites the (auto) lines after a rebuild; `make tmux-verify` rebuilds from scratch and
checks the committed bytes match.

| | |
|---|---|
| sha256 (auto) | `48b1ee2b533b1fce7bb01de64ab4bfabe6150d9c22e043daaf5deebc503b7ed9` |
| size (auto) | 1532400 bytes |
| format | ELF 64-bit LSB executable, ARM aarch64, statically linked (musl), stripped |
| tmux | 3.8 (2026-09-09) — `tmux-3.8.tar.gz`, sha256 `e79c699c7e949dccd0a4a125e17b8d1261e311b16979dbc8eb34542f3966d82e` (= the digest GitHub publishes for the release asset) |
| libevent | 2.1.13-stable — `libevent-2.1.13-stable.tar.gz`, sha256 `f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c` (= GitHub's published asset digest) |
| ncurses | 6.6 — `ncurses-6.6.tar.gz`, sha256 `355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11` (the same bytes from ftp.gnu.org and invisible-island.net, 2026-10-27) |
| Zig | 0.16.0 — the same pinned toolchain as deckhold (see `../deckhold/build.sh`): compiler, archiver, musl |
| ncurses build | static C library only (`--without-shared --without-progs --without-cxx --disable-db-install --enable-widec`); terminfo read from `/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo` |
| libevent build | static, no TLS (`--disable-shared --disable-openssl --disable-mbedtls`) |
| tmux build | `./configure --host=aarch64-linux-musl --enable-static` against both; `CC="zig cc -target aarch64-linux-musl"`, `CFLAGS=-O2 -ffile-prefix-map=<build>=.`, `LDFLAGS=-static -s` — the whole recipe is [`build.sh`](build.sh) |
| reproducible | yes — 2026-10-27 (M-series, macOS 27): two `FORCE=1` builds in the checkout, and a third from another directory with the tarballs downloaded again and a fresh compiler cache — identical bytes; no build path is in the binary |
| tested | `ToolsLayerTests` (the plan, the copy, the guest scripts), `make test-cli-tmux38` (Debian and Alpine sandboxes: a session in this tmux, a copy and `xdg-open` through it, the theme reported to a pane, OSC 7501) |

Rebuild: `make tmux` (first run downloads the three tarballs, ~5 MB, into the gitignored `.tools/tmux-src`; the pinned
Zig comes from `Guest/deckhold/build.sh`). Built on macOS (arm64) for the Linux guest; nothing is installed
system-wide.

Licences of what the binary contains (texts in [`LICENCES/`](LICENCES/), and in the release's third-party notices):
tmux (ISC), libevent (BSD-3-Clause, with parts under ISC/BSD-2-Clause as its LICENSE lists), ncurses (the X11-style
MIT licence), musl libc (MIT) — all statically linked by Zig.
