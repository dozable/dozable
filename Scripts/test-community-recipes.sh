#!/bin/bash
# test-community-recipes.sh — `make test-community-recipes`: your own recipes and community catalogues end to end, offline,
# with THROWAWAY keys and a scratch settings folder, store and site (653).
#
#   1. yours: `doz recipe new` writes a file that fails `doz recipe check`; a copy of OpenCode (--from) fails only on what
#      is yours to fill in, passes once filled in (the pass recorded with the file's sha256); it is labelled "yours" in
#      doz search, doz try's list and the plan; a recipe with one of Dozable's ids is refused.
#   2. a community catalogue: published with `make publish-recipes COMMUNITY=1` (a throwaway key) → a local server →
#      `doz recipe source add` refuses and fetches NOTHING before the key's fingerprint is confirmed, a wrong fingerprint
#      too; confirmed, it is fetched and used, labelled "community · example"; a sandbox of it is refused without a yes
#      (no terminal), made after `doz recipe trust`.
#   3. a second source offering the same id is refused whole, and said; the first stays.
#   4. a tampered serial is refused whole by the host's refresh; the one in use stays.
#   5. removing the source (and your recipe) never breaks the sandbox made from it: its record lists and inspects, the
#      recipe is kept unpublished; nothing is pushed.
#
# Never the network, never the real key, never the owner's store or settings: a guarded run (DOZ_TEST_GUARD=1).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DOZ="${1:?the built doz (.build/debug/doz)}"
R="$(mktemp -d "${TMPDIR:-/tmp/}doz-test-community.XXXXXX")"
PORT=$(( 18211 + RANDOM % 300 ))
pass=0; failn=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$*"; }
bad() { failn=$((failn + 1)); printf 'FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
server=""
export DOZ_TEST_GUARD=1 DOZ_TEST_NO_MAC_LOGIN=1 DOZ_TEST_CREDENTIALS=memory DOZ_TEST_CODEX_HOME="$R/codex" DO_NOT_TRACK=1 NO_COLOR=1
export XDG_CONFIG_HOME="$R/xdg"
unset DOZ_TEST_RECIPE_CATALOGUE DOZ_TEST_UPDATE_KEY
STORE="$R/store"
mkdir -p "$R/codex" "$R/xdg/doz" "$STORE" "$R/projects" "$R/pub" "$R/pub2" "$R/www"
printf '[store]\npath = "%s"\n\n[defaults]\nprojects_dir = "%s"\n' "$STORE" "$R/projects" > "$R/xdg/doz/doz.toml"
cleanup() {
    "$DOZ" host stop --store "$STORE" >/dev/null 2>&1 || true
    if [[ -n "$server" ]]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
    [[ -n "${KEEP:-}" ]] || rm -rf "$R"
}
trap cleanup EXIT
RECIPES="$R/xdg/doz/recipes"
d() { "$DOZ" "$@" --store "$STORE" </dev/null; }
# run d, keep its output in $R/out and its exit status in $rc
run() { d "$@" >"$R/out" 2>&1 && rc=0 || rc=$?; }
has() { grep -q -- "$1" "$R/out"; }
waitfor() { local i; for i in $(seq 1 150); do eval "$1" && return 0; sleep 0.2; done; return 1; }

# ── 1. yours ──────────────────────────────────────────────────────────────────
run recipe ls
check "no recipe of yours yet" has "No recipes of yours"
run recipe new mytool
check "doz recipe new writes recipes/mine/mytool.yaml" bash -c "[ $rc = 0 ] && [ -f '$RECIPES/mine/mytool.yaml' ]"
run recipe check mytool
check "  … the file to fill in fails doz recipe check (exit 1, item by item, one verdict)" bash -c "[ $rc = 1 ] && grep -q '✓ document' '$R/out' && grep -q '✕ about' '$R/out' && grep -q 'does not meet the minimum requirements for a community recipe' '$R/out'"
run recipe new opencode
check "doz recipe new with one of Dozable's ids is refused" bash -c "[ $rc != 0 ] && grep -q \"one of Dozable's own recipes\" '$R/out'"
run recipe new myopen --from opencode
check "doz recipe new myopen --from opencode writes a copy" bash -c "[ $rc = 0 ] && grep -q '^id: local/myopen' '$RECIPES/mine/myopen.yaml'"
run recipe check myopen
check "  … the copy fails only on what is yours to fill in (about)" bash -c "[ $rc = 1 ] && grep -q '✕ about' '$R/out' && grep -q '1 of 13 failed' '$R/out'"
python3 - "$RECIPES/mine/myopen.yaml" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r"(?m)^author: .*$", "author: The test", s)
s = re.sub(r"(?m)^sourceUrl: .*$", "sourceUrl: https://example.com/myopen", s)
s = re.sub(r"(?m)^description: .*$", "description: OpenCode, as a recipe of my own.", s)
open(p, "w").write(s)
PY
run recipe check myopen
check "  … filled in, it passes (exit 0)" bash -c "[ $rc = 0 ] && grep -q '^meets the minimum requirements for a community recipe' '$R/out'"
SHA="$(shasum -a 256 "$RECIPES/mine/myopen.yaml" | cut -d' ' -f1)"
check "  … the pass is recorded with the file's sha256" grep -q "$SHA" "$RECIPES/checks.json"
run recipe ls
check "  … doz recipe ls: myopen yours, in use, checked" bash -c "grep -E '^myopen +yours +in use +static' '$R/out' >/dev/null"
check "  … and mytool refused (it is not filled in)" bash -c "grep -E '^mytool +yours +refused' '$R/out' >/dev/null"
run search myopen
check "doz search labels it [yours] (654: beside its full name)" bash -c "[ $rc = 0 ] && grep -q 'My OpenCode · mine/local/myopen \[yours\] — supported' '$R/out'"
run try
check "doz try's list labels it [yours]" bash -c "[ $rc = 64 ] && grep -q '\[yours\]' '$R/out'"
run try myopen --dry-run
check "the plan says whose recipe it is and what its bake installs" bash -c "grep -q 'recipe: mine/local/myopen.* — your own recipe' '$R/out' && grep -q 'installs: npm-platform-binary opencode-ai' '$R/out'"
# 654: its full name — with its source; without one, a name means Dozable's recipe.
run try mine/local/myopen --dry-run
check "654: doz try mine/local/myopen plans it" bash -c "[ $rc = 0 ] && grep -q 'recipe: mine/local/myopen' '$R/out'"
run try local/myopen --dry-run
check "654: … local/myopen (no source) is refused, naming mine/local/myopen" bash -c "[ $rc != 0 ] && grep -q 'yours — mine/local/myopen' '$R/out'"
run recipe show mine/local/myopen
check "654: doz recipe show takes and shows the full name" bash -c "[ $rc = 0 ] && head -1 '$R/out' | grep -q 'mine/local/myopen'"
sed -e 's#^id: local/myopen#id: local/opencode#' -e 's#com.dozable/myopen@#com.dozable/opencode@#' -e 's#model:myopen#model:opencode2x#' "$RECIPES/mine/myopen.yaml" > "$R/clash.yaml"
run recipe add "$R/clash.yaml"
check "doz recipe add of a recipe with Dozable's id is refused (not-dozable)" bash -c "[ $rc != 0 ] && grep -q '✕ not-dozable' '$R/out' && [ ! -e '$RECIPES/mine/opencode.yaml' ]"

