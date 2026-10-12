# A fake xAI + Gemini API over TLS (its own throwaway CA) for the network profiler and VM proofs (617). Python 3.9+ stdlib only.
# Usage: python3 fake_provider.py LEAF.pem LEAF.key REQUESTS.log PORTFILE
# Env: FAKE_XAI_KEY, FAKE_GOOGLE_KEY — the (fake) real keys the proxy must swap in; anything else is answered 401/400.
# Every request is one JSON line in REQUESTS.log: method, path, the auth header's name and value, and whether the
# body carried the facts marker. Never a real key.
import http.server, json, os, ssl, sys

leaf, key, logf, portf = sys.argv[1:5]
XAI, GOOGLE = os.environ.get("FAKE_XAI_KEY", ""), os.environ.get("FAKE_GOOGLE_KEY", "")

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def record(self, body=b""):
        auth = {k.lower(): self.headers[k] for k in self.headers.keys() if k.lower() in ("authorization", "x-goog-api-key", "x-api-key")}
        with open(logf, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "host": self.headers.get("host"), "auth": auth,
                                "facts_in_body": b"Dozer" in body or b"dozer" in body}) + "\n")
        return auth

    def send(self, code, obj, ctype="application/json"):
        b = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def xai_ok(self, auth):
        return auth.get("authorization") == "Bearer " + XAI

    def google_ok(self, auth):
        return auth.get("x-goog-api-key") == GOOGLE

    def do_GET(self):
        auth = self.record()
        p = self.path.split("?")[0]
        if p == "/v1/models":
            if not self.xai_ok(auth): return self.send(400, {"code": "invalid-argument", "error": "Incorrect API key provided"})
            return self.send(200, {"object": "list", "data": [{"id": "grok-4.6", "object": "model", "owned_by": "xai"}]})
        if p == "/v1/api-key":
            if not self.xai_ok(auth): return self.send(400, {"code": "invalid-argument", "error": "Incorrect API key provided"})
            return self.send(200, {"name": "fake", "api_key_id": "fake-id", "redacted_api_key": "xai-…", "team_id": "t",
                                   "acls": ["api-key:model:*", "api-key:endpoint:*"], "api_key_blocked": False, "api_key_disabled": False, "team_blocked": False})
        if p == "/v1beta/models":
            if not self.google_ok(auth): return self.send(400, {"error": {"code": 400, "message": "API key not valid.", "status": "INVALID_ARGUMENT"}})
            return self.send(200, {"models": [{"name": "models/gemini-fake"}]})
        self.send(404, {"error": "not here"})

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n) if n else b""
        auth = self.record(body)
        p = self.path.split("?")[0]
        if p.endswith("/chat/completions"):
            if not self.xai_ok(auth): return self.send(401, {"error": "the proxy did not swap the key"})
            req = json.loads(body or b"{}")
            if req.get("stream"):
                c = {"id": "x", "object": "chat.completion.chunk", "created": 0, "model": "grok-4.6",
                     "choices": [{"index": 0, "delta": {"role": "assistant", "content": "DOZ_FAKE_OK"}, "finish_reason": None}]}
                out = "data: " + json.dumps(c) + "\n\n"
                c["choices"][0]["delta"] = {}
                c["choices"][0]["finish_reason"] = "stop"
                c["usage"] = {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
                out += "data: " + json.dumps(c) + "\n\ndata: [DONE]\n\n"
                return self.send(200, out.encode(), "text/event-stream")
            return self.send(200, {"id": "x", "object": "chat.completion", "created": 0, "model": "grok-4.6",
                                   "choices": [{"index": 0, "message": {"role": "assistant", "content": "DOZ_FAKE_OK"}, "finish_reason": "stop"}],
                                   "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})
        if p == "/v1/responses":
            # OpenAI's Responses API (what Grok Build 1.0.50 uses against the real api.x.ai).
            if not self.xai_ok(auth): return self.send(401, {"error": "the proxy did not swap the key"})
            req = json.loads(body or b"{}")
            item = {"id": "msg_1", "type": "message", "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": "DOZ_FAKE_OK", "annotations": []}]}
            done = {"id": "resp_1", "object": "response", "created_at": 0, "status": "completed", "model": req.get("model", "grok-4.6"),
                    "output": [item], "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2,
                                                "input_tokens_details": {"cached_tokens": 0}, "output_tokens_details": {"reasoning_tokens": 0}}}
            if not req.get("stream"):
                return self.send(200, done)
            started = dict(done, status="in_progress", output=[], usage=None)
            open_item = dict(item, status="in_progress", content=[])
            part = {"type": "output_text", "text": "", "annotations": []}
            evs = [("response.created", {"response": started}),
                   ("response.in_progress", {"response": started}),
                   ("response.output_item.added", {"output_index": 0, "item": open_item}),
                   ("response.content_part.added", {"item_id": "msg_1", "output_index": 0, "content_index": 0, "part": part}),
                   ("response.output_text.delta", {"item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": "DOZ_FAKE_OK"}),
                   ("response.output_text.done", {"item_id": "msg_1", "output_index": 0, "content_index": 0, "text": "DOZ_FAKE_OK"}),
                   ("response.content_part.done", {"item_id": "msg_1", "output_index": 0, "content_index": 0, "part": item["content"][0]}),
                   ("response.output_item.done", {"output_index": 0, "item": item}),
                   ("response.completed", {"response": done})]
            out = ""
            for i, (t, d) in enumerate(evs):
                out += "event: " + t + "\ndata: " + json.dumps(dict(d, type=t, sequence_number=i)) + "\n\n"
            return self.send(200, out.encode(), "text/event-stream")
        if ":streamGenerateContent" in p or ":generateContent" in p:
            if not self.google_ok(auth): return self.send(400, {"error": {"code": 400, "message": "API key not valid.", "status": "INVALID_ARGUMENT"}})
            if ":streamGenerateContent" in p:
                ev = {"candidates": [{"content": {"role": "model", "parts": [{"text": "DOZ_FAKE_OK"}]}, "finishReason": "STOP", "index": 0}],
                      "usageMetadata": {"promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2}}
                return self.send(200, ("data: " + json.dumps(ev) + "\r\n\r\n").encode(), "text/event-stream")
            ev = {"candidates": [{"content": {"role": "model", "parts": [{"text": "{\"complexity_reasoning\":\"x\",\"complexity_score\":1}"}]},
                                  "finishReason": "STOP", "index": 0}]}
            return self.send(200, ev)
        self.send(404, {"error": "not here"})

    def log_message(self, *a):
        pass

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(leaf, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
with open(portf, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
