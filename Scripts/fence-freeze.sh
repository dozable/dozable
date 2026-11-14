#!/bin/bash
# fence-freeze.sh — DEV ONLY. Records what a LIVE session needs from the fence, so its lists can be frozen.
#
# A fenced session's profiles allow short lists of Mach services (`MacFenceProfile.agentMachServices`, and for --xcode /
# --simulator `xcodeMachServices` / `simulatorMachServices` and their prefixes) and read an allowlist of the home. This
# harness runs a REAL fenced session through the doz you give it and meanwhile collects every refusal the kernel logs for
# that session's tag (`log stream`, Sandbox lines only). When the session ends it writes a report with the versions
# (macOS, doz, Claude Code or Xcode) and, per operation, what was refused: the Mach services (and which of them the
# profile does NOT allow — the review's input), the files (shown with ~), preference writes, the sysctls and the rest.
#
# Two ways to run it:
#   - an AGENT session (default): `doz run @mac --fenced … -- claude`, attached — you use it as you would (edit a file,
#     run the tests, fetch a page), then /exit;
#   - a BUILD (`--run 'COMMAND'`, e.g. with --xcode): the command runs non-interactively in the fenced session (in your
#     folder), its exit code and the end of its output go into the report. For Xcode:
#       Scripts/fence-freeze.sh --xcode --workdir ~/src/App --run \
#         'xcodebuild -scheme App -destination "generic/platform=macOS" -derivedDataPath "$DOZ_DERIVED" -scmProvider system build'
#     (add CODE_SIGNING_ALLOWED=NO, or --keychain to sign as you; --simulator for a run in the Simulator — a guard rail).
#
# It uses YOUR doz, store, login and a folder of yours: it is the person's run, never a test's. Nothing is changed in the
# profile: the report says what to add, and the change is a reviewed commit, versions recorded beside the list.
#
# Usage: Scripts/fence-freeze.sh [--doz PATH] [--workdir DIR] [--session NAME] [--out FILE] [--xcode] [--simulator]
#                                [--keychain] [--run 'COMMAND'] [-- CLAUDE ARGS…]
#   --doz        the doz to use (default: the one on PATH)
#   --workdir    the folder the session works in (default: the current folder; never the home)
#   --session    its name (default: freeze-agent, or freeze-xcode / freeze-simulator)
#   --out        the report (default: ./fence-freeze-<date>.txt, beside where you ran it)
#   --xcode      the Xcode build profile; --simulator also the Simulator (implies --xcode); --keychain opens the Keychain
#   --run        a command for /bin/sh -c instead of an attached Claude Code session
# Needs: an admin account (the system log's Sandbox lines), python3 (macOS's).
set -u
umask 077

HERE=$(cd "$(dirname "$0")" && pwd -P)
DOZ=$(command -v doz || true)
WORKDIR=$(pwd -P)
SESSION=""
OUT=""
PROFILE=agent
KEYCHAIN=""
RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --doz) DOZ=$2; shift 2 ;;
    --workdir) WORKDIR=$(cd "$2" && pwd -P); shift 2 ;;
    --session) SESSION=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --xcode) [ "$PROFILE" = simulator ] || PROFILE=xcode; shift ;;
    --simulator) PROFILE=simulator; shift ;;
    --keychain) KEYCHAIN=--keychain; shift ;;
    --run) RUN=$2; shift 2 ;;
    --) shift; break ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "fence-freeze: unknown option $1 (--help)" >&2; exit 64 ;;
  esac
done
[ -n "$DOZ" ] && [ -x "$DOZ" ] || { echo "fence-freeze: no doz (--doz PATH)" >&2; exit 64; }
[ -n "$SESSION" ] || SESSION="freeze-$PROFILE"
[ -n "$OUT" ] || OUT="$(pwd -P)/fence-freeze-$(date +%Y%m%d-%H%M%S).txt"
case "$PROFILE" in
  xcode) PFLAGS=(--xcode) ;;
  simulator) PFLAGS=(--xcode --simulator) ;;
  *) PFLAGS=() ;;
esac
[ -n "$KEYCHAIN" ] && PFLAGS+=("$KEYCHAIN")

SCRATCH=$(/usr/bin/mktemp -d /private/tmp/doz-fence-freeze.XXXXXX)
LOG="$SCRATCH/log.ndjson"
trap 'kill "$LOGPID" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

# Every Sandbox refusal from now on (kernel lines; the session's tag is matched afterwards, on the message's last line).
/usr/bin/log stream --style ndjson --predicate 'sender == "Sandbox"' > "$LOG" 2>"$SCRATCH/log.err" &
LOGPID=$!; disown "$LOGPID" 2>/dev/null
sleep 1
kill -0 "$LOGPID" 2>/dev/null || { echo "fence-freeze: log stream did not start (an admin account is needed): $(cat "$SCRATCH/log.err")" >&2; exit 1; }

if [ -n "$RUN" ]; then
  # The command's output and exit code go to the session's own temp folder (outside your project).
  "$DOZ" run @mac -d --fenced ${PFLAGS[@]+"${PFLAGS[@]}"} --session "$SESSION" --workdir "$WORKDIR" -- /bin/sh -c \
    "( $RUN ) > \"\$TMPDIR/fence-freeze.out\" 2>&1; echo \$? > \"\$TMPDIR/fence-freeze.rc\"; sleep 3600" \
    || { echo "fence-freeze: the session did not start" >&2; exit 1; }
