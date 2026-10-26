#!/usr/bin/env python3
# 655: the recipe audit's DECISIONS (Scripts/recipe_audit.py) on fixtures — with the network REFUSED: every socket this
# process tries to open fails, so a decision that reached a registry would show as an error here, never pass.
#
#   /usr/bin/python3 -I Tests/Scripts/test_recipe_audit.py      (make test-recipe-audit; RecipeAuditScriptTests in make test)
#
# The fixtures are built here from known bytes (a hash in a fixture is always the hash of those bytes), plus three real
# files read-only: Sources/DozableKit/BaseCatalogue.swift (what the audit reads its shared pins from) and two recipe YAMLs
# (the pin rewrite). Python 3.9+ stdlib only.
import base64, hashlib, importlib.util, json, os, shutil, socket, sys, tempfile, unittest


def _refused(*a, **k):
    raise OSError("the network is refused in the recipe audit's unit tests")


class _NoSocket(socket.socket):
    def __init__(self, *a, **k):
        _refused()


socket.socket = _NoSocket
socket.create_connection = _refused
socket.getaddrinfo = _refused

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_spec = importlib.util.spec_from_file_location("recipe_audit", os.path.join(REPO, "Scripts", "recipe_audit.py"))
ra = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ra)


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def sri(b):
    return "sha512-" + base64.b64encode(hashlib.sha512(b).digest()).decode()


class FakeNet:
    """The registries, as fixtures: URL → a JSON answer, text, bytes (hashed like a download), or 404 / an outage.
    Every call is recorded, so a test can say what was NOT fetched."""

    GONE, DOWN, HUGE = "<404>", "<down>", "<huge>"

    def __init__(self, answers=None, digests=None):
        self.answers = dict(answers or {})
        self.digests = dict(digests or {})
        self.calls = []

    def _get(self, kind, url):
        self.calls.append((kind, url))
        if url not in self.answers:
            raise ra.Unreachable("no fixture for " + url)
        a = self.answers[url]
        if a == self.GONE:
            raise ra.Gone("%s answered 404" % ra._host(url))
        if a == self.DOWN:
            raise ra.Unreachable("%s answered 503" % ra._host(url))
        if a == self.HUGE:
            raise ra.TooBig("900 MiB")
        return a

    def json(self, url):
        return self._get("json", url)

    def text(self, url):
        return self._get("text", url)

    def hashes(self, url):
        b = self._get("hashes", url)
        return {"sha256": sha256(b), "sha512": hashlib.sha512(b).hexdigest(), "size": len(b)}

    def manifest_digest(self, registry, repo, ref):
        key = "%s/%s@%s" % (registry, repo, ref)
        self.calls.append(("digest", key))
        d = self.digests.get(key, self.GONE)
        if d == self.GONE:
            raise ra.Gone("%s answered 404" % registry)
        if d == self.DOWN:
            raise ra.Unreachable("%s answered 503" % registry)
        return d


def recipe(id_, kind, pin, install=None, vendor="acme", builtin=False, major=None, published=True, network=None):
    caps = [{"type": "com.dozable/install@1", "config": dict({"kind": kind}, **(install or {}), **({"builtin": True} if builtin else {}))},
            {"type": "com.dozable/directory@1", "config": dict({"default_base": "debian"}, **({} if published else {"published": False}))},
            {"type": "com.dozable/auth@1", "config": {"methods": [{"kind": "api-key", "provider": "xai"}]}},
            {"type": "com.dozable/gateways@1", "config": {"entries": [{"gateway": "openrouter", "level": "documented"}]}}]
    if major is not None:
        caps.append({"type": "com.dozable/family@1", "config": {"family": id_, "major": major, "recommended": True, "title": id_}})
    if network is not None:
        caps.append({"type": "com.docker.sandbox/network-policy@1", "config": network})
    return ra.load({"id": "%s/%s" % (vendor, id_), "displayName": id_.title(), "args": {"version": {"default": pin}}, "capabilities": caps})


