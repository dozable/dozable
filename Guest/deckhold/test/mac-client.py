#!/usr/bin/env python3
"""A deckhold client for mac-smoke.sh, over `deckhold-mac pipe -s NAME` (the host's transport): frames in, frames out.

usage: mac-client.py DECKHOLD NAME [--send TEXT] [--wait TEXT | --until-exit] [--seconds N] [--hold N]
  Sends HELLO 0x0 (keep the size), then DATA TEXT when --send, and reads frames until TEXT (--wait) is seen in a
  SNAPSHOT or DATA frame (exit 0), an EXIT frame comes (prints `exit=CODE`, exit 0 when nothing is waited for), or
  --seconds pass (exit 1). --hold N: then keep reading N seconds and print every DATA frame's text (a second viewer).
Frames: [type u8][len u32 big-endian][payload].
"""
import os
import select
import struct
import subprocess
import sys
import time

deckhold, name = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
send = wait = None
seconds, hold = 10.0, 0.0
until_exit = False
while args:
    a = args.pop(0)
    if a == "--until-exit": until_exit = True
    elif a == "--send": send = args.pop(0)
    elif a == "--wait": wait = args.pop(0)
    elif a == "--seconds": seconds = float(args.pop(0))
    elif a == "--hold": hold = float(args.pop(0))


def frame(t, payload=b""):
    return t.encode() + struct.pack(">I", len(payload)) + payload


p = subprocess.Popen([deckhold, "pipe", "-s", name], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
p.stdin.write(frame("H", struct.pack(">HH", 0, 0)))
if send is not None:
    p.stdin.write(frame("D", send.encode()))
p.stdin.flush()
buf, seen, code = b"", b"", None
end = time.time() + seconds
found = wait is None and not until_exit
while time.time() < end:
    r, _, _ = select.select([p.stdout], [], [], 0.2)
    if not r:
        if found and hold == 0: break
        continue
    chunk = os.read(p.stdout.fileno(), 65536)
    if not chunk: break
    buf += chunk
    while len(buf) >= 5:
        n = struct.unpack(">I", buf[1:5])[0]
        if len(buf) < 5 + n: break
        t, payload, buf = chr(buf[0]), buf[5:5 + n], buf[5 + n:]
        if t in "SD":
            seen += payload
            if hold: print("data:", payload.decode(errors="replace").replace("\n", " "))
        if t == "X":
            code = struct.unpack(">I", payload)[0] if len(payload) >= 4 else None
            print("exit=%s" % code)
            if until_exit: found = True
        if t == "N":
            print("nosession")
    if wait and wait.encode() in seen and not found:
        found = True
        print("seen: %s" % wait)
        if hold: end = time.time() + hold
        else: break
    if code is not None: break
p.stdin.close()
p.wait(timeout=5)
sys.exit(0 if found else 1)
