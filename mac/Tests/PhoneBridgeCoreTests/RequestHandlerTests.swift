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

final class RequestHandlerTests: XCTestCase {
    private var icons: MockIconStore!
    private var sink: MockSink!
    private var handler: RequestHandler!

    private let validNotify = """
        {"v":1,"key":"k1","pkg":"com.whatsapp","appName":"WhatsApp",\
        "title":"Alice","text":"hi","postedAt":1768406400000,"iconHash":"sha256:aa"}
        """

    override func setUp() {
        icons = MockIconStore()
        sink = MockSink()
        handler = RequestHandler(token: "secret", icons: icons, sink: sink)
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
}
