# dozchat — provenance

`dozchat` is a member of a Dozable chat room in one C file, [`dozchat.c`](dozchat.c) (libc and POSIX only; no
third-party code), MIT like the rest of this package. Dozable ships it in two builds of that same file:

## Resources/dozchat — every sandbox's `dozchat` (committed)

`Sources/DozableKit/Resources/dozchat` is a **committed build artefact**, like doznet: the tools layer copies it into
every sandbox (`/usr/local/lib/doz/bin/dozchat`, linked `/usr/local/bin/dozchat` when free). `make dozchat` rewrites the
(auto) lines after a rebuild; `make dozchat-verify` (and CI's `dozchat` job) rebuilds from scratch and checks the bytes.

| | |
|---|---|
| sha256 (auto) | `ee924b6c4fd99c903b19707da26885078854573d0a237b289cd0ec974ae59a53` |
| size (auto) | 141128 bytes |
| format | ELF 64-bit LSB executable, ARM aarch64, statically linked (musl), stripped |
| source | [`dozchat.c`](dozchat.c) (this directory) |
| Zig | 0.16.0 — the same pinned toolchain as the other guest helpers; [`build.sh`](build.sh) fetches it (same URL and sha256 as `../deckhold/build.sh`) when missing |
| command | `zig cc -target aarch64-linux-musl -static -O2 -s -std=c11 -Wall -Wextra -Wformat=2 -Wshadow -Wvla -Werror -fstack-protector-strong -ftrivial-auto-var-init=zero dozchat.c` (run from this folder: no checkout path enters the binary) |
| reproducible | yes — two `FORCE=1` rebuilds (2026-11-18, one after emptying the Zig local cache) gave identical bytes. `-static-pie` is not used: `zig cc` 0.16.0 ignores it (an unused-argument error under `-Werror`) |

Licences: dozchat itself (MIT, this package) and musl libc (MIT), statically linked by Zig.

## dozchat-linux-x86_64 — for agents outside Dozable on x86_64 Linux (not committed, a release asset)

The same source, flags and Zig version, for `x86_64-linux-musl`: `make dozchat-linux-x86_64` (`Guest/dozchat/build.sh
x86_64`) → `.build/dozchat-linux-x86_64/dozchat`. Never in a sandbox (every sandbox is arm64) and never committed;
`make release` attaches it to the GitHub release as `dozchat-linux-x86_64` with its `.sha256`. A Mac uses Zig's
aarch64-macos build (the pin above); CI's Linux job (`.github/workflows/dozchat-linux.yml`) builds it with Zig's
x86_64-linux build of 0.16.0 (sha256 `70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00`, from
ziglang.org/download) and checks the bytes are these.

| | |
|---|---|
| x86_64 sha256 | `160fc421b5f7537a551230669ecc36336e15c89be0f17f764478f4e3b40617b1` |
| x86_64 size | 155752 bytes |
| format | ELF 64-bit LSB executable, x86-64, statically linked (musl), stripped |
| reproducible | yes — two `FORCE=1` builds on the Mac (one after emptying Zig's local cache) gave identical bytes |

Outside Dozable, through a local proxy with no password (Tailscale in userspace, say):
`CHAT_URL=http://HOST:8790 http_proxy=http://localhost:PORT dozchat send ROOM TEXT` (the token from `CHAT_TOKEN_FILE`).

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
