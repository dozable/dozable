import Foundation
import NIOCore
import NIOPosix
import NIOSSL

// 653 — the stand-in model provider of `doz recipe check --full`: what `Scripts/fake-provider.py` is to `make recipe-check`,
// in Swift, because an installed doz cannot assume Python. A TLS server on 127.0.0.1 with a THROWAWAY CA (SandboxCA; one
// leaf naming every host it answers for), which a scratch host's proxy is pointed at through the existing test seams
// (DOZ_TEST_PROVIDER_UPSTREAM/_CA, DOZ_TEST_OPENAI_UPSTREAM/_CA) — trusting only that CA.
//
// It answers xAI, Google (the Gemini API and its OpenAI-compatible endpoint), Anthropic's Messages API, OpenAI's Responses
// and Chat Completions APIs, and the two gateways (OpenRouter, Vercel AI Gateway: both shapes under their base URLs) with
// DOZ_FAKE_OK — only for the FAKE key the proxy must swap in; anything else gets that provider's refusal. Every request is
// recorded (method, host, path, the auth headers). What it leaves to fake-provider.py: tool-call answers (an agent that
// ends its turn only through a tool), Google Stitch, OpenCode Zen's key-less models.

public final class StandInProvider: @unchecked Sendable {
    public static let answer = "DOZ_FAKE_OK"
    /// The hosts its one leaf names (each provider's API host and the gateways').
    public static let hosts = ["api.x.ai", "generativelanguage.googleapis.com", "api.anthropic.com", "api.openai.com",
                               "openrouter.ai", "ai-gateway.vercel.sh"]
    /// The FAKE keys, by key provider — never a real one (the shapes are a real key's, so a client takes them).
    public static let fakeKeys: [String: String] = [
        "xai": "xai-FAKE-RECIPECHECK-0123456789abcdef",
        "google": "AIzaFAKERECIPECHECK-0123456789abcdef",
        "anthropic": "sk-ant-api03-FAKERECIPECHECK-0123456789abcdefghijklmnopqrstuvwxyz",
        "openai": "sk-proj-FAKERECIPECHECK-0123456789abcdefghijklmnopqrstuvwxyz",
        "openrouter": "sk-or-v1-FAKERECIPECHECK-0123456789abcdef0123456789abcdef",
        "vercel-ai-gateway": "vck_FAKERECIPECHECK0123456789abcdefghijklmnop",
    ]

    /// One request as it arrived.
    public struct Request: Codable, Equatable, Sendable {
        public var method: String
        public var host: String
        public var path: String
        /// `authorization`, `x-api-key`, `x-goog-api-key` — their values (fake keys or placeholders; never a real key).
        public var auth: [String: String]
    }

    public let port: Int
    /// The throwaway CA a client must trust (PEM).
    public let caPEM: String
    private let channel: Channel
    private let lock = NSLock()
    private var seen: [Request] = []

