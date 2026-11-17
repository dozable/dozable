#!/usr/bin/env python3
"""chat_client.py: a bare-bones member of a chat room, in one file, Python 3 standard library only.

It speaks the chat protocol (../protocol.md, sections 4.1, 4.8 and 7.5) as a participant that polls:
one with its own token and no webhook. Read it whole before you trust it; it is short on purpose.

    python3 chat_client.py send ROOM TEXT [--re MSG_ID] [--to NAME ...] [--dm]
    python3 chat_client.py receive [--wait SECONDS] [--ack] [--redeliver]
    python3 chat_client.py ack ROOM:MSG_ID[:DELIVERY] ...      (or: ack -   reads receive's lines on stdin)
    python3 chat_client.py listen [--wait SECONDS]
    python3 chat_client.py file get URL-OR-ID [--out FOLDER] [--name NAME]
    python3 chat_client.py file send ROOM PATH [TEXT] [--re MSG_ID]
    python3 chat_client.py rooms [--room ROOM]                 (both are sent in a room you are in: name one
    python3 chat_client.py protocol [--room ROOM]               with --room unless you are in the default room)

Configuration (nothing secret on the command line, ever):
    CHAT_URL         the chat server's page address; default http://127.0.0.1:8790
    CHAT_TOKEN_FILE  a file holding your token: a regular file of yours that no one else may read or write
                     (chmod 600), not a link; refused otherwise
    CHAT_TOKEN       the token itself, used only when CHAT_TOKEN_FILE is not set
The token is sent only as "Authorization: Bearer ..." to CHAT_URL's own scheme, host and port. It is never printed and
never put in an error. Redirects are never followed. Every call has a timeout. https is checked with the system's
default certificate rules.

Output: stdout carries data, one JSON object per line (protocol prints its Markdown text). Words for a person go to
stderr.

Exit codes:
    0  done
    1  a local problem: a file that cannot be read or written, a bad answer from the server
    2  usage or configuration: a bad argument, no token, a token file others can read
    3  the server refused the message (422: state "refused"; the reason is printed)
    4  the server refused the call: 401 (token), 403 (not a participant that polls), 409 (delivered by webhook).
       Do not retry without changing something
    5  the server could not be reached, timed out, or answered 5xx

As a module:
    import chat_client
    c = chat_client.Client.from_env()
    c.send("room1", "hello")
    c.listen(lambda item: print(item["message"]["content"]))   # acknowledged after the handler returns

Inside a Dozable sandbox or a fenced session on the Mac, the chat server is reached through the Mac's route and the
token stays on the Mac: Dozable gives the session a placeholder and swaps the real token in on requests to that one
port. On the Mac (the token file is yours alone, outside the session's folder):

    doz chat add bot1 --to-file ~/.config/chat/bot1.token
    doz run @mac --host-port 8790 \\
        --secret CHAT_TOKEN,src=~/.config/chat/bot1.token,to=host.dozable.internal:8790,file=CHAT_TOKEN_FILE -- bash
    (a sandbox: doz run NAME --host-port 8790 --secret ...the same... -- bash)

and inside, with this file in the session's folder:

    CHAT_URL=http://host.dozable.internal:8790 python3 chat_client.py listen

CHAT_TOKEN_FILE (set by --secret's file=) then holds the placeholder; the proxy the session already uses (its
http_proxy) carries the request. Use the page port `doz chat status` shows if it is not 8790.
"""

import argparse
import base64
import http.client
import json
import os
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

DEFAULT_URL = "http://127.0.0.1:8790"
MAX_FILE = 20 * 1024 * 1024          # protocol 4.8: 20 MiB per attachment
MAX_BODY = 64 * 1024 * 1024          # never read more than this of an answer
CALL_TIMEOUT = 30                    # seconds, for every call that does not wait
EXIT_OK, EXIT_LOCAL, EXIT_USAGE, EXIT_REFUSED, EXIT_DENIED, EXIT_AWAY = 0, 1, 2, 3, 4, 5


