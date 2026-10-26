#!/bin/bash
# publish-recipes.sh — put the tree's recipe data on the update site as a signed recipe catalogue (`make publish-recipes`).
#
#   make publish-recipes                        # → UPDATES_DIR/v1/recipes.json + v1/recipes/<serial>/…, committed, NOT pushed
#   make publish-recipes MIN_DOZ=0.37.20        # the oldest doz that reads every file (default: the published one's, else VERSION)
#   make publish-recipes DRY_RUN=1              # show what would change, write nothing
#   make publish-recipes PUSH=1                 # … and push the update site (the owner's word first)
#
# The catalogue sits beside the update feed (Distribution.recipeCatalogueURL in Sources/DozableHost/Updates.swift) and is
# signed with the SAME key (the login keychain's; a test passes UPDATE_KEY_FILE with TEST_PUBLISH=1). In order:
#
#   1. Scripts/recipe-catalogue.py stages the committed compiled data (Recipes/compiled, less the built-in three;
#      providers, gateways, tags, known, icons) with the next serial — or says "unchanged" and stops;
#   2. the message is signed (update-key.swift sign-catalogue) and the signature checked against the key doz carries
#      (Distribution.updatePublicKey; a test: UPDATE_PUBLIC_KEY) — a key doz does not trust is refused here;
#   3. THIS build's doz reads the staged catalogue (a guarded run, scratch settings and store, the file seam) and must
#      use it: the same signature check, the same merge and every validator a doz runs at its start;
#   4. only then UPDATES_DIR gets v1/recipes/<serial>/ and v1/recipes.json (older serials are kept: an installed doz
#      may still be fetching one); a commit when it is a git checkout; a push only with PUSH=1.
#
# macOS bash 3.2 — no bash 4.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
say() { printf '%s\n' "$*"; }
fail() { printf 'x publish-recipes: %s\n' "$*" >&2; exit 1; }

DOZ="${DOZ:-.build/debug/doz}"
DRY_RUN="${DRY_RUN:-}"; PUSH="${PUSH:-}"; TEST_PUBLISH="${TEST_PUBLISH:-}"
UPDATES_DIR="${UPDATES_DIR:-${TMPDIR:-/tmp/}doz-updates-site}"
dist_value() { sed -n "s/.*static let $1 = \"\\([^\"]*\\)\".*/\\1/p" Sources/DozableHost/Updates.swift | head -1; }
CATALOGUE_URL="$(dist_value recipeCatalogueURL)"
PUBLIC_KEY="${UPDATE_PUBLIC_KEY:-$(dist_value updatePublicKey)}"
[[ "$CATALOGUE_URL" =~ ^https://[^/]+/v1/recipes\.json$ ]] || fail "cannot read the catalogue URL from Sources/DozableHost/Updates.swift"
[[ -n "$PUBLIC_KEY" ]] || fail "doz carries no update public key (Distribution.updatePublicKey)"
if [[ -n "${UPDATE_KEY_FILE:-}" && -z "$TEST_PUBLISH" ]]; then fail "UPDATE_KEY_FILE is for tests (TEST_PUBLISH=1) — a real publish signs with the keychain's key"; fi
if [[ -n "$PUSH" ]]; then git -C "$UPDATES_DIR" remote get-url origin >/dev/null 2>&1 || fail "PUSH=1 but $UPDATES_DIR is not a git checkout with an origin"; fi
[[ -x "$DOZ" ]] || fail "no $DOZ — make cli first (make publish-recipes builds it)"
# The tree's committed recipe data — a test may stage an edited copy (RECIPES_DIR, with TEST_PUBLISH=1 only).
RECIPES_DIR="${RECIPES_DIR:-Sources/DozableKit/Recipes}"
if [[ "$RECIPES_DIR" != Sources/DozableKit/Recipes && -z "$TEST_PUBLISH" ]]; then fail "RECIPES_DIR is for tests (TEST_PUBLISH=1) — a real publish is the tree's committed data"; fi

VERSION_NOW="$(tr -d '[:space:]' < VERSION)"
PUBLISHED="$UPDATES_DIR/v1/recipes.json"
if [[ -z "${MIN_DOZ:-}" ]]; then
    MIN_DOZ="$( [[ -f "$PUBLISHED" ]] && python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["minimum_doz"])' "$PUBLISHED" || echo "$VERSION_NOW")"
fi
say "━━━ publish the recipe catalogue (made from $VERSION_NOW, needs doz $MIN_DOZ${DRY_RUN:+, dry run})"

work="$(mktemp -d "${TMPDIR:-/tmp/}doz-publish-recipes.XXXXXX")"
trap 'rm -rf "$work"' EXIT
STAGE="$work/stage"

# 1. Stage.
GOT="$(python3 Scripts/recipe-catalogue.py prepare --recipes "$RECIPES_DIR" --site "$UPDATES_DIR" --stage "$STAGE" \
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

if [[ -n "$DRY_RUN" ]]; then
    say "  • DRY RUN — would write $UPDATES_DIR/v1/recipes.json and $UPDATES_DIR/v1/recipes/$SERIAL/"
    exit 0
fi

# 4. The update site.
mkdir -p "$UPDATES_DIR/v1/recipes"
rm -rf "$UPDATES_DIR/v1/recipes/$SERIAL"
cp -R "$STAGE/v1/recipes/$SERIAL" "$UPDATES_DIR/v1/recipes/$SERIAL"
cp "$STAGE/v1/recipes.json" "$UPDATES_DIR/v1/recipes.json.new" && mv -f "$UPDATES_DIR/v1/recipes.json.new" "$UPDATES_DIR/v1/recipes.json"
say "  ✓ $UPDATES_DIR/v1/recipes.json (serial $SERIAL) + v1/recipes/$SERIAL/"

if git -C "$UPDATES_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$UPDATES_DIR" add v1/recipes.json "v1/recipes/$SERIAL"
    git -C "$UPDATES_DIR" commit --quiet -m "recipe catalogue $SERIAL (from $VERSION_NOW, needs doz $MIN_DOZ)"
    say "  ✓ committed in $UPDATES_DIR: $(git -C "$UPDATES_DIR" log --oneline -1)"
    if [[ -n "$PUSH" ]]; then git -C "$UPDATES_DIR" push --quiet origin HEAD && say "  ✓ pushed $UPDATES_DIR"; else say "  • not pushed (PUSH=1 pushes)"; fi
else
    say "  • $UPDATES_DIR is not a git checkout — written, not committed"
fi
say ""
say "✓ recipe catalogue $SERIAL is at $UPDATES_DIR/v1/recipes.json — served as $CATALOGUE_URL once the site is pushed"
