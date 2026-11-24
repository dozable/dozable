#!/usr/bin/env bash
# publish-docs.sh — this version's manual on the website, at /v/VERSION/ (docs/engineering/updates-and-release.md).
#
# Every release carries its own manual (libexec/doz/manual, made by Scripts/manual-bundle.py) and points at the same
# manual online: https://dozable.com/v/VERSION/llms.txt. This script puts that manual there, in the website checkout
# WEBSITE_DIR (Makefile.config), built from the release's TAG — never from the working tree:
#   - v/VERSION/: llms.txt, llms-full.txt, every page NN-name.md, VERSION, and docs/NAME.md (the same pages under the
#     website's own page names, the shape the menu bar app links to); each Markdown file starts with a banner naming
#     the version and pointing at the stable manual;
#   - v/VERSION/index.html: the version, its pages, a link to the stable manual, and noindex;
#   - v/VERSION/onboarding.md|.html and v/VERSION/docs/onboarding.md|.html redirect to that version's setting-up page, as
#     docs/onboarding.* does for the stable manual (a guessed `onboarding.md` is the name `doz onboard` suggests);
#   - robots.txt keeps `Disallow: /v/` (the stable manual stays the one search engines show);
#   - docs/onboarding.md and docs/onboarding.html redirect to the setting-up page (`doz onboard` sends people looking for it).
# Old versions are kept. Nothing outside v/, robots.txt and docs/onboarding.* is touched.
#
# Environment: VERSION (required), WEBSITE_DIR (required), CHANNEL (canary | beta | stable; default canary),
# DRY_RUN=1 (build into a scratch folder and print what would change; nothing written to WEBSITE_DIR),
# PUSH=1 (commit and push the website; otherwise commit only). The commit uses the repository's noreply identity.
set -euo pipefail

PACKAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:?VERSION=X.Y.Z}"
WEBSITE_DIR="${WEBSITE_DIR:?WEBSITE_DIR=the website checkout (Makefile.config)}"
CHANNEL="${CHANNEL:-canary}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "x publish-docs: VERSION must be X.Y.Z" >&2; exit 64; }
[[ "$CHANNEL" =~ ^(canary|beta|stable)$ ]] || { echo "x publish-docs: CHANNEL is canary, beta or stable" >&2; exit 64; }
[[ -d "$WEBSITE_DIR/.git" ]] || { echo "x publish-docs: $WEBSITE_DIR is not a git checkout" >&2; exit 1; }
git -C "$PACKAGE" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "x publish-docs: no tag v$VERSION" >&2; exit 1; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# The manual at the tag, bundled exactly as the release bundles it.
mkdir -p "$SCRATCH/src"
git -C "$PACKAGE" archive "v$VERSION" docs/manual Scripts/manual-bundle.py | tar -x -C "$SCRATCH/src"
python3 "$SCRATCH/src/Scripts/manual-bundle.py" --out "$SCRATCH/manual" --version "$VERSION" \
    --manual "$SCRATCH/src/docs/manual" --check >/dev/null

case "$CHANNEL" in
    stable) line="Dozable $VERSION. The current stable manual is https://dozable.com/docs/ (https://dozable.com/llms.txt)." ;;
    *)      line="Dozable $VERSION — $CHANNEL; not the Homebrew stable release. The stable manual is https://dozable.com/docs/ (https://dozable.com/llms.txt)." ;;
esac

