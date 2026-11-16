#!/usr/bin/env python3
"""A fake launchctl for `make test-cli-daemon` (DOZ_TEST_LAUNCHCTL, guarded runs only) — never the real launchd.

It records every call (one line of argv in $FAKE_LAUNCHCTL_LOG) and keeps launchd's state in a JSON file of its own
($FAKE_LAUNCHCTL_STATE): {"loaded": {label: plist path}, "apps": {label: program}, "disabled": [label, ...]}.

  bootstrap gui/UID PLIST    loads it (its Label); 5 when that label is loaded already
  bootout gui/UID/LABEL      unloads it; 113 when not loaded
  kickstart gui/UID/LABEL    runs the loaded plist's ProgramArguments NOW, detached (its own session, stdin /dev/null,
                             stdout+stderr appended to its StandardOutPath), the way launchd runs a job in the desktop
                             session: without DOZ_TEST_KEYCHAIN_LOCKED and SSH_CONNECTION (that session's keychain is open)
  print gui/UID/LABEL        0 and a `program = …` / `arguments = {…}` block when loaded (or an app job in "apps"); else 113
  print-disabled gui/UID     the "disabled services" block from "disabled"

The suite edits the state file itself to stand in for the menu bar app's job or a switched-off item.
"""
import fcntl
import json
import os
import plistlib
import subprocess
import sys

log = os.environ.get("FAKE_LAUNCHCTL_LOG")
state_path = os.environ.get("FAKE_LAUNCHCTL_STATE")
args = sys.argv[1:]
if log:
    with open(log, "a") as f:
        f.write(" ".join(args) + "\n")
if not state_path:
    sys.stderr.write("fake launchctl: FAKE_LAUNCHCTL_STATE is not set\n")
    sys.exit(1)

lock = open(state_path + ".lock", "a")
fcntl.flock(lock, fcntl.LOCK_EX)
try:
    with open(state_path) as f:
        state = json.load(f)
except (OSError, ValueError):
    state = {}
state.setdefault("loaded", {})
state.setdefault("apps", {})
state.setdefault("disabled", [])


def save():
    with open(state_path + ".new", "w") as f:
        json.dump(state, f)
    os.replace(state_path + ".new", state_path)


def label_of(target):
    parts = target.split("/")
    return parts[2] if len(parts) >= 3 else None


def read_plist(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def run_job(plist):
    argv = plist.get("ProgramArguments") or []
    if not argv:
        return
    env = dict(os.environ)
    env.pop("DOZ_TEST_KEYCHAIN_LOCKED", None)
    env.pop("SSH_CONNECTION", None)
    env.update(plist.get("EnvironmentVariables") or {})
    out = plist.get("StandardOutPath")
    sink = open(out, "a") if out else subprocess.DEVNULL
    subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=sink, stderr=sink, start_new_session=True, close_fds=True)


verb = args[0] if args else ""
code = 0
if verb == "bootstrap" and len(args) == 3:
    p = read_plist(args[2])
    label = p.get("Label")
    if label in state["loaded"]:
        sys.stderr.write("Bootstrap failed: 5: Input/output error\n")
        code = 5
    else:
        state["loaded"][label] = os.path.abspath(args[2])
        save()
        if os.environ.get("FAKE_LAUNCHCTL_RUN_AT_LOAD") == "1" and p.get("RunAtLoad"):
            run_job(p)
elif verb == "bootout" and len(args) == 2:
    label = label_of(args[1])
    if label in state["loaded"]:
        del state["loaded"][label]
        save()
    else:
        sys.stderr.write("Boot-out failed: 113: Could not find service \"%s\" in domain for user gui\n" % label)
        code = 113
elif verb == "kickstart" and len(args) == 2:
    label = label_of(args[1])
    if label in state["loaded"]:
        run_job(read_plist(state["loaded"][label]))
    elif label not in state["apps"]:
        sys.stderr.write("Could not find service \"%s\" in domain for user gui\n" % label)
        code = 113
elif verb == "print" and len(args) == 2:
    label = label_of(args[1])
    program = None
    argv = []
    if label in state["loaded"]:
        try:
            argv = read_plist(state["loaded"][label]).get("ProgramArguments") or []
        except OSError:
            argv = []
        program = argv[0] if argv else None
    elif label in state["apps"]:
        program = state["apps"][label]
        argv = [program, "daemon", "start", "--login-item"]
    if program is None:
        sys.stderr.write("Could not find service \"%s\" in domain for user gui\n" % label)
        code = 113
    else:
        print("%s = {\n\tactive count = 0\n\tpath = %s\n\tstate = not running\n\n\tprogram = %s\n\targuments = {"
              % (args[1], state["loaded"].get(label, "(app)"), program))
        for a in argv:
            print("\t\t%s" % a)
        print("\t}\n}")
elif verb == "print-disabled" and len(args) == 2:
    print("disabled services = {")
    for label in state["disabled"]:
        print("\t\"%s\" => disabled" % label)
    print("}")
else:
    sys.stderr.write("fake launchctl: not a verb this fake knows: %s\n" % " ".join(args))
    code = 64
sys.exit(code)
