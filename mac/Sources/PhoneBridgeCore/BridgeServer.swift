import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

public enum ServerMode: Equatable {
    case open      // pairing possible: no client cert requested
    case locked    // steady state: mutual TLS, only the enrolled phone gets in
}

public final class BridgeServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    public private(set) var port: Int = 0

    // Retained so a mode switch can rebind the same listener with a new TLS
    // context without the caller re-supplying everything.
    private var certPath: URL?
    private var keyPEM: Data?
    private var handler: RequestHandler?
    private var preferredPort = 52735
    private var phoneCertPath: URL?
    public private(set) var mode: ServerMode = .open

    public init() {}

    public func start(
        certPath: URL, keyPEM: Data,
        handler: RequestHandler, preferredPort: Int = 52735,
        phoneCertPath: URL? = nil, mode: ServerMode = .open
    ) throws {
        self.certPath = certPath
        self.keyPEM = keyPEM
        self.handler = handler
        self.preferredPort = preferredPort
        self.phoneCertPath = phoneCertPath
        try bind(mode: mode)
    }

    // Restart the listener with the other TLS context. The port is fixed and
    // SO_REUSEADDR is set, so the EADDRINUSE retry loop absorbs the brief
    // overlap. In-flight requests are short except /call/wait, which the
    // phone already treats as retryable.
    public func reload(mode: ServerMode, phoneCertPath: URL?) throws {
        self.phoneCertPath = phoneCertPath
        stop()
        try bind(mode: mode)
    }

    private func bind(mode requested: ServerMode) throws {
        guard let handler else { return }

        let sslContext = try makeContext(mode: requested)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // The source gate runs before TLS: an internet-routed peer is
                // closed before it can start a handshake.
                channel.pipeline
                    .addHandler(SourceGateHandler())
                    .flatMap { channel.pipeline.addHandler(NIOSSLServerHandler(context: sslContext)) }
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
        // Locked was requested but no usable phone cert exists: degrade to
        // open so the phone can (re-)enroll instead of being locked out.
        mode = (requested == .locked
            && phoneCertPath.flatMap { PhoneCertStore.loadTrustRoot(at: $0) } != nil)
            ? .locked : .open
    }

    private func makeContext(mode: ServerMode) throws -> NIOSSLContext {
        guard let certPath, let keyPEM else { throw PairingError.badPEM }
        let certs = try NIOSSLCertificate.fromPEMFile(certPath.path)
            .map { NIOSSLCertificateSource.certificate($0) }
        let key = try NIOSSLPrivateKey(bytes: Array(keyPEM), format: .pem)
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs, privateKey: .privateKey(key))
        // TLS 1.0/1.1 are obsolete; the phone client speaks 1.2+.
        tls.minimumTLSVersion = .tlsv12

        if mode == .locked,
           let phoneCertPath,
           let phoneCert = PhoneCertStore.loadTrustRoot(at: phoneCertPath) {
            // Require the peer to present the enrolled certificate and prove
            // possession of its key. NIOSSL sets SSL_VERIFY_FAIL_IF_NO_PEER_CERT
            // for any verification mode other than .none, so a client with no
            // cert (or a different one) is dropped at the handshake.
            tls.certificateVerification = .noHostnameVerification
            tls.trustRoots = .certificates([phoneCert])
        }
        return try NIOSSLContext(configuration: tls)
    }

    public func stop() {
        try? channel?.close().wait()
        channel = nil
    }
}

// Drops connections from anything that is not loopback / private / VPN before
// the TLS handler ever sees a byte. Rejection is silent: a scanner learns
// only that the port refused, not what runs behind it.
final class SourceGateHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    func channelActive(context: ChannelHandlerContext) {
        if let remote = context.remoteAddress, PrivateAddress.isAllowed(remote) {
            context.fireChannelActive()
        } else {
            context.close(promise: nil)
        }
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
