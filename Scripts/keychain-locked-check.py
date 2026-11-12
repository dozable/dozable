#!/usr/bin/env python3
"""A host started where the login keychain is locked (make test-cli-keychainlocked).

usage: Scripts/keychain-locked-check.py DOZ

A guarded test run (the Makefile's DOZ_TEST_GUARD=1 and friends) on a SCRATCH store and settings of its own under
$TMPDIR, no VM. DOZ_TEST_KEYCHAIN_LOCKED=1 (a guarded seam) makes a process's session read as an ssh one. Checks:
  1. a host started with it says so before it starts (stderr), and `host status --json` carries keychainLocked: ssh;
  2. `doz account ls` (from a normal session) names that host as the reason, with the restart hint, on stderr;
  3. `doz doctor --json` has a `host login` warning saying the same;
  4. a host started without it carries nothing, and nothing is said.
Prints PASS/FAIL lines and `keychain-locked-check: ALL PASS` last; stops every host it started.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

doz = os.path.abspath(sys.argv[1])
if os.environ.get("DOZ_TEST_GUARD") != "1":
    sys.exit("keychain-locked-check: run it from make (DOZ_TEST_GUARD=1 is not set)")
root = tempfile.mkdtemp(prefix="dozkc-", dir=os.environ.get("TMPDIR", "/tmp"))
store = os.path.join(root, "store")
xdg = os.path.join(root, "xdg")
os.makedirs(os.path.join(xdg, "doz"))
os.makedirs(store)
os.makedirs(os.path.join(root, "projects"))
with open(os.path.join(xdg, "doz", "doz.toml"), "w") as f:
    f.write('[store]\npath = "%s"\n\n[defaults]\nprojects_dir = "%s"\n' % (store, os.path.join(root, "projects")))
env = dict(os.environ, XDG_CONFIG_HOME=xdg)
env.pop("DOZ_TEST_KEYCHAIN_LOCKED", None)
locked = dict(env, DOZ_TEST_KEYCHAIN_LOCKED="1")
failures = 0


def check(ok, what):
    global failures
    print(("PASS " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures += 1


def run(args, e=env):
    return subprocess.run([doz] + args, env=e, capture_output=True, text=True, timeout=120)


def status():
    try:
        return json.loads(run(["host", "status", "--json"]).stdout)
    except ValueError:
        return {}


try:
    r = run(["host", "start"], locked)
    check(r.returncode == 0 and "login keychain is locked (ssh)" in r.stderr,
          "a host started where the keychain is locked: said before it starts (%s)" % r.stderr.strip()[:160])
    st = status()
    check(st.get("keychainLocked") == "ssh", "host status --json: keychainLocked ssh (%s)" % st.get("keychainLocked"))
    r = run(["account", "ls"])
    pid = str(st.get("pid", "?"))
    check("the doz host (pid %s, started" % pid in r.stderr and "doz host restart from a logged-in session" in r.stderr,
          "account ls names the host as the reason, with the restart hint (%s)" % r.stderr.strip()[:200])
    r = run(["account", "ls", "--json"])
    check("doz host" not in r.stdout, "--json's stdout stays the rows")
    r = run(["doctor", "--json"])
    try:
        checks = {c["check"]: c for c in json.loads(r.stdout)}
    except ValueError:
        checks = {}
    hl = checks.get("host login", {})
    check(hl.get("status") == "warn" and "doz host restart" in hl.get("detail", ""), "doctor: host login warns (%s)" % hl.get("detail", "none"))
    run(["host", "stop"])
    r = run(["host", "start"])
    check(r.returncode == 0 and "keychain" not in r.stderr, "a host started from a normal session: nothing said")
    st = status()
    check("keychainLocked" not in st or st.get("keychainLocked") is None, "…and its status carries nothing")
    r = run(["account", "ls"])
    check("doz host restart" not in r.stderr, "…and account ls says nothing")
finally:
    subprocess.run([doz, "host", "stop"], env=env, capture_output=True, timeout=300)
    shutil.rmtree(root, ignore_errors=True)

print("keychain-locked-check: ALL PASS" if failures == 0 else "keychain-locked-check: %d FAILED" % failures)
sys.exit(1 if failures else 0)
