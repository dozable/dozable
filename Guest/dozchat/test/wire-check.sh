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

"$BIN" --version | grep -qx 'dozchat 2'; check $? "dozchat --version runs here"
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

# Asks: posted with the options, deciders and the time to expire; decided once (a second is refused, exit 3); ask-show
# --wait's exit codes (0 decided, 10 declined, 12 withdrawn); --questions passed verbatim, a file that is not one array
# refused before anything is sent; a bare number is #N.
out=$(run "$BIN" ask room1 "Ship it?" --option yes=Yes --option no=No --decider decbot --reason "the release" --expires-in 60 2>"$W/e5"); rc=$?
[ $rc = 0 ] && grep -q '"state":"queued"' <<<"$out"; check $? "ask (exit $rc)"
grep 'send ' "$W/server.log" | tail -1 | grep -q '"ask": {"deciders": \["decbot"\], "expires_at": "20[0-9-]*T[0-9:]*Z", "questions": \[{"options": \[{"id": "yes", "label": "Yes"}, {"id": "no", "label": "No"}\]}\], "reason": "the release"}'
check $? "…the ask's body: questions, deciders, reason, expires_at"
grep 'send ' "$W/server.log" | tail -1 | grep -q '"kind": "ask"'; check $? "…kind ask"
out=$(run "$BIN" decide room1 1 yes "after lunch" 2>"$W/e6"); rc=$?
[ $rc = 0 ] && grep -q '"state":"decided"' <<<"$out"; check $? "decide 1 yes: a bare number is #N (exit $rc)"
grep 'decide ' "$W/server.log" | tail -1 | grep -q '"ask_id": "#1".*"option": "yes".*"text": "after lunch"'; check $? "…the decision's body"
out=$(run "$BIN" decide room1 '#1' no 2>&1); rc=$?
[ $rc = 3 ] && grep -q 'this ask is closed' <<<"$out"; check $? "a second decision is refused: exit 3 (exit $rc)"
run "$BIN" ask-show room1 '#1' --wait 5 >/dev/null 2>&1; rc=$?; check $([ $rc = 0 ]; echo $?) "ask-show --wait: decided, exit 0 ($rc)"
run "$BIN" ask room1 "Again?" >/dev/null 2>&1
run "$BIN" decide room1 '#2' --decline "not now" >/dev/null 2>&1
run "$BIN" ask-show room1 2 --wait 5 >/dev/null 2>&1; rc=$?; check $([ $rc = 10 ]; echo $?) "ask-show --wait: declined, exit 10 ($rc)"
run "$BIN" ask room1 "Once more?" >/dev/null 2>&1
run "$BIN" withdraw room1 '#3' >/dev/null 2>&1
run "$BIN" ask-show room1 '#3' --wait 5 >/dev/null 2>&1; rc=$?; check $([ $rc = 12 ]; echo $?) "ask-show --wait: withdrawn, exit 12 ($rc)"
printf '%s' '[{"id":"q1","question":"One?"}, {"id":"q2","question":"Two?"}]' > "$W/qs.json"
out=$(run "$BIN" ask room1 "Two things" --questions "$W/qs.json" 2>&1); rc=$?
[ $rc = 0 ] && grep 'send ' "$W/server.log" | tail -1 | grep -q '"questions": \[{"id": "q1", "question": "One?"}, {"id": "q2", "question": "Two?"}\]'
check $? "--questions passed verbatim (exit $rc)"
n=$(grep -c 'send ' "$W/server.log")
printf '%s' '{"id":"q1"}' > "$W/notarray.json"
out=$(run "$BIN" ask room1 "Bad" --questions "$W/notarray.json" 2>&1); rc=$?
[ $rc = 2 ] && [ "$(grep -c 'send ' "$W/server.log")" = "$n" ]; check $? "--questions that is not one array: exit 2, nothing sent (exit $rc)"
out=$(run "$BIN" decide room1 'ZZ' yes 2>&1); rc=$?
[ $rc = 2 ]; check $? "an ask named neither #N nor an id: exit 2 (exit $rc)"
grep -q "$TOKEN" "$W"/e5 "$W"/e6 && bad=1 || bad=0; check $bad "the token in no stderr of the asks"

# A proxy that refuses the credentials (407, or 401) and closes before reading the body: exit 4 at once, one attempt,
# "the proxy refused the credentials", the password in no output — a small message and one too big to be read first.
head -c 900000 /dev/zero | tr '\0' 'x' > "$W/big.txt"
for st in 407 401; do
  rm -f "$W/rport"; python3 "$HERE/stub.py" refuse "$W/rport" "$st" "$W/refuse-$st.log" & pids+=($!)
  waitfile "$W/rport"; RPORT=$(cat "$W/rport")
  for size in small big; do
    : > "$W/refuse-$st.log"
    if [ $size = small ]; then
      out=$(run HTTP_PROXY="http://doz:wrong-pass-0123456789@127.0.0.1:$RPORT" "$BIN" send room1 "hi" 2>&1); rc=$?
    else
      out=$(run HTTP_PROXY="http://doz:wrong-pass-0123456789@127.0.0.1:$RPORT" "$BIN" send room1 - < "$W/big.txt" 2>&1); rc=$?
    fi
    [ $rc = 4 ] && grep -q "the proxy refused the credentials (HTTP $st)" <<<"$out" && [ "$(grep -c connection "$W/refuse-$st.log")" = 1 ] \
      && ! grep -q -e wrong-pass -e "$RPORT" -e "$TOKEN" <<<"$out"
    check $? "a proxy that refuses the credentials ($st, a $size message): exit 4, one attempt, no password shown (exit $rc)"
  done
done

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
