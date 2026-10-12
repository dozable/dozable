#!/usr/bin/env python3
# The agents' currency report (617, owner: "we are going to see this a lot so need to record the latest version and how
# old it is and is it current"). For every recipe: its latest release (npm's registry, or the vendor's own release
# manifest), when it came out and how old that is, freshness (active <= 90 days, quiet > 90, stale > 180; deprecated
# overrides), npm's deprecation message, whether the vendor's GitHub repository is archived, and the lifecycle the recipe
# RECORDS (current / superseded by … / retired). Read-only, unauthenticated requests to registry.npmjs.org, the vendor's
# manifest and api.github.com. Python 3.9+ stdlib only.
#
#   make agent-currency             print the report and write profiles/currency.json
#   Scripts/agent-currency.py --check   print only; exit 1 when something needs a person (see below)
#
# Against the last committed report and the network profiles it says what to do: a NEW latest version → "re-profile
# its network" (make profile-agents AGENTS=…); newly deprecated or archived → "review its lifecycle".
import datetime, glob, json, os, re, sys, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECIPES = os.path.join(REPO, "Sources/DozerKit/Recipes/agents")
OUT = os.path.join(REPO, "profiles/currency.json")
TODAY = datetime.date.today()
UA = {"User-Agent": "dozer-sandbox-agent-currency (read-only)"}

def get(url, method="GET", accept="application/json"):
    req = urllib.request.Request(url, method=method, headers=dict(UA, Accept=accept))
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.headers, (r.read() if method == "GET" else b"")

def npm(package):
    _, body = get("https://registry.npmjs.org/" + package.replace("/", "%2F"))
    d = json.loads(body)
    v = d.get("dist-tags", {}).get("latest")
    t = d.get("time", {}).get(v)
    dep = d.get("versions", {}).get(v, {}).get("deprecated")
    repo = d.get("repository", {})
    url = repo.get("url") if isinstance(repo, dict) else repo
    return v, (t or "")[:10] or None, dep, url

def manifest(recipe):
    _, body = get(recipe["install"]["manifest"])
    m = json.loads(body)
    released = None
    try:
        h, _ = get(m["url"], method="HEAD", accept="*/*")
        lm = h.get("Last-Modified")
        if lm:
            released = datetime.datetime.strptime(lm, "%a, %d %b %Y %H:%M:%S %Z").date().isoformat()
    except Exception:
        pass
    return m["version"], released, None, recipe.get("homepage")

def github(url):
    m = re.search(r"github\.com[/:]([^/]+)/([^/#?]+?)(?:\.git)?(?:[/#?]|$)", url or "")
    if not m:
        return None
    try:
        _, body = get("https://api.github.com/repos/%s/%s" % (m.group(1), m.group(2)), accept="application/vnd.github+json")
        d = json.loads(body)
        return {"repo": "%s/%s" % (m.group(1), m.group(2)), "archived": bool(d.get("archived")), "pushed": (d.get("pushed_at") or "")[:10] or None}
    except Exception as e:
        return {"repo": "%s/%s" % (m.group(1), m.group(2)), "error": str(e)[:120]}

def freshness(released, deprecated):
    if deprecated:
        return "deprecated"
    if not released:
        return "unknown"
    age = (TODAY - datetime.date.fromisoformat(released)).days
    return "stale" if age > 180 else "quiet" if age > 90 else "active"

BUILTIN_PACKAGES = {"claude-code": "@anthropic-ai/claude-code", "pi": "@earendil-works/pi-coding-agent", "codex": "@openai/codex"}

def main():
    check = "--check" in sys.argv
    try:
        old = {a["agent"]: a for a in json.load(open(OUT))["agents"]}
    except FileNotFoundError:
        old = {}
    rows, todo = [], []
    for f in sorted(glob.glob(os.path.join(RECIPES, "*.json"))):
        r = json.load(open(f))
        aid = r["id"]
        try:
            if r["install"]["kind"] == "manifest-binary":
                v, released, dep, repo = manifest(r)
            else:
                v, released, dep, repo = npm(r["install"].get("package") or BUILTIN_PACKAGES[aid])
            err = None
        except Exception as e:
            v, released, dep, repo, err = None, None, None, None, str(e)[:160]
        gh = github(repo or r.get("homepage"))
        life = r.get("lifecycle") or {"status": "current"}
        try:
            profiled = json.load(open(os.path.join(REPO, "profiles", aid + ".json"))).get("version", "")
        except FileNotFoundError:
            profiled = None
        row = {"agent": aid, "title": r["title"], "latest": v, "released": released,
               "ageDays": (TODAY - datetime.date.fromisoformat(released)).days if released else None,
               "freshness": freshness(released, dep), "deprecated": dep, "github": gh,
               "lifecycle": life, "profiledVersion": profiled, "error": err}
        rows.append(row)
        prev = old.get(aid, {})
        if v and prev.get("latest") and prev["latest"] != v:
            todo.append("%s: a new release %s (was %s) — re-profile its network: make profile-agents AGENTS=%s" % (aid, v, prev["latest"], aid))
        elif v and profiled is not None and v not in profiled:
            todo.append("%s: its profile is of %s, the latest is %s — re-profile its network: make profile-agents AGENTS=%s" % (aid, profiled, v, aid))
        if dep and not prev.get("deprecated"):
            todo.append("%s: deprecated by its maker (%s) — review its lifecycle" % (aid, dep))
        if gh and gh.get("archived") and not (prev.get("github") or {}).get("archived"):
            todo.append("%s: its GitHub repository %s is archived — review its lifecycle" % (aid, gh["repo"]))
        if err:
            todo.append("%s: could not be checked (%s)" % (aid, err))
    print("%-12s %-22s %-11s %-9s %-10s %s" % ("AGENT", "LATEST", "RELEASED", "AGE", "FRESHNESS", "STANDING"))
    for r in rows:
        life = r["lifecycle"]
        standing = life["status"] + (" by " + life["by"] if life.get("by") else "") + (" (checked %s)" % life["checked"] if life.get("checked") else "")
        if r["github"] and r["github"].get("archived"):
            standing += " · repo archived"
        print("%-12s %-22s %-11s %-9s %-10s %s" % (r["agent"], (r["latest"] or "?")[:22], r["released"] or "?",
                                                  ("%dd" % r["ageDays"]) if r["ageDays"] is not None else "?", r["freshness"], standing))
    for t in todo:
        print("TODO  " + t)
    if not check:
        with open(OUT, "w") as f:
            json.dump({"schema": 1, "checked": TODAY.isoformat(), "agents": rows}, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print("wrote " + os.path.relpath(OUT, REPO))
    return 1 if (check and todo) else 0

sys.exit(main())
