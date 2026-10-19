#!/usr/bin/env python3
# 629 (owner: "withdraw most of the recipes … so that ci and other per-recipe build steps reduce"): which recipes are
# PUBLISHED — read from the compiled recipes (Sources/DozableKit/Recipes/compiled/*.json), never a list kept here. A recipe
# is unpublished when its `com.dozersandbox/directory@1` config says `published: false`; absent means published.
# The ONE helper the per-recipe work reads: Scripts/recipe-check.py (`all`, `--changed`), Scripts/agent-currency.py and
# the nightly profile loop in .github/workflows/recipes.yml. Python 3.9+ stdlib only.
#
#   Scripts/recipes_published.py                 the published ids, space-separated, sorted
#   Scripts/recipes_published.py --unpublished   the unpublished ones
import glob, json, os, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPILED = os.path.join(REPO, "Sources/DozableKit/Recipes/compiled")
DIRECTORY = "com.dozersandbox/directory@1"


def is_published(doc):
    """A compiled recipe document (its JSON) is published unless its directory@1 config says `published: false`."""
    for c in doc.get("capabilities") or []:
        if c.get("type") == DIRECTORY:
            return (c.get("config") or {}).get("published", True) is not False
    return True


def recipes(compiled=COMPILED):
    """{id: published} for every compiled recipe, sorted by id."""
    out = {}
    for p in sorted(glob.glob(os.path.join(compiled, "*.json"))):
        with open(p) as f:
            out[os.path.basename(p)[:-5]] = is_published(json.load(f))
    return out


def published(compiled=COMPILED):
    return [i for i, p in recipes(compiled).items() if p]


def unpublished(compiled=COMPILED):
    return [i for i, p in recipes(compiled).items() if not p]


if __name__ == "__main__":
    print(" ".join(unpublished() if "--unpublished" in sys.argv[1:] else published()))
