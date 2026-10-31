#!/bin/bash
# publish-recipes.sh — put the tree's recipe data on Dozable's recipe directory, doz.sh, as a signed recipe catalogue
# (`make publish-recipes`).
#
#   make publish-recipes                        # → DIRECTORY_DIR/v1/recipes.json + v1/recipes/<serial>/ + v1/index.json
#                                               #   (+ CNAME, .nojekyll), committed, NOT pushed
#   make publish-recipes MIN_DOZ=0.37.20        # the oldest doz that reads every file (default: the published one's, else VERSION)
#   make publish-recipes DRY_RUN=1              # show what would change, write nothing
#   make publish-recipes PUSH=1                 # … push the directory's repository (the owner's word first), then wait for it live
#
# DIRECTORY_DIR is a checkout of the directory's GitHub Pages repository (the host of Distribution.recipeCatalogueURL in
# Sources/DozableHost/Updates.swift — doz.sh); never the update site (that holds the feed and is refused). The catalogue
# is signed with Dozable's update key (the login keychain's; a test passes UPDATE_KEY_FILE with TEST_PUBLISH=1). In order:
#
#   1. Scripts/recipe-catalogue.py stages the committed compiled data (Recipes/compiled, less the built-in three;
#      providers, gateways, tags, known, icons) with the next serial — or says "unchanged" and stops;
#   2. the message is signed (update-key.swift sign-catalogue) and the signature checked against the key doz carries
#      (Distribution.updatePublicKey; a test: UPDATE_PUBLIC_KEY) — a key doz does not trust is refused here;
#   3. THIS build's doz reads the staged catalogue (a guarded run, scratch settings and store, the file seam) and must
#      use it: the same signature check, the same merge and every validator a doz runs at its start;
#   4. only then DIRECTORY_DIR gets v1/recipes/<serial>/ and v1/recipes.json (older serials are kept: an installed doz
#      may still be fetching one), v1/index.json (`doz search --index`: dozable-directory/v1, unsigned, for the website —
#      doz never reads it), CNAME (the constant's host) and .nojekyll; a commit when it is a git checkout; a push only
#      with PUSH=1, and then it waits until the live catalogue says the new serial.
#
# macOS bash 3.2 — no bash 4.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
say() { printf '%s\n' "$*"; }
fail() { printf 'x publish-recipes: %s\n' "$*" >&2; exit 1; }
dist_value() { sed -n "s/.*static let $1 = \"\\([^\"]*\\)\".*/\\1/p" Sources/DozableHost/Updates.swift | head -1; }

DOZ="${DOZ:-.build/debug/doz}"
DRY_RUN="${DRY_RUN:-}"; PUSH="${PUSH:-}"; TEST_PUBLISH="${TEST_PUBLISH:-}"; COMMUNITY="${COMMUNITY:-}"