TOOL = b"tool-1.0.0 tarball"
PLAT = b"tool-linux-arm64-1.0.0 tarball"
NPM_TOOL = {"dist": {"integrity": sri(TOOL), "tarball": "https://registry.npmjs.org/tool/-/tool-1.0.0.tgz"}}
NO_CURRENCY = ({}, None)


def ing(row, name):
    return next(i for i in row["ingredients"] if i["ingredient"] == name)


class PinTests(unittest.TestCase):
    def test_a_matching_npm_pin_is_ok(self):
        net = FakeNet({ra.npm_url("tool", "1.0.0"): NPM_TOOL})
        r = ra.audit_recipe(net, recipe("tool", "npm", "1.0.0", {"package": "tool", "integrity": sri(TOOL)}), NO_CURRENCY)
        self.assertEqual(ing(r, "pin")["status"], "ok", ing(r, "pin"))

    def test_a_changed_integrity_is_changed_and_fails_the_run(self):
        net = FakeNet({ra.npm_url("tool", "1.0.0"): {"dist": {"integrity": sri(b"someone re-published it")}}})
        rec = recipe("tool", "npm", "1.0.0", {"package": "tool", "integrity": sri(TOOL)})
        rep = ra.audit(net, [rec], NO_CURRENCY, "", "2026-10-26")
        self.assertEqual(ing(rep["recipes"][0], "pin")["status"], "changed")
        self.assertEqual(rep["recipes"][0]["status"], "changed")
        self.assertTrue(ra.failing(rep))
        self.assertIn("FAILED", ra.summary_markdown(rep))

    def test_a_gone_version_is_gone(self):
        net = FakeNet({ra.npm_url("tool", "1.0.0"): FakeNet.GONE})
        r = ra.audit_recipe(net, recipe("tool", "npm", "1.0.0", {"package": "tool", "integrity": sri(TOOL)}), NO_CURRENCY)
        self.assertEqual(ing(r, "pin")["status"], "gone")

    def test_an_outage_is_unchecked_never_gone_and_does_not_fail(self):
        net = FakeNet({ra.npm_url("tool", "1.0.0"): FakeNet.DOWN})
        rep = ra.audit(net, [recipe("tool", "npm", "1.0.0", {"package": "tool", "integrity": sri(TOOL)})], NO_CURRENCY, "", "2026-10-26")
        self.assertEqual(ing(rep["recipes"][0], "pin")["status"], "unchecked")
        self.assertFalse(ra.failing(rep))

    def test_a_platform_package_needs_its_main_package_and_its_own_integrity(self):
        install = {"package": "tool", "platform_package": "tool-linux-arm64", "integrity": sri(PLAT)}
        ok = FakeNet({ra.npm_url("tool", "1.0.0"): NPM_TOOL, ra.npm_url("tool-linux-arm64", "1.0.0"): {"dist": {"integrity": sri(PLAT)}}})
        self.assertEqual(ing(ra.audit_recipe(ok, recipe("tool", "npm-platform-binary", "1.0.0", install), NO_CURRENCY), "pin")["status"], "ok")
        main_gone = FakeNet({ra.npm_url("tool", "1.0.0"): FakeNet.GONE, ra.npm_url("tool-linux-arm64", "1.0.0"): {"dist": {"integrity": sri(PLAT)}}})
        self.assertEqual(ing(ra.audit_recipe(main_gone, recipe("tool", "npm-platform-binary", "1.0.0", install), NO_CURRENCY), "pin")["status"], "gone")
        main_ok_wrong_platform = FakeNet({ra.npm_url("tool", "1.0.0"): NPM_TOOL, ra.npm_url("tool-linux-arm64", "1.0.0"): {"dist": {"integrity": sri(TOOL)}}})
        self.assertEqual(ing(ra.audit_recipe(main_ok_wrong_platform, recipe("tool", "npm-platform-binary", "1.0.0", install), NO_CURRENCY), "pin")["status"], "changed")

    def test_codex_built_in_is_checked_at_its_linux_arm64_version(self):
        net = FakeNet({ra.npm_url("@openai/codex", "0.160.1-linux-arm64"): {"dist": {"integrity": sri(PLAT)}}})
        r = ra.audit_recipe(net, recipe("codex", "builtin", "0.160.1", {"package": "@openai/codex", "integrity": sri(PLAT)}, builtin=True), NO_CURRENCY)
        self.assertEqual(ing(r, "pin")["status"], "ok", ing(r, "pin"))
        self.assertEqual(net.calls, [("json", "https://registry.npmjs.org/@openai%2Fcodex/0.160.1-linux-arm64")])

    def test_manifest_binary_uses_the_manifest_hash_while_it_names_the_pin(self):
        tmpl = "https://dl.example.com/cli/${{ dozable.build }}/cli_linux_arm64.tar.gz"
        url = "https://dl.example.com/cli/1.3.4-55/cli_linux_arm64.tar.gz"
        install = {"manifest": "https://dl.example.com/manifest.json", "url": tmpl, "integrity": sri(TOOL)}
        net = FakeNet({install["manifest"]: {"version": "1.3.4", "url": url, "sha512": hashlib.sha512(TOOL).hexdigest()}})
        r = ra.audit_recipe(net, recipe("cli", "manifest-binary", "1.3.4+55", install), NO_CURRENCY)
        self.assertEqual(ing(r, "pin")["status"], "ok", ing(r, "pin"))
        self.assertNotIn("hashes", [k for k, _ in net.calls], "no download while the manifest's own hash proves it")
        # The manifest moved on: the pinned archive is downloaded and hashed instead.
        moved = FakeNet({install["manifest"]: {"version": "1.3.5", "url": url.replace("1.3.4-55", "1.3.5-60"), "sha512": "0" * 128}, url: TOOL})
        self.assertEqual(ing(ra.audit_recipe(moved, recipe("cli", "manifest-binary", "1.3.4+55", install), NO_CURRENCY), "pin")["status"], "ok")
        self.assertIn(("hashes", url), moved.calls)
        replaced = FakeNet({install["manifest"]: {}, url: b"other bytes"})
        self.assertEqual(ing(ra.audit_recipe(replaced, recipe("cli", "manifest-binary", "1.3.4+55", install), NO_CURRENCY), "pin")["status"], "changed")

    def test_release_binary_download_and_githubs_digest(self):
        tmpl = "https://github.com/acme/tool/releases/download/v${{ kit.args.version }}/tool_Linux_arm64.tar.gz"
        url = "https://github.com/acme/tool/releases/download/v1.0.0/tool_Linux_arm64.tar.gz"
        api = "https://api.github.com/repos/acme/tool/releases/tags/v1.0.0"
        install = {"url": tmpl, "integrity": sri(TOOL)}
        agree = FakeNet({url: TOOL, api: {"assets": [{"name": "tool_Linux_arm64.tar.gz", "digest": "sha256:" + sha256(TOOL)}]}})
        p = ing(ra.audit_recipe(agree, recipe("tool", "release-binary", "1.0.0", install), NO_CURRENCY), "pin")
        self.assertEqual(p["status"], "ok", p)
        self.assertIn("GitHub's asset digest agrees", p["why"])
        disagree = FakeNet({url: TOOL, api: {"assets": [{"name": "tool_Linux_arm64.tar.gz", "digest": "sha256:" + sha256(b"x")}]}})
        self.assertEqual(ing(ra.audit_recipe(disagree, recipe("tool", "release-binary", "1.0.0", install), NO_CURRENCY), "pin")["status"], "changed")
        no_api = FakeNet({url: TOOL})
        self.assertEqual(ing(ra.audit_recipe(no_api, recipe("tool", "release-binary", "1.0.0", install), NO_CURRENCY), "pin")["status"], "ok")

    def test_a_download_over_the_cap_is_unchecked(self):
        tmpl = "https://example.com/tool-${{ kit.args.version }}.tar.gz"
        net = FakeNet({"https://example.com/tool-1.0.0.tar.gz": FakeNet.HUGE})
        p = ing(ra.audit_recipe(net, recipe("tool", "release-binary", "1.0.0", {"url": tmpl, "integrity": sri(TOOL)}), NO_CURRENCY), "pin")
        self.assertEqual(p["status"], "unchecked")
        self.assertIn("too big", p["why"])


