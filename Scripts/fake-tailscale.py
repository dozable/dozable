#!/usr/bin/env python3
"""A fake Tailscale for `make test-cli-alwayson` (the dashboard published on Tailscale) — never the real one.

Installed under a scratch Homebrew-shaped prefix (DOZ_TEST_BREW_PREFIX) as BOTH opt/tailscale/bin/tailscale and
opt/tailscale/bin/tailscaled; it acts as the one its file is named. Every call is one line in $FAKE_TAILSCALE_LOG
("tailscale ARGV…" / "tailscaled ARGV…"); the node's state is a JSON file, $FAKE_TAILSCALE_STATE:

  {"daemon": bool, "socket": path, "backend": "NeedsLogin"|"Running", "hostname": name, "login": "approve"|"never",
   "web": {"443": target, "80": target}}

  tailscaled --statedir=D --socket=S …   marks the daemon running on S and exits (the fake launchctl runs it at load)
  tailscale --socket=S …                 refused (exit 1) unless the daemon runs on exactly S
    status --json                        BackendState, AuthURL, Self.HostName, Self.DNSName (<hostname>.tail-fake.ts.net.)
    up --hostname=N --timeout=Ts         Running: takes the name. Else prints a login link; "approve": signed in at once;
                                         "never": waits T seconds and fails as tailscale does on its timeout
    set --hostname=N                     takes the name
    serve --bg --yes --https=443 T / --http=80 T, serve reset, serve status --json (ipn.ServeConfig's shape); T is
                                         http://127.0.0.1:PORT (or a port). A unix: target or a path handler is refused
                                         with the real message (401 … must be root …) and exit 1, as for a tailscaled
                                         that runs under a LaunchAgent
    logout                               NeedsLogin
The suite edits the state file itself to stand in for a node that serves another port.
"""
import fcntl
import json
import os
import sys
import time

me = os.path.basename(sys.argv[0])
args = sys.argv[1:]
log = os.environ.get("FAKE_TAILSCALE_LOG")
state_path = os.environ.get("FAKE_TAILSCALE_STATE")
if log:
    with open(log, "a") as f:
        f.write(me + " " + " ".join(args) + "\n")
if not state_path:
    sys.stderr.write("fake tailscale: FAKE_TAILSCALE_STATE is not set\n")
    sys.exit(1)

lock = open(state_path + ".lock", "a")
fcntl.flock(lock, fcntl.LOCK_EX)
try:
    with open(state_path) as f:
        state = json.load(f)
except (OSError, ValueError):
    state = {}
state.setdefault("backend", "NeedsLogin")
state.setdefault("hostname", "localhost")
state.setdefault("login", "approve")
state.setdefault("web", {})


def save():
    with open(state_path + ".new", "w") as f:
        json.dump(state, f)
    os.replace(state_path + ".new", state_path)


def opt(name):
    for a in args:
        if a.startswith("--" + name + "="):
            return a.split("=", 1)[1]
    return None


def dns():
    return state["hostname"] + ".tail-fake.ts.net"


LINK = "https://login.tailscale.com/a/fake0123"

if me == "tailscaled":
    state["daemon"] = True
    state["socket"] = opt("socket")
    save()
    sys.exit(0)

sock = opt("socket")
rest = [a for a in args if not a.startswith("--socket=")]
if not state.get("daemon") or state.get("socket") != sock:
    sys.stderr.write("failed to connect to local tailscaled; it doesn't appear to be running\n")
    sys.exit(1)
verb = rest[0] if rest else ""
code = 0
if verb == "status":
    signed = state["backend"] == "Running"
    print(json.dumps({"BackendState": state["backend"], "AuthURL": "" if signed else LINK,
                      "Self": {"HostName": state["hostname"], "DNSName": dns() + "." if signed else ""}}))
elif verb == "up":
    name = opt("hostname")
    if state["backend"] == "Running":
        state["hostname"] = name or state["hostname"]
        save()
    else:
        sys.stderr.write("\nTo authenticate, visit:\n\n\t%s\n\n" % LINK)
        sys.stderr.flush()
        if state["login"] == "approve":
            lock.close()
            time.sleep(0.3)
            lock = open(state_path + ".lock", "a")
            fcntl.flock(lock, fcntl.LOCK_EX)
            state["backend"] = "Running"
            state["hostname"] = name or state["hostname"]
            save()
            print("Success.")
        else:
            lock.close()
            t = (opt("timeout") or "5s").rstrip("s")
            time.sleep(float(t))
            sys.stderr.write("timeout waiting for Tailscale service to enter a Running state; check health with \"tailscale status\"\n")
            code = 1
elif verb == "set":
    state["hostname"] = opt("hostname") or state["hostname"]
    save()
elif verb == "serve" and rest[1:2] == ["status"]:
    web = {}
    tcp = {}
    for port, target in state["web"].items():
        web["%s:%s" % (dns(), port)] = {"Handlers": {"/": {"Proxy": target}}}
        tcp[port] = {"HTTPS": True} if port == "443" else {"HTTP": True}
    print(json.dumps({"TCP": tcp, "Web": web} if web else {}))
elif verb == "serve" and rest[1:2] == ["reset"]:
    state["web"] = {}
    save()
elif verb == "serve":
    target = rest[-1]
    # As the real one (1.104.7) for a tailscaled run by a LaunchAgent: a unix: target or a path handler (a file or folder
    # target, or --set-path) needs root or a sudo-capable operator — refused, the config unchanged.
    if target.startswith("unix:") or target.startswith("/") or opt("set-path") is not None:
        sys.stderr.write("sending serve config: 401 Unauthorized: must be root, or be an operator and able to run "
                         "'sudo tailscale' to serve a path or Unix socket\n")
        sys.exit(1)
    if not (target.startswith("http://") or target.startswith("https://") or target.isdigit()):
        sys.stderr.write("fake tailscale: a serve target this fake does not know: %s\n" % target)
        sys.exit(2)
    if opt("https"):
        state["web"][opt("https")] = target
    elif opt("http"):
        state["web"][opt("http")] = target
    else:
        sys.stderr.write("fake tailscale: serve without --https/--http\n")
        code = 2
    save()
elif verb == "logout":
    state["backend"] = "NeedsLogin"
    save()
else:
    sys.stderr.write("fake tailscale: not a verb this fake knows: %s\n" % " ".join(args))
    code = 64
sys.exit(code)