# ── 653: a COMMUNITY catalogue — a publisher's own recipes, signed with their OWN key ─────────────────────────────────
#
#   make publish-recipes COMMUNITY=1 RECIPES_DIR=<folder of YAML recipes> UPDATE_KEY_FILE=<your key> UPDATES_DIR=<your site>
#                        [MIN_DOZ=] [DRY_RUN=1] [PUSH=1]
#
# The same format (v1/recipes.json + v1/recipes/<serial>/), product "doz-community-recipes", recipes only (agents/<id>.json).
# A key of your own: `swift Scripts/update-key.swift community-key FILE` (it prints the public key and its fingerprint —
# publish both where people can compare them). In order: each YAML compiled by this doz (`doz recipe show FILE --document`)
# → staged with the next serial → signed with your key → checked against its public half → THIS doz must accept it
# (`doz recipe source verify`: signature, format, every recipe's minimum requirements, no id of Dozable's) → only then the
# site; a commit when it is a git checkout; a push only with PUSH=1.
if [[ -n "$COMMUNITY" ]]; then
    [[ -n "${UPDATE_KEY_FILE:-}" && -f "${UPDATE_KEY_FILE:-}" ]] || fail "COMMUNITY=1 signs with your own key: UPDATE_KEY_FILE=<file> (swift Scripts/update-key.swift community-key FILE makes one)"
    [[ -n "${RECIPES_DIR:-}" && -d "${RECIPES_DIR:-}" ]] || fail "COMMUNITY=1 needs RECIPES_DIR=<a folder of your YAML recipes>"
    [[ -n "${UPDATES_DIR:-}" ]] || fail "COMMUNITY=1 needs UPDATES_DIR=<your site's folder>"
    if [[ -n "$PUSH" ]]; then git -C "$UPDATES_DIR" remote get-url origin >/dev/null 2>&1 || fail "PUSH=1 but $UPDATES_DIR is not a git checkout with an origin"; fi
    [[ -x "$DOZ" ]] || fail "no $DOZ — make cli first"
    PUB="$(swift Scripts/update-key.swift public-of "$UPDATE_KEY_FILE")"
    [[ "$PUB" != "$(dist_value updatePublicKey)" ]] || fail "that is Dozable's own key — a community catalogue is signed with its publisher's"
    VERSION_NOW="$(tr -d '[:space:]' < VERSION)"
    PUBLISHED="$UPDATES_DIR/v1/recipes.json"
    if [[ -z "${MIN_DOZ:-}" ]]; then
        MIN_DOZ="$( [[ -f "$PUBLISHED" ]] && python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["minimum_doz"])' "$PUBLISHED" || echo "$VERSION_NOW")"
    fi
    say "━━━ publish a community recipe catalogue (needs doz $MIN_DOZ${DRY_RUN:+, dry run})"
    work="$(mktemp -d "${TMPDIR:-/tmp/}doz-publish-community.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    mkdir -p "$work/agents" "$work/xdg/doz" "$work/store" "$work/codex"
    printf '[store]\npath = "%s"\n' "$work/store" > "$work/xdg/doz/doz.toml"
    scratch_doz() { env DOZ_TEST_GUARD=1 DOZ_TEST_NO_MAC_LOGIN=1 DOZ_TEST_CREDENTIALS=memory DOZ_TEST_CODEX_HOME="$work/codex" \
                        XDG_CONFIG_HOME="$work/xdg" "$DOZ" "$@" --store "$work/store"; }
    n=0
    for y in "$RECIPES_DIR"/*.yaml "$RECIPES_DIR"/*.yml; do
        [[ -f "$y" ]] || continue
        scratch_doz recipe show "$y" --document > "$work/one.json" 2>"$work/err" || fail "$y does not read as a recipe: $(cat "$work/err")"
        id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"].split("/")[-1])' "$work/one.json")"
        [[ ! -e "$work/agents/$id.json" ]] || fail "two recipes are $id"
        mv "$work/one.json" "$work/agents/$id.json"
        n=$((n + 1))
    done
    [[ "$n" -gt 0 ]] || fail "no *.yaml recipe in $RECIPES_DIR"
    STAGE="$work/stage"
    GOT="$(python3 Scripts/recipe-catalogue.py prepare --community --agents "$work/agents" --site "$UPDATES_DIR" --stage "$STAGE" \
        --min-doz "$MIN_DOZ" --source-version "$VERSION_NOW" --date "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    case "$GOT" in
        unchanged*) say "  • the published catalogue (serial ${GOT#unchanged }) already says this — nothing to do"; exit 0 ;;
        new*) SERIAL="${GOT#new }" ;;
        *) fail "recipe-catalogue.py said: $GOT" ;;
    esac
    say "  ✓ staged serial $SERIAL ($n recipe(s))"
    SIG="$(swift Scripts/update-key.swift sign-catalogue "$STAGE/message.txt" --key-file "$UPDATE_KEY_FILE")"
    swift Scripts/update-key.swift verify-catalogue "$STAGE/message.txt" --signature "$SIG" --public-key "$PUB" >/dev/null \
        || fail "the signature does not verify with the key's public half"
    python3 Scripts/recipe-catalogue.py finish --stage "$STAGE" --signature "$SIG"
    say "  ✓ signed with your key"
    scratch_doz recipe source verify "$STAGE/v1/recipes.json" --key "$PUB" > "$work/verify.out" 2>&1 \
        || fail "this doz would not use it: $(cat "$work/verify.out")"
    say "  ✓ this doz would use it: $(tail -1 "$work/verify.out")"
    if [[ -n "$DRY_RUN" ]]; then say "  • DRY RUN — would write $UPDATES_DIR/v1/recipes.json and $UPDATES_DIR/v1/recipes/$SERIAL/"; exit 0; fi
    mkdir -p "$UPDATES_DIR/v1/recipes"
    rm -rf "$UPDATES_DIR/v1/recipes/$SERIAL"
    cp -R "$STAGE/v1/recipes/$SERIAL" "$UPDATES_DIR/v1/recipes/$SERIAL"
    cp "$STAGE/v1/recipes.json" "$UPDATES_DIR/v1/recipes.json.new" && mv -f "$UPDATES_DIR/v1/recipes.json.new" "$UPDATES_DIR/v1/recipes.json"
    say "  ✓ $UPDATES_DIR/v1/recipes.json (serial $SERIAL) + v1/recipes/$SERIAL/"
    if git -C "$UPDATES_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$UPDATES_DIR" add v1/recipes.json "v1/recipes/$SERIAL"
        git -C "$UPDATES_DIR" commit --quiet -m "community recipe catalogue $SERIAL (needs doz $MIN_DOZ)"
        say "  ✓ committed in $UPDATES_DIR"
        if [[ -n "$PUSH" ]]; then git -C "$UPDATES_DIR" push --quiet origin HEAD && say "  ✓ pushed $UPDATES_DIR"; else say "  • not pushed (PUSH=1 pushes)"; fi
    fi
    say "✓ community catalogue $SERIAL — people add it with: doz recipe source add <its https URL>/v1/recipes.json --key $PUB"
    exit 0
fi
DIRECTORY_DIR="${DIRECTORY_DIR:-${TMPDIR:-/tmp/}doz-directory-site}"
CATALOGUE_URL="$(dist_value recipeCatalogueURL)"
PUBLIC_KEY="${UPDATE_PUBLIC_KEY:-$(dist_value updatePublicKey)}"
[[ "$CATALOGUE_URL" =~ ^https://[^/]+/v1/recipes\.json$ ]] || fail "cannot read the catalogue URL from Sources/DozableHost/Updates.swift"
[[ -n "$PUBLIC_KEY" ]] || fail "doz carries no update public key (Distribution.updatePublicKey)"
if [[ -n "${UPDATE_KEY_FILE:-}" && -z "$TEST_PUBLISH" ]]; then fail "UPDATE_KEY_FILE is for tests (TEST_PUBLISH=1) — a real publish signs with the keychain's key"; fi
DIRECTORY_HOST="${CATALOGUE_URL#https://}"; DIRECTORY_HOST="${DIRECTORY_HOST%%/*}"
# The directory is its own site: never the update site (its feed would be served from the recipe host), and its CNAME
# must be this constant's host. Refused before anything is written.
if [[ -e "$DIRECTORY_DIR/v1/feed.json" ]]; then fail "$DIRECTORY_DIR holds the update feed (v1/feed.json) — DIRECTORY_DIR is the recipe directory's own repository, not the update site"; fi
if [[ -n "${UPDATES_DIR:-}" && -d "$UPDATES_DIR" && -d "$DIRECTORY_DIR" && "$(cd "$UPDATES_DIR" && pwd -P)" == "$(cd "$DIRECTORY_DIR" && pwd -P)" ]]; then
    fail "DIRECTORY_DIR and UPDATES_DIR are the same folder — the recipe directory ($DIRECTORY_HOST) is not the update site"
fi
if [[ -e "$DIRECTORY_DIR/CNAME" && "$(tr -d '[:space:]' < "$DIRECTORY_DIR/CNAME")" != "$DIRECTORY_HOST" ]]; then
    fail "$DIRECTORY_DIR/CNAME names $(tr -d '[:space:]' < "$DIRECTORY_DIR/CNAME") — this doz's recipe directory is $DIRECTORY_HOST (Distribution.recipeCatalogueURL)"
fi
if [[ -n "$PUSH" ]]; then git -C "$DIRECTORY_DIR" remote get-url origin >/dev/null 2>&1 || fail "PUSH=1 but $DIRECTORY_DIR is not a git checkout with an origin"; fi
[[ -x "$DOZ" ]] || fail "no $DOZ — make cli first (make publish-recipes builds it)"
# The tree's committed recipe data — a test may stage an edited copy (RECIPES_DIR, with TEST_PUBLISH=1 only).
RECIPES_DIR="${RECIPES_DIR:-Sources/DozableKit/Recipes}"
if [[ "$RECIPES_DIR" != Sources/DozableKit/Recipes && -z "$TEST_PUBLISH" ]]; then fail "RECIPES_DIR is for tests (TEST_PUBLISH=1) — a real publish is the tree's committed data"; fi

VERSION_NOW="$(tr -d '[:space:]' < VERSION)"
PUBLISHED="$DIRECTORY_DIR/v1/recipes.json"
if [[ -z "${MIN_DOZ:-}" ]]; then
    MIN_DOZ="$( [[ -f "$PUBLISHED" ]] && python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["minimum_doz"])' "$PUBLISHED" || echo "$VERSION_NOW")"
fi
say "━━━ publish the recipe catalogue (made from $VERSION_NOW, needs doz $MIN_DOZ${DRY_RUN:+, dry run})"

work="$(mktemp -d "${TMPDIR:-/tmp/}doz-publish-recipes.XXXXXX")"
trap 'rm -rf "$work"' EXIT
STAGE="$work/stage"

# 1. Stage.
GOT="$(python3 Scripts/recipe-catalogue.py prepare --recipes "$RECIPES_DIR" --site "$DIRECTORY_DIR" --stage "$STAGE" \
    --min-doz "$MIN_DOZ" --source-version "$VERSION_NOW" --date "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
case "$GOT" in
    unchanged*) say "  • the published catalogue (serial ${GOT#unchanged }) already says this — nothing to do"; exit 0 ;;
    new*) SERIAL="${GOT#new }" ;;
    *) fail "recipe-catalogue.py said: $GOT" ;;
esac
say "  ✓ staged serial $SERIAL ($(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["files"]))' "$STAGE/manifest.json") files)"

# 2. Sign, and check against the key doz carries.
keyargs=()
[[ -n "${UPDATE_KEY_FILE:-}" ]] && keyargs=(--key-file "$UPDATE_KEY_FILE")
SIG="$(swift Scripts/update-key.swift sign-catalogue "$STAGE/message.txt" ${keyargs[@]+"${keyargs[@]}"})"
swift Scripts/update-key.swift verify-catalogue "$STAGE/message.txt" --signature "$SIG" --public-key "$PUBLIC_KEY" >/dev/null \
    || fail "the signing key does not match the public key doz carries — nothing published (a doz would refuse this catalogue)"
python3 Scripts/recipe-catalogue.py finish --stage "$STAGE" --signature "$SIG"
say "  ✓ signed — verifies with the key doz carries"

# 3. This build's doz must USE it (a guarded run: scratch settings + store, the seam naming the staged file).
mkdir -p "$work/xdg/doz" "$work/store" "$work/codex"
printf '[store]\npath = "%s"\n' "$work/store" > "$work/xdg/doz/doz.toml"
check="$(env DOZ_TEST_GUARD=1 DOZ_TEST_NO_MAC_LOGIN=1 DOZ_TEST_CREDENTIALS=memory DOZ_TEST_CODEX_HOME="$work/codex" \
    XDG_CONFIG_HOME="$work/xdg" DOZ_TEST_RECIPE_CATALOGUE="$STAGE/v1/recipes.json" DOZ_TEST_UPDATE_KEY="$PUBLIC_KEY" \
    "$DOZ" doctor --json --store "$work/store" 2>/dev/null || true)"
detail="$(python3 -c 'import json,sys
d=[c for c in json.loads(sys.stdin.read() or "[]") if c.get("check")=="recipes"]
print(d[0]["detail"] if d else "no recipes line")' <<<"$check")"
[[ "$detail" == "catalogue $SERIAL "* ]] || fail "this build's doz does not use the staged catalogue: $detail"
say "  ✓ this build's doz uses it: $detail"
# The directory index (dozable-directory/v1) of what that catalogue makes the active set — the same guarded run.
env DOZ_TEST_GUARD=1 DOZ_TEST_NO_MAC_LOGIN=1 DOZ_TEST_CREDENTIALS=memory DOZ_TEST_CODEX_HOME="$work/codex" \
    XDG_CONFIG_HOME="$work/xdg" DOZ_TEST_RECIPE_CATALOGUE="$STAGE/v1/recipes.json" DOZ_TEST_UPDATE_KEY="$PUBLIC_KEY" \
    "$DOZ" search --index "$work/index.json" --store "$work/store" >/dev/null 2>"$work/index.err" \
    || fail "this build's doz could not write the directory index: $(cat "$work/index.err")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("format")=="dozable-directory/v1", d.get("format")' "$work/index.json" \
    || fail "the directory index is not dozable-directory/v1"
say "  ✓ directory index: $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("entries", [])))' "$work/index.json") entries"

if [[ -n "$DRY_RUN" ]]; then
    say "  • DRY RUN — would write $DIRECTORY_DIR/v1/recipes.json, v1/recipes/$SERIAL/, v1/index.json, CNAME ($DIRECTORY_HOST) and .nojekyll"
    exit 0
fi

# 4. The directory site.
mkdir -p "$DIRECTORY_DIR/v1/recipes"
rm -rf "$DIRECTORY_DIR/v1/recipes/$SERIAL"
cp -R "$STAGE/v1/recipes/$SERIAL" "$DIRECTORY_DIR/v1/recipes/$SERIAL"
cp "$STAGE/v1/recipes.json" "$DIRECTORY_DIR/v1/recipes.json.new" && mv -f "$DIRECTORY_DIR/v1/recipes.json.new" "$DIRECTORY_DIR/v1/recipes.json"
cp "$work/index.json" "$DIRECTORY_DIR/v1/index.json.new" && mv -f "$DIRECTORY_DIR/v1/index.json.new" "$DIRECTORY_DIR/v1/index.json"
[[ -e "$DIRECTORY_DIR/CNAME" ]] || printf '%s\n' "$DIRECTORY_HOST" > "$DIRECTORY_DIR/CNAME"
[[ -e "$DIRECTORY_DIR/.nojekyll" ]] || : > "$DIRECTORY_DIR/.nojekyll"
say "  ✓ $DIRECTORY_DIR/v1/recipes.json (serial $SERIAL) + v1/recipes/$SERIAL/ + v1/index.json (CNAME $DIRECTORY_HOST, .nojekyll)"

if git -C "$DIRECTORY_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$DIRECTORY_DIR" add CNAME .nojekyll v1/recipes.json v1/index.json "v1/recipes/$SERIAL"
    git -C "$DIRECTORY_DIR" commit --quiet -m "recipe catalogue $SERIAL (from $VERSION_NOW, needs doz $MIN_DOZ)"
    say "  ✓ committed in $DIRECTORY_DIR: $(git -C "$DIRECTORY_DIR" log --oneline -1)"
    if [[ -n "$PUSH" ]]; then git -C "$DIRECTORY_DIR" push --quiet origin HEAD && say "  ✓ pushed $DIRECTORY_DIR"; else say "  • not pushed (PUSH=1 pushes)"; fi
else
    say "  • $DIRECTORY_DIR is not a git checkout — written, not committed"
fi

# 5. With PUSH=1: wait until the LIVE catalogue says this serial (GitHub Pages builds for a minute or so; a query that
#    is unique, past the CDN's copy) — so "published" means a doz can fetch it now.
if [[ -n "$PUSH" && -z "$TEST_PUBLISH" ]]; then
    say "  … waiting for the live catalogue to say serial $SERIAL ($CATALOGUE_URL)"
    live=""
    for _ in $(seq 1 40); do
        if curl -fsS -m 10 "$CATALOGUE_URL?t=$(date +%s)" 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("serial")==int(sys.argv[1]) else 1)' "$SERIAL" 2>/dev/null; then
            live=1; break
        fi
        sleep 15
    done
    [[ -n "$live" ]] && say "  ✓ the live catalogue is serial $SERIAL" || say "  ! the live catalogue is not serial $SERIAL after 10 minutes — check the directory repository's Pages build"
fi
say ""
say "✓ recipe catalogue $SERIAL is at $DIRECTORY_DIR/v1/recipes.json — served as $CATALOGUE_URL once the site is pushed"
