import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

public final class BridgeServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    public private(set) var port: Int = 0

    public init() {}

    public func start(
        certPath: URL, keyPath: URL,
        handler: RequestHandler, preferredPort: Int = 52735
    ) throws {
        let certs = try NIOSSLCertificate.fromPEMFile(certPath.path)
            .map { NIOSSLCertificateSource.certificate($0) }
        let key = try NIOSSLPrivateKey(file: keyPath.path, format: .pem)
        let tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs, privateKey: .privateKey(key))
        let sslContext = try NIOSSLContext(configuration: tls)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline
                    .addHandler(NIOSSLServerHandler(context: sslContext))
                    .flatMap { channel.pipeline.configureHTTPServerPipeline() }
                    .flatMap { channel.pipeline.addHandler(HTTPHandler(handler: handler)) }
            }

        // The port is part of the pairing contract: the phone's subnet
        // sweep knocks on exactly this port, so a silent fallback to a
        // random port would make the Mac unfindable. Retry briefly (the
        // usual squatter is a stale instance still shutting down), then
        // fail loudly.
        var attempt = 0
        while true {
            do {
                channel = try bootstrap.bind(host: "0.0.0.0", port: preferredPort).wait()
                break
            } catch {
                attempt += 1
                guard let ioError = error as? IOError,
                      ioError.errnoCode == EADDRINUSE,
                      attempt < 3 else { throw error }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        port = channel?.localAddress?.port ?? 0
    }

    public func stop() {
        try? channel?.close().wait()
        channel = nil
    }
}

final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let maxBodyBytes = 2 * 1024 * 1024

    private let handler: RequestHandler
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var tooLarge = false

    init(handler: RequestHandler) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            body.clear()
            tooLarge = false
        case .body(var chunk):
            guard !tooLarge else { return }
            if body.readableBytes + chunk.readableBytes > Self.maxBodyBytes {
                tooLarge = true
                let version = head?.version ?? .http1_1
                var responseHead = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: 413))
                let responseBody = context.channel.allocator.buffer(string: #"{"error":"too large"}"#)
                responseHead.headers.add(name: "Content-Type", value: "application/json")
                responseHead.headers.add(
                    name: "Content-Length", value: String(responseBody.readableBytes))
                context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
                context.write(wrapOutboundOut(.body(.byteBuffer(responseBody))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                    context.close(promise: nil)
                }
                return
            }
            body.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            self.head = nil
            if tooLarge { return }
            let auth = head.headers.first(name: "Authorization")
            let requestBody = Data(body.readableBytesView)
            let version = head.version
            let loop = context.eventLoop
            let ctx = context
            handler.handleAsync(path: head.uri, authorization: auth, body: requestBody) { result in
                loop.execute {
                    var responseHead = HTTPResponseHead(
                        version: version,
                        status: HTTPResponseStatus(statusCode: result.status))
                    let responseBody = ctx.channel.allocator.buffer(string: result.body)
                    responseHead.headers.add(name: "Content-Type", value: "application/json")
                    responseHead.headers.add(
                        name: "Content-Length", value: String(responseBody.readableBytes))
                    ctx.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(responseBody))), promise: nil)
                    ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                }
            }
        }
    }
}
