#!/bin/bash
# deckhold-mac on this Mac, end to end (make deckhold-mac-check): a session held in a scratch DECKHOLD_DIR — serve,
# the socket owner-only, ls, a client over `pipe` (HELLO 0x0 + DATA) and the program's answer, dump, two viewers at
# once, the child's exit recorded (ls shows ended=N), and SIGTERM to the holder hanging up the child. Each check prints
# PASS/FAIL; `mac-smoke: ALL PASS` last. Nothing outside the scratch folder is touched; every holder it starts is
# stopped. (A poll across `pmset sleepnow` is checked by hand: see PROVENANCE.md.)
#
# Usage: Guest/deckhold/test/mac-smoke.sh [DECKHOLD]   (default .build/deckhold-mac/deckhold-mac)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/../../.." && pwd)"
D="${1:-$PKG/.build/deckhold-mac/deckhold-mac}"
CLIENT="$HERE/mac-client.py"
[ -x "$D" ] || { echo "no $D — make deckhold-mac first" >&2; exit 2; }
DIR="$(mktemp -d "${TMPDIR:-/tmp}/dhm-XXXXXX")"
export DECKHOLD_DIR="$DIR"
FAILS=0
check() { if [ "$1" = 0 ]; then echo "PASS $2"; else echo "FAIL $2"; FAILS=$((FAILS + 1)); fi; }
holder() { pgrep -f "deckhold-mac serve -s $1 " | head -1; }
cleanup() {
  for s in sh1 sh2 sh3; do p="$(holder "$s")"; [ -n "$p" ] && kill -KILL "$p" 2>/dev/null; done
  rm -rf "$DIR"
}
trap cleanup EXIT

file "$D" | grep -q "Mach-O 64-bit executable arm64"; check $? "a Mach-O arm64 executable ($(file -b "$D" | cut -c1-60))"

"$D" serve -s sh1 -x 80 -y 24 -- /bin/sh >/dev/null 2>&1; check $? "serve -s sh1 -- /bin/sh returns once it listens"
[ -S "$DIR/sh1.sock" ]; check $? "its socket is in DECKHOLD_DIR"
[ "$(stat -f %Lp "$DIR/sh1.sock")" = 600 ]; check $? "the socket is owner-only (0600: $(stat -f %Lp "$DIR/sh1.sock"))"
[ "$(stat -f %Lp "$DIR")" = 700 ]; check $? "its folder is owner-only (0700: $(stat -f %Lp "$DIR"))"
"$D" ls | grep -q "^sh1"; check $? "ls lists it ($("$D" ls | head -1 | cut -c1-80))"

OUT="$(python3 "$CLIENT" "$D" sh1 --send $'echo mac-$((6*7))\n' --wait "mac-42" --seconds 10)"
check $? "a client over pipe (HELLO 0x0 + DATA): the program's answer comes back ($OUT)"
"$D" dump -s sh1 | grep -q "mac-42"; check $? "dump: the holder's screen has it"
"$D" dump -s sh1 | tail -1 | grep -q "^cursor=.* size=80x24 screen=primary"; check $? "dump's last line: cursor, size 80x24, primary ($("$D" dump -s sh1 | tail -1))"

# Two viewers at once: the first only watches, the second types; both see the answer.
python3 "$CLIENT" "$D" sh1 --wait "two-2-v" --seconds 10 > "$DIR/v1.out" &
V1=$!
sleep 0.5
python3 "$CLIENT" "$D" sh1 --send $'echo two-$((1+1))-v\n' --wait "two-2-v" --seconds 10 >/dev/null; check $? "the second viewer types and sees its answer"
wait "$V1"; check $? "the first viewer (attached before) sees it too ($(cat "$DIR/v1.out"))"

# The child exits: the viewer gets EXIT 3, the socket goes, ls shows ended=3.
OUT="$(python3 "$CLIENT" "$D" sh1 --send $'exit 3\n' --until-exit --seconds 10)"
echo "$OUT" | grep -q "exit=3"; check $? "the program exits: the viewer gets EXIT 3 ($OUT)"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$DIR/sh1.sock" ] || break; sleep 0.2; done
[ ! -S "$DIR/sh1.sock" ]; check $? "the holder removed its socket"
"$D" ls | grep -q "^sh1	ended=3"; check $? "ls: sh1 ended=3 ($("$D" ls | grep sh1))"
OUT="$(python3 "$CLIENT" "$D" sh1 --until-exit --seconds 5)"
echo "$OUT" | grep -q "exit=3"; check $? "pipe to an ended session answers its EXIT ($OUT)"
OUT="$(python3 "$CLIENT" "$D" nosuch --seconds 3)"
echo "$OUT" | grep -q "nosession"; check $? "pipe to no session answers NOSESSION ($OUT)"

# SIGTERM to the holder hangs the program up; the holder ends with it.
"$D" serve -s sh2 -- /bin/sh -c "trap 'echo hup > \"$DIR/hup\"; exit 0' HUP; while :; do sleep 0.2; done" >/dev/null 2>&1
check $? "serve -s sh2 (a program that traps SIGHUP)"
H="$(holder sh2)"
[ -n "$H" ]; check $? "the holder runs (pid ${H:-none})"
sleep 0.5
kill -TERM "$H" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -f "$DIR/hup" ] && ! kill -0 "$H" 2>/dev/null && break; sleep 0.2; done
[ -f "$DIR/hup" ]; check $? "SIGTERM to the holder: the program got SIGHUP"
! kill -0 "$H" 2>/dev/null; check $? "…and the holder is gone"

# A holder whose program the Mac kills (not an exit): recorded too.
"$D" serve -s sh3 -- /bin/sleep 600 >/dev/null 2>&1
C="$("$D" ls | sed -n 's/^sh3.*pid=\([0-9]*\).*/\1/p')"
[ -n "$C" ]; check $? "serve -s sh3 -- sleep 600 (child pid ${C:-none})"
kill -KILL "$C" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$DIR/sh3.sock" ] || break; sleep 0.2; done
"$D" ls | grep -q "^sh3	ended="; check $? "a killed program: the holder records its end ($("$D" ls | grep sh3))"

if [ "$FAILS" = 0 ]; then echo "mac-smoke: ALL PASS"; else echo "mac-smoke: $FAILS FAILED"; exit 1; fi
