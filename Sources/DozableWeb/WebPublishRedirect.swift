import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import DozableHost

/// 715 — port 80 of the dashboard's Tailscale address (`doz ui publish tailscale`): `tailscale serve --http=80` hands
/// every plain-http request to this unix socket in the store (`<store>/tailscale/http.sock`), and it answers each with
/// `308 Permanent Redirect` to the published https address + the request's own path (`TailscalePublish.redirectLocation`).
/// It serves nothing else: no body is read, no header believed, the target is the published address (the marker), never
/// the request's `Host`. Run by `doz ui` while the dashboard is published; a restart's new process binds it again.
public final class WebPublishRedirect: @unchecked Sendable {
    let channel: Channel
    public let path: String

    private init(channel: Channel, path: String) {
        self.channel = channel
        self.path = path
    }

    /// Listen on `path` (a stale socket file there is replaced; the file is 0600).
    public static func start(path: String, origin: String,
                             group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> WebPublishRedirect {
        let ch = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .childChannelInitializer { child in
                child.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    child.pipeline.addHandler(RedirectHandler(origin: origin))
                }
            }
            .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true)
            .get()
        chmod(path, 0o600)
        return WebPublishRedirect(channel: ch, path: path)
    }

    public func close() async {
        try? await channel.close()
        unlink(path)
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
