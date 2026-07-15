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

        do {
            channel = try bootstrap.bind(host: "0.0.0.0", port: preferredPort).wait()
        } catch {
            if let ioError = error as? IOError, ioError.errnoCode == EADDRINUSE {
                channel = try bootstrap.bind(host: "0.0.0.0", port: 0).wait()
            } else {
                throw error
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
            guard !tooLarge else {
                head = nil
                return
            }
            guard let head else { return }
            let auth = head.headers.first(name: "Authorization")
            let result = handler.handle(
                path: head.uri,
                authorization: auth,
                body: Data(body.readableBytesView))

            var responseHead = HTTPResponseHead(
                version: head.version,
                status: HTTPResponseStatus(statusCode: result.status))
            let responseBody = context.channel.allocator.buffer(string: result.body)
            responseHead.headers.add(name: "Content-Type", value: "application/json")
            responseHead.headers.add(
                name: "Content-Length", value: String(responseBody.readableBytes))

            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(responseBody))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            self.head = nil
        }
    }
}
