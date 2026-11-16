#!/usr/bin/env python3
"""check-agent-plist.py PLIST — the menu bar app's login agent (Contents/Library/LaunchAgents/com.dozable.app.daemon.plist)
carries EXACTLY the keys of the design, with their values, and its Label is doz's reserved label
(`DaemonLoginItem.appLabel` in Sources/DozableHost/DaemonLoginItem.swift — read from the source, so the two never drift).

Run by Scripts/assemble-app.sh (every `make app` and release) and by Scripts/release.sh on the SIGNED bundle. Exit 0 and
one line when it is right; exit 1 naming what is wrong otherwise. The same rule as AgentPlistTests (Swift).
"""
import os
import plistlib
import re
import sys

EXPECTED = {
    "Label": "com.dozable.app.daemon",
    "BundleProgram": "Contents/MacOS/Dozable",
    "ProgramArguments": ["Dozable", "--launch-daemon"],
    "RunAtLoad": True,
    "StartInterval": 900,
    "LimitLoadToSessionType": "Aqua",
    "AbandonProcessGroup": True,
    "ProcessType": "Standard",
}

if len(sys.argv) != 2:
    sys.stderr.write("usage: check-agent-plist.py PLIST\n")
    sys.exit(64)
path = sys.argv[1]
try:
    with open(path, "rb") as f:
        p = plistlib.load(f)
except Exception as e:  # noqa: BLE001 — any read or parse failure is the answer
    print("x the agent plist %s does not parse: %s" % (path, e))
    sys.exit(1)

bad = []
extra = sorted(set(p) - set(EXPECTED))
missing = sorted(set(EXPECTED) - set(p))
if extra:
    bad.append("keys it must not have: " + ", ".join(extra))
if missing:
    bad.append("keys missing: " + ", ".join(missing))
for k, v in EXPECTED.items():
    if k in p and (p[k] != v or type(p[k]) is not type(v)):
        bad.append("%s is %r, not %r" % (k, p[k], v))

src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "DozableHost", "DaemonLoginItem.swift")
try:
    m = re.search(r'static let appLabel = "([^"]+)"', open(src).read())
except OSError:
    m = None
if not m:
    bad.append("could not read doz's reserved label (DaemonLoginItem.appLabel) from %s" % src)
elif p.get("Label") != m.group(1):
    bad.append("Label %r is not doz's reserved label %r" % (p.get("Label"), m.group(1)))

if bad:
    print("x the agent plist %s: %s" % (path, "; ".join(bad)))
    sys.exit(1)
print("agent plist: exactly the design's %d keys, label %s (doz's)" % (len(EXPECTED), p["Label"]))
