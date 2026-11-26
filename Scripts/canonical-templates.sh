#!/bin/sh
# The workspace templates doz carries, GENERATED from canonical/ (the one source; canonical/README.md):
#   canonical/TEMPLATES                          → Sources/DozableKit/Resources/templates/ORDER
#   canonical/workspace/ID/ID.workspace.yaml     → Sources/DozableKit/Resources/templates/ID/workspace.yaml
#   canonical/workspace/ID/template.json         → Sources/DozableKit/Resources/templates/ID/template.json
#   canonical/workspace/ID/DESCRIPTION.md        → Sources/DozableKit/Resources/templates/ID/DESCRIPTION.md
# Usage: Scripts/canonical-templates.sh          write the generated files (commit the result) — `make templates`
#        Scripts/canonical-templates.sh --check  fail when what is committed is not exactly what canonical/ makes —
#                                                `make templates-check` (CanonicalWorkspaceTests checks the same)
# Nothing is deleted: a file or folder in the templates folder that canonical/ does not make is named, and the run fails
# until it is removed by hand.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/canonical"
dst="$root/Sources/DozableKit/Resources/templates"
mode=write
case "${1:-}" in
  "") ;;
  --check) mode=check ;;
  *) echo "usage: $0 [--check]" >&2; exit 64 ;;
esac

[ -f "$src/TEMPLATES" ] || { echo "canonical-templates: no $src/TEMPLATES" >&2; exit 1; }

# Generate into a scratch folder first: every source must be there before anything is written.
out=$(mktemp -d "${TMPDIR:-/tmp}/doz-canonical-templates.XXXXXX")
trap 'rm -r "$out"' EXIT
cp "$src/TEMPLATES" "$out/ORDER"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  from="$src/workspace/$id"
  for f in "$id.workspace.yaml" template.json DESCRIPTION.md; do
    [ -f "$from/$f" ] || { echo "canonical-templates: canonical/workspace/$id/$f is missing" >&2; exit 1; }
  done
  mkdir "$out/$id"
  cp "$from/$id.workspace.yaml" "$out/$id/workspace.yaml"
  cp "$from/template.json" "$from/DESCRIPTION.md" "$out/$id/"
done < "$src/TEMPLATES"

# Anything in the templates folder canonical/ does not make.
extra=$(cd "$dst" 2>/dev/null && find . -mindepth 1 \( -type f -o -type d \) | sed 's#^\./##' | while IFS= read -r p; do
  [ -e "$out/$p" ] || echo "$p"
done)

if [ "$mode" = check ]; then
  if ! diff -r "$out" "$dst" >/dev/null 2>&1 || [ -n "$extra" ]; then
    echo "canonical-templates: Sources/DozableKit/Resources/templates differs from canonical/ — run make templates and commit:" >&2
    diff -r "$out" "$dst" >&2 || true
    exit 1
  fi
  echo "canonical-templates: the shipped templates are canonical/'s"
  exit 0
fi

if [ -n "$extra" ]; then
  echo "canonical-templates: not made from canonical/ — remove by hand (nothing is deleted here):" >&2
  echo "$extra" | sed 's/^/  /' >&2
  exit 1
fi
mkdir -p "$dst"
cp -R "$out/" "$dst/"
echo "canonical-templates: wrote $(grep -c . "$src/TEMPLATES") templates into Sources/DozableKit/Resources/templates"