class ChatError(Exception):
    """A failure with an exit code. Its text never holds the token."""

    def __init__(self, code, text, answer=None):
        Exception.__init__(self, text)
        self.code, self.answer = code, answer


def say(text):
    print(text, file=sys.stderr, flush=True)


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, sort_keys=True) + "\n")
    sys.stdout.flush()


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # a 3xx is then raised as an HTTPError, and never followed


def raise_for(status, raw, answer=None):
    """Turn an answer that is not a success into a ChatError with the server's own reason."""
    why = (answer.get("error") or answer.get("detail")) if isinstance(answer, dict) else None
    why = why or raw[:200].decode("utf-8", "replace").strip() or "no text"
    if status == 422:
        raise ChatError(EXIT_REFUSED, "refused: %s" % why, answer)
    if status in (401, 403, 409):
        raise ChatError(EXIT_DENIED, "HTTP %d: %s" % (status, why), answer)
    if status >= 500:
        raise ChatError(EXIT_AWAY, "HTTP %d from the chat server: %s" % (status, why), answer)
    raise ChatError(EXIT_LOCAL, "unexpected answer HTTP %d: %s" % (status, why), answer)


def read_token(environ=None):
    env = os.environ if environ is None else environ
    path = env.get("CHAT_TOKEN_FILE")
    if path:
        try:
            st = os.lstat(path)
        except OSError as e:
            raise ChatError(EXIT_USAGE, "CHAT_TOKEN_FILE cannot be read: %s" % e.strerror)
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
            raise ChatError(EXIT_USAGE, "CHAT_TOKEN_FILE must be a regular file, not a link")
        if st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise ChatError(EXIT_USAGE, "CHAT_TOKEN_FILE must be yours alone: chmod 600 it")
        with open(path, "rb") as f:
            raw = f.read(4096)
        token = raw.decode("utf-8", "replace").strip()
    else:
        token = env.get("CHAT_TOKEN", "").strip()
    if not token:
        raise ChatError(EXIT_USAGE, "no token: set CHAT_TOKEN_FILE (a file only you can read) or CHAT_TOKEN")
    if len(token) < 16 or any(c.isspace() or not c.isprintable() or ord(c) > 126 for c in token):
        raise ChatError(EXIT_USAGE, "the token is not usable: at least 16 printable characters, no spaces")
    return token


