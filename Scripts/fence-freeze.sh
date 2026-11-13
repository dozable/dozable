#!/bin/bash
# fence-freeze.sh — DEV ONLY. Records what a LIVE agent session needs from the fence, so its lists can be frozen.
#
# A fenced session's `agent` profile allows a short list of Mach services (`MacFenceProfile.agentMachServices`) and
# reads an allowlist of the home. This harness runs a REAL fenced Claude Code session through the doz you give it
# (`doz run @mac --fenced … -- claude`), attaches you to it — you use it as you would: edit a file, run the tests, fetch a
# page, then /exit — and meanwhile collects every refusal the kernel logs for that session's tag (`log stream`,
# Sandbox lines only). When the session ends it writes a report with the versions (macOS, doz, Claude Code) and, per
# operation, what was refused: the Mach services (and which of them are NOT in the frozen list — the review's input),
# the files (shown with ~), the sysctls and the rest.
#
# It uses YOUR doz, store, Claude login (swapped in by the session's proxy — the program sees a placeholder) and a folder
# of yours: it is the person's run, never a test's. Nothing is changed in the profile: the report says what to add, and
# the change is a reviewed commit (MacFenceProfile.agentMachServices + the read allowlist), versions recorded beside it.
#
# Usage: Scripts/fence-freeze.sh [--doz PATH] [--workdir DIR] [--session NAME] [--out FILE] [-- CLAUDE ARGS…]
#   --doz      the doz to use (default: the one on PATH)
#   --workdir  the folder the session works in (default: the current folder; never the home)
#   --session  its name (default: freeze-agent)
#   --out      the report (default: ./fence-freeze-<date>.txt)
# Needs: an admin account (the system log's Sandbox lines), python3 (macOS's).
set -u
umask 077

DOZ=$(command -v doz || true)
WORKDIR=$(pwd -P)
SESSION=freeze-agent
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --doz) DOZ=$2; shift 2 ;;
    --workdir) WORKDIR=$(cd "$2" && pwd -P); shift 2 ;;
    --session) SESSION=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --) shift; break ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "fence-freeze: unknown option $1 (--help)" >&2; exit 64 ;;
  esac
done
[ -n "$DOZ" ] && [ -x "$DOZ" ] || { echo "fence-freeze: no doz (--doz PATH)" >&2; exit 64; }
[ -n "$OUT" ] || OUT="$(pwd -P)/fence-freeze-$(date +%Y%m%d-%H%M%S).txt"

SCRATCH=$(/usr/bin/mktemp -d /private/tmp/doz-fence-freeze.XXXXXX)
LOG="$SCRATCH/log.ndjson"
trap 'kill "$LOGPID" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

# Every Sandbox refusal from now on (kernel lines; the session's tag is matched afterwards, on the message's last line).
/usr/bin/log stream --style ndjson --predicate 'sender == "Sandbox"' > "$LOG" 2>"$SCRATCH/log.err" &
LOGPID=$!
sleep 1
kill -0 "$LOGPID" 2>/dev/null || { echo "fence-freeze: log stream did not start (an admin account is needed): $(cat "$SCRATCH/log.err")" >&2; exit 1; }

"$DOZ" run @mac -d --fenced --session "$SESSION" --workdir "$WORKDIR" -- claude "$@" || { echo "fence-freeze: the session did not start" >&2; exit 1; }
STORE=$("$DOZ" config get store.path 2>/dev/null | tail -1)
STORE=${STORE/#\~/$HOME}
TAG=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sessions"][sys.argv[2]]["fence"]["tag"])' \
      "$STORE/mac-sessions/sessions.json" "$SESSION" 2>/dev/null)
[ -n "$TAG" ] || { echo "fence-freeze: no tag for $SESSION in $STORE" >&2; "$DOZ" sessions end @mac "$SESSION" --yes; exit 1; }
echo "fence-freeze: session $SESSION (tag $TAG) — work in it as you would (edit, run tests, fetch a page), then /exit."
"$DOZ" attach @mac "$SESSION"
"$DOZ" sessions end @mac "$SESSION" --yes >/dev/null 2>&1
sleep 2
kill "$LOGPID" 2>/dev/null

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
/usr/bin/python3 - "$LOG" "$TAG" "$OUT" "$HOME" "$(sw_vers -productVersion) ($(sw_vers -buildVersion))" "$("$DOZ" --version 2>/dev/null | head -1)" "$CLAUDE_VERSION" <<'PY'
import json, re, sys, collections
log, tag, out, home, macos, doz, claude = sys.argv[1:8]
# The frozen list today (keep in step with MacFenceProfile.agentMachServices).
frozen = {"com.apple.trustd", "com.apple.trustd.agent", "com.apple.ocspd", "com.apple.networkd",
          "com.apple.SystemConfiguration.configd", "com.apple.SystemConfiguration.DNSConfiguration", "com.apple.bsd.dirhelper",
          "com.apple.system.opendirectoryd.membership", "com.apple.system.opendirectoryd.libinfo", "com.apple.system.logger",
          "com.apple.system.notification_center", "com.apple.logd", "com.apple.diagnosticd", "com.apple.cfprefsd.daemon",
          "com.apple.cfprefsd.agent", "com.apple.FSEvents"}
line = re.compile(r"Sandbox: (\S+)\((\d+)\) deny\(\d+\) (\S+) ?(.*)")
seen = collections.defaultdict(collections.Counter)
for raw in open(log, errors="replace"):
    try:
        m = json.loads(raw).get("eventMessage", "")
    except Exception:
        continue
    parts = m.split("\n")
    if parts[-1].strip() != "doz-fence:" + tag:
        continue
    r = line.match(parts[0])
    if not r:
        continue
    proc, _, op, target = r.groups()
    target = target.replace(home, "~", 1) if target.startswith(home) else target
    seen[op][(target, proc)] += 1
with open(out, "w") as f:
    f.write(f"fence-freeze report — macOS {macos}; {doz}; Claude Code {claude}; tag {tag}\n")
    f.write("Refusals the kernel logged for the session (macOS folds repeats: presence, not counts).\n\n")
    mach = sorted({t for (t, _) in seen.get("mach-lookup", {})})
    f.write("== Mach services refused (" + str(len(mach)) + ")\n")
    for t in mach:
        f.write(("  NEW  " if t not in frozen else "       ") + t + "\n")
    for op in sorted(seen):
        if op == "mach-lookup":
            continue
        f.write(f"\n== {op}\n")
        for (t, p), n in sorted(seen[op].items()):
            f.write(f"  {t}   ({p})\n")
print(f"fence-freeze: report written to {out}")
PY
