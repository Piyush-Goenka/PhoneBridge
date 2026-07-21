import XCTest
import CryptoKit
@testable import PhoneBridgeCore

final class MockIconStore: IconStoring {
    var stored: [String: Data] = [:]
    func has(_ hash: String) -> Bool { stored[hash] != nil }
    func save(_ hash: String, png: Data) throws { stored[hash] = png }
    func path(_ hash: String) -> URL? {
        stored[hash] != nil ? URL(fileURLWithPath: "/mock/\(hash)") : nil
    }
}

final class MockSink: NotificationSink {
    var shown: [NotifyPayload] = []
    var dismissed: [String] = []
    func show(_ payload: NotifyPayload, iconPath: URL?) { shown.append(payload) }
    func dismiss(key: String) { dismissed.append(key) }
}

final class MockCallSink: CallSink {
    var calls: [(key: String, caller: String)] = []
    var updated: [(key: String, caller: String)] = []
    var states: [(key: String, state: CallState)] = []
    var ended: [String] = []
    func showCall(key: String, caller: String) { calls.append((key, caller)) }
    func updateCall(key: String, caller: String) { updated.append((key, caller)) }
    func setCallState(key: String, state: CallState) { states.append((key, state)) }
    func endCall(key: String) { ended.append(key) }
}

final class RequestHandlerTests: XCTestCase {
    private var icons: MockIconStore!
    private var sink: MockSink!
    private var handler: RequestHandler!
    private var callSink: MockCallSink!
    private var registry: CallActionRegistry!

    // 64-hex icon hash in the exact format the phone sends.
    static let hashA = "sha256:" + String(repeating: "a", count: 64)

    private let validNotify = """
        {"v":1,"key":"k1","pkg":"com.whatsapp","appName":"WhatsApp",\
        "title":"Alice","text":"hi","postedAt":1768406400000,"iconHash":"\(hashA)"}
        """

    override func setUp() {
        icons = MockIconStore()
        sink = MockSink()
        callSink = MockCallSink()
        registry = CallActionRegistry(timeout: 10)
        // Clock frozen to the payloads' postedAt so freshness checks pass.
        handler = RequestHandler(
            token: "secret", icons: icons, sink: sink,
            calls: registry, callSink: callSink,
            now: { Date(timeIntervalSince1970: 1_768_406_400) })
    }

    private func post(_ path: String, auth: String?, body: String) -> HandlerResult {
        handler.handle(path: path, authorization: auth, body: Data(body.utf8))
    }

    func testMissingTokenIs401() {
        let r = post("/notify", auth: nil, body: validNotify)
        XCTAssertEqual(r.status, 401)
        XCTAssertTrue(sink.shown.isEmpty)
    }

    func testWrongTokenIs401() {
        let r = post("/notify", auth: "Bearer wrong", body: validNotify)
        XCTAssertEqual(r.status, 401)
        XCTAssertTrue(sink.shown.isEmpty)
    }

    func testValidNotifyShowsNotification() {
        let r = post("/notify", auth: "Bearer secret", body: validNotify)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(sink.shown.first?.title, "Alice")
        XCTAssertEqual(sink.shown.first?.appName, "WhatsApp")
    }

