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
    // Shared across every accepted connection so a flood cannot exhaust the
    // single event loop's file descriptors or memory (#5).
    private let limiter = ConnectionLimiter()
    // Longer than the 45 s /call/wait hold plus its re-poll, so a legitimate
    // long-poll survives while a silent slow-loris connection is reaped.
    private static let idleTimeout = TimeAmount.seconds(90)

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
            .childChannelInitializer { [limiter] channel in
                // Runs before TLS, cheapest checks first: drop internet-routed
                // peers, then enforce the connection cap, then reap idle/slow
                // connections, all before a handshake byte is processed.
                channel.pipeline
                    .addHandler(SourceGateHandler())
                    .flatMap { channel.pipeline.addHandler(ConnectionLimitHandler(limiter: limiter)) }
                    .flatMap {
                        channel.pipeline.addHandler(
                            IdleStateHandler(allTimeout: Self.idleTimeout))
                    }
                    .flatMap { channel.pipeline.addHandler(IdleCloseHandler()) }
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

// Bounds concurrent connections in total and per source IP, so no single peer
// (or a flood of them) can pin the single event loop's resources. Shared
// across every connection, so its counts are guarded by a lock.
public final class ConnectionLimiter {
    private let lock = NSLock()
    private var perIP: [String: Int] = [:]
    private var total = 0
    private let maxTotal: Int
    private let maxPerIP: Int

    public init(maxTotal: Int = 64, maxPerIP: Int = 8) {
        self.maxTotal = maxTotal
        self.maxPerIP = maxPerIP
    }

    public func acquire(_ ip: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard total < maxTotal, perIP[ip, default: 0] < maxPerIP else { return false }
        total += 1
        perIP[ip, default: 0] += 1
        return true
    }

    public func release(_ ip: String) {
        lock.lock(); defer { lock.unlock() }
        total = max(0, total - 1)
        guard let count = perIP[ip] else { return }
        if count <= 1 { perIP[ip] = nil } else { perIP[ip] = count - 1 }
    }
}

final class ConnectionLimitHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let limiter: ConnectionLimiter
    private var acquiredIP: String?

    init(limiter: ConnectionLimiter) {
        self.limiter = limiter
    }

    func channelActive(context: ChannelHandlerContext) {
        let ip = context.remoteAddress?.ipAddress ?? "?"
        if limiter.acquire(ip) {
            acquiredIP = ip
            context.fireChannelActive()
        } else {
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let ip = acquiredIP {
            limiter.release(ip)
            acquiredIP = nil
        }
        context.fireChannelInactive()
    }
}

// Closes a connection that IdleStateHandler reports as idle, reaping
// slow-loris connections that complete no request within the window.
final class IdleCloseHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
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
            handler.handleAsync(
                path: head.uri, authorization: auth, body: requestBody,
                method: head.method.rawValue
            ) { result in
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