# ── 2. a community catalogue ─────────────────────────────────────────────────
KEYOUT="$(swift Scripts/update-key.swift community-key "$R/key")"
PUB="$(sed -n 's/^public key: *//p' <<<"$KEYOUT")"
FP="$(sed -n 's/^fingerprint: *//p' <<<"$KEYOUT")"
sed -e 's#^id: local/myopen#id: example/comtool#' -e 's#com.dozable/myopen@#com.dozable/comtool@#' -e 's#model:myopen#model:comtool#' \
    -e 's#^displayName: .*#displayName: Com Tool#' "$RECIPES/mine/myopen.yaml" > "$R/pub/comtool.yaml"
git init -q -b main "$R/site"
pubc() { env COMMUNITY=1 RECIPES_DIR="$1" UPDATE_KEY_FILE="$2" UPDATES_DIR="$3" DOZ="$DOZ" Scripts/publish-recipes.sh >"$R/publish.log" 2>&1; }
check "make publish-recipes COMMUNITY=1 → serial 1, signed with the publisher's key, accepted by this doz" pubc "$R/pub" "$R/key" "$R/site"
check "  … agents only, product doz-community-recipes" bash -c "[ -f '$R/site/v1/recipes/1/agents/comtool.json' ] && [ ! -e '$R/site/v1/recipes/1/providers.json' ] && grep -q '\"doz-community-recipes\"' '$R/site/v1/recipes.json'"
check "  … committed, never pushed" bash -c "git -C '$R/site' log --oneline -1 | grep -q 'community recipe catalogue 1' && grep -q 'not pushed' '$R/publish.log' && [ -z \"\$(git -C '$R/site' remote)\" ]"
mkdir -p "$R/www/one"
cp -R "$R/site/v1" "$R/www/one/"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$R/www" >"$R/server.log" 2>&1 &
server=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
URL="http://127.0.0.1:$PORT/one/v1/recipes.json"
run recipe source add "$URL" --key "$PUB" --name example
check "not confirmed (no terminal, no --fingerprint): refused, exit 5" bash -c "[ $rc = 5 ] && grep -q \"$FP\" '$R/out'"
check "  … nothing fetched, nothing saved" bash -c "! grep -q 'GET /one/v1/recipes.json' '$R/server.log' && [ ! -e '$RECIPES/sources.json' ]"
run search comtool
check "  … its recipe is unknown to doz search" bash -c "[ $rc = 2 ]"
run recipe source add "$URL" --key "$PUB" --name example --fingerprint "SHA256:not-it"
check "a wrong fingerprint: refused, nothing fetched" bash -c "[ $rc != 0 ] && ! grep -q 'GET /one/v1/recipes.json' '$R/server.log'"
run recipe source add "$URL" --key "$PUB" --name example --fingerprint "$FP"
check "confirmed: fetched and verified, in use (no host runs)" bash -c "[ $rc = 0 ] && grep -q 'catalogue 1 downloaded and verified' '$R/out' && grep -q 'in use from now' '$R/out' && grep -q 'GET /one/v1/recipes.json' '$R/server.log'"
run search comtool
check "doz search labels it [community · example] (654: beside its full name)" bash -c "[ $rc = 0 ] && grep -q 'Com Tool · example/example/comtool \[community · example\] — supported' '$R/out'"
run try
check "doz try's list labels it [community · example]" grep -q 'Com Tool · example/example/comtool \[community · example\]' "$R/out"
run recipe source add "$URL" --key "$PUB" --name mine --fingerprint "$FP"
check "654: a source may not be called mine" bash -c "[ $rc != 0 ] && grep -q 'a word of recipe names' '$R/out'"
run recipe source ls
check "doz recipe source ls: example, its key fingerprint, in use, catalogue 1" bash -c "grep -q '^example — $URL' '$R/out' && grep -q \"key $FP\" '$R/out' && grep -q 'in use · catalogue 1 · recipes: comtool' '$R/out'"
printf 'xai-FAKE-COMMUNITYTEST-0123456789abcdef\n' | "$DOZ" account add k1 --provider xai --no-verify --store "$STORE" >/dev/null 2>&1 || true
run create c1 --agent comtool
check "a sandbox of a community recipe without a yes (no terminal): refused, exit 5, naming doz recipe trust" bash -c "[ $rc = 5 ] && grep -q 'doz recipe trust comtool' '$R/out' && grep -q 'a community recipe from example' '$R/out'"
run recipe trust comtool
check "doz recipe trust comtool says yes for this version" bash -c "[ $rc = 0 ] && grep -q '\"comtool\"' '$RECIPES/trusted.json'"
run create c1 --agent comtool
check "  … then the sandbox is made" bash -c "[ $rc = 0 ] && grep -q '^created c1: comtool' '$R/out'"
d host stop >/dev/null 2>&1 || true