class Client:
    def __init__(self, url, token, opener=None):
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise ChatError(EXIT_USAGE, "CHAT_URL must be http:// or https:// and a host")
        self.base = "%s://%s" % (parts.scheme, parts.netloc)
        self._token = token
        # The proxy from the environment is kept (a Dozable session reaches the Mac through it); redirects are not.
        self._open = (opener or urllib.request.build_opener(urllib.request.ProxyHandler(), _NoRedirect())).open

    @classmethod
    def from_env(cls, environ=None):
        env = os.environ if environ is None else environ
        return cls(env.get("CHAT_URL", DEFAULT_URL).rstrip("/"), read_token(env))

    def __repr__(self):
        return "Client(%s)" % self.base  # never the token

    # One HTTP call. Returns (status, headers, body bytes). Raises ChatError for what is not an answer.
    def _call(self, method, path, body=None, timeout=CALL_TIMEOUT):
        headers = {"Authorization": "Bearer " + self._token, "Accept": "application/json"}
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with self._open(req, timeout=timeout) as resp:
                return resp.status, resp.headers, resp.read(MAX_BODY + 1)
        except urllib.error.HTTPError as e:
            try:
                raw = e.read(MAX_BODY + 1)
            finally:
                e.close()
            return e.code, e.headers, raw
        except (urllib.error.URLError, OSError, http.client.HTTPException) as e:
            # Protocol 7.5: a server may restart at any time; a refused connection or a broken answer means "try
            # again". The reason names no token: urllib's errors carry the address, never the headers.
            reason = getattr(e, "reason", None) or type(e).__name__
            raise ChatError(EXIT_AWAY, "the chat server at %s did not answer: %s" % (self.base, reason))

    def _json(self, method, path, body=None, timeout=CALL_TIMEOUT, ok=(200,)):
        status, _, raw = self._call(method, path, body, timeout)
        try:
            answer = json.loads(raw.decode("utf-8")) if raw else None
        except ValueError:
            answer = None
        if status in ok and answer is not None:
            return status, answer
        if status in ok:
            raise ChatError(EXIT_AWAY, "a broken answer from the chat server (HTTP %d, not JSON)" % status)
        raise_for(status, raw, answer)

    # --- the calls ---------------------------------------------------------------------------------------------

    def send(self, room, text, re=None, to=None, private=False, attachments=None, msg_id=None):
        """POST /agent/send. Returns the server's answer, such as {"state":"queued","msg_id":...,"detail":""}."""
        body = {"msg_id": msg_id or str(uuid.uuid4()), "message": {"content": text}}
        if room:
            body["room"] = room
        if re:
            body["re_msg_id"] = re
        if to:
            body["to"] = [n.lstrip("@").lower() for n in to]
        if private:
            body["private"] = True
        if attachments:
            body["attachments"] = attachments
        # A retry with the same msg_id is answered "duplicate" and sends nothing twice (protocol 4.1).
        for attempt in range(3):
            try:
                return self._json("POST", "/agent/send", body, ok=(200,))[1]
            except ChatError as e:
                if e.code != EXIT_AWAY or attempt == 2:
                    raise
                time.sleep(1 + attempt)

    def receive(self, wait=0, ack=True, redeliver=False):
        """GET /agent/receive. Returns the list of items. With ack, they wait for ack() (or 60 s, then come again)."""
        wait = max(0, min(50, int(wait)))
        q = {"wait": str(wait)}
        if ack:
            q["ack"] = "1"
        if redeliver:
            q["redeliver"] = "1"
        path = "/agent/receive?" + urllib.parse.urlencode(q)
        answer = self._json("GET", path, timeout=wait + 15)[1]
        items = answer.get("messages") if isinstance(answer, dict) else None
        if not isinstance(items, list):
            raise ChatError(EXIT_LOCAL, "unexpected answer: no messages list")
        return items

    def ack(self, items):
        """POST /agent/ack for receive's items (each needs room, msg_id and delivery). Returns how many were acked."""
        acks = [{"room": i.get("room", ""), "msg_id": i.get("msg_id", ""), "delivery": i.get("delivery", "")}
                for i in items]
        if not acks:
            return 0
        return int(self._json("POST", "/agent/ack", {"acks": acks})[1].get("acked", 0))

    def listen(self, handler, wait=25, stop=None):
        """Receive forever; call handler(item) for each item, then acknowledge it. Survives a server restart."""
        backoff, first = 1, True
        while not (stop and stop()):
            try:
                items = self.receive(wait=wait, ack=True, redeliver=first)
                first, backoff = False, 1
            except ChatError as e:
                if e.code != EXIT_AWAY:
                    raise
                say("%s; trying again in %d s" % (e, backoff))
                time.sleep(backoff)
                backoff = min(backoff * 2, 30)
                continue
            for item in items:
                handler(item)
                try:
                    self.ack([item])
                except ChatError as e:
                    if e.code != EXIT_AWAY:
                        raise
                    say("could not acknowledge %s (%s); it will come again" % (item.get("msg_id"), e))

    def command(self, text, room=None):
        """A slash command such as /rooms or /protocol, answered to this participant alone (state "info")."""
        return self.send(room, text)

    def file_get(self, ref, folder=".", name=None):
        """GET /files/{id}/{name} with this token. ref is an attachment's url (/files/ID/NAME) or its id.
        Writes into folder only, never outside it, and never over an existing file. Returns what it wrote."""
        parts = urllib.parse.urlsplit(ref)
        if parts.scheme or parts.netloc:
            if "%s://%s" % (parts.scheme, parts.netloc) != self.base:
                raise ChatError(EXIT_USAGE, "that address is not this chat server's; the token goes nowhere else")
            ref = parts.path
        segs = [s for s in ref.split("/") if s]
        if len(segs) >= 2 and segs[0] == "files":
            file_id, url_name = segs[1], urllib.parse.unquote(segs[2]) if len(segs) > 2 else ""
        elif len(segs) == 1:
            file_id, url_name = segs[0], ""
        else:
            raise ChatError(EXIT_USAGE, "give an attachment's url (/files/ID/NAME) or its id")
        if not file_id or any(c not in "0123456789abcdef" for c in file_id):
            raise ChatError(EXIT_USAGE, "an attachment id is hex digits")
        safe = clean_name(name or url_name or file_id)
        folder_real = os.path.realpath(folder)
        if not os.path.isdir(folder_real):
            raise ChatError(EXIT_USAGE, "no such folder: %s" % folder)
        dest = os.path.join(folder_real, safe)
        if os.path.dirname(dest) != folder_real:
            raise ChatError(EXIT_USAGE, "refused: that name would write outside the folder")
        if os.path.lexists(dest):
            raise ChatError(EXIT_LOCAL, "refused: %s exists" % dest)
        path = "/files/%s/%s" % (file_id, urllib.parse.quote(safe))
        status, headers, raw = self._call("GET", path)
        if status == 404:
            raise ChatError(EXIT_REFUSED, "no such attachment, or not one you may read")
        if status != 200:
            raise_for(status, raw)
        if len(raw) > MAX_FILE:
            raise ChatError(EXIT_LOCAL, "the file is larger than 20 MB; not written")
        fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(raw)
        return {"id": file_id, "path": dest, "size": len(raw), "type": headers.get("Content-Type", "")}

    def file_send(self, room, path, text="", re=None):
        """POST /agent/send with the file's bytes inline (base64). At most 20 MB, not empty."""
        try:
            st = os.stat(path)
            if not stat.S_ISREG(st.st_mode):
                raise ChatError(EXIT_USAGE, "not a regular file: %s" % path)
            if st.st_size == 0 or st.st_size > MAX_FILE:
                raise ChatError(EXIT_USAGE, "a file is sent when it is 1 byte to 20 MB")
            with open(path, "rb") as f:
                data = f.read(MAX_FILE + 1)
        except OSError as e:
            raise ChatError(EXIT_LOCAL, "cannot read %s: %s" % (path, e.strerror))
        att = {"name": clean_name(os.path.basename(path)), "data_base64": base64.b64encode(data).decode("ascii")}
        return self.send(room, text, re=re, attachments=[att])


