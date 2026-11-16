#!/usr/bin/env python3
"""A host started where the login keychain is locked (make test-cli-keychainlocked).

usage: Scripts/keychain-locked-check.py DOZ

A guarded test run (the Makefile's DOZ_TEST_GUARD=1 and friends) on a SCRATCH store and settings of its own under
$TMPDIR, no VM. DOZ_TEST_KEYCHAIN_LOCKED=1 (a guarded seam) makes a process's session read as an ssh one. Checks:
  1. a host started with it says so before it starts (stderr), and `host status --json` carries keychainLocked: ssh;
  2. `doz account ls` (from a normal session) names that host as the reason, with the restart hint, on stderr;
  3. `doz doctor --json` has a `host login` warning saying the same;
  4. a host started without it carries nothing, and nothing is said;
  5. (always on) a locked daemon is NEVER always on, whatever daemon.always_on says: its status says alwaysOn false and an
     idle timeout of 5 minutes when the setting's is 0; with a 3 s timeout it exits by itself.
  6. (the login item) a locked `daemon restart` against an unlocked daemon with no login item loaded is refused;
  7. the login item's look (`daemon start --login-item`, a normal session) replaces a locked daemon that runs nothing;
  8. doctor's login item row; nothing is written to the (scratch) LaunchAgents folder.
Prints PASS/FAIL lines and `keychain-locked-check: ALL PASS` last; stops every host it started.
"""
import json
import os
import time
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
        return json.loads(run(["daemon", "status", "--json"]).stdout)
    except ValueError:
        return {}


try:
    r = run(["daemon", "start"], locked)
    check(r.returncode == 0 and "login keychain is locked (ssh)" in r.stderr,
          "a host started where the keychain is locked: said before it starts (%s)" % r.stderr.strip()[:160])
    st = status()
    check(st.get("keychainLocked") == "ssh", "host status --json: keychainLocked ssh (%s)" % st.get("keychainLocked"))
    r = run(["account", "ls"])
    pid = str(st.get("pid", "?"))
    check("the doz daemon (pid %s, started" % pid in r.stderr and "doz daemon restart from a logged-in session" in r.stderr,
          "account ls names the host as the reason, with the restart hint (%s)" % r.stderr.strip()[:200])
    r = run(["account", "ls", "--json"])
    check("doz daemon" not in r.stdout, "--json's stdout stays the rows")
    r = run(["doctor", "--json"])
    try:
        checks = {c["check"]: c for c in json.loads(r.stdout)}
    except ValueError:
        checks = {}
    hl = checks.get("daemon login", {})          # named "host login" before 0.50 (this row looked for that name since)
    check(hl.get("status") == "warn" and "doz daemon restart" in hl.get("detail", ""), "doctor: daemon login warns (%s)" % hl.get("detail", "none"))
    run(["daemon", "stop"])
    # 5. always on: never for a locked daemon.
    lon = dict(locked, DOZ_DAEMON_ALWAYS_ON="on", DOZ_DAEMON_IDLE="0")
    run(["daemon", "start"], lon)
    st = status()
    check(st.get("keychainLocked") == "ssh" and st.get("alwaysOn") is False and st.get("idleTimeoutMinutes") == 5,
          "a locked daemon with daemon.always_on on and no idle timeout: alwaysOn false, exits after 5 min (%s, %s)"
          % (st.get("alwaysOn"), st.get("idleTimeoutMinutes")))
    r = run(["daemon", "status"])
    check("not always on: it was started where the login keychain is locked" in r.stdout,
          "daemon status says why it is not always on (%s)" % r.stdout.strip().split("\n")[-1][:160])
    run(["daemon", "stop"])
    run(["daemon", "start"], dict(lon, DOZ_DAEMON_IDLE="0.05"))
    t0 = time.time()
    while time.time() - t0 < 30 and os.path.exists(os.path.join(store, "daemon.pid")):
        time.sleep(0.2)
    check(not os.path.exists(os.path.join(store, "daemon.pid")),
          "a locked daemon with daemon.always_on on and a 3 s timeout exited by itself after %.1f s" % (time.time() - t0))
    r = run(["daemon", "start"])
    check(r.returncode == 0 and "keychain" not in r.stderr, "a host started from a normal session: nothing said")
    st = status()
    check("keychainLocked" not in st or st.get("keychainLocked") is None, "…and its status carries nothing")
    r = run(["account", "ls"])
    check("doz daemon restart" not in r.stderr, "…and account ls says nothing")
    # 6. (the login item) from a locked session, a restart never replaces a daemon that can read the keychain — the
    #    Makefile's launchctl refuses everything, so no login item is loaded: refused, the same daemon.
    pid = status().get("pid")
    r = run(["daemon", "restart"], locked)
    check(r.returncode != 0 and "not restarted" in r.stderr and status().get("pid") == pid,
          "a locked daemon restart against an unlocked daemon, no login item: refused (exit %d), the same pid" % r.returncode)
    # 7. the login item's look (doz daemon start --login-item, from the desktop session) replaces a locked daemon that
    #    runs nothing — and only then.
    run(["daemon", "stop"])
    run(["daemon", "start"], locked)
    st = status()
    lpid = st.get("pid")
    check(st.get("keychainLocked") == "ssh", "a locked daemon again (pid %s)" % lpid)
    r = run(["daemon", "start", "--login-item", "--store", store])
    st = status()
    log = open(os.path.join(store, "login-item.log")).read() if os.path.exists(os.path.join(store, "login-item.log")) else ""
    check(r.returncode == 0 and st.get("pid") not in (None, lpid) and st.get("keychainLocked") is None
          and "cannot read the login keychain and runs nothing" in log,
          "the login item's look replaced the locked idle daemon (pid %s -> %s, keychainLocked %s)" % (lpid, st.get("pid"), st.get("keychainLocked")))
    # 8. doctor has its login item row (never set up here: nothing in the scratch LaunchAgents folder).
    r = run(["doctor", "--json"])
    try:
        checks = {c["check"]: c for c in json.loads(r.stdout)}
    except ValueError:
        checks = {}
    li = checks.get("login item", {})
    check(li.get("status") == "ok" and "not set up" in li.get("detail", ""), "doctor: the login item row (%s)" % li.get("detail", "none"))
    agents = os.environ.get("DOZ_TEST_LAUNCH_AGENTS_DIR", "")
    check(not agents or not any(n.startswith("com.dozable.") for n in (os.listdir(agents) if os.path.isdir(agents) else [])),
          "nothing written to the scratch LaunchAgents folder")
finally:
    subprocess.run([doz, "daemon", "stop"], env=env, capture_output=True, timeout=300)
    shutil.rmtree(root, ignore_errors=True)

print("keychain-locked-check: ALL PASS" if failures == 0 else "keychain-locked-check: %d FAILED" % failures)
sys.exit(1 if failures else 0)
