import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import DozableHost

/// 715 — port 80 of the dashboard's Tailscale address (`doz ui publish tailscale`): `tailscale serve --http=80` hands
/// every plain-http request to `http://127.0.0.1:<port>` (716: the marker's `redirectPort` — a loopback TCP port, never a
/// unix socket, which Tailscale serves only for an admin), and this answers each with `308 Permanent Redirect` to the
/// published https address + the request's own path (`TailscalePublish.redirectLocation`). It serves nothing else: no body
/// is read, no header believed, the target is the published address (the marker), never the request's `Host`. Run by
/// `doz ui` while the dashboard is published; a restart's new process binds it again.
public final class WebPublishRedirect: @unchecked Sendable {
    let channel: Channel
    public let port: Int

    private init(channel: Channel, port: Int) {
        self.channel = channel
        self.port = port
    }

    public enum StartError: Error, CustomStringConvertible {
        case inUse(Int)
        public var description: String {
            switch self { case .inUse(let p): return "127.0.0.1:\(p) is already in use" }
        }
    }

    /// Listen on 127.0.0.1:`port` (loopback only). Refused when something already answers there — a wildcard listener
    /// included, which a SO_REUSEADDR bind to loopback would otherwise shadow.
    public static func start(port: Int, origin: String,
                             group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> WebPublishRedirect {
        if WebLoopbackAddress.inUse(port) { throw StartError.inUse(port) }
        let ch = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                child.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    child.pipeline.addHandler(RedirectHandler(origin: origin))
                }
            }
            .bind(host: "127.0.0.1", port: port)
            .get()
        return WebPublishRedirect(channel: ch, port: ch.localAddress?.port ?? port)
    }

    public func close() async {
        try? await channel.close()
    }
}

/// One answer per request: 308 to the published address, `Connection: close`.
private final class RedirectHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let origin: String
    private var target = "/"
    private var version = HTTPVersion(major: 1, minor: 1)

    init(origin: String) { self.origin = origin }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            target = head.uri
            version = head.version
        case .body:
            break
        case .end:
            let location = TailscalePublish.redirectLocation(origin: origin, target: target)
            let body = "Moved to \(location)\n"
            var headers = HTTPHeaders()
            headers.add(name: "Location", value: location)
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: String(body.utf8.count))
            headers.add(name: "Connection", value: "close")
            headers.add(name: "Cache-Control", value: "no-store")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: version, status: .permanentRedirect, headers: headers))), promise: nil)
            var buf = context.channel.allocator.buffer(capacity: body.utf8.count)
            buf.writeString(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            let ch = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in ch.close(promise: nil) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
