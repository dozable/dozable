#!/usr/bin/env python3
"""The cost of a `doz` start (make test-cli-startup).

usage: Scripts/startup-check.py DOZ

Runs the given doz (a guarded test run: the Makefile's DOZ_TEST_GUARD=1 and friends) against a SCRATCH store and settings
of its own under $TMPDIR, and checks:
  1. `ls --json`, `sessions nosuch --json`, `exec nosuch --no-start -- true` and `attach nosuch` build no recipe part
     (DOZ_TEST_STARTUP_TRACE=1 prints each lazily built part on stderr) — with a doz.toml that sets only Dozable's own
     keys, and with one that also sets a recipe's key; `doz config show --json` is the positive control (it must build them);
  2. the median wall time of 10 `doz ls --json` runs (after one warm-up) is at most STARTUP_MAX_MS (default 60), and at
     most STARTUP_BG_MAX_MS (default 1000) under `taskpolicy -b` (macOS background priority);
  3. `taskpolicy -b doz doctor` warns about the priority; a host started by a `taskpolicy -b` client leaves the
     background state (`host status`: priority not background, priorityRestored) and doctor says so.
Any host a command started is stopped at the end (only this scratch store's). Prints PASS/FAIL lines and
`startup-check: ALL PASS` last.
"""
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

doz = os.path.abspath(sys.argv[1])
max_ms = float(os.environ.get("STARTUP_MAX_MS", "60"))
bg_max_ms = float(os.environ.get("STARTUP_BG_MAX_MS", "1000"))
if os.environ.get("DOZ_TEST_GUARD") != "1":
    sys.exit("startup-check: run it from make (DOZ_TEST_GUARD=1 is not set)")

# A short root: a store's socket path must stay under 104 bytes.
root = tempfile.mkdtemp(prefix="dozsu-", dir=os.environ.get("TMPDIR", "/tmp"))
store = os.path.join(root, "store")
xdg = os.path.join(root, "xdg")
os.makedirs(os.path.join(xdg, "doz"))
os.makedirs(store)
os.makedirs(os.path.join(root, "projects"))
env = dict(os.environ, XDG_CONFIG_HOME=xdg)
env.pop("DOZ_TEST_STARTUP_TRACE", None)
failures = 0


def check(ok, what):
    global failures
    print(("PASS " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures += 1


def settings(extra=""):
    with open(os.path.join(xdg, "doz", "doz.toml"), "w") as f:
        f.write('[store]\npath = "%s"\n\n[defaults]\nprojects_dir = "%s"\n%s' % (store, os.path.join(root, "projects"), extra))


def traced(args):
    p = subprocess.run([doz] + args, env=dict(env, DOZ_TEST_STARTUP_TRACE="1"), capture_output=True, text=True, timeout=120)
    return [l for l in p.stderr.splitlines() if l.startswith("doz-startup-trace:")]


def times(prefix, n=10):
    cmd = prefix + [doz, "ls", "--json"]
    subprocess.run(cmd, env=env, capture_output=True, timeout=120)
    out = []
    for _ in range(n):
        t0 = time.perf_counter()
        subprocess.run(cmd, env=env, capture_output=True, timeout=120)
        out.append((time.perf_counter() - t0) * 1000)
    return out


try:
    commands = [["ls", "--json"], ["sessions", "nosuch", "--json"], ["exec", "nosuch", "--no-start", "--", "true"], ["attach", "nosuch"]]
    for name, extra in [("Dozable's keys only", ""), ("a recipe's key too", '\n[recipes.xai.grok]\napprovals = "ask"\n')]:
        settings(extra)
        for c in commands:
            built = traced(c)
            check(not built, "doz %s builds no recipe part (%s)%s" % (" ".join(c), name, "" if not built else ": " + "; ".join(built)))
    settings()
    control = traced(["config", "show", "--json"])
    check(any("settings" in l for l in control), "the positive control: doz config show --json builds the recipes' settings (%s)" % "; ".join(control))

    t = times([])
    m = statistics.median(t)
    check(m <= max_ms, "doz ls --json: median %.0f ms <= %.0f ms (runs: %s)" % (m, max_ms, " ".join("%.0f" % x for x in t)))
    if shutil.which("taskpolicy"):
        b = times(["taskpolicy", "-b"])
        mb = statistics.median(b)
        check(mb <= bg_max_ms, "doz ls --json under taskpolicy -b: median %.0f ms <= %.0f ms (runs: %s)" % (mb, bg_max_ms, " ".join("%.0f" % x for x in b)))

        # 3. Background priority: doctor says so, and a host a background client started leaves it.
        def doctor(prefix):
            p = subprocess.run(prefix + [doz, "doctor", "--json"], env=env, capture_output=True, text=True, timeout=300)
            try:
                return {c["check"]: c for c in json.loads(p.stdout)}
            except ValueError:
                return {}
        d = doctor(["taskpolicy", "-b"])
        pr = d.get("priority", {})
        check(pr.get("status") == "warn" and "background priority" in pr.get("detail", ""),
              "taskpolicy -b doz doctor: the priority warning (%s)" % pr.get("detail", "none"))
        d = doctor([])
        check(d.get("priority", {}).get("status") == "ok", "doz doctor at normal priority: priority ok (%s)" % d.get("priority", {}).get("detail", "none"))
        # (exec nosuch above started a host: a fresh one, from a background client)
        subprocess.run([doz, "host", "stop"], env=env, capture_output=True, timeout=300)
        subprocess.run(["taskpolicy", "-b", doz, "host", "start"], env=env, capture_output=True, timeout=120)
        p = subprocess.run([doz, "host", "status", "--json"], env=env, capture_output=True, text=True, timeout=60)
        try:
            st = json.loads(p.stdout)
        except ValueError:
            st = {}
        hp = st.get("priority") or {}
        check(hp.get("background") is False and st.get("priorityRestored") is True and (hp.get("pri") or 0) > 4,
              "a host started by a taskpolicy -b client leaves the background: %s, priorityRestored %s" % (hp, st.get("priorityRestored")))
        d = doctor(["taskpolicy", "-b"])
        hc = d.get("host priority", {})
        check(hc.get("status") == "ok" and "moved out of the background priority" in hc.get("detail", ""),
              "doctor's host priority: ok, moved out (%s)" % hc.get("detail", "none"))
        subprocess.run([doz, "host", "stop"], env=env, capture_output=True, timeout=300)
finally:
    subprocess.run([doz, "host", "stop"], env=env, capture_output=True, timeout=300)
    shutil.rmtree(root, ignore_errors=True)

print("startup-check: ALL PASS" if failures == 0 else "startup-check: %d FAILED" % failures)
sys.exit(1 if failures else 0)
