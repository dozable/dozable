#!/usr/bin/env python3
"""deckhold-mac's held socket (a fenced session's proxy port), end to end — run by mac-smoke.sh.

  mac-holdfd.py DECKHOLD SESSION OUTFILE

Binds a listening TCP socket on 127.0.0.1:0, starts `DECKHOLD serve --hold-fd 3 -s SESSION -- /usr/bin/sandbox-exec -p
'(version 1)(allow default)' -- python3 -c …` with it as fd 3, closes its own copy, then:
  1. the program (behind sandbox-exec, as a fenced one is) holds no socket at all (it writes what it has to OUTFILE);
  2. the socket still listens with nobody but the holder holding it (a connect is queued, not refused);
  3. GETFD hands the same socket back (SCM_RIGHTS; the same port), and accepting on it gets that queued connection;
  4. a second GETFD works too (each host that adopts the session gets it).
Prints one PASS/FAIL line per check; exits 1 on any FAIL.
"""
import array, os, socket, subprocess, sys, time

d, name, outfile = sys.argv[1], sys.argv[2], sys.argv[3]
fails = 0

def check(ok, what):
    global fails
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        fails += 1

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
s.listen(16)
port = s.getsockname()[1]
fd = s.fileno()
if fd != 3:
    os.dup2(fd, 3)
probe = ("import os, stat, time\n"
         "def sock(n):\n"
         "    try: return stat.S_ISSOCK(os.fstat(n).st_mode)\n"
         "    except OSError: return False\n"
         "socks = [n for n in range(3, 256) if sock(n)]\n"
         "open(OUT, 'w').write('sockets=' + ','.join(map(str, socks)) + '\\n')\n"
         "time.sleep(60)\n").replace("OUT", repr(outfile))
argv = [d, "serve", "--hold-fd", "3", "-s", name, "-x", "80", "-y", "24", "--",
        "/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "--", "/usr/bin/python3", "-c", probe]
rc = subprocess.call(argv, pass_fds=(3,), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if fd != 3:
    os.close(3)
s.close()
check(rc == 0, "serve --hold-fd 3 starts (rc %d)" % rc)
for _ in range(50):
    if os.path.exists(outfile) and open(outfile).read().endswith("\n"):
        break
    time.sleep(0.1)
got = open(outfile).read().strip() if os.path.exists(outfile) else "(nothing written)"
check(got == "sockets=", "the program behind sandbox-exec holds no socket of the holder's (%s)" % got)

c = socket.create_connection(("127.0.0.1", port), timeout=3)
check(True, "the port still listens with only the holder holding it (127.0.0.1:%d)" % port)

def getfd():
    u = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    u.connect(os.path.join(os.environ["DECKHOLD_DIR"], name + ".sock"))
    u.sendall(b"F\x00\x00\x00\x00")
    fds = array.array("i")
    msg, anc, _, _ = u.recvmsg(5, socket.CMSG_LEN(fds.itemsize))
    u.close()
    for level, typ, data in anc:
        if level == socket.SOL_SOCKET and typ == socket.SCM_RIGHTS:
            fds.frombytes(data[:fds.itemsize])
    return msg, (fds[0] if fds else None)

msg, got_fd = getfd()
check(msg == b"F\x00\x00\x00\x00" and got_fd is not None, "GETFD answers one F frame with a descriptor")
if got_fd is not None:
    g = socket.socket(fileno=got_fd)
    check(g.getsockname()[1] == port, "…the same socket (port %d)" % g.getsockname()[1])
    g.settimeout(3)
    a, _ = g.accept()
    a.sendall(b"hi")
    check(c.recv(2) == b"hi", "accepting on it gets the connection that waited in the backlog")
    a.close()
    g.close()
c.close()
msg, again = getfd()
check(again is not None, "a second GETFD gets it again")
if again is not None:
    os.close(again)
sys.exit(1 if fails else 0)
