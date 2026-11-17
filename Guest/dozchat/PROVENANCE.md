# dozchat — provenance

`dozchat` is a member of a Dozable chat room in one C file, [`dozchat.c`](dozchat.c) (libc and POSIX only; no
third-party code), MIT like the rest of this package. Dozable ships it in two builds of that same file:

## Resources/dozchat — every sandbox's `dozchat` (committed)

`Sources/DozableKit/Resources/dozchat` is a **committed build artefact**, like doznet: the tools layer copies it into
every sandbox (`/usr/local/lib/doz/bin/dozchat`, linked `/usr/local/bin/dozchat` when free). `make dozchat` rewrites the
(auto) lines after a rebuild; `make dozchat-verify` (and CI's `dozchat` job) rebuilds from scratch and checks the bytes.

| | |
|---|---|
| sha256 (auto) | `055c9e71e8e7d80cb4bf489a1ec0221391e93df44e6c7065953966e190758288` |
| size (auto) | 117872 bytes |
| format | ELF 64-bit LSB executable, ARM aarch64, statically linked (musl), stripped |
| source | [`dozchat.c`](dozchat.c) (this directory) |
| Zig | 0.16.0 — the same pinned toolchain as the other guest helpers; [`build.sh`](build.sh) fetches it (same URL and sha256 as `../deckhold/build.sh`) when missing |
| command | `zig cc -target aarch64-linux-musl -static -O2 -s -std=c11 -Wall -Wextra -Wformat=2 -Wshadow -Wvla -Werror -fstack-protector-strong -ftrivial-auto-var-init=zero dozchat.c` (run from this folder: no checkout path enters the binary) |
| reproducible | yes — two `FORCE=1` rebuilds (2026-11-18, one after emptying the Zig local cache) gave identical bytes. `-static-pie` is not used: `zig cc` 0.16.0 ignores it (an unused-argument error under `-Werror`) |

Licences: dozchat itself (MIT, this package) and musl libc (MIT), statically linked by Zig.

## dozchat-mac — a fenced session's `dozchat` (not committed)

| | |
|---|---|
| built by | [`build-mac.sh`](build-mac.sh) — `make dozchat-mac`, and by `make cli`, `make install-cli` and `Scripts/release.sh` (fresh, `FORCE=1`) |
| output | `.build/dozchat-mac/dozchat-mac` → `libexec/doz/dozchat-mac` in the CLI release (never the helper) |
| format | Mach-O 64-bit executable arm64, linked against libSystem only |
| compiler | the Mac's own clang (`cc`) |
| command | `cc -O2 -arch arm64 -mmacosx-version-min=<Package.swift> -std=c11 -Wall -Wextra -Wformat=2 -Wshadow -Wvla -Werror -fstack-protector-strong -ftrivial-auto-var-init=zero -D_FORTIFY_SOURCE=2 dozchat.c` |
| signing | the release's identity, hardened runtime, secure timestamp, NO entitlements; notarised in the same submission as `doz` |

Not committed, like `deckhold-mac`: a Mach-O is signed per release, and the Mac's clang does not promise the same bytes
across Xcode versions.

## Checks

`make dozchat-check` builds [`test/unit-check.c`](test/unit-check.c) (which includes `dozchat.c`) under AddressSanitizer
and UndefinedBehaviorSanitizer with `-fno-sanitize-recover=all`: fixed vectors for the escaper, the scanner, base64,
the name rule (`test/clean-name.tsv`, shared with the chat server's `ChatFileRules.cleanName`), URLs, `NO_PROXY` and the
answer's head, then a seeded fuzz of the escaper and the scanner. `make test` runs it too
(`Tests/DozableChatTests/DozchatUnitTests.swift`), with the end-to-end `ChatDozchatClientTests`.
