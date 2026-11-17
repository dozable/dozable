#!/usr/bin/env bash
# chat-conformance.sh — the chat server's outside-in gate (docs/engineering/chat.md).
#
# The conformance runner is a program of the reference chat server's PRIVATE repository; it is not in this repository
# and CI cannot fetch it. This repository pins it by version and SHA-256 (Tests/Conformance/RUNNER) and keeps the ratchet
# (Tests/Conformance/expected-green.txt: the checks that must PASS, by name). The script:
#   - finds the runner at $DOZ_CHAT_CONFORMANCE, else ~/.cache/doz/switchboard-conformance; without one it prints
#     "conformance: not run (private runner)" and exits 0, so CI and contributors stay green;
#   - refuses a runner whose SHA-256 is not the pinned one;
#   - runs it against the built doz: every check starts its own `doz chat serve --config {config} --bind {bind}` on
#     127.0.0.1, on ports the runner picks, in scratch folders the runner makes and removes;
#   - hands it the ratchet with its -expect FILE: it fails when a check in the ratchet is not PASS (EXPECT-MISSING), and
#     lists every PASS that is not in the ratchet yet (EXPECT-EXTRA).
#
# Environment: DOZ_BIN (default .build/debug/doz), CHECKS (a -test.run pattern: a look at a subset, which prints its
# failures and does not judge the ratchet; default every check, judged),
# REPORT (where the report goes; default a scratch file it names).
set -euo pipefail

PACKAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$PACKAGE/Tests/Conformance/RUNNER"
RATCHET="$PACKAGE/Tests/Conformance/expected-green.txt"
DOZ="${DOZ_BIN:-$PACKAGE/.build/debug/doz}"
RUNNER="${DOZ_CHAT_CONFORMANCE:-$HOME/.cache/doz/switchboard-conformance}"

if [[ ! -x "$RUNNER" ]]; then
    echo "conformance: not run (private runner)"
    exit 0
fi
[[ -f "$PIN" && -f "$RATCHET" ]] || { echo "x chat-conformance: missing $PIN or $RATCHET" >&2; exit 1; }
[[ -x "$DOZ" ]] || { echo "x chat-conformance: no doz at $DOZ (make cli)" >&2; exit 1; }

want=$(awk '$1 == "sha256" { print $2 }' "$PIN")
version=$(awk '$1 == "version" { print $2 }' "$PIN")
have=$(shasum -a 256 "$RUNNER" | cut -d' ' -f1)
if [[ "$have" != "$want" ]]; then
    echo "x chat-conformance: $RUNNER is not the pinned runner $version (sha256 $have, want $want)" >&2
    exit 1
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/doz-chat-conformance.XXXXXX")
REPORT="${REPORT:-$scratch/report.txt}"
LOG="$scratch/full.log"
args=(-server-cmd "'$DOZ' chat serve --config {config} --bind {bind}" -report-log "$LOG")
# A subset is a look, not the gate: the ratchet is judged on a full run only.
if [[ -n "${CHECKS:-}" ]]; then args+=(-test.run "$CHECKS"); else args+=(-expect "$RATCHET"); fi

echo "conformance: runner $version against $DOZ …"
set +e
(cd "$scratch" && env -u CONFORMANCE_SERVER_CMD -u CONFORMANCE_STATUS_CMD "$RUNNER" "${args[@]}") > "$REPORT" 2>&1
rc=$?
set -e
grep -E '^SUMMARY ' "$REPORT" || echo "conformance: the runner printed no SUMMARY (exit $rc); see $REPORT"
if [[ -n "${CHECKS:-}" ]]; then
    grep -E '^(FAIL|SKIP) ' "$REPORT" | cut -c1-300 || true
    echo "conformance: a subset (CHECKS=$CHECKS); the ratchet is judged on a full run (report: $REPORT)"
    exit 0
fi
grep -E '^EXPECT ' "$REPORT" || true

new=$(sed -n 's/^EXPECT-EXTRA \([A-Za-z0-9_]*\).*/\1/p' "$REPORT")
missing=$(sed -n 's/^EXPECT-MISSING \([A-Za-z0-9_]*\).*/\1/p' "$REPORT")
if [[ -n "$new" ]]; then
    echo "conformance: PASS but not in the ratchet yet (add them to Tests/Conformance/expected-green.txt):"
    printf '  %s\n' $new
fi
if [[ -n "$missing" || $rc -ne 0 ]]; then
    echo "x conformance: in the ratchet but not PASS (runner exit $rc):" >&2
    for c in $missing; do
        line=$(grep -E "^(FAIL|SKIP) $c " "$REPORT" || echo "$c: not run")
        printf '  %s\n' "$line" >&2
    done
    echo "  report: $REPORT; full output: $LOG" >&2
    exit 1
fi
echo "ok conformance: all $(grep -cvE '^[[:space:]]*(#|$)' "$RATCHET") checks of the ratchet PASS (report: $REPORT)"
