import XCTest
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

    private let validNotify = """
        {"v":1,"key":"k1","pkg":"com.whatsapp","appName":"WhatsApp",\
        "title":"Alice","text":"hi","postedAt":1768406400000,"iconHash":"sha256:aa"}
        """

    override func setUp() {
        icons = MockIconStore()
        sink = MockSink()
        callSink = MockCallSink()
        registry = CallActionRegistry(timeout: 10)
        handler = RequestHandler(
            token: "secret", icons: icons, sink: sink,
            calls: registry, callSink: callSink)
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
        try icons.save("sha256:aa", png: Data([1]))
        let r = post("/notify", auth: "Bearer secret", body: validNotify)
        XCTAssertEqual(r.body, #"{"needIcon":false}"#)
    }

    func testEmptyIconHashNeverRequestsIcon() {
        let body = validNotify.replacingOccurrences(of: "sha256:aa", with: "")
        let r = post("/notify", auth: "Bearer secret", body: body)
        XCTAssertEqual(r.body, #"{"needIcon":false}"#)
    }

    func testMalformedJSONIs400() {
        let r = post("/notify", auth: "Bearer secret", body: "{nope")
        XCTAssertEqual(r.status, 400)
    }

    func testIconUploadStoresPNG() {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let r = post("/icon", auth: "Bearer secret",
                     body: #"{"iconHash":"sha256:bb","png":"\#(png)"}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(icons.has("sha256:bb"))
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
        let body = #"{"v":1,"key":"c1","caller":"Palak","postedAt":0}"#
        let r = post("/call", auth: "Bearer secret", body: body)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(callSink.calls.first?.key, "c1")
        XCTAssertEqual(callSink.calls.first?.caller, "Palak")
    }

    func testCallMalformedIs400() {
        XCTAssertEqual(post("/call", auth: "Bearer secret", body: "{nope").status, 400)
    }

    func testCallUpdateRoutesToUpdateNotShow() {
        let body = #"{"v":1,"key":"c1","caller":"Lattu Chacha","postedAt":0,"update":true}"#
        let r = post("/call", auth: "Bearer secret", body: body)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(callSink.calls.isEmpty)
        XCTAssertEqual(callSink.updated.first?.key, "c1")
        XCTAssertEqual(callSink.updated.first?.caller, "Lattu Chacha")
    }

    func testCallWithoutUpdateFlagShowsBanner() {
        let body = #"{"v":1,"key":"c1","caller":"Manoj","postedAt":0}"#
        _ = post("/call", auth: "Bearer secret", body: body)
        XCTAssertEqual(callSink.calls.first?.caller, "Manoj")
        XCTAssertTrue(callSink.updated.isEmpty)
    }

    func testCallStateActiveSwitchesPanelToInCall() {
        let body = #"{"v":1,"key":"c1","caller":"Manoj","postedAt":0,"state":"active"}"#
        let r = post("/call", auth: "Bearer secret", body: body)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(callSink.calls.isEmpty)
        XCTAssertEqual(callSink.states.first?.key, "c1")
        XCTAssertEqual(callSink.states.first?.state, .active)
    }

    func testCallStateSilencedMarksPanel() {
        let body = #"{"v":1,"key":"c1","caller":"Manoj","postedAt":0,"state":"silenced"}"#
        _ = post("/call", auth: "Bearer secret", body: body)
        XCTAssertEqual(callSink.states.first?.state, .silenced)
        XCTAssertTrue(callSink.calls.isEmpty)
    }

    func testUnknownCallStateFallsBackToShowingTheCall() {
        let body = #"{"v":1,"key":"c1","caller":"Manoj","postedAt":0,"state":"wat"}"#
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
