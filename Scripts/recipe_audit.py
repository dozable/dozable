#!/usr/bin/env python3
# The recipe ingredient audit (655, backlog 617.B3; owner: "a daily audit of all the recipe ingredients and a refresh of
# the directory with the latest versions"). For every PUBLISHED recipe (`--recipes "a b"`: any), one row per INGREDIENT —
# the bytes a bake downloads — each `ok | changed | behind | gone | unchecked` with why:
#
#   pin           the pinned release still exists and its integrity is the recipe's (npm: the version's dist.integrity;
#                 manifest-binary: the vendor manifest's sha512 while it names the pin, else a download's; release-binary
#                 and pypi: a bounded, cached download's sha512, cross-checked with GitHub's asset digest / PyPI's sha256)
#   requirements  pypi: every lock line's sha256 is one PyPI publishes for that release
#   extras[i]     each install.extras URL still serves the bytes its sha256 names
#   latest        the newest release, from profiles/currency.json (currency's data, never a second lookup): `behind`
#                 when the pin is older — information only
# plus, once per run, the shared ingredients: each base image's pinned digest still resolves on its registry (the
# catalogue's tags; a moved tag is `behind`), the Node and Python runtimes' pinned sha256 are the ones their publishers
# list, and Claude Code's native build checksums. Recorded as they are, never judged (the profiles judge): the recipe's
# network hosts, auth methods, gateway levels, default base and lifecycle.
#
# Read-only, unauthenticated requests to public registries; no key, no VM. Network trouble is `unchecked`, never
# `gone` (only a 404/410 is). Exit 1 on any `changed` or `gone` (a pin that no longer matches is a supply-chain alarm).
#
#   make recipe-audit [RECIPES="a b"] [PROPOSE=1]    (RECIPE_AUDIT_CACHE, RECIPE_AUDIT_REPORT, RECIPE_AUDIT_SUMMARY)
#
# Writes profiles/audit.json (sorted, dated, deterministic; only for the published set — a named set prints and writes
# --report only). `--propose` (PROPOSE=1): for each `behind` recipe that is NOT built-in, rewrites its YAML's pin
# (args.version.default, install integrity, extras sha256) from the registry — VERIFIED against a download — and runs
# `make recipes`. It never commits, pushes or publishes: a proposal must pass `make recipe-check RECIPES=ID` first.
# A pypi recipe is never proposed (its lock is resolved in a scratch VM — RECIPE-FORMAT.md).
#
# Python 3.9+ stdlib only. Unit tests: Tests/Scripts/test_recipe_audit.py (`make test-recipe-audit`, and in `make test`).
import argparse, base64, datetime, glob, hashlib, json, os, re, subprocess, sys, tempfile
import urllib.error, urllib.parse, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import recipes_published  # noqa: E402

COMPILED = os.path.join(REPO, "Sources/DozableKit/Recipes/compiled")
AGENTS = os.path.join(REPO, "Sources/DozableKit/Recipes/agents")
BASES_SWIFT = os.path.join(REPO, "Sources/DozableKit/BaseCatalogue.swift")
CURRENCY = os.path.join(REPO, "profiles/currency.json")
OUT = os.path.join(REPO, "profiles/audit.json")
UA = "dozable-recipe-audit (read-only)"

# Worst last: a recipe's status is its worst ingredient's.
STATUSES = ("ok", "behind", "unchecked", "changed", "gone")
FAILING = ("changed", "gone")
MAX_BYTES = 400 * 1024 * 1024
# Codex (built-in) is installed from its linux-arm64 platform VERSION of the same package (AgentImages.codexPlatformVersion).
BUILTIN_PLATFORM_SUFFIX = {"codex": "-linux-arm64"}
NPM = "https://registry.npmjs.org/"
PYPI = "https://pypi.org/pypi/"


# ── The network: ONE object, so every decision below is a pure function the tests drive with a fake ──────────────────

class Gone(Exception):
    """The registry says it is not there (404/410)."""


class Unreachable(Exception):
    """Anything else — a timeout, a 5xx, a rate limit: `unchecked`, never `gone`."""


class TooBig(Exception):
    """A download over the cap."""


class _AuthNeeded(Exception):
    def __init__(self, challenge):
        Exception.__init__(self, challenge)
        self.challenge = challenge or ""


