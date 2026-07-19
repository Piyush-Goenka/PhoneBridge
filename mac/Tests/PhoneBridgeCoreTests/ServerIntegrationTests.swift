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
}