class ExtrasAndRequirementsTests(unittest.TestCase):
    TMPL = "https://codeload.github.com/acme/tool/tar.gz/refs/tags/v${{ kit.args.version }}"
    URL = "https://codeload.github.com/acme/tool/tar.gz/refs/tags/v1.0.0"

    def rec(self, extra_sha):
        return recipe("tool", "npm", "1.0.0", {"package": "tool", "integrity": sri(TOOL),
                                                "extras": [{"url": self.TMPL, "sha256": extra_sha, "path": "x", "to": "/opt/tool/x"}]})

    def test_an_extras_mismatch_is_changed(self):
        net = FakeNet({ra.npm_url("tool", "1.0.0"): NPM_TOOL, self.URL: b"patterns, re-tagged"})
        r = ra.audit_recipe(net, self.rec(sha256(b"patterns")), NO_CURRENCY)
        self.assertEqual(ing(r, "extras[0]")["status"], "changed")
        self.assertEqual(ing(r, "extras[0]")["url"], self.URL)

    def test_matching_and_gone_extras(self):
        ok = FakeNet({ra.npm_url("tool", "1.0.0"): NPM_TOOL, self.URL: b"patterns"})
        self.assertEqual(ing(ra.audit_recipe(ok, self.rec(sha256(b"patterns")), NO_CURRENCY), "extras[0]")["status"], "ok")
        gone = FakeNet({ra.npm_url("tool", "1.0.0"): NPM_TOOL, self.URL: FakeNet.GONE})
        self.assertEqual(ing(ra.audit_recipe(gone, self.rec(sha256(b"patterns")), NO_CURRENCY), "extras[0]")["status"], "gone")

    def pypi(self, dep_published_hash, own=TOOL):
        lock = ["tool==1.0 --hash=sha256:" + sha256(own),"dep==2.0 --hash=sha256:" + sha256(b"dep wheel")]
        rec = recipe("tool", "pypi", "1.0", {"package": "tool", "integrity": sri(own), "requirements": lock})
        whl = "https://files.pythonhosted.org/tool-1.0-py3-none-any.whl"
        net = FakeNet({ra.PYPI + "tool/1.0/json": {"info": {}, "urls": [{"filename": "tool-1.0-py3-none-any.whl", "url": whl, "digests": {"sha256": sha256(own)}}]},
                       ra.PYPI + "dep/2.0/json": {"info": {}, "urls": [{"digests": {"sha256": dep_published_hash}}]},
                       whl: own})
        return ra.audit_recipe(net, rec, NO_CURRENCY)

    def test_pypi_pin_and_lock(self):
        r = self.pypi(sha256(b"dep wheel"))
        self.assertEqual(ing(r, "pin")["status"], "ok", ing(r, "pin"))
        self.assertEqual(ing(r, "requirements")["status"], "ok", ing(r, "requirements"))

    def test_a_lock_hash_pypi_does_not_publish_is_changed(self):
        r = self.pypi(sha256(b"a different wheel"))
        self.assertEqual(ing(r, "requirements")["status"], "changed")
        self.assertIn("dep==2.0", ing(r, "requirements")["why"])


