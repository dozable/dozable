#!/bin/bash
# test-recipe-catalogue.sh — `make test-recipe-catalogue`: the recipe catalogue end to end, offline, with a THROWAWAY key.
#
#   an edited copy of the tree's recipes (Grok Build published, its description changed; a NEW recipe, "LLM Two")
#   → make publish-recipes into a scratch site (signed, checked by this doz) → a local server (python3 http.server on
#   127.0.0.1) → a REAL host in a scratch store refreshes: first nothing published (404 — the embedded set stays), then
#   the catalogue (its files sha256-checked → next.json) → the next host start applies it → NEW processes use it
#   (doz doctor, doz search); a tampered file is never used; a re-publish is idempotent; nothing is pushed.
#
# Never the network, never the real key, never the owner's store/settings: everything under one scratch folder, a
# guarded run (DOZ_TEST_GUARD=1) with its own settings dir, store and seams.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DOZ="${1:?the built doz (.build/debug/doz)}"
R="$(mktemp -d "${TMPDIR:-/tmp/}doz-test-recipes.XXXXXX")"
PORT=$(( 17911 + RANDOM % 300 ))
pass=0; failn=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$*"; }
bad() { failn=$((failn + 1)); printf 'FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
server=""
export DOZ_TEST_GUARD=1 DOZ_TEST_NO_MAC_LOGIN=1 DOZ_TEST_CREDENTIALS=memory DOZ_TEST_CODEX_HOME="$R/codex"
export XDG_CONFIG_HOME="$R/xdg"
STORE="$R/store"
mkdir -p "$R/codex" "$R/xdg/doz" "$STORE" "$R/projects"
printf '[store]\npath = "%s"\n\n[defaults]\nprojects_dir = "%s"\n' "$STORE" "$R/projects" > "$R/xdg/doz/doz.toml"
cleanup() {
    "$DOZ" host stop --store "$STORE" >/dev/null 2>&1 || true
    if [[ -n "$server" ]]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
    [[ -n "${KEEP:-}" ]] || rm -rf "$R"
}
trap cleanup EXIT
CACHE="$R/xdg/doz/recipes"
# doz doctor's recipes line, from a NEW process (env args first: `recipes -u VAR`).
recipes() { env "$@" "$DOZ" doctor --json --store "$STORE" 2>/dev/null | python3 -c 'import json,sys
d=[c for c in json.loads(sys.stdin.read() or "[]") if c.get("check")=="recipes"]
print(d[0]["detail"] if d else "none")'; }

# ── an edited copy of the tree's recipes ─────────────────────────────────────
cp -R Sources/DozableKit/Recipes "$R/recipes"
python3 - "$R/recipes/compiled" <<'PY'
import json, sys, os
d = sys.argv[1]
def directory(doc):
    return next(c for c in doc["capabilities"] if c["type"] == "com.dozable/directory@1")["config"]
g = json.load(open(os.path.join(d, "grok.json")))
g["description"] = "Grok Build, from the recipe catalogue."
g["displayName"] = "Grok Build (catalogue)"
directory(g).pop("published", None)                    # the catalogue offers it again
json.dump(g, open(os.path.join(d, "grok.json"), "w"), indent=2, sort_keys=True)
n = json.load(open(os.path.join(d, "llm.json")))        # a NEW recipe: a copy of llm as "llm2"
n["id"] = n["id"].split("/")[0] + "/llm2"
n["displayName"] = "LLM Two"
n["provides"] = ["com.dozable/llm2@${{ kit.args.version }}"]
directory(n).pop("published", None)
for c in n["capabilities"]:
    if c["type"] == "com.docker.sandbox/network-policy@1":
        c["config"]["dozable"]["model"]["id"] = "model:llm2"
json.dump(n, open(os.path.join(d, "llm2.json"), "w"), indent=2, sort_keys=True)
PY

# ── the test key, publish ────────────────────────────────────────────────────
PUB="$(swift Scripts/update-key.swift test-key "$R/key")"
export DOZ_TEST_UPDATE_KEY="$PUB"
git init -q -b main "$R/site"
pubr() { env TEST_PUBLISH=1 UPDATE_KEY_FILE="$R/key" UPDATE_PUBLIC_KEY="$PUB" RECIPES_DIR="$R/recipes" UPDATES_DIR="$R/site" \
         DOZ="$DOZ" "$@" Scripts/publish-recipes.sh >"$R/publish.log" 2>&1; }
check "embedded first: doz doctor says the build's own recipes" grep -q '^embedded (doz ' <<<"$(recipes)"
check "UPDATE_KEY_FILE outside TEST_PUBLISH=1 is refused" bash -c "! env UPDATE_KEY_FILE='$R/key' UPDATES_DIR='$R/site' DOZ='$DOZ' Scripts/publish-recipes.sh >/dev/null 2>&1"
check "a key doz does not trust is refused (nothing written)" bash -c "! env TEST_PUBLISH=1 UPDATE_KEY_FILE='$R/key' UPDATE_PUBLIC_KEY=$(swift Scripts/update-key.swift test-key "$R/other") RECIPES_DIR='$R/recipes' UPDATES_DIR='$R/site' DOZ='$DOZ' Scripts/publish-recipes.sh >/dev/null 2>&1 && [ ! -e '$R/site/v1/recipes.json' ]"
check "publish → serial 1, checked by this doz" pubr
check "  … v1/recipes.json and v1/recipes/1/ are written" bash -c "[ -f '$R/site/v1/recipes.json' ] && [ -f '$R/site/v1/recipes/1/agents/llm2.json' ] && [ ! -e '$R/site/v1/recipes/1/agents/claude-code.json' ]"
check "  … committed in the site, never pushed (no PUSH=1)" bash -c "git -C '$R/site' log --oneline -1 | grep -q 'recipe catalogue 1' && grep -q 'not pushed' '$R/publish.log'"
cp "$R/site/v1/recipes.json" "$R/manifest.before"
check "a re-publish of the same data is idempotent" bash -c "env TEST_PUBLISH=1 UPDATE_KEY_FILE='$R/key' UPDATE_PUBLIC_KEY='$PUB' RECIPES_DIR='$R/recipes' UPDATES_DIR='$R/site' DOZ='$DOZ' Scripts/publish-recipes.sh 2>&1 | grep -q 'already says this' && cmp -s '$R/manifest.before' '$R/site/v1/recipes.json'"

# ── the local server: nothing published yet ──────────────────────────────────
mkdir -p "$R/www/v1"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$R/www" >"$R/server.log" 2>&1 &
server=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
export DOZ_TEST_RECIPE_CATALOGUE="http://127.0.0.1:$PORT/v1/recipes.json"
waitfor() { local i; for i in $(seq 1 100); do eval "$1" && return 0; sleep 0.2; done; return 1; }
"$DOZ" host start --store "$STORE" >/dev/null
check "404: the host asked, and keeps the embedded set" waitfor "grep -q 'GET /v1/recipes.json HTTP/1.1\" 404' '$R/server.log'"
"$DOZ" host stop --store "$STORE" >/dev/null
check "  … no catalogue cached" bash -c "[ ! -e '$CACHE/next.json' ] && [ ! -e '$CACHE/current.json' ]"
check "  … a command still uses the embedded set" grep -q '^embedded (doz ' <<<"$(recipes)"

# ── published: the host's refresh downloads it; the next host start applies it ──
cp -R "$R/site/v1/." "$R/www/v1/"
rm -f "$CACHE/state.json"                       # the hour since the 404 has "passed"
"$DOZ" host start --store "$STORE" >/dev/null
check "the host's refresh fetched it → next.json (files sha256-checked)" waitfor "[ -f '$CACHE/next.json' ] && [ -f '$CACHE/files/1/agents/llm2.json' ]"
line="$(recipes)"
check "  … a command still uses what the running host uses (embedded)" grep -q '^embedded (doz .*catalogue 1 is downloaded and applies at the next host start' <<<"$line"
"$DOZ" host stop --store "$STORE" >/dev/null
"$DOZ" host start --store "$STORE" >/dev/null
check "the next host start applied it (next.json → current.json)" waitfor "[ -f '$CACHE/current.json' ] && [ ! -e '$CACHE/next.json' ]"
check "  … the host log says so" grep -q "recipes: catalogue 1 from" "$STORE/host.log"
check "a NEW process uses catalogue 1" grep -q '^catalogue 1 from' <<<"$(recipes)"
"$DOZ" search llm2 --store "$STORE" >"$R/search.out" 2>&1 && rc=0 || rc=$?
check "  … doz search finds the catalogue's NEW recipe (exit 0)" bash -c "[ $rc = 0 ] && grep -q 'LLM Two' '$R/search.out'"
"$DOZ" search grok --details --store "$STORE" >"$R/grok.out" 2>&1 && rc=0 || rc=$?
check "  … and its edited copy of Grok Build (published again, its new title)" bash -c "[ $rc = 0 ] && grep -q '^Grok Build (catalogue)' '$R/grok.out'"
"$DOZ" search claude-code --details --store "$STORE" >"$R/claude.out" 2>&1 || true
check "  … the built-in Claude Code is this build's" grep -q '^Claude Code ' "$R/claude.out"
"$DOZ" host stop --store "$STORE" >/dev/null

# ── a tampered file is never used ─────────────────────────────────────────────
python3 - "$R/recipes/compiled/grok.json" <<'PY'
import json, sys
p = sys.argv[1]; g = json.load(open(p)); g["description"] = "Grok Build, catalogue two."; json.dump(g, open(p, "w"), indent=2, sort_keys=True)
PY
check "publish → serial 2" pubr
cp -R "$R/site/v1/." "$R/www/v1/"
printf ' ' >> "$R/www/v1/recipes/2/agents/grok.json"
rm -f "$CACHE/state.json"
"$DOZ" host start --store "$STORE" >/dev/null
check "a tampered file: the host refuses catalogue 2 (said in its log)" waitfor "grep -q 'catalogue 2 was ignored: agents/grok.json does not match its sha256' '$STORE/host.log'"
check "  … nothing waits, nothing of it is kept" bash -c "[ ! -e '$CACHE/next.json' ] && [ ! -e '$CACHE/files/2' ]"
"$DOZ" host stop --store "$STORE" >/dev/null
line="$(recipes)"
check "  … catalogue 1 stays in use, and doctor says the problem" grep -q '^catalogue 1 from.*does not match its sha256' <<<"$line"

# ── offline: the cache only, nothing asked ────────────────────────────────────
n0="$(grep -c 'GET /v1/recipes.json' "$R/server.log" || true)"
DOZ_TEST_RECIPE_CATALOGUE=offline "$DOZ" search llm2 --store "$STORE" >/dev/null 2>&1 && rc=0 || rc=$?
check "DOZ_TEST_RECIPE_CATALOGUE=offline: the cached catalogue, no request" bash -c "[ $rc = 0 ] && [ \"\$(grep -c 'GET /v1/recipes.json' '$R/server.log' || true)\" = '$n0' ]"
check "a guarded run without its seam uses the embedded set" grep -q '^embedded (doz ' <<<"$(recipes -u DOZ_TEST_RECIPE_CATALOGUE)"

printf '\ntest-recipe-catalogue: %d passed, %d failed%s\n' "$pass" "$failn" "$([[ -n "${KEEP:-}" ]] && echo " (kept $R)")"
[[ "$failn" == 0 ]]
