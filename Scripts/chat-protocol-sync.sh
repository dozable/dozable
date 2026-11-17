#!/usr/bin/env bash
# chat-protocol-sync.sh SRC [REF] — copy the chat protocol's public documents into docs/chat/, unchanged.
#
# SRC is a git checkout of the protocol's source; REF a tag or commit in it (default: its HEAD). The two files
# public/protocol.md and public/webhook.md are taken from REF exactly as committed there (never from a working tree) and
# written to docs/chat/protocol.md and docs/chat/webhook.md as ONE header line followed by those bytes, untouched. The
# header names the tag (when REF is one), the commit and the protocol version the document states.
#
# Nothing here edits the documents: their names and examples are their owner's. Afterwards it prints the commit and the
# two files' SHA-256; Tests/DozableChatTests/ChatPublicDocumentsTests.swift pins those, so put the new values there in
# the same commit (a hand edit of either file then fails `make test`).
set -euo pipefail

SRC="${1:?usage: Scripts/chat-protocol-sync.sh SRC [REF] — SRC is a checkout of the source of the protocol}"
REF="${2:-HEAD}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$HERE/docs/chat"

COMMIT="$(git -C "$SRC" rev-parse --verify "$REF^{commit}")"
TAG="$(git -C "$SRC" describe --tags --exact-match "$COMMIT" 2>/dev/null || true)"
mkdir -p "$OUT"

for f in protocol.md webhook.md; do
    tmp="$(mktemp)"
    git -C "$SRC" show "$COMMIT:public/$f" > "$tmp.body"
    VER="$(grep -Eo 'protocol version .[0-9a-f]+.' "$tmp.body" | head -1 | grep -Eo '[0-9a-f]{6,}' || true)"
    if [[ -z "$VER" ]]; then echo "chat-protocol-sync: $f names no protocol version" >&2; rm -f "$tmp" "$tmp.body"; exit 1; fi
    SOURCE="the public source of the chat protocol${TAG:+, tag $TAG}, commit $COMMIT, protocol version $VER"
    printf '<!-- Copied unchanged from %s. Not edited here: Scripts/chat-protocol-sync.sh copies it again. -->\n' "$SOURCE" > "$tmp"
    cat "$tmp.body" >> "$tmp"
    mv "$tmp" "$OUT/$f"
    chmod 644 "$OUT/$f"
    rm -f "$tmp.body"
done

echo "copied at commit $COMMIT${TAG:+ ($TAG)}"
for f in protocol.md webhook.md; do
    echo "$(shasum -a 256 "$OUT/$f" | cut -d' ' -f1)  docs/chat/$f"
done
