import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

// The two listeners, on swift-nio (the bootstrap pattern of the dashboard's server): the line port speaks JSON lines —
// one JSON object per line, a line of 32 MiB or more closes the connection with no reply, as does 30 seconds without a
// line — and the page port speaks HTTP/1.1. Each connection is a task; its requests and lines are handed to the
// transport-free handlers (ChatPageHandler, ChatLineConnection) off the event loop, in order.

public final class ChatListeners: @unchecked Sendable {
    public let linePort: Int
    public let pagePort: Int
    private let line: NIOAsyncChannel<LineAccepted, Never>
    private let page: NIOAsyncChannel<PageAccepted, Never>
    /// The owner's private socket (`ChatOwnerSocket`), when the server was given one.
    private let owner: NIOAsyncChannel<PageAccepted, Never>?
    private let core: ChatServerCore
    private let log: ChatLog

    struct LineAccepted: Sendable {
        let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        let ip: String
    }

    struct PageAccepted: Sendable {
        let channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>
        let ip: String
    }

    /// The largest request body the page port reads; a larger one is refused with 413 and the connection closed.
    public static let maxBody = ChatProtocol.maxLine + 1

    /// Binds both ports (line first), then the owner's socket when one is given (`ownerSocket`, checked by
    /// `ChatOwnerSocket.refusal` first; made 0600). A failure is thrown as it came, for the caller to judge.
    public static func bind(core: ChatServerCore, host: String, linePort: Int, pagePort: Int, ownerSocket: String? = nil, log: ChatLog,
                            group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> ChatListeners {
        let line = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: linePort) { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineFrameDecoder(max: ChatProtocol.maxLine)))
                    try child.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: .seconds(ChatLineConnection.idleSeconds)))
                    try child.pipeline.syncOperations.addHandler(CloseWhenIdle())
                    return LineAccepted(channel: try NIOAsyncChannel(wrappingChannelSynchronously: child),
                                        ip: child.remoteAddress?.ipAddress ?? "")
                }
            }
        let page: NIOAsyncChannel<PageAccepted, Never>
        do {
            page = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: host, port: pagePort) { child in
                    child.eventLoop.makeCompletedFuture {
                        // No pipelining assistance: requests are answered in order by one task per connection anyway, and the
                        // connection must keep reading while a stream or a long poll is open, so that a caller that goes
                        // away is noticed (its close ends the stream or the wait).
                        try child.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                        return PageAccepted(channel: try NIOAsyncChannel(wrappingChannelSynchronously: child),
                                            ip: child.remoteAddress?.ipAddress ?? "")
                    }
                }
        } catch {
            try? await line.channel.close()
            throw error
        }
        var owner: NIOAsyncChannel<PageAccepted, Never>?
        if let path = ownerSocket {
            do {
                if let why = ChatOwnerSocket.refusal(path: path) { throw ChatConfigError(why) }
                owner = try await ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.backlog, value: 64)
                    .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true) { child in
                        child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                            return PageAccepted(channel: try NIOAsyncChannel(wrappingChannelSynchronously: child), ip: "")
                        }
                    }
                // In a 0700 folder already; the socket itself is the user's alone too.
                guard chmod(path, 0o600) == 0 else { throw ChatConfigError("--owner-socket \(path): cannot make it 0600") }
            } catch {
                try? await owner?.channel.close()
                try? await page.channel.close()
                try? await line.channel.close()
                throw error
            }
        }
        let l = ChatListeners(line: line, page: page, owner: owner, core: core, log: log)
        return l
    }

    private init(line: NIOAsyncChannel<LineAccepted, Never>, page: NIOAsyncChannel<PageAccepted, Never>,
                 owner: NIOAsyncChannel<PageAccepted, Never>?, core: ChatServerCore, log: ChatLog) {
        self.line = line
        self.page = page
        self.owner = owner
        self.core = core
        self.log = log
        linePort = line.channel.localAddress?.port ?? 0
        pagePort = page.channel.localAddress?.port ?? 0
    }

    /// Serves until the listeners close.
    public func serve() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.serveLines() }
            group.addTask { await self.servePages() }
            if self.owner != nil { group.addTask { await self.serveOwner() } }
        }
    }

    /// Closes both listeners: no new connection is accepted.
    public func close() {
        line.channel.close(promise: nil)
        page.channel.close(promise: nil)
        owner?.channel.close(promise: nil)
    }

    // MARK: the line port

    private func serveLines() async {
        try? await line.executeThenClose { inbound in
            try await withThrowingDiscardingTaskGroup { group in
                for try await conn in inbound {
                    group.addTask { await self.lineConnection(conn) }
                }
            }
        }
    }

    private func lineConnection(_ a: LineAccepted) async {
        let core = self.core, log = self.log
        guard var state = ChatLineConnection(core: core, remoteIP: a.ip) else {
            log("chat: refused \(a.ip): not an allowed address")
            try? await a.channel.channel.close()
            return
        }
        try? await a.channel.executeThenClose { inbound, outbound in
            for try await buf in inbound {
                let raw = Array(buf.readableBytesView)
                let current = state
                let (outcome, next) = await Self.offload { () -> (ChatLineConnection.Outcome, ChatLineConnection) in
                    var s = current
                    let o = s.handle(raw)
                    return (o, s)
                }
                state = next
                switch outcome {
                case .nothing: continue
                case .close(let why):
                    log("chat: dropped \(a.ip): \(why)")
                    return
                case .reply(let bytes):
                    try await outbound.write(ByteBuffer(bytes: bytes))
                }
            }
        }
    }

    // MARK: the page port

    private func servePages() async {
        try? await page.executeThenClose { inbound in
            try await withThrowingDiscardingTaskGroup { group in
                for try await conn in inbound {
                    group.addTask { await self.pageConnection(conn) }
                }
            }
        }
    }

    // MARK: the owner's socket

    private func serveOwner() async {
        guard let owner else { return }
        try? await owner.executeThenClose { inbound in
            try await withThrowingDiscardingTaskGroup { group in
                for try await conn in inbound {
                    group.addTask {
                        // Only a process of this same user is the owner; anyone else is closed with no answer.
                        let uid = await Self.peerUID(conn.channel.channel)
                        guard ChatOwnerSocket.admit(peerUID: uid) else {
                            self.log("chat: refused a connection to the owner's socket: " + (uid.map { "it runs as user \($0)" } ?? "its user cannot be read"))
                            try? await conn.channel.channel.close()
                            return
                        }
                        await self.pageConnection(conn, caller: .owner)
                    }
                }
            }
        }
    }

    /// The user a connected Unix socket's peer runs as (LOCAL_PEERCRED), or nil when it cannot be read.
    static func peerUID(_ ch: Channel) async -> uid_t? {
        guard let p = ch as? SocketOptionProvider else { return nil }
        do {
            let c: xucred = try await p.unsafeGetSocketOption(level: SocketOptionLevel(SOL_LOCAL), name: SocketOptionName(LOCAL_PEERCRED)).get()
            return c.cr_version == UInt32(XUCRED_VERSION) ? c.cr_uid : nil
        } catch { return nil }
    }

    private func pageConnection(_ a: PageAccepted, caller: ChatCaller = .tcp) async {
        let handler = ChatPageHandler(core: core)
        try? await a.channel.executeThenClose { inbound, outbound in
            var head: HTTPRequestHead?
            var body: [UInt8] = []
            var tooLarge = false
            var limit = Self.maxBody
            for try await part in inbound {
                switch part {
                case .head(let h):
                    head = h
                    body = []
                    tooLarge = false
                    limit = ChatPageHandler.bodyLimit(method: h.method.rawValue, target: h.uri)
                case .body(let b):
                    // Nothing past the request's limit is kept; the handler of a file upload answers it in its own words.
                    if body.count + b.readableBytes > limit { tooLarge = true } else { body.append(contentsOf: b.readableBytesView) }
                case .end:
                    guard let h = head else { continue }
                    head = nil
                    var headers: [String: String] = [:]
                    for (k, v) in h.headers where headers[k.lowercased()] == nil { headers[k.lowercased()] = v }
                    let upload = limit != Self.maxBody
                    let req = ChatHTTPRequest(method: h.method.rawValue, target: h.uri, headers: headers, body: body, remoteIP: a.ip,
                                              truncated: tooLarge, caller: caller)
                    var res: ChatHTTPResponse = tooLarge && !upload
                        ? .jsonError(413, "the request is too large")
                        : await Self.offload { handler.handle(req) }
                    if let poll = res.poll {   // a receive that waits; the caller going away ends the wait
                        a.channel.channel.closeFuture.whenComplete { _ in poll.cancel() }
                        res = await poll.finish()
                    }
                    if let sub = res.stream {
                        a.channel.channel.closeFuture.whenComplete { _ in sub.cancel() }
                        defer { self.core.unsubscribe(sub) }
                        try await Self.stream(res, sub, for: h, to: outbound)
                        return
                    }
                    let keepAlive = h.isKeepAlive && !tooLarge
                    try await Self.write(res, for: h, keepAlive: keepAlive, to: outbound)
                    if !keepAlive { return }
                }
            }
        }
    }

    private static func write(_ res: ChatHTTPResponse, for req: HTTPRequestHead, keepAlive: Bool,
                              to out: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        var headers = HTTPHeaders()
        for (k, v) in res.headers { headers.add(name: k, value: v) }
        // A HEAD answer carries the length GET would send (set by the handler) and no body.
        let headLength = req.method == .HEAD && res.body.isEmpty && res.header("Content-Length") != nil
        if !(res.status == 204 || res.status == 304) && !headLength { headers.replaceOrAdd(name: "Content-Length", value: String(res.body.count)) }
        headers.replaceOrAdd(name: "Date", value: httpDate())
        if !keepAlive { headers.replaceOrAdd(name: "Connection", value: "close") } else if req.version.minor == 0 {
            headers.replaceOrAdd(name: "Connection", value: "keep-alive")
        }
        try await out.write(.head(HTTPResponseHead(version: req.version, status: HTTPResponseStatus(statusCode: res.status), headers: headers)))
        if !res.body.isEmpty { try await out.write(.body(.byteBuffer(ByteBuffer(bytes: res.body)))) }
        try await out.write(.end(nil))
    }

    /// The live stream: the head (no length: the body is chunked), the hello, then every event as it comes; a stream
    /// that fell behind ends with resync. The connection closes after it.
    private static func stream(_ res: ChatHTTPResponse, _ sub: ChatSubscriber, for req: HTTPRequestHead,
                               to out: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        var headers = HTTPHeaders()
        for (k, v) in res.headers { headers.add(name: k, value: v) }
        headers.replaceOrAdd(name: "Date", value: httpDate())
        try await out.write(.head(HTTPResponseHead(version: req.version, status: .ok, headers: headers)))
        try await out.write(.body(.byteBuffer(ByteBuffer(bytes: res.body))))
        loop: while true {
            switch await sub.next() {
            case .event(let e): try await out.write(.body(.byteBuffer(ByteBuffer(bytes: e.frame))))
            case .resync:
                try await out.write(.body(.byteBuffer(ByteBuffer(bytes: Array("data: {\"kind\":\"resync\"}\n\n".utf8)))))
                break loop
            case .end: break loop
            }
        }
        try await out.write(.end(nil))
    }

    private static func httpDate() -> String {
        var t = time(nil)
        var tmv = tm()
        gmtime_r(&t, &tmv)
        var buf = [Int8](repeating: 0, count: 64)
        let n = strftime(&buf, buf.count, "%a, %d %b %Y %H:%M:%S GMT", &tmv)
        return String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Runs blocking work (the store, a 32 MiB line) on a worker thread, never on an event loop.
    static func offload<T: Sendable>(_ f: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: f()) } }
    }
}