# ── 3. a second source with the same id is refused whole ─────────────────────
KEYOUT2="$(swift Scripts/update-key.swift community-key "$R/key2")"
PUB2="$(sed -n 's/^public key: *//p' <<<"$KEYOUT2")"
FP2="$(sed -n 's/^fingerprint: *//p' <<<"$KEYOUT2")"
cp "$R/pub/comtool.yaml" "$R/pub2/comtool.yaml"
git init -q -b main "$R/site2"
check "a second publisher's catalogue (the same id) is published" pubc "$R/pub2" "$R/key2" "$R/site2"
mkdir -p "$R/www/two"
cp -R "$R/site2/v1" "$R/www/two/"
run recipe source add "http://127.0.0.1:$PORT/two/v1/recipes.json" --key "$PUB2" --name other --fingerprint "$FP2"
check "  … added, and said it would not be used (comtool is another recipe's)" bash -c "[ $rc = 0 ] && grep -q 'it would not be used' '$R/out'"
run recipe source ls
check "  … doz recipe source ls: other refused whole, example still in use" bash -c "grep -A2 '^other — ' '$R/out' | grep -q 'refused: comtool.json: comtool is already another recipe' && grep -A2 '^example — ' '$R/out' | grep -q 'in use'"
run search comtool
check "  … comtool is still example's" grep -q 'Com Tool · example/example/comtool \[community · example\]' "$R/out"