class LatestTests(unittest.TestCase):
    def latest(self, pin, latest, major=None, builtin=False):
        cur = ({"tool": {"agent": "tool", "latest": latest, "released": "2026-10-20"}} if latest else {}, "2026-10-26")
        return ra.latest_check(recipe("tool", "npm", pin, {"package": "tool", "integrity": sri(TOOL)}, major=major, builtin=builtin), cur)

    def test_behind_ok_and_unchecked(self):
        self.assertEqual(self.latest("1.0.0", "1.2.0")[0], "behind")
        self.assertEqual(self.latest("1.0.0", "1.0.0")[0], "ok")
        self.assertEqual(self.latest("1.10.0", "1.9.0")[0], "ok", "version order, not text order")
        self.assertEqual(self.latest("1.9.0", "1.10.0")[0], "behind")
        self.assertEqual(self.latest("1.0.0", None)[0], "unchecked")
        self.assertEqual(self.latest("1.3.4+5524", "1.3.5")[0], "behind", "a +build pin compares by its release")
        self.assertEqual(self.latest("1.3.5+5524", "1.3.5")[0], "ok")

    def test_another_major_is_another_recipe(self):
        s, why = self.latest("1.19.0", "2.0.30", major=1)
        self.assertEqual(s, "unchecked")
        self.assertIn("another major", why)
        self.assertEqual(self.latest("2.0.29", "2.0.30", major=2)[0], "behind")

    def test_behind_is_information_only(self):
        net = FakeNet({ra.npm_url("tool", "1.0.0"): NPM_TOOL})
        cur = ({"tool": {"agent": "tool", "latest": "1.1.0"}}, "2026-10-26")
        rep = ra.audit(net, [recipe("tool", "npm", "1.0.0", {"package": "tool", "integrity": sri(TOOL)})], cur, "", "2026-10-26")
        self.assertEqual(rep["recipes"][0]["status"], "behind")
        self.assertFalse(ra.failing(rep))


