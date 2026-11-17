#!/bin/bash
# wire-check.sh DOZCHAT — a built dozchat (any platform this machine runs) against test/stub.py: send direct, send through
# a local proxy with NO password, receive --wait, ack -, a 401 (exit 4, the token in no output), and a server restart
# while `listen` runs. Prints one line per check and "ok wire-check" last. Needs python3; everything in a scratch folder.
set -uo pipefail
BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/dozchat-wire.XXXXXX")"
TOKEN="stub-token-0123456789abcdef"
fails=0
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
check() { if [ "$1" = 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fails=$((fails + 1)); fi; }
waitfile() { for _ in $(seq 100); do [ -s "$1" ] && return 0; sleep 0.1; done; return 1; }
start_server() {
  rm -f "$W/sport"
  python3 "$HERE/stub.py" server "$W/sport" "$W/server.log" ${1:-} & spid=$!; pids+=("$spid")
  waitfile "$W/sport"; SPORT=$(cat "$W/sport")
}
printf '%s\n' "$TOKEN" > "$W/token"; chmod 600 "$W/token"
printf '%s\n' "wrong-token-0123456789abcdef" > "$W/bad"; chmod 600 "$W/bad"
start_server
python3 "$HERE/stub.py" proxy "$W/pport" "$SPORT" "$W/proxy.log" & pids+=($!)
waitfile "$W/pport"; PPORT=$(cat "$W/pport")
run() { env -i PATH=/usr/bin:/bin CHAT_URL="http://127.0.0.1:$SPORT" CHAT_TOKEN_FILE="$W/token" "$@"; }

"$BIN" --version | grep -qx 'dozchat 1'; check $? "dozchat --version runs here"
out=$(run "$BIN" send room1 "hello direct" 2>"$W/e1"); rc=$?
[ $rc = 0 ] && grep -q '"state":"queued"' <<<"$out"; check $? "send, direct (exit $rc)"
out=$(run HTTP_PROXY="http://127.0.0.1:$PPORT" "$BIN" send room1 "hello through the proxy" 2>"$W/e2"); rc=$?
[ $rc = 0 ] && grep -q '"state":"queued"' <<<"$out"; check $? "send through a local proxy with no password (exit $rc)"
grep -qx 'POST absolute=True proxy-auth=none' "$W/proxy.log"; check $? "…the absolute form, no Proxy-Authorization"
recv=$(run "$BIN" receive --wait 5 2>"$W/e3"); rc=$?
[ $rc = 0 ] && [ "$(grep -c . <<<"$recv")" = 2 ] && grep -q 'hello direct' <<<"$recv" && grep -q 'hello through the proxy' <<<"$recv"
check $? "receive --wait 5: both messages, one line each (exit $rc)"
out=$(printf '%s\n' "$recv" | run "$BIN" ack - 2>"$W/e4"); rc=$?
[ $rc = 0 ] && [ "$out" = '{"acked":2}' ]; check $? "ack - with receive's lines ($out)"
out=$(run "$BIN" receive --wait 1 2>&1); rc=$?
[ $rc = 0 ] && [ -z "$out" ]; check $? "receive --wait 1 after the ack: nothing (exit $rc)"
out=$(env -i PATH=/usr/bin:/bin CHAT_URL="http://127.0.0.1:$SPORT" CHAT_TOKEN_FILE="$W/bad" "$BIN" receive 2>&1); rc=$?
[ $rc = 4 ] && ! grep -q wrong-token <<<"$out" && grep -q 'HTTP 401' <<<"$out"; check $? "a wrong token: exit 4, the token in no output (exit $rc)"
grep -q "$TOKEN" "$W"/e* && bad=1 || bad=0; check $bad "the token in no stderr of the calls above"

# listen across a restart of the server (same port)
run "$BIN" listen --wait 2 > "$W/listen.out" 2> "$W/listen.err" & lpid=$!; pids+=("$lpid")
run "$BIN" send room1 "before the restart" >/dev/null 2>&1
for _ in $(seq 100); do grep -q 'before the restart' "$W/listen.out" && break; sleep 0.1; done
grep -q 'before the restart' "$W/listen.out"; check $? "listen prints a message"
kill "$spid"; wait "$spid" 2>/dev/null; sleep 2
start_server "$SPORT"
run "$BIN" send room1 "after the restart" >/dev/null 2>&1
for _ in $(seq 300); do grep -q 'after the restart' "$W/listen.out" && break; sleep 0.1; done
grep -q 'after the restart' "$W/listen.out"; check $? "listen goes on after the server restarted"
grep -q 'trying again' "$W/listen.err"; check $? "…and said it was trying again"
[ "$(grep -c 'before the restart' "$W/listen.out")" = 1 ]; check $? "…acknowledged: not printed twice"
kill "$lpid" 2>/dev/null
grep -q "$TOKEN" "$W/listen.out" "$W/listen.err" && bad=1 || bad=0; check $bad "the token in no output of listen"

if [ "$fails" = 0 ]; then echo "ok wire-check: dozchat $(uname -s) $(uname -m)"; else echo "x wire-check: $fails failed"; exit 1; fi
