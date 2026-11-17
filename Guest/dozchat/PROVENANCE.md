# dozchat — provenance

`dozchat` is a member of a Dozable chat room in one C file, [`dozchat.c`](dozchat.c) (libc and POSIX only; no
third-party code), MIT like the rest of this package. Dozable ships it in two builds of that same file:

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