class SharedTests(unittest.TestCase):
    SWIFT = ra.read_text(os.path.join(REPO, "Sources/DozableKit/BaseCatalogue.swift"))

    def test_the_real_base_catalogue_reads_as_expected(self):
        p = ra.shared_pins(self.SWIFT)
        self.assertEqual(len(p["bases"]), 10, [b["id"] for b in p["bases"]])
        self.assertEqual({b["id"] for b in p["bases"]} >= {"node", "python", "debian", "alpine", "dotnet"}, True)
        for k in ("node22", "node24", "python", "claude"):
            self.assertIsNotNone(p[k], k)

    def test_a_base_digest_that_resolves_a_moved_tag_and_a_gone_one(self):
        b = {"id": "debian", "reference": "docker.io/library/debian:bookworm", "digest": "sha256:" + "a" * 64}
        same = FakeNet(digests={"docker.io/library/debian@sha256:" + "a" * 64: b["digest"], "docker.io/library/debian@bookworm": b["digest"]})
        self.assertEqual(ra.guarded(ra.base_check, same, b)[0], "ok")
        moved = FakeNet(digests={"docker.io/library/debian@sha256:" + "a" * 64: b["digest"], "docker.io/library/debian@bookworm": "sha256:" + "b" * 64})
        self.assertEqual(ra.guarded(ra.base_check, moved, b)[0], "behind")
        self.assertEqual(ra.guarded(ra.base_check, FakeNet(), b)[0], "gone")
        self.assertEqual(ra.split_reference("mcr.microsoft.com/dotnet/sdk:9.0"), ("mcr.microsoft.com", "dotnet/sdk", "9.0"))

    def test_a_checksum_list(self):
        sums = "%s  node-v1-linux-arm64.tar.xz\n%s  node-v1-darwin-arm64.tar.gz\n" % ("a" * 64, "b" * 64)
        self.assertEqual(ra.listed(sums, "node-v1-linux-arm64.tar.xz", "a" * 64)[0], "ok")
        self.assertEqual(ra.listed(sums, "node-v1-linux-arm64.tar.xz", "c" * 64)[0], "changed")
        self.assertEqual(ra.listed(sums, "node-v2-linux-arm64.tar.xz", "a" * 64)[0], "gone")

    def test_shared_ingredients_are_all_reported_and_an_outage_is_unchecked(self):
        rows = ra.audit_shared(FakeNet(), self.SWIFT)
        names = [r["ingredient"] for r in rows]
        self.assertEqual(names, sorted(names))
        self.assertIn("native:claude-code", names)
        self.assertEqual({r["status"] for r in rows if r["ingredient"].startswith("runtime:")}, {"unchecked"})
        self.assertEqual(ra.audit_shared(FakeNet(), "")[0]["status"], "unchecked", "a catalogue that no longer reads is said")