else
  "$DOZ" run @mac -d --fenced ${PFLAGS[@]+"${PFLAGS[@]}"} --session "$SESSION" --workdir "$WORKDIR" -- claude "$@" \
    || { echo "fence-freeze: the session did not start" >&2; exit 1; }
fi
STORE=${DOZ_STORE:-$("$DOZ" config get store.path 2>/dev/null | tail -1)}
STORE=${STORE/#\~/$HOME}
read -r TAG FOLDER < <(/usr/bin/python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))["sessions"][sys.argv[2]]["fence"]; print(f["tag"], f["sessionFolder"])' \
      "$STORE/mac-sessions/sessions.json" "$SESSION" 2>/dev/null)
[ -n "${TAG:-}" ] || { echo "fence-freeze: no tag for $SESSION in $STORE" >&2; "$DOZ" sessions end @mac "$SESSION" --yes; exit 1; }
RC=""
if [ -n "$RUN" ]; then
  echo "fence-freeze: session $SESSION (tag $TAG, $PROFILE) runs: $RUN"
  while [ ! -s "$FOLDER/tmp/fence-freeze.rc" ]; do
    sleep 2
    "$DOZ" sessions @mac --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin) if x["name"]==sys.argv[1]]; sys.exit(0 if r and not r[0].get("ended") else 1)' "$SESSION" || break
  done
  RC=$(cat "$FOLDER/tmp/fence-freeze.rc" 2>/dev/null || echo "?")
  tail -40 "$FOLDER/tmp/fence-freeze.out" > "$SCRATCH/out.tail" 2>/dev/null
  echo "fence-freeze: it exited $RC"
else
  echo "fence-freeze: session $SESSION (tag $TAG) — work in it as you would (edit, run tests, fetch a page), then /exit."
  "$DOZ" attach @mac "$SESSION"
fi
"$DOZ" sessions end @mac "$SESSION" --yes >/dev/null 2>&1
sleep 2
kill "$LOGPID" 2>/dev/null

if [ "$PROFILE" = agent ]; then TOOL="Claude Code $(claude --version 2>/dev/null | head -1)"; else TOOL="$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"; fi
/usr/bin/python3 - "$LOG" "$TAG" "$OUT" "$HOME" "$(sw_vers -productVersion) ($(sw_vers -buildVersion))" "$("$DOZ" --version 2>/dev/null | head -1)" \
  "$TOOL" "$PROFILE" "$HERE/../Sources/DozableHost/MacFenceProfile.swift" "$RC" "$SCRATCH/out.tail" "$RUN" <<'PY'
import json, re, sys, collections, os
log, tag, out, home, macos, doz, tool, profile, swift, rc, tailf, run = sys.argv[1:13]
# The profile's lists, read from the source (never a copy that drifts).
src = open(swift).read() if os.path.exists(swift) else ""
def lst(name):
    m = re.search(r"static let " + name + r"(?:: \[String\])? = \[(.*?)\]", src, re.S)
    return set(re.findall(r'"([^"]+)"', m.group(1))) if m else set()
names = lst("agentMachServices")
prefixes = set()
if profile in ("xcode", "simulator"):
    names |= lst("xcodeMachServices"); prefixes |= lst("xcodeMachPrefixes")
if profile == "simulator":
    names |= lst("simulatorMachServices"); prefixes |= lst("simulatorMachPrefixes")
def allowed(n): return n in names or any(n.startswith(p) for p in prefixes)
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
    f.write(f"fence-freeze report — profile {profile}; macOS {macos}; {doz}; {tool}; tag {tag}\n")
    if run:
        f.write(f"command: {run}\nexit code: {rc}\n")
    f.write("Refusals the kernel logged for the session (macOS folds repeats: presence, not counts).\n\n")
    mach = sorted({t for (t, _) in seen.get("mach-lookup", {})})
    ls = [t for t in mach if "launchservices" in t.lower() or t.startswith("com.apple.lsd.") or "CoreSimulator" in t]
    prefs = sorted({t for (t, _) in seen.get("user-preference-write", {})})
    f.write("== Summary\n")
    f.write("  LaunchServices / CoreSimulator refused: " + (", ".join(ls) if ls else "none") + "\n")
    f.write("  preference writes refused: " + (", ".join(prefs) if prefs else "none") + "\n")
    f.write("  Mach services refused that the profile does not allow: " + str(sum(1 for t in mach if not allowed(t))) + "\n\n")
    f.write("== Mach services refused (" + str(len(mach)) + ")\n")
    for t in mach:
        f.write(("  NEW  " if not allowed(t) else "       ") + t + "\n")
    for op in sorted(seen):
        if op == "mach-lookup":
            continue
        f.write(f"\n== {op}\n")
        for (t, p), n in sorted(seen[op].items()):
            f.write(f"  {t}   ({p})\n")
    if run and os.path.exists(tailf):
        f.write("\n== the end of the command's output\n" + open(tailf, errors="replace").read())
print(f"fence-freeze: report written to {out}")
PY