/// JSON lines: each line without its newline (and a carriage return before it, as Go's line scanner drops one). A
/// line that would not fit in `max` bytes with its newline is an error, which closes the connection.
struct LineFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    let max: Int
    private var scanned = 0

    init(max: Int) { self.max = max }

    struct TooLong: Error {}

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let view = buffer.readableBytesView
        if let nl = view.dropFirst(scanned).firstIndex(of: 0x0A) {
            let len = nl - view.startIndex
            guard len + 1 <= max else { throw TooLong() }
            var line = buffer.readSlice(length: len)!
            buffer.moveReaderIndex(forwardBy: 1)
            if line.readableBytes > 0, line.readableBytesView.last == 0x0D { line = line.getSlice(at: line.readerIndex, length: line.readableBytes - 1)! }
            scanned = 0
            context.fireChannelRead(wrapInboundOut(line))
            return .continue
        }
        scanned = view.count
        if view.count >= max { throw TooLong() }
        return .needMoreData
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        while try decode(context: context, buffer: &buffer) == .continue {}
        if seenEOF, buffer.readableBytes > 0 {   // the last line, without a newline
            var line = buffer.readSlice(length: buffer.readableBytes)!
            if line.readableBytesView.last == 0x0D { line = line.getSlice(at: line.readerIndex, length: line.readableBytes - 1)! }
            scanned = 0
            context.fireChannelRead(wrapInboundOut(line))
        }
        return .needMoreData
    }
}

/// Closes a line connection that went `idleSeconds` without a line (the idle handler sits after the line decoder, so
/// only whole lines count as reading).
final class CloseWhenIdle: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil); return }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)   // a line too long, or a reset: no reply, the connection ends
    }
}