def clean_name(name):
    """The protocol's rule for a stored name (4.8): the last path part, A-Za-z0-9._ ()+- kept, others "_"."""
    name = name.replace("\\", "/").split("/")[-1]
    keep = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._ ()+-"
    name = "".join(c if c in keep else "_" for c in name).lstrip(". ")[-120:]
    return name or "file"


def parse_ack_ref(ref):
    room, sep, rest = ref.partition(":")
    msg_id, _, delivery = rest.partition(":")
    if not sep or not room or not msg_id:
        raise ChatError(EXIT_USAGE, "ack takes ROOM:MSG_ID[:DELIVERY] (DELIVERY is the item's delivery), or -")
    return {"room": room, "msg_id": msg_id, "delivery": delivery or msg_id}


def main(argv=None):
    p = argparse.ArgumentParser(prog="chat_client.py", description="A bare-bones chat room member (see the top of "
                                "this file). CHAT_URL, CHAT_TOKEN_FILE or CHAT_TOKEN configure it.")
    sub = p.add_subparsers(dest="cmd")
    s = sub.add_parser("send", help="post TEXT to ROOM")
    s.add_argument("room"), s.add_argument("text")
    s.add_argument("--re", help="the msg_id (or its start) this answers")
    s.add_argument("--to", action="append", default=[], help="a member it is addressed to (repeat)")
    s.add_argument("--dm", action="store_true", help="a direct message to the --to names only")
    r = sub.add_parser("receive", help="print what waits, one JSON line per item")
    r.add_argument("--wait", type=int, default=0, help="seconds to wait when nothing waits (0 to 50)")
    r.add_argument("--ack", action="store_true", help="acknowledge the items once printed")
    r.add_argument("--redeliver", action="store_true", help="also what was handed over and not yet acknowledged")
    a = sub.add_parser("ack", help="acknowledge items: ROOM:MSG_ID[:DELIVERY] ..., or - to read receive's lines")
    a.add_argument("refs", nargs="+")
    li = sub.add_parser("listen", help="print every item as it comes, acknowledging each; never ends by itself")
    li.add_argument("--wait", type=int, default=25)
    f = sub.add_parser("file", help="fetch or send an attachment")
    fs = f.add_subparsers(dest="fcmd")
    fg = fs.add_parser("get", help="fetch an attachment into a folder")
    fg.add_argument("ref"), fg.add_argument("--out", default=".", help="the folder (default: here)")
    fg.add_argument("--name", help="the file name to write (cleaned)")
    fp = fs.add_parser("send", help="send a file to ROOM, with optional TEXT")
    fp.add_argument("room"), fp.add_argument("path"), fp.add_argument("text", nargs="?", default="")
    fp.add_argument("--re")
    for name, what in (("rooms", "the rooms you are in"), ("protocol", "the protocol, as Markdown")):
        c = sub.add_parser(name, help=what)
        c.add_argument("--room", help="a room you are in (default: the server's default room)")
    args = p.parse_args(argv)
    if not args.cmd or (args.cmd == "file" and not args.fcmd):
        p.print_help(sys.stderr)
        return EXIT_USAGE
    try:
        client = Client.from_env()
        if args.cmd == "send":
            if args.dm and not args.to:
                raise ChatError(EXIT_USAGE, "--dm needs --to NAME")
            emit(client.send(args.room, args.text, re=args.re, to=args.to, private=args.dm))
        elif args.cmd == "receive":
            items = client.receive(wait=args.wait, ack=True, redeliver=args.redeliver)
            for item in items:
                emit(item)
            if args.ack and items:
                say("acknowledged %d" % client.ack(items))
        elif args.cmd == "ack":
            if args.refs == ["-"]:
                items = [json.loads(line) for line in sys.stdin if line.strip()]
            else:
                items = [parse_ack_ref(ref) for ref in args.refs]
            emit({"acked": client.ack(items)})
        elif args.cmd == "listen":
            say("listening at %s (Ctrl-C stops)" % client.base)
            client.listen(emit, wait=args.wait)
        elif args.cmd == "file" and args.fcmd == "get":
            emit(client.file_get(args.ref, args.out, args.name))
        elif args.cmd == "file" and args.fcmd == "send":
            emit(client.file_send(args.room, args.path, args.text, re=args.re))
        elif args.cmd == "rooms":
            emit(client.command("/rooms", args.room))
        elif args.cmd == "protocol":
            answer = client.command("/protocol", args.room)
            sys.stdout.write(answer.get("detail", "") + "\n")
        return EXIT_OK
    except ChatError as e:
        say("chat_client: %s" % e)
        if e.code == EXIT_REFUSED and args.cmd in ("rooms", "protocol") and "not a member" in str(e):
            say("chat_client: give --room ROOM, a room you are in")
        if e.answer is not None and e.code == EXIT_REFUSED:
            emit(e.answer)
        return e.code
    except KeyboardInterrupt:
        return 130
    except ValueError as e:
        say("chat_client: not a JSON line: %s" % e)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