class ReportTests(unittest.TestCase):
    def test_deterministic_sorted_and_dated(self):
        recs = [recipe("zed", "npm", "1.0.0", {"package": "zed", "integrity": sri(TOOL)}),
                recipe("abc", "npm", "1.0.0", {"package": "abc", "integrity": sri(TOOL)})]
        answers = {ra.npm_url("zed", "1.0.0"): NPM_TOOL, ra.npm_url("abc", "1.0.0"): NPM_TOOL}
        one = json.dumps(ra.audit(FakeNet(answers), recs, NO_CURRENCY, "", "2026-10-26"), sort_keys=True)
        two = json.dumps(ra.audit(FakeNet(answers), list(reversed(recs)), NO_CURRENCY, "", "2026-10-26"), sort_keys=True)
        self.assertEqual(one, two)
        rep = json.loads(one)
        self.assertEqual([r["agent"] for r in rep["recipes"]], ["abc", "zed"])
        self.assertEqual(rep["checked"], "2026-10-26")

    def test_recorded_as_it_is(self):
        net = {"runtime": {"allow": ["api.x.ai:443", "opencode.ai:443"]},
               "dozable": {"model": {"hosts": [{"host": "api.x.ai", "reason": "xAI"}, {"host": "opencode.ai", "paths": ["/zen/v1/responses"]}]},
                           "excluded": [], "vendor": [{"host": "raw.githubusercontent.com", "exact_paths": ["/a/b"]}]}}
        rec = ra.records(recipe("tool", "npm", "1.0.0", {"package": "tool", "integrity": "x", "bake_hosts": ["github.com"]}, network=net))
        self.assertEqual(rec["hosts"], {"allow": ["api.x.ai", "opencode.ai"], "model": ["api.x.ai", "opencode.ai"],
                                        "vendor": ["raw.githubusercontent.com"], "bake": ["github.com"]})
        self.assertEqual(rec["auth"], ["api-key:xai"])
        self.assertEqual(rec["gateways"], {"openrouter": "documented"})
        self.assertEqual(rec["lifecycle"], {"status": "current"})
        self.assertEqual(rec["default_base"], "debian")