# ── 4. a tampered serial is refused whole ────────────────────────────────────
sed -i '' 's#^description: .*#description: OpenCode, catalogue two.#' "$R/pub/comtool.yaml"
check "example publishes serial 2" pubc "$R/pub" "$R/key" "$R/site"
cp -R "$R/site/v1/." "$R/www/one/v1/"
printf ' ' >> "$R/www/one/v1/recipes/2/agents/comtool.json"
rm -f "$RECIPES/community/example/state.json"
d host start >/dev/null
check "the host's refresh refuses serial 2 (a file does not match its sha256), said in its log" waitfor "grep -q 'community recipes example: catalogue 2 was ignored: agents/comtool.json does not match its sha256' '$STORE/host.log'"
d host stop >/dev/null 2>&1 || true
check "  … nothing waits; serial 1 stays in use" bash -c "[ ! -e '$RECIPES/community/example/next.json' ] && [ ! -e '$RECIPES/community/example/files/2' ] && grep -Eq '\"serial\": *1,' '$RECIPES/community/example/current.json'"

# ── 5. removal never breaks a sandbox ────────────────────────────────────────
run recipe source rm example --yes
check "doz recipe source rm example: its recipes kept for the sandboxes" bash -c "[ $rc = 0 ] && [ -f '$RECIPES/kept/comtool.json' ] && [ ! -e '$RECIPES/community/example' ]"
run ls --json
check "  … c1's record still lists, made from comtool" bash -c "[ $rc = 0 ] && grep -q '\"image\" : \"comtool\"' '$R/out'"
run inspect c1
check "  … and inspects" bash -c "[ $rc = 0 ]"
run recipe ls --all
check "  … doz recipe ls --all: comtool removed, kept" bash -c "grep -E '^comtool +community · example +removed — kept for its sandboxes' '$R/out' >/dev/null"
run recipe source ls
check "  … the other source's comtool is never put under it: still refused (the id is the kept one's)" bash -c "grep -A2 '^other — ' '$R/out' | grep -q 'refused: comtool.json: comtool is already another recipe'"
run search comtool
check "  … offered nowhere (doz search)" bash -c "[ $rc != 0 ]"
run recipe rm comtool --forget --yes
check "  … --forget is refused while c1 was made from it" bash -c "[ $rc != 0 ] && grep -q 'c1 was made from comtool' '$R/out'"
run recipe rm myopen --yes
check "doz recipe rm myopen: removed, kept" bash -c "[ $rc = 0 ] && [ ! -e '$RECIPES/mine/myopen.yaml' ] && [ -f '$RECIPES/kept/myopen.json' ]"
check "nothing pushed (no remote in either site)" bash -c "[ -z \"\$(git -C '$R/site' remote)\" ] && [ -z \"\$(git -C '$R/site2' remote)\" ]"

printf '\ntest-community-recipes: %d passed, %d failed%s\n' "$pass" "$failn" "$([[ -n "${KEEP:-}" ]] && echo " (kept $R)")"
[[ "$failn" == 0 ]]