    /// Start it on 127.0.0.1 (any free port).
    public init() throws {
        let ca = try SandboxCA.generate(sandbox: "recipe-check stand-in")
        let leaf = try ca.leaf(forHosts: Self.hosts)
        let chain = [try NIOSSLCertificate(bytes: Array(leaf.certificatePEM.utf8), format: .pem),
                     try NIOSSLCertificate(bytes: Array(ca.certificatePEM.utf8), format: .pem)]
        var cfg = TLSConfiguration.makeServerConfiguration(certificateChain: chain.map { .certificate($0) },
                                                           privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(leaf.keyPEM.utf8), format: .pem)))
        cfg.applicationProtocols = ["http/1.1"]
        let ctx = try NIOSSLContext(configuration: cfg)
        caPEM = ca.certificatePEM
        let box = RecorderBox()
        channel = try ServerBootstrap(group: SharedEventLoop.group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: ctx))
                    try ch.pipeline.syncOperations.addHandler(Handler(record: { box.owner?.record($0) }))
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        port = channel.localAddress?.port ?? 0
        box.owner = self
    }

    final class RecorderBox: @unchecked Sendable { weak var owner: StandInProvider? }

    func record(_ r: Request) {
        lock.lock(); seen.append(r); lock.unlock()
    }

    /// Every request so far.
    public var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    public func stop() {
        try? channel.close().wait()
    }

    deinit { channel.close(promise: nil) }

    // MARK: - the HTTP side

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let record: (Request) -> Void
        var buffer: [UInt8] = []
        init(record: @escaping (Request) -> Void) { self.record = record }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var b = unwrapInboundIn(data)
            buffer += b.readBytes(length: b.readableBytes) ?? []
            while let (head, body, used) = StandInProvider.nextRequest(buffer) {
                buffer.removeFirst(used)
                let (status, type, out, req) = StandInProvider.answer(head: head, body: body)
                record(req)
                var r = "HTTP/1.1 \(status) \(status < 300 ? "OK" : "Refused")\r\ncontent-type: \(type)\r\ncontent-length: \(out.count)\r\n"
                let close = head.value("connection")?.lowercased() == "close"
                r += close ? "connection: close\r\n\r\n" : "\r\n"
                var w = context.channel.allocator.buffer(capacity: r.utf8.count + out.count)
                w.writeString(r)
                w.writeBytes(out)
                context.writeAndFlush(wrapOutboundOut(w), promise: nil)
                if close { context.close(promise: nil); return }
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }

    /// The first whole request in `b` (Content-Length or chunked), and how many bytes it used.
    static func nextRequest(_ b: [UInt8]) -> (HTTPHead, [UInt8], Int)? {
        guard let end = find(b, [13, 10, 13, 10], from: 0), let head = HTTPHead(Array(b[0..<end + 4])) else { return nil }
        var i = end + 4
        if head.value("transfer-encoding")?.lowercased().contains("chunked") == true {
            var body: [UInt8] = []
            while true {
                guard let e = find(b, [13, 10], from: i) else { return nil }
                let line = String(decoding: b[i..<e], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
                guard let n = Int(line.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
                i = e + 2
                if n == 0 {
                    // trailers, then the blank line
                    while true {
                        guard let t = find(b, [13, 10], from: i) else { return nil }
                        let empty = t == i
                        i = t + 2
                        if empty { return (head, body, i) }
                    }
                }
                guard b.count >= i + n + 2 else { return nil }
                body += b[i..<i + n]
                i += n + 2
            }
        }
        let n = Int(head.value("content-length") ?? "0") ?? 0
        guard b.count >= i + n else { return nil }
        return (head, Array(b[i..<i + n]), i + n)
    }

    static func find(_ b: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        guard b.count >= needle.count, from <= b.count - needle.count else { return nil }
        for i in from...(b.count - needle.count) where b[i] == needle[0] && Array(b[i..<i + needle.count]) == needle { return i }
        return nil
    }

    // MARK: - the answers

    static func json(_ o: Any) -> [UInt8] { Array((try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)) }
    static func sse(_ events: [(String?, Any)]) -> [UInt8] {
        var s = ""
        for (t, d) in events {
            if let t { s += "event: \(t)\n" }
            s += "data: " + String(decoding: json(d), as: UTF8.self) + "\n\n"
        }
        return Array(s.utf8)
    }

    /// The answer to one request: status, content type, body, and the request as recorded.
    static func answer(head: HTTPHead, body: [UInt8]) -> (Int, String, [UInt8], Request) {
        let host = (head.value("host") ?? "").split(separator: ":").first.map { $0.lowercased() } ?? ""
        let path = head.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.target
        var auth: [String: String] = [:]
        for k in ["authorization", "x-api-key", "x-goog-api-key"] { if let v = head.value(k) { auth[k] = v } }
        let req = Request(method: head.method, host: host, path: path, auth: auth)
        let parsed = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] ?? [:]
        let stream = parsed["stream"] as? Bool ?? false
        let model = parsed["model"] as? String ?? "fake"
        func ok(_ provider: String) -> Bool {
            guard let k = fakeKeys[provider] else { return false }
            return auth.values.contains { $0 == k || $0 == "Bearer " + k }
        }
        func refuse(_ provider: String) -> (Int, String, [UInt8], Request) {
            switch provider {
            case "anthropic": return (401, "application/json", json(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]]), req)
            case "google": return (400, "application/json", json(["error": ["code": 400, "message": "API key not valid.", "status": "INVALID_ARGUMENT"]]), req)
            default: return (401, "application/json", json(["error": ["message": "Incorrect API key provided", "code": "invalid_api_key"]]), req)
            }
        }
        func reply(_ x: (String, [UInt8])) -> (Int, String, [UInt8], Request) { (200, x.0, x.1, req) }
        let isPost = head.method == "POST"
        switch host {
        case "api.anthropic.com":
            guard ok("anthropic") else { return refuse("anthropic") }
            if isPost, path == "/v1/messages/count_tokens" { return reply(("application/json", json(["input_tokens": 1]))) }
            if isPost, path == "/v1/messages" { return reply(messages(model, stream)) }
            if path.hasPrefix("/v1/models") { return reply(("application/json", json(["data": [["type": "model", "id": "claude-fake", "display_name": "Fake"]], "has_more": false]))) }
            return (404, "application/json", json(["type": "error", "error": ["type": "not_found_error", "message": "not here"]]), req)
        case "api.openai.com":
            guard ok("openai") else { return refuse("openai") }
            if path.hasPrefix("/v1/models") { return reply(("application/json", json(["object": "list", "data": [["id": "gpt-fake", "object": "model", "owned_by": "openai"]]]))) }
            if isPost, path.hasPrefix("/v1/responses") { return reply(responses(model, stream)) }
            if isPost, path == "/v1/chat/completions" { return reply(chat(model, stream)) }
            return reply(("application/json", json([:] as [String: Any])))
        case "openrouter.ai", "ai-gateway.vercel.sh":
            let provider = host == "openrouter.ai" ? "openrouter" : "vercel-ai-gateway"
            guard ok(provider) else { return refuse(provider) }
            var p = path
            if host == "openrouter.ai", p.hasPrefix("/api") { p = String(p.dropFirst(4)) }
            if p == "/v1/key" { return reply(("application/json", json(["data": ["label": "fake", "usage": 0, "is_free_tier": false]]))) }
            if p.hasPrefix("/v1/models") { return reply(("application/json", json(["object": "list", "data": [["id": "openai/gpt-5.4-mini", "object": "model"]]]))) }
            if isPost, p == "/v1/chat/completions" { return reply(chat(model, stream)) }
            if isPost, p.hasPrefix("/v1/responses") { return reply(responses(model, stream)) }
            if isPost, p == "/v1/messages/count_tokens" { return reply(("application/json", json(["input_tokens": 1]))) }
            if isPost, p == "/v1/messages" { return reply(messages(model, stream)) }
            return (404, "application/json", json(["error": ["message": "not here", "code": 404]]), req)
        default:
            let google = host == "generativelanguage.googleapis.com"
            let provider = google ? "google" : "xai"
            if path == "/v1/models" || path == "/v1/api-key" || path == "/v1beta/models" {
                guard ok(provider) else { return (400, "application/json", json(["error": "Incorrect API key provided"]), req) }
                if path == "/v1beta/models" { return reply(("application/json", json(["models": [["name": "models/gemini-fake"]]]))) }
                if path == "/v1/api-key" { return reply(("application/json", json(["name": "fake", "api_key_blocked": false, "api_key_disabled": false]))) }
                return reply(("application/json", json(["object": "list", "data": [["id": "grok-fake", "object": "model", "owned_by": "xai"]]])))
            }
            guard ok(provider) else { return refuse(provider) }
            if isPost, path.hasSuffix("/chat/completions") { return reply(chat(model, stream)) }
            if isPost, path == "/v1/responses" { return reply(responses(model, stream)) }
            if path.contains(":streamGenerateContent") || path.contains(":generateContent") { return reply(gemini(stream: path.contains(":stream"), body: parsed)) }
            return (404, "application/json", json(["error": "not here"]), req)
        }
    }

    static func chat(_ model: String, _ stream: Bool) -> (String, [UInt8]) {
        let usage = ["prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2]
        if stream {
            let first: [String: Any] = ["id": "x", "object": "chat.completion.chunk", "created": 0, "model": model,
                                        "choices": [["index": 0, "delta": ["role": "assistant", "content": answer], "finish_reason": NSNull()]]]
            let last: [String: Any] = ["id": "x", "object": "chat.completion.chunk", "created": 0, "model": model,
                                       "choices": [["index": 0, "delta": [:] as [String: Any], "finish_reason": "stop"]], "usage": usage]
            return ("text/event-stream", sse([(nil, first), (nil, last)]) + Array("data: [DONE]\n\n".utf8))
        }
        return ("application/json", json(["id": "x", "object": "chat.completion", "created": 0, "model": model, "usage": usage,
                                          "choices": [["index": 0, "message": ["role": "assistant", "content": answer], "finish_reason": "stop"]]]))
    }

    static func responses(_ model: String, _ stream: Bool) -> (String, [UInt8]) {
        let item: [String: Any] = ["id": "msg_1", "type": "message", "role": "assistant", "status": "completed",
                                   "content": [["type": "output_text", "text": answer, "annotations": [] as [Any]]]]
        let usage: [String: Any] = ["input_tokens": 1, "output_tokens": 1, "total_tokens": 2,
                                    "input_tokens_details": ["cached_tokens": 0], "output_tokens_details": ["reasoning_tokens": 0]]
        let done: [String: Any] = ["id": "resp_1", "object": "response", "created_at": 0, "status": "completed", "model": model,
                                   "output": [item], "usage": usage]
        guard stream else { return ("application/json", json(done)) }
        var started = done
        started["status"] = "in_progress"; started["output"] = [] as [Any]; started["usage"] = NSNull()
        var open = item
        open["status"] = "in_progress"; open["content"] = [] as [Any]
        let part: [String: Any] = ["type": "output_text", "text": "", "annotations": [] as [Any]]
        let evs: [(String, [String: Any])] = [
            ("response.created", ["response": started]), ("response.in_progress", ["response": started]),
            ("response.output_item.added", ["output_index": 0, "item": open]),
            ("response.content_part.added", ["item_id": "msg_1", "output_index": 0, "content_index": 0, "part": part]),
            ("response.output_text.delta", ["item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": answer]),
            ("response.output_text.done", ["item_id": "msg_1", "output_index": 0, "content_index": 0, "text": answer]),
            ("response.content_part.done", ["item_id": "msg_1", "output_index": 0, "content_index": 0, "part": (item["content"] as! [[String: Any]])[0]]),
            ("response.output_item.done", ["output_index": 0, "item": item]),
            ("response.completed", ["response": done]),
        ]
        return ("text/event-stream", sse(evs.enumerated().map { i, e in
            var d = e.1; d["type"] = e.0; d["sequence_number"] = i; return (e.0, d)
        }))
    }

    static func messages(_ model: String, _ stream: Bool) -> (String, [UInt8]) {
        let usage = ["input_tokens": 1, "output_tokens": 1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0]
        let msg: [String: Any] = ["id": "msg_fake", "type": "message", "role": "assistant", "model": model,
                                  "content": [["type": "text", "text": answer]], "stop_reason": "end_turn", "stop_sequence": NSNull(), "usage": usage]
        guard stream else { return ("application/json", json(msg)) }
        var start = msg
        start["content"] = [] as [Any]; start["stop_reason"] = NSNull()
        let evs: [(String, [String: Any])] = [
            ("message_start", ["message": start]),
            ("content_block_start", ["index": 0, "content_block": ["type": "text", "text": ""]]),
            ("content_block_delta", ["index": 0, "delta": ["type": "text_delta", "text": answer]]),
            ("content_block_stop", ["index": 0]),
            ("message_delta", ["delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()], "usage": ["output_tokens": 1]]),
            ("message_stop", [:]),
        ]
        return ("text/event-stream", sse(evs.map { e in var d = e.1; d["type"] = e.0; return (e.0, d) }))
    }

    static func gemini(stream: Bool, body: [String: Any]) -> (String, [UInt8]) {
        // A request for JSON (Gemini CLI's model router) gets JSON; any other the answer in words.
        let gc = body["generationConfig"] as? [String: Any] ?? [:]
        let wantsJSON = gc["responseMimeType"] as? String == "application/json" || gc["responseSchema"] != nil || gc["responseJsonSchema"] != nil
        let text = wantsJSON && !stream ? "{\"complexity_reasoning\":\"x\",\"complexity_score\":1}" : answer
        let ev: [String: Any] = ["candidates": [["content": ["role": "model", "parts": [["text": text]]], "finishReason": "STOP", "index": 0]],
                                 "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2]]
        if stream { return ("text/event-stream", Array(("data: " + String(decoding: json(ev), as: UTF8.self) + "\r\n\r\n").utf8)) }
        return ("application/json", json(ev))
    }
}
