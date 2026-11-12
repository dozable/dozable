# deckhold — provenance of the committed binary

`Sources/DozableKit/Resources/deckhold` is a **committed build artefact**: the guest-side
PTY holder every sandbox installs at `/usr/local/bin/deckhold` on start. It is the pin, the way a
vendored xcframework is — consumers never need Zig or the ghostty source. This file records exactly
what produced it; `make deckhold` rewrites the two lines marked (auto) after a rebuild, and
`make deckhold-verify` rebuilds from scratch and checks the committed bytes match.

| | |
|---|---|
| sha256 (auto) | `26dc610a3c8e7d0385f3068dac371167db1d4ac5c9ae06f37ca97ba4ce30e323` |
| size (auto) | 1619032 bytes |
| format | ELF 64-bit LSB executable, ARM aarch64, statically linked (musl), stripped |
| source | [`deckhold.c`](deckhold.c) (this directory) |
| Zig | 0.16.0 — `zig-aarch64-macos-0.16.0.tar.xz`, sha256 `b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489` |
| ghostty | `b988efcfe584e88a3d0330e2c17c386ffa419d72` (2026-07-22) — why this commit: see [`build.sh`](build.sh) |
| libghostty-vt | `zig build -Demit-lib-vt=true -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast` |
| deckhold | `zig cc -target aarch64-linux-musl -static -O2 -s -Wall -Wextra -Wno-unused-parameter -I<vt>/include deckhold.c <vt>/lib/libghostty-vt.a -lc++` |
| reproducible | yes — two `FORCE=1` rebuilds on the M3 (2026-09-25) produced identical bytes; 610 (2026-10-08, M4): `make deckhold` then `make deckhold-verify` (a `FORCE=1` rebuild; Zig and ghostty fetched fresh into `.tools/` that day) — identical; 612 (2026-10-09, M4): the same — identical |
| tested | `make deckhold-snapshot-check` (610): this source against a Mac build of the same ghostty commit — every SNAPSHOT replayed on a fresh emulator equals the holder's screen cell by cell (fixed cases + 20,000 seeded fuzz screens × size changes; 0.30.1's source: ~45 % of them a row off) ; 612: `make deckhold-status-check` — the OSC 7501 consumer: the query answered, the records' rules and limits, invalid input discarded, cut at every offset + 20,000 seeded fuzz inputs |

Rebuild: `make deckhold` (first run downloads Zig and a blobless ghostty clone into the gitignored
`.tools/`, ~3.5 min; `DECKHOLD_TOOLS=<dir>` reuses an existing toolchain directory of the same
layout). Built on macOS (arm64) for the Linux guest; nothing is installed system-wide.

## macOS build — `deckhold-mac`

The same holder for sessions held on the Mac itself, shipped in the CLI release beside `doz`
(`libexec/doz/deckhold-mac`; never in the helper build). It is **not committed**: a Mach-O is signed with each
release, and the Mac's clang does not promise the same bytes across Xcode versions — so each release builds it fresh
(`Scripts/release.sh` runs `Guest/deckhold/build-mac.sh` with `FORCE=1`) and carries this file in `licences/deckhold/`.

| | |
|---|---|
| source | [`deckhold.c`](deckhold.c) — the very file the guest binary is built from, unchanged |
| ghostty | the same `GHOSTTY_SHA` as above (read from [`build.sh`](build.sh)) |
| libghostty-vt | `zig build -Demit-lib-vt=true -Doptimize=ReleaseFast` for the Mac — its xcframework's fat static library `lib/ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a` (the step after the xcframework fails on a macOS 27 SDK and is not needed) |
| deckhold-mac | the Mac's clang: `cc -O2 -arch arm64 -mmacosx-version-min=<Package.swift's platform> -Wall -Wextra -Wno-unused-parameter -I<xcframework>/Headers deckhold.c <xcframework>/libghostty-vt.a -lc++` → `.build/deckhold-mac/deckhold-mac` |
| built with | Apple clang 21.0.0 (clang-2100.4.1.1), macOS 26.0 minimum, arm64 (2026-11-12, M-series) |
| signed | by `release.sh`: the release's Developer ID, hardened runtime, secure timestamp, NO entitlements; notarised with `doz` (one zip) and its ticket checked by CDHash |
| tested | `make deckhold-mac-check`: the status, grid and snapshot checks (this source against the same Mac library), then `test/mac-smoke.sh` — serve `sh` in a scratch `DECKHOLD_DIR` (socket 0600, folder 0700), `ls`, a client over `pipe` (HELLO 0×0 + DATA) and the program's answer, `dump` (cursor, size, primary), two viewers at once, the program's exit (EXIT to the viewer, the socket gone, `ls` `ended=3`, `pipe` answering EXIT; NOSESSION for none), SIGTERM to the holder hanging the program up, a killed program recorded (`ended=137`). No change to `deckhold.c` was needed on macOS. By hand, not in the check: a poll across `pmset sleepnow` |

Build: `make deckhold-mac` (needs `make deckhold` once, for the toolchain in `.tools/`); `make cli` / `make install-cli`
put it beside `doz` (by rename).

Licences of what the binary contains: deckhold itself (MIT, this package), libghostty-vt and its
bundled simdutf/highway (MIT / Apache-2.0 / MIT — see `LICENCES.md`), musl libc (MIT), LLVM libc++
(Apache-2.0 with LLVM exception), all statically linked by Zig.