    func testUnknownIconHashRequestsIcon() {
        let r = post("/notify", auth: "Bearer secret", body: validNotify)
        XCTAssertEqual(r.body, #"{"needIcon":true}"#)
    }

    func testKnownIconHashDoesNotRequestIcon() throws {
        try icons.save(Self.hashA, png: Data([1]))
        let r = post("/notify", auth: "Bearer secret", body: validNotify)
        XCTAssertEqual(r.body, #"{"needIcon":false}"#)
    }

    func testEmptyIconHashNeverRequestsIcon() {
        let body = validNotify.replacingOccurrences(of: Self.hashA, with: "")
        let r = post("/notify", auth: "Bearer secret", body: body)
        XCTAssertEqual(r.body, #"{"needIcon":false}"#)
    }

    func testMalformedJSONIs400() {
        let r = post("/notify", auth: "Bearer secret", body: "{nope")
        XCTAssertEqual(r.status, 400)
    }

    // A minimal payload that passes the PNG-signature check, with the hash
    // computed the same way the phone computes it.
    private func pngAndHash() -> (base64: String, hash: String) {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        let hex = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        return (png.base64EncodedString(), "sha256:\(hex)")
    }

    func testIconUploadStoresPNG() {
        let (png, hash) = pngAndHash()
        let r = post("/icon", auth: "Bearer secret",
                     body: #"{"iconHash":"\#(hash)","png":"\#(png)"}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(icons.has(hash))
    }

    func testIconUploadRejectsNonPNGBytes() {
        let notPng = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        let hex = SHA256.hash(data: notPng).map { String(format: "%02x", $0) }.joined()
        let r = post("/icon", auth: "Bearer secret",
                     body: #"{"iconHash":"sha256:\#(hex)","png":"\#(notPng.base64EncodedString())"}"#)
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(icons.stored.isEmpty)
    }

    func testIconUploadRejectsHashMismatch() {
        let (png, _) = pngAndHash()
        let r = post("/icon", auth: "Bearer secret",
                     body: #"{"iconHash":"\#(Self.hashA)","png":"\#(png)"}"#)
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(icons.stored.isEmpty)
    }

    func testNotifyRejectsWrongProtocolVersion() {
        let body = validNotify.replacingOccurrences(of: #""v":1"#, with: #""v":2"#)
        XCTAssertEqual(post("/notify", auth: "Bearer secret", body: body).status, 400)
        XCTAssertTrue(sink.shown.isEmpty)
    }

    func testCallRejectsWrongProtocolVersion() {
        let body = #"{"v":9,"key":"c1","caller":"Manoj","postedAt":1768406400000}"#
        XCTAssertEqual(post("/call", auth: "Bearer secret", body: body).status, 400)
        XCTAssertTrue(callSink.calls.isEmpty)
    }

    func testNotifyRejectsOversizedField() {
        let long = String(repeating: "x", count: 5000)
        let body = validNotify.replacingOccurrences(of: #""text":"hi""#, with: #""text":"\#(long)""#)
        XCTAssertEqual(post("/notify", auth: "Bearer secret", body: body).status, 400)
        XCTAssertTrue(sink.shown.isEmpty)
    }

    func testNotifyRejectsMalformedIconHash() {
        let body = validNotify.replacingOccurrences(of: Self.hashA, with: "sha256:../escape")
        XCTAssertEqual(post("/notify", auth: "Bearer secret", body: body).status, 400)
    }

    func testNotifyRejectsStaleTimestamp() {
        // Two days before the frozen clock: outside the 24 h window.
        let body = validNotify.replacingOccurrences(
            of: "1768406400000", with: "1768233600000")
        XCTAssertEqual(post("/notify", auth: "Bearer secret", body: body).status, 400)
        XCTAssertTrue(sink.shown.isEmpty)
    }

    func testNotifyRejectsFarFutureTimestamp() {
        // Two hours ahead of the frozen clock: outside the 1 h skew.
        let body = validNotify.replacingOccurrences(
            of: "1768406400000", with: "1768413600000")
        XCTAssertEqual(post("/notify", auth: "Bearer secret", body: body).status, 400)
    }

    func testNonPostMethodIs405() {
        let r = handler.handle(
            path: "/notify", authorization: "Bearer secret",
            body: Data(validNotify.utf8), method: "GET")
        XCTAssertEqual(r.status, 405)
        XCTAssertTrue(sink.shown.isEmpty)
    }

    func testCallWaitNonPostIs405() {
        let expectation = expectation(description: "wait")
        handler.handleAsync(
            path: "/call/wait", authorization: "Bearer secret",
            body: Data(#"{"key":"c1"}"#.utf8), method: "GET") { result in
            XCTAssertEqual(result.status, 405)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testDismissForwardsKey() {
        let r = post("/dismiss", auth: "Bearer secret", body: #"{"key":"k1"}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(sink.dismissed, ["k1"])
    }

    func testUnknownPathIs404() {
        let r = post("/whatever", auth: "Bearer secret", body: "{}")
        XCTAssertEqual(r.status, 404)
    }

    func testCallShowsActionableBanner() {
        let body = #"{"v":1,"key":"c1","caller":"Palak","postedAt":1768406400000}"#
        let r = post("/call", auth: "Bearer secret", body: body)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(callSink.calls.first?.key, "c1")
        XCTAssertEqual(callSink.calls.first?.caller, "Palak")
    }

    func testCallMalformedIs400() {
        XCTAssertEqual(post("/call", auth: "Bearer secret", body: "{nope").status, 400)
    }

    func testCallUpdateRoutesToUpdateNotShow() {
        let body = #"{"v":1,"key":"c1","caller":"Lattu Chacha","postedAt":1768406400000,"update":true}"#
        let r = post("/call", auth: "Bearer secret", body: body)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(callSink.calls.isEmpty)
        XCTAssertEqual(callSink.updated.first?.key, "c1")
        XCTAssertEqual(callSink.updated.first?.caller, "Lattu Chacha")
    }

    func testCallWithoutUpdateFlagShowsBanner() {
        let body = #"{"v":1,"key":"c1","caller":"Manoj","postedAt":1768406400000}"#
        _ = post("/call", auth: "Bearer secret", body: body)
        XCTAssertEqual(callSink.calls.first?.caller, "Manoj")
        XCTAssertTrue(callSink.updated.isEmpty)
    }

    func testCallStateActiveSwitchesPanelToInCall() {
        let body = #"{"v":1,"key":"c1","caller":"Manoj","postedAt":1768406400000,"state":"active"}"#
        let r = post("/call", auth: "Bearer secret", body: body)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(callSink.calls.isEmpty)
        XCTAssertEqual(callSink.states.first?.key, "c1")
        XCTAssertEqual(callSink.states.first?.state, .active)
    }

    func testCallStateSilencedMarksPanel() {
        let body = #"{"v":1,"key":"c1","caller":"Manoj","postedAt":1768406400000,"state":"silenced"}"#
        _ = post("/call", auth: "Bearer secret", body: body)
        XCTAssertEqual(callSink.states.first?.state, .silenced)
        XCTAssertTrue(callSink.calls.isEmpty)
    }

    func testUnknownCallStateFallsBackToShowingTheCall() {
        let body = #"{"v":1,"key":"c1","caller":"Manoj","postedAt":1768406400000,"state":"wat"}"#
        _ = post("/call", auth: "Bearer secret", body: body)
        XCTAssertEqual(callSink.calls.first?.caller, "Manoj")
        XCTAssertTrue(callSink.states.isEmpty)
    }

    func testCallWaitCanReturnEndAction() {
        let expectation = expectation(description: "wait")
        handler.handleAsync(
            path: "/call/wait", authorization: "Bearer secret",
            body: Data(#"{"key":"c1"}"#.utf8)) { result in
            XCTAssertEqual(result.body, #"{"action":"end"}"#)
            expectation.fulfill()
        }
        registry.fulfill(key: "c1", action: .end)
        wait(for: [expectation], timeout: 2)
    }

    func testCallWaitCompletesWhenFulfilled() {
        let expectation = expectation(description: "wait")
        handler.handleAsync(
            path: "/call/wait", authorization: "Bearer secret",
            body: Data(#"{"key":"c1"}"#.utf8)) { result in
            XCTAssertEqual(result.status, 200)
            XCTAssertEqual(result.body, #"{"action":"silence"}"#)
            expectation.fulfill()
        }
        registry.fulfill(key: "c1", action: .silence)
        wait(for: [expectation], timeout: 2)
    }

    func testCallWaitAnswerAction() {
        let expectation = expectation(description: "wait")
        handler.handleAsync(
            path: "/call/wait", authorization: "Bearer secret",
            body: Data(#"{"key":"c2"}"#.utf8)) { result in
            XCTAssertEqual(result.body, #"{"action":"answer"}"#)
            expectation.fulfill()
        }
        registry.fulfill(key: "c2", action: .answer)
        wait(for: [expectation], timeout: 2)
    }

    func testCallWaitBadTokenIs401() {
        let expectation = expectation(description: "wait")
        handler.handleAsync(
            path: "/call/wait", authorization: "Bearer wrong",
            body: Data(#"{"key":"c1"}"#.utf8)) { result in
            XCTAssertEqual(result.status, 401)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testDismissEndsCallOnSink() {
        _ = post("/dismiss", auth: "Bearer secret", body: #"{"key":"c9"}"#)
        XCTAssertEqual(callSink.ended, ["c9"])
    }

    func testDismissFulfillsPendingWaitWithNone() {
        let expectation = expectation(description: "wait")
        handler.handleAsync(
            path: "/call/wait", authorization: "Bearer secret",
            body: Data(#"{"key":"c1"}"#.utf8)) { result in
            XCTAssertEqual(result.body, #"{"action":"none"}"#)
            expectation.fulfill()
        }
        _ = post("/dismiss", auth: "Bearer secret", body: #"{"key":"c1"}"#)
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(sink.dismissed, ["c1"])
    }

    func testHandleAsyncPassesThroughSyncPaths() {
        let expectation = expectation(description: "sync")
        handler.handleAsync(path: "/whatever", authorization: "Bearer secret", body: Data("{}".utf8)) { result in
            XCTAssertEqual(result.status, 404)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}
