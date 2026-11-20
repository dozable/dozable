#!/usr/bin/env python3
"""A stand-in for the chat server's agent calls, and a plain HTTP proxy — for wire-check.sh, which runs a built dozchat
against them (CI's x86_64 Linux job; any machine with Python 3). Standard library only. Not the chat server: the Mac's
suites run dozchat against the real one. Every answer carries Content-Length and Connection: close.

    stub.py server PORTFILE LOGFILE [PORT]      the agent calls with one token (TOKEN below); 401 otherwise
    stub.py proxy PORTFILE UPSTREAM_PORT LOGFILE   absolute-form requests only, NO Proxy-Authorization expected
    stub.py refuse PORTFILE STATUS LOGFILE         a proxy that refuses the credentials: it reads the request's head
                                                   only, answers STATUS (407 or 401) and closes without reading the body
"""
import http.server
import json
import socket
import sys
import threading
import time
import urllib.parse

TOKEN = "stub-token-0123456789abcdef"


def log(path, line):
    with open(path, "a") as f:
        f.write(line + "\n")


class State:
    lock = threading.Lock()
    pending = []  # items not yet acknowledged
    n = 0
    asks = {}  # msg_id -> {"number", "state", "declined"}


class Server(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    logfile = ""

    def log_message(self, *a):
        pass

    def answer(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def authed(self):
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            self.answer(401, {"error": "unknown token"})
            return False
        return True

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_POST(self):
        if not self.authed():
            return
        b = self.body()
        if self.path == "/agent/send":
            log(self.logfile, "send " + json.dumps(b, sort_keys=True))
            if b.get("kind") == "ask":
                with State.lock:
                    State.asks[b["msg_id"]] = {"number": len(State.asks) + 1, "state": "open", "declined": False}
                self.answer(200, {"state": "queued", "msg_id": b["msg_id"], "detail": ""})
                return
            with State.lock:
                State.n += 1
                State.pending.append({"room": b.get("room", "general"), "msg_id": b["msg_id"], "delivery": b["msg_id"],
                                      "from": "bot1", "message": {"content": b["message"]["content"]}})
            self.answer(200, {"state": "queued", "msg_id": b["msg_id"], "detail": ""})
        elif self.path in ("/agent/decide", "/agent/withdraw"):
            log(self.logfile, self.path[7:] + " " + json.dumps(b, sort_keys=True))
            with State.lock:
                a = self.find(b.get("ask_id", ""))
                if a is None:
                    self.answer(404, {"error": "no such ask"})
                    return
                if a["state"] != "open":
                    self.answer(422, {"state": "refused", "detail": "this ask is closed"})
                    return
                a["state"] = "decided" if self.path == "/agent/decide" else "withdrawn"
                a["declined"] = bool(b.get("decline"))
            self.answer(200, {"state": a["state"], "msg_id": b.get("msg_id", ""), "detail": ""})
        elif self.path == "/agent/ack":
            ids = {a["msg_id"] for a in b.get("acks", [])}
            with State.lock:
                before = len(State.pending)
                State.pending = [i for i in State.pending if i["msg_id"] not in ids]
                acked = before - len(State.pending)
            log(self.logfile, "ack %d" % acked)
            self.answer(200, {"acked": acked})
        else:
            self.answer(404, {"error": "no such call"})

    def find(self, ref):
        if ref.startswith("#"):
            for k, v in State.asks.items():
                if str(v["number"]) == ref[1:]:
                    return v
            return None
        hits = [v for k, v in State.asks.items() if k.startswith(ref)]
        return hits[0] if len(hits) == 1 else None

    def do_GET(self):
        if not self.authed():
            return
        u = urllib.parse.urlsplit(self.path)
        if u.path.startswith("/agent/asks/"):
            ref = urllib.parse.unquote(u.path[len("/agent/asks/"):])
            with State.lock:
                a = self.find(ref)
                if a is None:
                    self.answer(404, {"error": "no such ask"})
                    return
                if a["state"] == "open" and a.get("expire_on_look"):
                    a["state"] = "expired"
                ask = {"state": a["state"], "number": a["number"]}
                if a["state"] in ("decided", "expired"):
                    ask["decision"] = {"declined": a["declined"] or a["state"] == "expired"}
            self.answer(200, {"kind": "ask", "ask": ask})
            return
        if u.path != "/agent/receive":
            self.answer(404, {"error": "no such call"})
            return
        q = urllib.parse.parse_qs(u.query)
        deadline = time.time() + min(50, int(q.get("wait", ["0"])[0]))
        while True:
            with State.lock:
                items = list(State.pending)
            if items or time.time() >= deadline:
                break
            time.sleep(0.1)
        self.answer(200, {"messages": items, "protocol_version": "stub"})


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream = 0
    logfile = ""

    def log_message(self, *a):
        pass

    def relay(self):
        prefix = "http://127.0.0.1:%d/" % self.upstream
        ok = self.path.startswith(prefix)
        auth = self.headers.get("Proxy-Authorization")
        log(self.logfile, "%s absolute=%s proxy-auth=%s" % (self.command, ok, "present" if auth else "none"))
        if not ok or auth:
            self.send_response(400)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        head = "%s /%s HTTP/1.1\r\n" % (self.command, self.path[len(prefix):])
        for k, v in self.headers.items():
            if k.lower() not in ("proxy-authorization", "proxy-connection", "connection"):
                head += "%s: %s\r\n" % (k, v)
        head += "Connection: close\r\n\r\n"
        s = socket.create_connection(("127.0.0.1", self.upstream), timeout=70)
        s.sendall(head.encode() + body)
        while True:
            d = s.recv(65536)
            if not d:
                break
            self.wfile.write(d)
        s.close()
        self.close_connection = True

    do_GET = relay
    do_POST = relay


def refuse(portfile, status, logfile):
    reason = {407: "Proxy Authentication Required", 401: "Unauthorized"}.get(status, "Refused")
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(8)
    with open(portfile + ".tmp", "w") as f:
        f.write(str(s.getsockname()[1]))
    __import__("os").replace(portfile + ".tmp", portfile)
    while True:
        c, _ = s.accept()
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 65536:
            d = c.recv(1)
            if not d:
                break
            head += d
        log(logfile, "connection %s" % head.split(b"\r\n")[0].decode(errors="replace"))
        c.sendall(("HTTP/1.1 %d %s\r\nProxy-Authenticate: Basic realm=\"stub\"\r\nContent-Type: text/html\r\n"
                   "Content-Length: 0\r\nConnection: close\r\n\r\n" % (status, reason)).encode())
        c.close()  # the body is never read: closing with it unread resets the connection


def main():
    mode, portfile = sys.argv[1], sys.argv[2]
    if mode == "refuse":
        refuse(portfile, int(sys.argv[3]), sys.argv[4])
        return
    if mode == "server":
        Server.logfile = sys.argv[3]
        port = int(sys.argv[4]) if len(sys.argv) > 4 else 0
        httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Server)
    else:
        Proxy.upstream, Proxy.logfile = int(sys.argv[3]), sys.argv[4]
        httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    with open(portfile + ".tmp", "w") as f:
        f.write(str(httpd.server_address[1]))
    __import__("os").replace(portfile + ".tmp", portfile)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