class _KeepMethod(urllib.request.HTTPRedirectHandler):
    """Follow redirects keeping HEAD a HEAD, and never carry a registry token to another host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = urllib.request.HTTPRedirectHandler.redirect_request(self, req, fp, code, msg, headers, newurl)
        if new is None:
            return None
        new.method = req.get_method()
        if urllib.parse.urlsplit(newurl).netloc != urllib.parse.urlsplit(req.full_url).netloc:
            for k in [k for k in new.headers if k.lower() == "authorization"]:
                del new.headers[k]
        return new


class Net:
    """Read-only HTTP: JSON, text, HEAD, a download's hashes (bounded, cached by ETag/Last-Modified/length), and a
    registry manifest's digest (anonymous bearer token when the registry asks)."""

    def __init__(self, cache=None, max_bytes=MAX_BYTES, timeout=60):
        self.cache = cache
        self.max_bytes = max_bytes
        self.timeout = timeout
        self.opener = urllib.request.build_opener(_KeepMethod)
        self.memo = {}

    def _open(self, url, method="GET", accept="*/*", headers=None):
        h = {"User-Agent": UA, "Accept": accept}
        h.update(headers or {})
        try:
            return self.opener.open(urllib.request.Request(url, method=method, headers=h), timeout=self.timeout)
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                raise Gone("%s answered %d" % (_host(url), e.code))
            if e.code == 401:
                raise _AuthNeeded(e.headers.get("WWW-Authenticate"))
            raise Unreachable("%s answered %d" % (_host(url), e.code))
        except Exception as e:  # URLError, timeouts, TLS
            raise Unreachable("%s: %s" % (_host(url), str(getattr(e, "reason", e))[:120]))

    def _read(self, url, accept):
        key = ("GET", url, accept)
        if key not in self.memo:
            try:
                with self._open(url, accept=accept) as r:
                    self.memo[key] = ("ok", r.read())
            except (Gone, Unreachable) as e:
                self.memo[key] = (e, None)
            except _AuthNeeded:
                self.memo[key] = (Unreachable("%s asks for a sign-in" % _host(url)), None)
        err, body = self.memo[key]
        if err != "ok":
            raise err
        return body

    def json(self, url):
        try:
            return json.loads(self._read(url, "application/json"))
        except ValueError:
            raise Unreachable("%s did not answer JSON" % _host(url))

    def text(self, url):
        return self._read(url, "*/*").decode("utf-8", "replace")

    def head(self, url, accept="*/*", headers=None):
        with self._open(url, method="HEAD", accept=accept, headers=headers) as r:
            return {k.lower(): v for k, v in r.headers.items()}

    def hashes(self, url):
        """{sha256, sha512, size} of what URL serves now — from the cache when a HEAD shows the same ETag /
        Last-Modified / length as when it was hashed."""
        try:
            h = self.head(url)
        except (Unreachable, _AuthNeeded):
            h = {}
        ident = [h.get("etag"), h.get("last-modified"), h.get("content-length")]
        path = os.path.join(self.cache, hashlib.sha256(url.encode()).hexdigest() + ".json") if self.cache else None
        if path and (ident[0] or ident[1]) and os.path.exists(path):
            try:
                c = read_json(path)
                if c.get("url") == url and c.get("ident") == ident:
                    return c["hashes"]
            except (ValueError, KeyError, OSError):
                pass
        if h.get("content-length", "").isdigit() and int(h["content-length"]) > self.max_bytes:
            raise TooBig("%s MiB" % (int(h["content-length"]) // (1024 * 1024)))
        s256, s512, n = hashlib.sha256(), hashlib.sha512(), 0
        with self._open(url) as r:
            while True:
                b = r.read(1 << 20)
                if not b:
                    break
                n += len(b)
                if n > self.max_bytes:
                    raise TooBig("over %d MiB" % (self.max_bytes // (1024 * 1024)))
                s256.update(b)
                s512.update(b)
        out = {"sha256": s256.hexdigest(), "sha512": s512.hexdigest(), "size": n}
        if path:
            os.makedirs(self.cache, exist_ok=True)
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"url": url, "ident": ident, "hashes": out}, f)
            os.replace(tmp, path)
        return out

    MANIFEST_TYPES = ", ".join(["application/vnd.oci.image.index.v1+json",
                                "application/vnd.docker.distribution.manifest.list.v2+json",
                                "application/vnd.oci.image.manifest.v1+json",
                                "application/vnd.docker.distribution.manifest.v2+json"])

    def manifest_digest(self, registry, repo, ref):
        """The digest REGISTRY answers for REPO's manifest REF (a tag or a digest) — a HEAD, never a layer."""
        host = "registry-1.docker.io" if registry == "docker.io" else registry
        url = "https://%s/v2/%s/manifests/%s" % (host, repo, ref)
        try:
            h = self.head(url, accept=self.MANIFEST_TYPES)
        except _AuthNeeded as e:
            params = dict(re.findall(r'(\w+)="([^"]*)"', e.challenge))
            if "realm" not in params:
                raise Unreachable("%s asks for a sign-in" % host)
            q = {k: v for k, v in params.items() if k in ("service", "scope")}
            q.setdefault("scope", "repository:%s:pull" % repo)
            tok = self.json(params["realm"] + "?" + urllib.parse.urlencode(q))
            token = tok.get("token") or tok.get("access_token")
            if not token:
                raise Unreachable("%s gave no anonymous token" % host)
            try:
                h = self.head(url, accept=self.MANIFEST_TYPES, headers={"Authorization": "Bearer " + token})
            except _AuthNeeded:
                raise Unreachable("%s refused its own anonymous token" % host)
        d = h.get("docker-content-digest")
        if not d:
            raise Unreachable("%s gave no digest" % host)
        return d


def _host(url):
    return urllib.parse.urlsplit(url).netloc or url


def read_text(path):
    with open(path) as f:
        return f.read()


def read_json(path):
    with open(path) as f:
        return json.load(f)


# ── Small pure helpers ───────────────────────────────────────────────────────────────────────────────────────────────

def sri(hex512):
    return "sha512-" + base64.b64encode(bytes.fromhex(hex512)).decode()


def vkey(v):
    """A version's order: its numeric release parts, a pre-release (`-rc.1`) before the release itself."""
    v = (v or "").lstrip("v").split("+")[0]
    main, _, pre = v.partition("-")
    nums = tuple(int(x) if x.isdigit() else 0 for x in main.split("."))
    return nums + ((0, pre) if pre else (1, ""))


def major(v):
    return vkey(v)[0] if v else None


def npm_url(package, version):
    return NPM + package.replace("/", "%2F") + "/" + urllib.parse.quote(version, safe="")


def fill(template, pin):
    """A recipe URL template at PIN (`${{ kit.args.version }}` = the release, `${{ dozable.build }}` = VERSION-BUILD)."""
    version, _, build = pin.partition("+")
    return template.replace("${{ kit.args.version }}", version).replace("${{ dozable.build }}", version + "-" + build)


def row(name, status, why, **extra):
    r = {"ingredient": name, "status": status, "why": why}
    r.update({k: v for k, v in extra.items() if v is not None})
    return r


def worst(statuses):
    return max(statuses, key=STATUSES.index) if statuses else "ok"


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


# ── The recipe, as the audit reads it ────────────────────────────────────────────────────────────────────────────────

def load(doc):
    caps = {}
    for c in doc.get("capabilities") or []:
        caps.setdefault(c["type"], c.get("config") or {})
    install = caps.get("com.dozable/install@1", {})
    family = caps.get("com.dozable/family@1")
    return {"id": doc["id"].split("/")[-1], "qualified": doc["id"], "title": doc.get("displayName", ""),
            "pin": doc["args"]["version"]["default"], "install": install, "builtin": bool(install.get("builtin")),
            "major": family.get("major") if family else None, "published": recipes_published.is_published(doc),
            "lifecycle": (caps.get("com.dozable/currency@1") or {}).get("lifecycle") or {"status": "current"},
            "directory": caps.get("com.dozable/directory@1", {}), "network": caps.get("com.docker.sandbox/network-policy@1", {}),
            "auth": caps.get("com.dozable/auth@1", {}), "gateways": caps.get("com.dozable/gateways@1", {})}


def _hosts(v, top=True):
    """Host names in a network-policy part: a plain list of names (`host` or `host:port`) at its top, else the `host`
    of every entry, however deep (never a path or a reason)."""
    out = set()
    if isinstance(v, str):
        if top:
            out.add(v.split(":")[0])
    elif isinstance(v, dict):
        if isinstance(v.get("host"), str):
            out.add(v["host"])
        for x in v.values():
            if isinstance(x, (list, dict)):
                out |= _hosts(x, top=False)
    elif isinstance(v, list):
        for x in v:
            out |= _hosts(x, top=top)
    return out


def records(r):
    """What the report RECORDS of a recipe, as it is (no live judgement — the network profiles do that)."""
    net = r["network"]
    hosts = {"allow": sorted(_hosts((net.get("runtime") or {}).get("allow") or []))}
    for k, v in sorted((net.get("dozable") or {}).items()):
        if k in ("off_without",):
            continue
        hs = sorted(_hosts(v))
        if hs:
            hosts[k] = hs
    if r["install"].get("bake_hosts"):
        hosts["bake"] = sorted(r["install"]["bake_hosts"])
    auth = sorted(m.get("kind", "?") + (":" + m["provider"] if m.get("provider") else "") for m in r["auth"].get("methods") or [])
    gateways = {e["gateway"]: e.get("level", "?") for e in r["gateways"].get("entries") or [] if "gateway" in e}
    return {"hosts": {k: v for k, v in hosts.items() if v}, "auth": auth, "gateways": dict(sorted(gateways.items())),
            "default_base": r["directory"].get("default_base"), "lifecycle": r["lifecycle"]}


# ── The ingredients ──────────────────────────────────────────────────────────────────────────────────────────────────

def check_npm(net, package, version, integrity, main=None):
    """npm: PACKAGE@VERSION's dist.integrity against the recipe's (MAIN@VERSION must exist too, for a platform package)."""
    if main:
        net.json(npm_url(main, version))
    d = net.json(npm_url(package, version))
    got = (d.get("dist") or {}).get("integrity")
    dep = d.get("deprecated")
    if not got:
        return "unchecked", "npm gives no integrity for %s@%s" % (package, version)
    if got != integrity:
        return "changed", "npm's integrity for %s@%s is %s… — the recipe pins %s…" % (package, version, got[:24], (integrity or "")[:24])
    return "ok", "%s@%s on npm, integrity as pinned%s" % (package, version, " (deprecated: %s)" % str(dep)[:80] if dep else "")


def check_download(net, url, want, algo, label):
    """A download's ALGO (sha256 hex or sha512 SRI) against WANT."""
    h = net.hashes(url)
    got = sri(h["sha512"]) if algo == "sha512" else h["sha256"]
    if got != want:
        return "changed", "%s now serves %s %s… — the recipe pins %s…" % (label, algo, got[:24], (want or "")[:24]), h
    return "ok", "%s serves the pinned bytes (%s, %d bytes)" % (label, algo, h["size"]), h


def github_asset_digest(net, url):
    """GitHub's own sha256 for a release asset URL (None when the API does not say)."""
    m = re.match(r"https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/?#]+)$", url)
    if not m:
        return None
    try:
        d = net.json("https://api.github.com/repos/%s/%s/releases/tags/%s" % (m.group(1), m.group(2), m.group(3)))
    except (Gone, Unreachable):
        return None
    for a in d.get("assets") or []:
        if a.get("name") == urllib.parse.unquote(m.group(4)) and str(a.get("digest") or "").startswith("sha256:"):
            return a["digest"][7:]
    return None


def pin_check(net, r):
    i, pin, kind = r["install"], r["pin"], r["install"].get("kind")
    version = pin.split("+")[0]
    integrity = i.get("integrity")
    if r["builtin"]:
        if not i.get("package") or not integrity:
            return "unchecked", "a built-in agent without an npm package or integrity in its recipe"
        return check_npm(net, i["package"], version + BUILTIN_PLATFORM_SUFFIX.get(r["id"], ""), integrity)
    if kind == "npm":
        return check_npm(net, i["package"], version, integrity)
    if kind == "npm-platform-binary":
        return check_npm(net, i["platform_package"], version, integrity, main=i["package"])
    if kind == "manifest-binary":
        url = fill(i["url"], pin)
        try:
            m = net.json(i["manifest"])
        except (Gone, Unreachable):
            m = {}
        if m.get("url") == url and isinstance(m.get("sha512"), str) and re.match(r"^[0-9a-f]{128}$", m["sha512"]):
            got = sri(m["sha512"])
            if got != integrity:
                return "changed", "the vendor's manifest gives %s… for the pinned build — the recipe pins %s…" % (got[:24], integrity[:24])
            return "ok", "the vendor's manifest still names the pinned build with the pinned sha512"
        return check_download(net, url, integrity, "sha512", "the pinned archive")[:2]
    if kind == "release-binary":
        url = fill(i["url"], pin)
        status, why, h = check_download(net, url, integrity, "sha512", "the pinned download")
        gh = github_asset_digest(net, url)
        if gh and gh != h["sha256"]:
            return "changed", "GitHub's asset digest (sha256 %s…) is not the bytes served (%s…)" % (gh[:16], h["sha256"][:16])
        return status, why + ("; GitHub's asset digest agrees" if gh else "")
    if kind == "pypi":
        pkg = i["package"]
        line = next((parse_requirement(x) for x in i.get("requirements") or [] if norm(parse_requirement(x)[0]) == norm(pkg)), None)
        d = net.json(PYPI + "%s/%s/json" % (pkg, version))
        files = d.get("urls") or []
        yanked = (d.get("info") or {}).get("yanked") or any(f.get("yanked") for f in files)
        if not line:
            return "unchecked", "the lock has no line for %s itself" % pkg
        f = next((f for f in files if (f.get("digests") or {}).get("sha256") == line[2]), None)
        if not f:
            return "changed", "%s %s's lock hash (sha256 %s…) is not among the files PyPI publishes for it" % (pkg, version, line[2][:16])
        status, why, _ = check_download(net, f["url"], integrity, "sha512", f.get("filename") or "the package file")
        return status, why + (" (yanked on PyPI)" if yanked else "")
    return "unchecked", "install kind %r is not audited" % kind


def parse_requirement(line):
    m = re.match(r"^\s*([A-Za-z0-9_.\-\[\]]+)==(\S+)\s+--hash=sha256:([0-9a-f]{64})\s*$", line)
    if not m:
        return (line, None, None)
    return (re.sub(r"\[.*\]$", "", m.group(1)), m.group(2), m.group(3))


def requirements_check(net, r):
    lines = r["install"].get("requirements") or []
    bad, gone, unreach = [], [], []
    for x in lines:
        name, version, h = parse_requirement(x)
        if not version:
            bad.append(x[:60] + " (not name==version --hash=sha256:…)")
            continue
        try:
            d = net.json(PYPI + "%s/%s/json" % (name, version))
        except Gone:
            gone.append("%s==%s" % (name, version))
            continue
        except Unreachable as e:
            unreach.append("%s==%s (%s)" % (name, version, e))
            continue
        if h not in {(f.get("digests") or {}).get("sha256") for f in d.get("urls") or []}:
            bad.append("%s==%s" % (name, version))
    if gone:
        return "gone", "not on PyPI any more: " + ", ".join(gone[:6])
    if bad:
        return "changed", "a hash PyPI does not publish: " + ", ".join(bad[:6])
    if unreach:
        return "unchecked", "%d of %d lines could not be looked up: %s" % (len(unreach), len(lines), unreach[0])
    return "ok", "%d lines, each hash one PyPI publishes" % len(lines)


def latest_check(r, currency):
    """`behind` when currency's latest is newer than the pin — currency's data, never a second lookup."""
    rows, checked = currency
    c = rows.get(r["id"])
    if not c or not c.get("latest"):
        return "unchecked", "no latest in currency's data%s — make agent-currency" % (" (of %s)" % checked if checked else "")
    latest, pin = c["latest"], r["pin"].split("+")[0]
    when = " (%s)" % c["released"] if c.get("released") else ""
    if r["major"] is not None and major(latest) != r["major"]:
        return "unchecked", "currency's latest %s is major %s; this recipe is major %s — another major is another recipe" % (latest, major(latest), r["major"])
    if vkey(latest) > vkey(pin):
        return "behind", "%s is out%s; the recipe pins %s%s" % (latest, when, pin, " (built-in: it runs the latest; the pin is the frozen fallback)" if r["builtin"] else "")
    if vkey(latest) == vkey(pin):
        return "ok", "the pin is the latest%s" % when
    return "ok", "the pin %s is newer than currency's latest %s (currency of %s)" % (pin, latest, checked)


def guarded(fn, *args):
    try:
        out = fn(*args)
        return out[0], out[1]
    except Gone as e:
        return "gone", str(e)
    except TooBig as e:
        return "unchecked", "the download is too big to hash here (%s)" % e
    except Unreachable as e:
        return "unchecked", "could not be checked: %s" % e


def audit_recipe(net, r, currency):
    ing = [row("pin", *guarded(pin_check, net, r), version=r["pin"])]
    if r["install"].get("requirements"):
        ing.append(row("requirements", *guarded(requirements_check, net, r)))
    for n, e in enumerate(r["install"].get("extras") or []):
        url = fill(e["url"], r["pin"])
        ing.append(row("extras[%d]" % n, *guarded(lambda: check_download(net, url, e["sha256"], "sha256", url)[:2]), url=url))
    ing.append(row("latest", *latest_check(r, currency)))
    ing.sort(key=lambda x: x["ingredient"])
    return {"agent": r["id"], "qualified": r["qualified"], "title": r["title"], "kind": r["install"].get("kind"),
            "builtin": r["builtin"], "published": r["published"], "pin": r["pin"],
            "status": worst([x["status"] for x in ing]), "ingredients": ing, "recorded": records(r)}


# ── The shared ingredients: base images, runtimes, Claude Code's native build (read from BaseCatalogue.swift) ───────

def shared_pins(swift):
    """What BaseCatalogue.swift pins — every base's tag + digest, Node 22/24, the Python runtime, Claude Code's native
    build. A part that no longer reads as expected is None (said as `unchecked`; a unit test reads the real file)."""
    bases = [{"id": m.group(1), "reference": m.group(2), "digest": m.group(3)} for m in re.finditer(
        r'CatalogueBase\(id: "([\w-]+)".*?reference: "([^"]+)",\s*pinnedDigest: "(sha256:[0-9a-f]{64})"', swift, re.S)]
    def one(p):
        m = re.search(p, swift, re.S)
        return m.groups() if m else None
    return {"bases": bases,
            "node22": one(r'enum NodeRuntime \{.*?static let version = "([^"]+)"\s*public static let sha256 = "([0-9a-f]{64})"'),
            "node24": one(r'enum V24 \{\s*public static let version = "([^"]+)"\s*public static let sha256 = "([0-9a-f]{64})"'),
            "python": one(r'enum PythonRuntime \{\s*public static let version = "([^"]+)"\s*public static let build = "([^"]+)"\s*public static let sha256 = "([0-9a-f]{64})"'),
            "claude": one(r'static let pinned = NativeClaudeBuild\(version: "([^"]+)", sha256: \[\s*"linux-arm64": "([0-9a-f]{64})",\s*"linux-arm64-musl": "([0-9a-f]{64})"')}


def split_reference(ref):
    """`docker.io/library/node:22-bookworm` → (docker.io, library/node, 22-bookworm)."""
    host, _, rest = ref.partition("/")
    repo, _, tag = rest.rpartition(":")
    return host, repo, tag


def base_check(net, b):
    host, repo, tag = split_reference(b["reference"])
    net.manifest_digest(host, repo, b["digest"])
    try:
        now = net.manifest_digest(host, repo, tag)
    except (Gone, Unreachable) as e:
        return "ok", "the pinned digest resolves (the tag could not be read: %s)" % e
    if now != b["digest"]:
        return "behind", "the pinned digest resolves; the tag %s now points at %s…" % (tag, now[:19])
    return "ok", "the pinned digest resolves and is still the tag's"


def listed(sums, filename, sha):
    for line in sums.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip("*") == filename:
            if parts[0].lower() == sha:
                return "ok", "%s is listed with the pinned sha256" % filename
            return "changed", "%s is listed with sha256 %s… — the pin is %s…" % (filename, parts[0][:16], sha[:16])
    return "gone", "%s is not in its publisher's checksum list" % filename


def node_check(net, p):
    v, sha = p
    return listed(net.text("https://nodejs.org/dist/v%s/SHASUMS256.txt" % v), "node-v%s-linux-arm64.tar.xz" % v, sha)


def python_check(net, p):
    v, build, sha = p
    sums = net.text("https://github.com/astral-sh/python-build-standalone/releases/download/%s/SHA256SUMS" % build)
    return listed(sums, "cpython-%s+%s-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz" % (v, build), sha)


def claude_native_check(net, p):
    v, arm, musl = p
    m = net.json("https://downloads.claude.ai/claude-code-releases/%s/manifest.json" % v)
    plats = m.get("platforms") or {}
    for name, want in (("linux-arm64", arm), ("linux-arm64-musl", musl)):
        got = str((plats.get(name) or {}).get("checksum") or "").lower()
        if not got:
            return "gone", "the %s manifest has no %s build" % (v, name)
        if got != want:
            return "changed", "the %s manifest's %s checksum is %s… — the pin is %s…" % (v, name, got[:16], want[:16])
    return "ok", "%s's linux-arm64 and musl checksums are as pinned" % v


def audit_shared(net, swift):
    p = shared_pins(swift)
    out = []
    if not p["bases"]:
        out.append(row("base:*", "unchecked", "BaseCatalogue.swift's bases no longer read as expected"))
    for b in p["bases"]:
        out.append(row("base:" + b["id"], *guarded(base_check, net, b), version=b["reference"] + "@" + b["digest"]))
    for name, fn, label in (("runtime:node22", node_check, "node22"), ("runtime:node24", node_check, "node24"),
                            ("runtime:python", python_check, "python"), ("native:claude-code", claude_native_check, "claude")):
        if p[label] is None:
            out.append(row(name, "unchecked", "BaseCatalogue.swift's %s pin no longer reads as expected" % label))
        else:
            out.append(row(name, *guarded(fn, net, p[label]), version="+".join(p[label][:2]) if label == "python" else p[label][0]))
    out.sort(key=lambda x: x["ingredient"])
    return out


# ── The whole report ─────────────────────────────────────────────────────────────────────────────────────────────────

def read_currency(path=CURRENCY):
    try:
        d = read_json(path)
    except (OSError, ValueError):
        return {}, None
    return {a["agent"]: a for a in d.get("agents") or []}, d.get("checked")


def audit(net, recipes, currency, swift, today):
    rows = sorted((audit_recipe(net, r, currency) for r in recipes), key=lambda x: x["agent"])
    shared = audit_shared(net, swift)
    counts = {s: 0 for s in STATUSES}
    for x in [i for r in rows for i in r["ingredients"]] + shared:
        counts[x["status"]] += 1
    return {"schema": 1, "checked": today, "currency": currency[1], "counts": counts, "recipes": rows, "shared": shared}


def failing(report):
    return report["counts"]["changed"] + report["counts"]["gone"] > 0


def console(report):
    lines = []
    for r in report["recipes"]:
        lines.append("%s  %s %s (%s%s)%s" % (r["agent"], r["qualified"], r["pin"], r["kind"], ", built-in" if r["builtin"] else "",
                                              "" if r["published"] else " — unpublished"))
        for i in r["ingredients"]:
            lines.append("  %-9s %-13s %s" % (i["status"], i["ingredient"], i["why"]))
    lines.append("shared")
    for i in report["shared"]:
        lines.append("  %-9s %-19s %s" % (i["status"], i["ingredient"], i["why"]))
    c = report["counts"]
    lines.append("audit: %s" % ", ".join("%d %s" % (c[s], s) for s in STATUSES))
    return "\n".join(lines)


def summary_markdown(report):
    c = report["counts"]
    head = "FAILED — a pin no longer matches" if failing(report) else "no pin changed or gone"
    out = ["### Recipe audit — %s" % head, "",
           "%s · currency's data of %s · %s" % (report["checked"], report["currency"] or "?", ", ".join("%d %s" % (c[s], s) for s in STATUSES)), "",
           "| Recipe | Pin | Status | Ingredient | Why |", "|---|---|---|---|---|"]
    for r in report["recipes"]:
        for i in r["ingredients"]:
            if i["status"] != "ok" or i["ingredient"] == "pin":
                out.append("| %s | %s | %s | %s | %s |" % (r["agent"], r["pin"], "**%s**" % i["status"] if i["status"] in FAILING else i["status"],
                                                            i["ingredient"], i["why"].replace("|", "\\|")[:300]))
    for i in report["shared"]:
        if i["status"] != "ok":
            out.append("| (shared) | | %s | %s | %s |" % ("**%s**" % i["status"] if i["status"] in FAILING else i["status"], i["ingredient"], i["why"].replace("|", "\\|")[:300]))
    return "\n".join(out) + "\n"


# ── The refresh, PROPOSED: a verified pin edit in the YAML, never committed ──────────────────────────────────────────

class Refused(Exception):
    """Not proposed, for a reason that is no alarm (a built-in, a pypi lock, a YAML that does not read as expected)."""


class Mismatch(Refused):
    """Not proposed because the registry's own published hash is not the bytes it serves — an alarm (exit 1)."""


def propose_pin(net, r, latest):
    """(new pin, new integrity, [new extras sha256]) for R at LATEST, each verified against a download."""
    i, kind = r["install"], r["install"].get("kind")
    if r["builtin"]:
        raise Refused("built-in: its pin is RecipePinTests' frozen fallback, never proposed")
    if kind == "pypi":
        raise Refused("a pypi lock is resolved in a scratch VM (RECIPE-FORMAT.md) — not proposed")
    pin = latest
    if kind in ("npm", "npm-platform-binary"):
        pkg = i["platform_package"] if kind == "npm-platform-binary" else i["package"]
        if kind == "npm-platform-binary":
            net.json(npm_url(i["package"], latest))
        d = net.json(npm_url(pkg, latest))
        integ, tarball = (d.get("dist") or {}).get("integrity"), (d.get("dist") or {}).get("tarball")
        if not integ or not integ.startswith("sha512-") or not tarball:
            raise Refused("npm gives no sha512 integrity or tarball for %s@%s" % (pkg, latest))
        got = sri(net.hashes(tarball)["sha512"])
        if got != integ:
            raise Mismatch("the %s@%s tarball's sha512 is not npm's integrity" % (pkg, latest))
    elif kind == "release-binary":
        url = fill(i["url"], latest)
        h = net.hashes(url)
        gh = github_asset_digest(net, url)
        if gh and gh != h["sha256"]:
            raise Mismatch("GitHub's asset digest is not the bytes served for %s" % url)
        integ = sri(h["sha512"])
    elif kind == "manifest-binary":
        m = net.json(i["manifest"])
        v, url, hex512 = m.get("version"), m.get("url") or "", m.get("sha512") or ""
        if v != latest:
            raise Refused("the vendor's manifest names %s, currency's data %s" % (v, latest))
        seg = next((s for s in url.split("/") if s.startswith(v + "-")), "")
        build = seg[len(v) + 1:]
        if not re.match(r"^[0-9A-Za-z.]+$", build) or not re.match(r"^[0-9a-f]{128}$", hex512) or fill(i["url"], v + "+" + build) != url:
            raise Refused("the vendor's manifest names an archive the recipe does not expect")
        pin, integ = v + "+" + build, sri(hex512)
        if sri(net.hashes(url)["sha512"]) != integ:
            raise Mismatch("the archive's sha512 is not the manifest's")
    else:
        raise Refused("install kind %r is not proposed" % kind)
    extras = [net.hashes(fill(e["url"], pin))["sha256"] for e in i.get("extras") or []]
    return pin, integ, extras


def _yaml_scalar(v):
    return "'%s'" % v if re.match(r"^[0-9]+(\.[0-9]+)?$", v) else v


def rewrite_pin(text, old_pin, new_pin, old_integ, new_integ, extras):
    """The recipe YAML with ONLY its pin moved: `args.version.default`, `install@1.integrity` and each extras `sha256`
    (EXTRAS = [(old, new)]). Each must match exactly once, else Refused — nothing is guessed."""
    lines = text.split("\n")
    try:
        a = lines.index("args:")
    except ValueError:
        raise Refused("no top-level args: block")
    end = next((n for n in range(a + 1, len(lines)) if lines[n] and not lines[n].startswith(" ")), len(lines))
    hits = [n for n in range(a, end) if re.match(r"^    default: (['\"]?)%s\1$" % re.escape(old_pin), lines[n])]
    if len(hits) != 1:
        raise Refused("args.version.default %s found %d times" % (old_pin, len(hits)))
    q = re.match(r"^    default: (['\"]?)", lines[hits[0]]).group(1)
    lines[hits[0]] = "    default: " + (q + new_pin + q if q else _yaml_scalar(new_pin))

    def once(pattern, new, what):
        found = [n for n, l in enumerate(lines) if re.match(pattern, l)]
        if len(found) != 1:
            raise Refused("%s found %d times" % (what, len(found)))
        n = found[0]
        lines[n] = re.match(r"^(\s+(?:- )?\w+: )", lines[n]).group(1) + new
    once(r"^\s+integrity: %s$" % re.escape(old_integ), new_integ, "integrity")
    for old, new in extras:
        if old != new:
            once(r"^\s+(?:- )?sha256: %s$" % re.escape(old), new, "extras sha256 " + old[:12])
    return "\n".join(lines)


def yaml_path(r):
    vendor, product = r["qualified"].split("/")
    return os.path.join(AGENTS, vendor, product + ".yaml")


def propose(net, report, recipes, currency, compile_cmd=("make", "recipes")):
    by_id = {r["id"]: r for r in recipes}
    done, problems = [], []
    for row_ in report["recipes"]:
        lat = next(i for i in row_["ingredients"] if i["ingredient"] == "latest")
        if lat["status"] != "behind":
            continue
        r = by_id[row_["agent"]]
        latest = currency[0][r["id"]]["latest"]
        try:
            pin, integ, extras = propose_pin(net, r, latest)
            path = yaml_path(r)
            text = read_text(path)
            new = rewrite_pin(text, r["pin"], pin, r["install"]["integrity"], integ,
                              list(zip([e["sha256"] for e in r["install"].get("extras") or []], extras)))
            with open(path, "w") as f:
                f.write(new)
            done.append(r["id"])
            print("proposed  %-12s %s → %s (integrity verified against the download)" % (r["id"], r["pin"], pin))
        except Mismatch as e:
            print("NOT PROPOSED  %-12s %s" % (r["id"], e))
            problems.append(r["id"])
        except Refused as e:
            print("not proposed  %-12s %s" % (r["id"], e))
        except (Gone, Unreachable, TooBig) as e:
            print("not proposed  %-12s could not be verified: %s" % (r["id"], e))
    if not done:
        print("propose: nothing to rewrite")
        return 1 if problems else 0
    print("propose: compiling (%s) …" % " ".join(compile_cmd))
    rc = subprocess.call(list(compile_cmd), cwd=REPO)
    if rc != 0:
        print("propose: make recipes failed (%d)" % rc)
        return rc
    print("propose: rewritten, NOT committed: %s" % " ".join(done))
    print("next: make recipe-check RECIPES=\"%s\" && make profile-agents AGENTS=\"%s\" — then commit the YAML, compiled JSON and profiles"
          % (" ".join(done), " ".join(done)))
    return 1 if problems else 0


# ── main ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

def selected(names):
    docs = {}
    for f in sorted(glob.glob(os.path.join(COMPILED, "*.json"))):
        docs[os.path.basename(f)[:-5]] = read_json(f)
    if not names or names == ["all"]:
        return [load(d) for d in docs.values() if recipes_published.is_published(d)], True
    unknown = [n for n in names if n not in docs]
    if unknown:
        sys.exit("recipe-audit: no recipe %s (known: %s)" % (", ".join(unknown), " ".join(docs)))
    return [load(docs[n]) for n in names], False


def main(argv=None):
    ap = argparse.ArgumentParser(description="The recipe ingredient audit (read-only).")
    ap.add_argument("--recipes", default="", help='"a b" — any recipes (default: the published ones)')
    ap.add_argument("--propose", action="store_true", help="rewrite each behind, non-built-in recipe's pin (verified) and make recipes")
    ap.add_argument("--cache", default=os.path.join(tempfile.gettempdir(), "doz-recipe-audit"))
    ap.add_argument("--max-bytes", type=int, default=MAX_BYTES)
    ap.add_argument("--report", help="also write the JSON report here")
    ap.add_argument("--summary", help="append the Markdown summary here (the job summary)")
    a = ap.parse_args(argv)
    recipes, whole = selected(a.recipes.split())
    net = Net(cache=a.cache, max_bytes=a.max_bytes)
    currency = read_currency()
    report = audit(net, recipes, currency, read_text(BASES_SWIFT),datetime.date.today().isoformat())
    print(console(report))
    blob = json.dumps(report, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    if whole:
        with open(OUT, "w") as f:
            f.write(blob)
        print("wrote " + os.path.relpath(OUT, REPO))
    else:
        print("profiles/audit.json not written (a named set of recipes)")
    if a.report:
        with open(a.report, "w") as f:
            f.write(blob)
    if a.summary:
        with open(a.summary, "a") as f:
            f.write(summary_markdown(report))
    rc = 1 if failing(report) else 0
    if a.propose:
        rc = max(rc, propose(net, report, recipes, currency))
    return rc


if __name__ == "__main__":
    sys.exit(main())
