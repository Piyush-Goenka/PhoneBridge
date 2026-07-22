import XCTest
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
@testable import PhoneBridgeCore

final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private enum HandshakeProbeError: Error {
    case closedBeforeHandshake
    case timedOut
}

private final class HTTPResponseProbe: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<Int>
    private var completed = false
    private var status: Int?

    init(promise: EventLoopPromise<Int>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = Int(head.status.code)
        case .body:
            break
        case .end:
            if let status { succeedIfPending(status) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failIfPending(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failIfPending(HandshakeProbeError.closedBeforeHandshake)
        context.fireChannelInactive()
    }

    func timeOutIfPending() {
        failIfPending(HandshakeProbeError.timedOut)
    }

    private func succeedIfPending(_ status: Int) {
        guard !completed else { return }
        completed = true
        promise.succeed(status)
    }

    private func failIfPending(_ error: Error) {
        guard !completed else { return }
        completed = true
        promise.fail(error)
    }
}

final class ServerIntegrationTests: XCTestCase {
    private struct ClientIdentity {
        let certPath: URL
        let keyPath: URL
        let base64DER: String
    }

    private var dir: URL!
    private var server: BridgeServer!
    private var sink: MockSink!
    private var session: URLSession!
    private var token: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-tests-" + UUID().uuidString)
        let info = try Pairing.ensure(directory: dir)
        token = info.token
        sink = MockSink()
        let handler = RequestHandler(
            token: info.token,
            icons: try DiskIconStore(directory: dir.appendingPathComponent("icons")),
            sink: sink,
            calls: CallActionRegistry(),
            callSink: MockCallSink())
        server = BridgeServer()
        try server.start(
            certPath: info.certPath, keyPath: info.keyPath,
            handler: handler, preferredPort: 0)
        session = URLSession(
            configuration: .ephemeral, delegate: TrustAllDelegate(), delegateQueue: nil)
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func post(_ path: String, auth: String?, body: String) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "https://localhost:\(server.port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        return ((response as! HTTPURLResponse).statusCode,
                String(data: data, encoding: .utf8) ?? "")
    }

    func testNotifyOverTLSRoundTrip() async throws {
        // The server validates postedAt freshness against the real clock.
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let body = """
            {"v":1,"key":"k1","pkg":"com.x","appName":"X","title":"Hello",\
            "text":"world","postedAt":\(nowMillis),"iconHash":""}
            """
        let (status, response) = try await post("/notify", auth: "Bearer \(token!)", body: body)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(response, #"{"needIcon":false}"#)
        XCTAssertEqual(sink.shown.first?.title, "Hello")
    }

    func testRejectsMissingToken() async throws {
        let (status, _) = try await post("/notify", auth: nil, body: "{}")
        XCTAssertEqual(status, 401)
    }

    func testBindsEphemeralPort() {
        XCTAssertGreaterThan(server.port, 0)
    }

    func testThrowsWhenPreferredPortTaken() throws {
        let info = try Pairing.ensure(directory: dir)
        let secondHandler = RequestHandler(
            token: info.token,
            icons: try DiskIconStore(directory: dir.appendingPathComponent("icons")),
            sink: MockSink(),
            calls: CallActionRegistry(),
            callSink: MockCallSink())
        let secondServer = BridgeServer()
        defer { secondServer.stop() }
        XCTAssertThrowsError(try secondServer.start(
            certPath: info.certPath, keyPath: info.keyPath,
            handler: secondHandler, preferredPort: server.port))
    }

    // MARK: - Mutual TLS enrollment (finding #4)

    // Spins a dedicated server with an enroller and returns it plus its cert
    // directory. Ephemeral port keeps it independent of the setUp server.
    private func startEnrollingServer(open: Bool) throws -> (BridgeServer, EnrollmentCoordinator, URL, String) {
        let ownDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enroll-srv-" + UUID().uuidString)
        let info = try Pairing.ensure(directory: ownDir)
        let certPath = PhoneCertStore.path(directory: ownDir)
        let coordinator = EnrollmentCoordinator(certPath: certPath, open: open)
        let handler = RequestHandler(
            token: info.token,
            icons: try DiskIconStore(directory: ownDir.appendingPathComponent("icons")),
            sink: MockSink(), calls: CallActionRegistry(), callSink: MockCallSink(),
            enroller: coordinator)
        let srv = BridgeServer()
        try srv.start(
            certPath: info.certPath, keyPath: info.keyPath, handler: handler,
            preferredPort: 0, phoneCertPath: certPath, mode: open ? .open : .locked)
        return (srv, coordinator, certPath, info.token)
    }

    private func sampleClientCertBase64(in ownDir: URL) throws -> String {
        let cp = ownDir.appendingPathComponent("client-cert-\(UUID().uuidString).pem")
        let kp = ownDir.appendingPathComponent("client-key-\(UUID().uuidString).pem")
        try Pairing.generateCert(certPath: cp, keyPath: kp)
        let pem = try String(contentsOf: cp, encoding: .utf8)
        let der = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }.joined()
        // der here is already base64 of the DER, which is exactly the wire form.
        return der
    }

    // Mirrors the Android Keystore identity: a P-256 self-signed leaf that is
    // explicitly not a CA and may only be used for digital signatures.
    private func makeECClientIdentity(in ownDir: URL) throws -> ClientIdentity {
        let suffix = UUID().uuidString
        let certPath = ownDir.appendingPathComponent("ec-client-cert-\(suffix).pem")
        let keyPath = ownDir.appendingPathComponent("ec-client-key-\(suffix).pem")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "ec",
            "-pkeyopt", "ec_paramgen_curve:P-256",
            "-pkeyopt", "ec_param_enc:named_curve", "-nodes",
            "-keyout", keyPath.path, "-out", certPath.path,
            "-days", "1", "-subj", "/CN=PhoneBridgePhone",
            "-addext", "basicConstraints=critical,CA:FALSE",
            "-addext", "keyUsage=critical,digitalSignature",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PairingError.opensslFailed(process.terminationStatus)
        }

        let pem = try String(contentsOf: certPath, encoding: .utf8)
        let base64DER = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        return ClientIdentity(
            certPath: certPath, keyPath: keyPath, base64DER: base64DER)
    }

    private func performClientCertificateHandshake(
        port: Int, identity: ClientIdentity
    ) throws -> Int {
        var configuration = TLSConfiguration.makeClientConfiguration()
        // The test trusts its freshly generated server certificate. Client
        // authentication remains enabled independently below.
        configuration.certificateVerification = .none
        configuration.minimumTLSVersion = .tlsv12
        configuration.certificateChain = try NIOSSLCertificate
            .fromPEMFile(identity.certPath.path)
            .map { .certificate($0) }
        configuration.privateKey = .privateKey(try NIOSSLPrivateKey(
            file: identity.keyPath.path, format: .pem))
        let context = try NIOSSLContext(configuration: configuration)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let response = group.next().makePromise(of: Int.self)
        let probe = HTTPResponseProbe(promise: response)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(3))
            .channelInitializer { channel in
                do {
                    let tlsHandler = try NIOSSLClientHandler(
                        context: context, serverHostname: nil)
                    return channel.pipeline.addHandler(tlsHandler).flatMap {
                        channel.pipeline.addHTTPClientHandlers()
                    }.flatMap {
                        channel.pipeline.addHandler(probe)
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel = try bootstrap.connect(host: "127.0.0.1", port: port).wait()
        defer { try? channel.close().wait() }
        let timeout = channel.eventLoop.scheduleTask(in: TimeAmount.seconds(3)) {
            probe.timeOutIfPending()
        }
        defer { timeout.cancel() }

        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "localhost")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPRequestHead(
            version: .http1_1, method: .POST, uri: "/notify", headers: headers)
        _ = channel.write(HTTPClientRequestPart.head(head))
        _ = channel.writeAndFlush(HTTPClientRequestPart.end(nil))
        return try response.futureResult.wait()
    }

    private func post(to port: Int, path: String, auth: String?, body: String) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "https://localhost:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    func testEnrollAcceptedInOpenMode() async throws {
        let (srv, coordinator, certPath, token) = try startEnrollingServer(open: true)
        defer { srv.stop() }
        let responseWriteCompleted = expectation(description: "enrollment response write completed")
        coordinator.onEnrolled = { responseWriteCompleted.fulfill() }
        let certB64 = try sampleClientCertBase64(in: dir)
        let body = #"{"v":1,"cert":"\#(certB64)"}"#
        let (status, _) = try await post(to: srv.port, path: "/enroll", auth: "Bearer \(token)", body: body)
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(PhoneCertStore.loadTrustRoot(at: certPath))
        await fulfillment(of: [responseWriteCompleted], timeout: 1)
    }

    func testEnrollRejectsMissingToken() async throws {
        let (srv, _, _, _) = try startEnrollingServer(open: true)
        defer { srv.stop() }
        let certB64 = try sampleClientCertBase64(in: dir)
        let (status, _) = try await post(
            to: srv.port, path: "/enroll", auth: nil, body: #"{"v":1,"cert":"\#(certB64)"}"#)
        XCTAssertEqual(status, 401)
    }

    func testEnrollRejectsBadBase64() async throws {
        let (srv, _, _, token) = try startEnrollingServer(open: true)
        defer { srv.stop() }
        let (status, _) = try await post(
            to: srv.port, path: "/enroll", auth: "Bearer \(token)", body: #"{"v":1,"cert":"!!!!"}"#)
        XCTAssertEqual(status, 400)
    }

    // Lock/unpair must sever connections that are already accepted, not just
    // refuse new ones: a revoked client could otherwise keep its session (and
    // the old handler's token) alive by trickling traffic under the 90 s
    // idle timeout.
    func testReloadClosesAlreadyAcceptedConnections() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(server.port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(rc, 0)
        // Give the event loop a beat to accept the connection.
        Thread.sleep(forTimeInterval: 0.3)

        try server.reload(mode: .open, phoneCertPath: nil)

        // EOF (or reset) must arrive promptly; a 3 s silence means the old
        // connection survived the reload.
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, 3000)
        XCTAssertEqual(ready, 1, "connection stayed open after reload")
        var byte: UInt8 = 0
        let received = recv(fd, &byte, 1, MSG_DONTWAIT)
        XCTAssertLessThanOrEqual(
            received, 0, "expected EOF/reset after reload, got payload bytes")
    }

    // A no-client-cert session must fail the handshake once the server locks.
    func testLockedModeRejectsClientWithoutCertificate() async throws {
        let (srv, _, certPath, token) = try startEnrollingServer(open: true)
        defer { srv.stop() }
        let certB64 = try sampleClientCertBase64(in: dir)
        _ = try await post(
            to: srv.port, path: "/enroll", auth: "Bearer \(token)", body: #"{"v":1,"cert":"\#(certB64)"}"#)
        try srv.reload(mode: .locked, phoneCertPath: certPath)
        XCTAssertEqual(srv.mode, .locked)

        let body = """
            {"v":1,"key":"k","pkg":"com.x","appName":"X","title":"H","text":"w","postedAt":0,"iconHash":""}
            """
        do {
            _ = try await post(to: srv.port, path: "/notify", auth: "Bearer \(token)", body: body)
            XCTFail("handshake should have been rejected without a client certificate")
        } catch {
            // Expected: TLS handshake failure, no client certificate presented.
        }
    }

    func testLockedModeAcceptsExactEnrolledNonCAClientCertificate() async throws {
        let (srv, _, certPath, token) = try startEnrollingServer(open: true)
        defer { srv.stop() }
        let identity = try makeECClientIdentity(in: dir)
        let (status, _) = try await post(
            to: srv.port, path: "/enroll", auth: "Bearer \(token)",
            body: #"{"v":1,"cert":"\#(identity.base64DER)"}"#)
        XCTAssertEqual(status, 200)

        try srv.reload(mode: .locked, phoneCertPath: certPath)
        XCTAssertEqual(srv.mode, .locked)
        XCTAssertEqual(try performClientCertificateHandshake(
            port: srv.port, identity: identity), 401)
    }

    func testLockedModeRejectsDifferentClientCertificate() async throws {
        let (srv, _, certPath, token) = try startEnrollingServer(open: true)
        defer { srv.stop() }
        let enrolledIdentity = try makeECClientIdentity(in: dir)
        let (status, _) = try await post(
            to: srv.port, path: "/enroll", auth: "Bearer \(token)",
            body: #"{"v":1,"cert":"\#(enrolledIdentity.base64DER)"}"#)
        XCTAssertEqual(status, 200)

        try srv.reload(mode: .locked, phoneCertPath: certPath)
        let differentIdentity = try makeECClientIdentity(in: dir)
        XCTAssertThrowsError(try performClientCertificateHandshake(
            port: srv.port, identity: differentIdentity))
    }
}
