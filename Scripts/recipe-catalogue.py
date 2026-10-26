#!/usr/bin/env python3
"""recipe-catalogue.py — the recipe catalogue's files, manifest and signed message (`make publish-recipes`).

    prepare --recipes Sources/DozableKit/Recipes --site SITE --stage STAGE --min-doz V --source-version V --date D
        Copies the tree's compiled recipe data (less the built-in three) into STAGE/v1/recipes/<serial>/, writes the
        UNSIGNED manifest STAGE/manifest.json and the message to sign STAGE/message.txt. The serial is the published
        one (SITE/v1/recipes.json) + 1 — or the published one when nothing changed (prints "unchanged <serial>").
        Prints "new <serial>" otherwise.
    finish --stage STAGE --signature B64
        Writes STAGE/v1/recipes.json: the manifest with its signature.

The message, byte for byte (RecipeCatalogueManifest.message in doz builds the same):

    dozable-recipe-catalogue-v1\\n
    format: 1\\n product: doz-recipes\\n serial: N\\n date: D\\n minimum_doz: V\\n source_version: V\\n base: recipes/N/\\n
    file: <path> <sha256> <size>\\n   (one per file, sorted by path)

Standard library only. Paths are the closed set doz reads: agents/<id>.json, providers.json, gateways.json,
tags.json, known.json, icons/icons.json, icons/<name>.svg.
"""
import argparse
import hashlib
import json
import os
import shutil
import sys

BUILTINS = {"claude-code.json", "pi.json", "codex.json"}
DATA = ["providers.json", "gateways.json", "tags.json", "known.json"]


def fail(msg):
    sys.stderr.write("x recipe-catalogue: %s\n" % msg)
    sys.exit(1)


def collect(recipes):
    """path -> bytes, as a catalogue carries them."""
    out = {}
    compiled = os.path.join(recipes, "compiled")
    for name in sorted(os.listdir(compiled)):
        if name.endswith(".json") and name not in BUILTINS:
            out["agents/" + name] = open(os.path.join(compiled, name), "rb").read()
    for name in DATA:
        out[name] = open(os.path.join(recipes, name), "rb").read()
    icons = os.path.join(recipes, "icons")
    for name in sorted(os.listdir(icons)):
        if name == "icons.json" or name.endswith(".svg"):
            out["icons/" + name] = open(os.path.join(icons, name), "rb").read()
    return out


def message(m):
    s = "dozable-recipe-catalogue-v1\n"
    s += "format: %d\nproduct: %s\nserial: %d\ndate: %s\nminimum_doz: %s\n" % (m["format"], m["product"], m["serial"], m["date"], m["minimum_doz"])
    s += "source_version: %s\nbase: %s\n" % (m["source_version"], m["base"])
    for f in m["files"]:
        s += "file: %s %s %d\n" % (f["path"], f["sha256"], f["size"])
    return s.encode("utf-8")


def entries(files):
    return [{"path": p, "sha256": hashlib.sha256(files[p]).hexdigest(), "size": len(files[p])} for p in sorted(files)]


def prepare(a):
    files = collect(a.recipes)
    published = None
    pub_path = os.path.join(a.site, "v1", "recipes.json")
    if os.path.exists(pub_path):
        published = json.load(open(pub_path))
    files_list = entries(files)
    if published and published.get("files") == files_list and published.get("minimum_doz") == a.min_doz \
            and published.get("source_version") == a.source_version:
        print("unchanged %d" % published["serial"])
        return
    serial = (published or {}).get("serial", 0) + 1
    base = "recipes/%d/" % serial
    m = {"format": 1, "product": "doz-recipes", "serial": serial, "date": a.date, "minimum_doz": a.min_doz,
         "source_version": a.source_version, "base": base, "files": files_list, "signature": ""}
    if os.path.exists(a.stage):
        shutil.rmtree(a.stage)
    root = os.path.join(a.stage, "v1", base)
    for p, d in files.items():
        dest = os.path.join(root, p)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        open(dest, "wb").write(d)
    json.dump(m, open(os.path.join(a.stage, "manifest.json"), "w"), indent=2, sort_keys=True)
    open(os.path.join(a.stage, "message.txt"), "wb").write(message(m))
    print("new %d" % serial)


def finish(a):
    m = json.load(open(os.path.join(a.stage, "manifest.json")))
    m["signature"] = a.signature
    with open(os.path.join(a.stage, "v1", "recipes.json"), "w") as f:
        json.dump(m, f, indent=2, sort_keys=True)
        f.write("\n")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    pr = sub.add_parser("prepare")
    pr.add_argument("--recipes", required=True)
    pr.add_argument("--site", required=True)
    pr.add_argument("--stage", required=True)
    pr.add_argument("--min-doz", required=True)
    pr.add_argument("--source-version", required=True)
    pr.add_argument("--date", required=True)
    fi = sub.add_parser("finish")
    fi.add_argument("--stage", required=True)
    fi.add_argument("--signature", required=True)
    a = p.parse_args()
    {"prepare": prepare, "finish": finish}[a.cmd](a)


if __name__ == "__main__":
    main()
