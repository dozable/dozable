#!/bin/sh
# The network profiler (617, owner: "profile all the recipes by running them and recording their network requests and
# then make a determination"). For each agent: a fresh try in a SCRATCH store with the Open network and every HTTPS
# request decrypted and logged (DOZ_TEST_PROFILE_NETWORK=1), its first start, then a short scripted task run
# non-interactively (read a file, edit it, run a command); every request is recorded (host, method, path, whether a
# key or a placeholder rode it) and merged into profiles/AGENT.json by Scripts/agent-profile.py.
#
#   make profile-agents AGENTS="grok gemini"            record (keeps every determination already made)
#   make profile-agents AGENTS="grok" DIFF=1            report new / missing endpoints only — never writes, never allows
#
# Keys are FAKE, always: xAI and Google go to Scripts/fake-provider.py (the provider seam, its own CA), which answers
# text only (no tool calls); Anthropic and OpenAI get a fake key the real API refuses (401). A real-key run would see
# more — the model's turns and what its tool calls fetch — and is never automated. Never the default store, the Mac's
# logins, the keychain or a real op/aws: the scratch store is $PROFILE_WORK (default /tmp/doz-profile, kept between
# runs so prepared images are reused; a short path — the host's socket must fit in 104 bytes).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
DOZ=${DOZ:-$REPO/.build/debug/doz}
W=${PROFILE_WORK:-/tmp/doz-profile}
OUT=${PROFILE_OUT:-$REPO/profiles}
MODE=record
[ "${1:-}" = "--diff" ] && { MODE=diff; shift; }
[ $# -gt 0 ] || { echo "usage: profile-agents.sh [--diff] AGENT..." >&2; exit 64; }
mkdir -p "$W/xdg/dozer-sandbox" "$W/store" "$W/projects" "$W/codex-home" "$W/fake" "$W/runs"
[ -f "$W/xdg/dozer-sandbox/doz.toml" ] || printf '[store]\npath = "%s/store"\n\n[defaults]\nprojects_dir = "%s/projects"\n' "$W" "$W" > "$W/xdg/dozer-sandbox/doz.toml"
export XDG_CONFIG_HOME="$W/xdg" DO_NOT_TRACK=1 DOZ_TEST_NO_MAC_LOGIN=1 DOZ_TEST_CREDENTIALS=memory DOZ_TEST_GUARD=1
export DOZ_TEST_CODEX_HOME="$W/codex-home" DOZ_TEST_PROFILE_NETWORK=1

# The fake provider (xAI, Google) with its own CA.
F="$W/fake"
FAKE_XAI_KEY=xai-FAKE-PROFILE-0123456789abcdef FAKE_GOOGLE_KEY=AIzaFAKEPROFILE-0123456789abcdef \
  sh "$REPO/Scripts/fake-provider-up.sh" "$F" >/dev/null || exit 1
export DOZ_TEST_PROVIDER_UPSTREAM="127.0.0.1:$(cat "$F/port")" DOZ_TEST_PROVIDER_CA="$F/ca.pem"

doz() { "$DOZ" "$@"; }
# A host started by someone else's environment would not log every request: start this store's host afresh.
doz host stop >/dev/null 2>&1
printf 'xai-FAKE-PROFILE-0123456789abcdef\n' | doz account add xai --provider xai --force >/dev/null 2>&1
printf 'AIzaFAKEPROFILE-0123456789abcdef\n' | doz account add google --provider google --force >/dev/null 2>&1
printf 'sk-ant-api03-FAKEPROFILE-0123456789abcdefghijklmnopqrstuvwxyz\n' | doz account add anthropic --api-key --no-verify --force >/dev/null 2>&1
printf 'sk-proj-FAKEPROFILE-0123456789abcdefghijklmnopqrstuvwxyz\n' | doz account add openai --openai-key --no-verify --force >/dev/null 2>&1
doz account default anthropic >/dev/null 2>&1
doz account default openai >/dev/null 2>&1

TASK="Read notes.txt, add a line that says done to it, then run ls -la and tell me what you see."
trial() { doz ls --json | /usr/bin/python3 -c 'import json,sys; r=[x["name"] for x in json.load(sys.stdin) if x.get("trial")]; print(r[0] if r else "")'; }
rc=0
for a in "$@"; do
  case "$a" in
    claude-code) bin=claude; task="claude -p \"\$T\"" ;;
    pi) bin=pi; task="pi -p \"\$T\"" ;;
    codex) bin=codex; task="codex exec --skip-git-repo-check \"\$T\"" ;;
    gemini) bin=gemini; task="gemini -p \"\$T\"" ;;
    grok) bin=grok; task="grok -p \"\$T\"" ;;
    antigravity) bin=agy; task="agy -p \"\$T\"" ;;
    # 617 (other AI tools): a tool that answers and exits gets the task as its prompt (no tools of its own to run).
    fabric) bin=fabric; task="cat notes.txt | fabric \"\$T\"" ;;
    nanobot) bin=nanobot; task="nanobot agent -m \"\$T\"" ;;
    gptme) bin=gptme; task="gptme --non-interactive \"\$T\"" ;;
    openclaw) bin=openclaw; task="openclaw agent exec \"\$T\" --auth-env-only --model google/gemini-2.5-flash --timeout 80" ;;
    *) echo "profile-agents: no scripted task for $a — add one here" >&2; rc=2; continue ;;
  esac
  old=$(trial); [ -n "$old" ] && doz rm "$old" --yes >/dev/null 2>&1
  echo "== $a: a fresh try (Open network, every request logged)"
  doz try "$a" -d -q --rebuild --network open || { rc=1; continue; }
  n=$(trial)
  sleep "${PROFILE_FIRST_START_SECONDS:-25}"
  start=$(/bin/date +%s)
  echo "== $a: the scripted task"
  doz exec "$n" -- sh -c "cd /workspace && printf 'hello\n' > notes.txt && T='$TASK' && timeout ${PROFILE_TASK_SECONDS:-90} $task" > "$W/runs/$a.task.txt" 2>&1
  sleep 5
  version=$(doz exec "$n" -- "$bin" --version 2>/dev/null | head -1)
  doz net log "$n" --json > "$W/runs/$a.log.json"
  /usr/bin/python3 "$REPO/Scripts/agent-profile.py" "$MODE" --agent "$a" --version "$version" --log "$W/runs/$a.log.json" \
    --task-start "$start" --task-output "$W/runs/$a.task.txt" --profile "$OUT/$a.json" || rc=1
  doz rm "$n" --yes >/dev/null 2>&1
  rm -rf "$W/projects/$n"
done
doz host stop >/dev/null 2>&1
kill "$(cat "$F/pid")" 2>/dev/null
exit $rc