class ProposeTests(unittest.TestCase):
    def test_rewrite_moves_only_the_pin_in_a_real_recipe(self):
        path = os.path.join(REPO, "Sources/DozableKit/Recipes/agents/anomalyco/opencode2.yaml")
        text = ra.read_text(path)
        r = ra.load(ra.read_json(os.path.join(REPO, "Sources/DozableKit/Recipes/compiled/opencode2.json")))
        new = ra.rewrite_pin(text, r["pin"], "2.0.99", r["install"]["integrity"], "sha512-NEW==", [])
        diff = [(a, b) for a, b in zip(text.split("\n"), new.split("\n")) if a != b]
        self.assertEqual(diff, [("    default: " + r["pin"], "    default: 2.0.99"),
                                ("    integrity: " + r["install"]["integrity"], "    integrity: sha512-NEW==")])

    def test_rewrite_moves_the_extras_of_a_real_recipe(self):
        path = os.path.join(REPO, "Sources/DozableKit/Recipes/agents/danielmiessler/fabric.yaml")
        text = ra.read_text(path)
        r = ra.load(ra.read_json(os.path.join(REPO, "Sources/DozableKit/Recipes/compiled/fabric.json")))
        old = r["install"]["extras"][0]["sha256"]
        new = ra.rewrite_pin(text, r["pin"], "1.4.600", r["install"]["integrity"], "sha512-NEW==", [(old, "f" * 64)])
        self.assertEqual(sum(1 for a, b in zip(text.split("\n"), new.split("\n")) if a != b), 3)
        self.assertIn("      sha256: " + "f" * 64, new)
        self.assertIn("${{ kit.args.version }}", new, "templates are left alone")

    def test_rewrite_refuses_what_it_cannot_place_exactly(self):
        text = "schema: 2\nargs:\n  version:\n    default: 1.0.0\ncapabilities:\n- config:\n    integrity: sha512-A\n    integrity: sha512-A\n"
        with self.assertRaises(ra.Refused):
            ra.rewrite_pin(text, "1.0.0", "1.1.0", "sha512-A", "sha512-B", [])
        with self.assertRaises(ra.Refused):
            ra.rewrite_pin(text, "9.9.9", "1.1.0", "sha512-A", "sha512-B", [])
        quoted = "args:\n  version:\n    default: '1.0'\nx:\n    integrity: sha512-A\n"
        self.assertIn("    default: '1.1'", ra.rewrite_pin(quoted, "1.0", "1.1", "sha512-A", "sha512-B", []))
        bare = "args:\n  version:\n    default: 1.0.0\nx:\n    integrity: sha512-A\n"
        self.assertIn("    default: '2.0'", ra.rewrite_pin(bare, "1.0.0", "2.0", "sha512-A", "sha512-B", []), "a number-looking version stays a string")

    def test_a_proposal_is_verified_against_the_download(self):
        new = b"tool-1.1.0 tarball"
        tgz = "https://registry.npmjs.org/tool/-/tool-1.1.0.tgz"
        rec = recipe("tool", "npm", "1.0.0", {"package": "tool", "integrity": sri(TOOL)})
        good = FakeNet({ra.npm_url("tool", "1.1.0"): {"dist": {"integrity": sri(new), "tarball": tgz}}, tgz: new})
        self.assertEqual(ra.propose_pin(good, rec, "1.1.0"), ("1.1.0", sri(new), []))
        bad = FakeNet({ra.npm_url("tool", "1.1.0"): {"dist": {"integrity": sri(new), "tarball": tgz}}, tgz: b"not what npm says"})
        with self.assertRaises(ra.Mismatch):
            ra.propose_pin(bad, rec, "1.1.0")

    def test_built_in_and_pypi_are_never_proposed(self):
        with self.assertRaises(ra.Refused):
            ra.propose_pin(FakeNet(), recipe("pi", "builtin", "0.84.1", {"package": "pi", "integrity": "x"}, builtin=True), "1.2.0")
        with self.assertRaises(ra.Refused):
            ra.propose_pin(FakeNet(), recipe("llm", "pypi", "0.36", {"package": "llm", "integrity": "x"}), "0.37")

    def test_a_manifest_proposal(self):
        tmpl = "https://dl.example.com/cli/${{ dozable.build }}/cli.tar.gz"
        url = "https://dl.example.com/cli/1.3.5-60/cli.tar.gz"
        rec = recipe("cli", "manifest-binary", "1.3.4+55", {"manifest": "https://dl.example.com/m.json", "url": tmpl, "integrity": sri(TOOL)})
        net = FakeNet({"https://dl.example.com/m.json": {"version": "1.3.5", "url": url, "sha512": hashlib.sha512(PLAT).hexdigest()}, url: PLAT})
        self.assertEqual(ra.propose_pin(net, rec, "1.3.5"), ("1.3.5+60", sri(PLAT), []))
        elsewhere = FakeNet({"https://dl.example.com/m.json": {"version": "1.3.5", "url": "https://evil.example/1.3.5-60/cli.tar.gz", "sha512": hashlib.sha512(PLAT).hexdigest()}})
        with self.assertRaises(ra.Refused):
            ra.propose_pin(elsewhere, rec, "1.3.5")

    def test_propose_rewrites_the_yaml_and_compiles_never_commits(self):
        tmp = tempfile.mkdtemp()
        try:
            os.makedirs(os.path.join(tmp, "acme"))
            yaml = os.path.join(tmp, "acme", "tool.yaml")
            with open(yaml, "w") as f:
                f.write("schema: 2\nargs:\n  version:\n    default: 1.0.0\ncapabilities:\n- type: com.dozable/install@1\n  config:\n    integrity: %s\n" % sri(TOOL))
            new = b"tool-1.1.0 tarball"
            tgz = "https://registry.npmjs.org/tool/-/tool-1.1.0.tgz"
            net = FakeNet({ra.npm_url("tool", "1.0.0"): NPM_TOOL, ra.npm_url("tool", "1.1.0"): {"dist": {"integrity": sri(new), "tarball": tgz}}, tgz: new})
            rec = recipe("tool", "npm", "1.0.0", {"package": "tool", "integrity": sri(TOOL)})
            cur = ({"tool": {"agent": "tool", "latest": "1.1.0"}}, "2026-10-26")
            rep = ra.audit(net, [rec], cur, "", "2026-10-26")
            saved = ra.AGENTS
            ra.AGENTS = tmp
            try:
                stamp = os.path.join(tmp, "compiled")
                rc = ra.propose(net, rep, [rec], cur, compile_cmd=("/usr/bin/touch", stamp))
            finally:
                ra.AGENTS = saved
            self.assertEqual(rc, 0)
            self.assertTrue(os.path.exists(stamp), "make recipes ran")
            text = ra.read_text(yaml)
            self.assertIn("    default: 1.1.0\n", text)
            self.assertIn("    integrity: %s\n" % sri(new), text)
        finally:
            shutil.rmtree(tmp)

    def test_a_first_compile_that_fails_is_run_once_more(self):
        # make recipes after a YAML edit writes the JSON, then fails once on the old embedded data; the second run passes.
        tmp = tempfile.mkdtemp()
        try:
            os.makedirs(os.path.join(tmp, "acme"))
            with open(os.path.join(tmp, "acme", "tool.yaml"), "w") as f:
                f.write("schema: 2\nargs:\n  version:\n    default: 1.0.0\ncapabilities:\n- config:\n    integrity: %s\n" % sri(TOOL))
            new = b"tool-1.1.0 tarball"
            tgz = "https://registry.npmjs.org/tool/-/tool-1.1.0.tgz"
            net = FakeNet({ra.npm_url("tool", "1.0.0"): NPM_TOOL, ra.npm_url("tool", "1.1.0"): {"dist": {"integrity": sri(new), "tarball": tgz}}, tgz: new})
            rec = recipe("tool", "npm", "1.0.0", {"package": "tool", "integrity": sri(TOOL)})
            cur = ({"tool": {"agent": "tool", "latest": "1.1.0"}}, "2026-10-26")
            rep = ra.audit(net, [rec], cur, "", "2026-10-26")
            count = os.path.join(tmp, "runs")
            # Fails the first time (no count file yet), passes the second.
            cmd = ("/bin/sh", "-c", 'if [ -e "$0" ]; then exit 0; else : > "$0"; exit 1; fi', count)
            saved = ra.AGENTS
            ra.AGENTS = tmp
            try:
                self.assertEqual(ra.propose(net, rep, [rec], cur, compile_cmd=cmd), 0)
                always = ("/bin/sh", "-c", "exit 3")
                rec2 = recipe("tool", "npm", "1.0.0", {"package": "tool", "integrity": sri(new)})
                with open(os.path.join(tmp, "acme", "tool.yaml"), "w") as f:
                    f.write("schema: 2\nargs:\n  version:\n    default: 1.0.0\ncapabilities:\n- config:\n    integrity: %s\n" % sri(new))
                rep2 = ra.audit(net, [rec2], cur, "", "2026-10-26")
                self.assertEqual(ra.propose(net, rep2, [rec2], cur, compile_cmd=always), 3, "a compile that fails twice is the answer")
            finally:
                ra.AGENTS = saved
        finally:
            shutil.rmtree(tmp)


class NetworkGuardTests(unittest.TestCase):
    def test_the_real_net_cannot_reach_anything_here(self):
        with self.assertRaises(ra.Unreachable):
            ra.Net().json("https://registry.npmjs.org/tool/1.0.0")


if __name__ == "__main__":
    unittest.main(verbosity=1)