OUT="$SCRATCH/v/$VERSION"
mkdir -p "$OUT/docs"
cp "$SCRATCH/manual/VERSION" "$OUT/VERSION"
banner() { { printf '> %s\n\n' "$line"; cat "$1"; } > "$2"; }
for f in "$SCRATCH/manual"/*.md "$SCRATCH/manual"/llms.txt "$SCRATCH/manual"/llms-full.txt; do
    banner "$f" "$OUT/$(basename "$f")"
done
# The website's own page names (docs/NAME.md): NN-name.md → name.md.
pages=()
for f in "$SCRATCH/manual"/[0-9]*-*.md; do
    b="$(basename "$f")"; name="${b#*-}"
    banner "$f" "$OUT/docs/$name.tmp"
    # one folder down: the pages' relative links (NN-name.md) point back up
    sed -E 's#\]\(([0-9]{2}-[a-z0-9-]+\.md)#](../\1#g' "$OUT/docs/$name.tmp" > "$OUT/docs/$name" && rm "$OUT/docs/$name.tmp"
    pages+=("$b")
done

# A page that sends a browser (and an agent reading the refresh) to URL: noindex, a meta refresh, a canonical link.
redirect_page() {
    printf '<!doctype html><meta charset="utf-8"><meta name="robots" content="noindex"><meta http-equiv="refresh" content="0; url=%s"><link rel="canonical" href="%s"><title>Setting up</title><p>Moved: <a href="%s">%s</a> (doz onboard is described there).</p>\n' "$1" "$1" "$1" "$1"
}
# This version's onboarding.* → its own setting-up page (both name shapes: NN-name.md and docs/name.md).
setting_up="$(cd "$SCRATCH/manual" && ls [0-9]*-setting-up.md 2>/dev/null | head -1)"
[[ -n "$setting_up" ]] || { echo "x publish-docs: the manual at v$VERSION has no NN-setting-up.md page" >&2; exit 1; }
VTARGET="https://dozable.com/v/$VERSION/$setting_up"
redirect_page "$VTARGET" > "$OUT/onboarding.md"
redirect_page "$VTARGET" > "$OUT/onboarding.html"
redirect_page "https://dozable.com/v/$VERSION/docs/setting-up.md" > "$OUT/docs/onboarding.md"
redirect_page "https://dozable.com/v/$VERSION/docs/setting-up.md" > "$OUT/docs/onboarding.html"

esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
{
    printf '<!doctype html>\n<html lang="en-AU">\n<head>\n<meta charset="utf-8">\n'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
    printf '<meta name="robots" content="noindex">\n'
    printf '<title>Dozable %s — the manual</title>\n' "$VERSION"
    printf '<link rel="stylesheet" href="/site.css">\n</head>\n<body>\n<main style="max-width:70ch;margin:0 auto;padding:24px 16px">\n'
    printf '<h1>Dozable %s — the manual</h1>\n' "$VERSION"
    printf '<p>%s</p>\n' "$(printf '%s' "$line" | esc)"
    printf '<p><a href="/docs/">The stable manual</a> · <a href="llms.txt">llms.txt</a> · <a href="llms-full.txt">llms-full.txt</a></p>\n<ul>\n'
    for b in "${pages[@]}"; do printf '<li><a href="%s">%s</a></li>\n' "$b" "$b"; done
    printf '</ul>\n</main>\n</body>\n</html>\n'
} > "$OUT/index.html"

if [[ "${DRY_RUN:-}" == 1 ]]; then
    echo "publish-docs: DRY RUN — v/$VERSION would hold $(find "$OUT" -type f | wc -l | tr -d ' ') files ($SCRATCH/v/$VERSION, removed on exit)"
    grep -q '^Disallow: /v/' "$WEBSITE_DIR/robots.txt" || echo "publish-docs: robots.txt would gain Disallow: /v/"
    [[ -f "$WEBSITE_DIR/docs/onboarding.md" ]] || echo "publish-docs: docs/onboarding.md and .html would redirect to setting-up"
    exit 0
fi

rm -rf "$WEBSITE_DIR/v/$VERSION"
mkdir -p "$WEBSITE_DIR/v"
cp -R "$OUT" "$WEBSITE_DIR/v/$VERSION"

ROBOTS="$WEBSITE_DIR/robots.txt"
if ! grep -q '^Disallow: /v/' "$ROBOTS"; then
    awk '{ print } /^User-agent: \*/ && !done { print "Disallow: /v/"; done = 1 }' "$ROBOTS" > "$ROBOTS.new" && mv "$ROBOTS.new" "$ROBOTS"
fi

TARGET="https://dozable.com/docs/setting-up.md"
if [[ ! -f "$WEBSITE_DIR/docs/onboarding.md" ]]; then
    redirect="<!doctype html><meta charset=\"utf-8\"><meta name=\"robots\" content=\"noindex\"><meta http-equiv=\"refresh\" content=\"0; url=$TARGET\"><link rel=\"canonical\" href=\"$TARGET\"><title>Setting up</title><p>Moved: <a href=\"$TARGET\">$TARGET</a> (doz onboard is described there).</p>"
    printf '%s\n' "$redirect" > "$WEBSITE_DIR/docs/onboarding.md"
    printf '%s\n' "${redirect//setting-up.md/setting-up.html}" > "$WEBSITE_DIR/docs/onboarding.html"
fi

cd "$WEBSITE_DIR"
git add -- "v/$VERSION" robots.txt docs/onboarding.md docs/onboarding.html
if git diff --cached --quiet; then echo "publish-docs: v/$VERSION already published, nothing to commit"; exit 0; fi
git -c user.email=291958+johnoscott@users.noreply.github.com commit -q -m "docs: the manual of Dozable $VERSION at /v/$VERSION/ ($CHANNEL)"
echo "publish-docs: committed v/$VERSION ($(git rev-parse --short HEAD))"
if [[ "${PUSH:-}" == 1 ]]; then git push -q && echo "publish-docs: pushed — https://dozable.com/v/$VERSION/llms.txt in about a minute"; fi
