import XCTest
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

final class ServerIntegrationTests: XCTestCase {
    private var dir: URL!
    private var server: BridgeServer!
    private var sink: MockSink!
    private var session: URLSession!
    private var token: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-tests-" + UUID().uuidString)
        let info = try Pairing.ensure(directory: dir, secrets: InMemorySecretStore())
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
            certPath: info.certPath, keyPEM: info.keyPEM,
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
        let body = """
            {"v":1,"key":"k1","pkg":"com.x","appName":"X","title":"Hello",\
            "text":"world","postedAt":0,"iconHash":""}
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
        let info = try Pairing.ensure(directory: dir, secrets: InMemorySecretStore())
        let secondHandler = RequestHandler(
            token: info.token,
            icons: try DiskIconStore(directory: dir.appendingPathComponent("icons")),
            sink: MockSink(),
            calls: CallActionRegistry(),
            callSink: MockCallSink())
        let secondServer = BridgeServer()
        defer { secondServer.stop() }
        XCTAssertThrowsError(try secondServer.start(
            certPath: info.certPath, keyPEM: info.keyPEM,
            handler: secondHandler, preferredPort: server.port))
    }

    // MARK: - Mutual TLS enrollment (finding #4)

    // Spins a dedicated server with an enroller and returns it plus its cert
    // directory. Ephemeral port keeps it independent of the setUp server.
    private func startEnrollingServer(open: Bool) throws -> (BridgeServer, EnrollmentCoordinator, URL, String) {
        let ownDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enroll-srv-" + UUID().uuidString)
        let info = try Pairing.ensure(directory: ownDir, secrets: InMemorySecretStore())
        let certPath = PhoneCertStore.path(directory: ownDir)
        let coordinator = EnrollmentCoordinator(certPath: certPath, open: open)
        let handler = RequestHandler(
            token: info.token,
            icons: try DiskIconStore(directory: ownDir.appendingPathComponent("icons")),
            sink: MockSink(), calls: CallActionRegistry(), callSink: MockCallSink(),
            enroller: coordinator)
        let srv = BridgeServer()
        try srv.start(
            certPath: info.certPath, keyPEM: info.keyPEM, handler: handler,
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

    private func post(to port: Int, path: String, auth: String?, body: String) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "https://localhost:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    func testEnrollAcceptedInOpenMode() async throws {
        let (srv, _, certPath, token) = try startEnrollingServer(open: true)
        defer { srv.stop() }
        let certB64 = try sampleClientCertBase64(in: dir)
        let body = #"{"v":1,"cert":"\#(certB64)"}"#
        let (status, _) = try await post(to: srv.port, path: "/enroll", auth: "Bearer \(token)", body: body)
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(PhoneCertStore.loadTrustRoot(at: certPath))
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
}
