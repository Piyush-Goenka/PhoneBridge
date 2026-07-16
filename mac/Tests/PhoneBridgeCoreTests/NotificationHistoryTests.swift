import XCTest
@testable import PhoneBridgeCore

final class NotificationHistoryTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-tests-" + UUID().uuidString)
            .appendingPathComponent("history.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func payload(key: String, title: String = "t") -> NotifyPayload {
        NotifyPayload(
            v: 1, key: key, pkg: "p", appName: "App",
            title: title, text: "x", postedAt: 0, iconHash: "")
    }

    func testRecordsNewestFirst() {
        let history = NotificationHistory(fileURL: fileURL)
        history.record(payload(key: "a", title: "first"))
        history.record(payload(key: "b", title: "second"))
        XCTAssertEqual(history.entries.map(\.title), ["second", "first"])
    }

    func testCapsEntries() {
        let history = NotificationHistory(fileURL: fileURL, cap: 3)
        for index in 0..<5 {
            history.record(payload(key: "k\(index)", title: "t\(index)"))
        }
        XCTAssertEqual(history.entries.count, 3)
        XCTAssertEqual(history.entries.first?.title, "t4")
    }

    func testPersistsAcrossReload() {
        let history = NotificationHistory(fileURL: fileURL)
        history.record(payload(key: "a", title: "kept"))
        let reloaded = NotificationHistory(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.map(\.title), ["kept"])
    }

    func testClearEmptiesAndPersists() {
        let history = NotificationHistory(fileURL: fileURL)
        history.record(payload(key: "a"))
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(NotificationHistory(fileURL: fileURL).entries.isEmpty)
    }

    func testRecordCallMarksKindAndCaller() {
        let history = NotificationHistory(fileURL: fileURL)
        history.recordCall(key: "c1", caller: "Mummy")
        let entry = history.entries.first
        XCTAssertEqual(entry?.title, "Mummy")
        XCTAssertEqual(entry?.appName, "Phone")
        XCTAssertTrue(entry?.isCall == true)
    }

    func testCallHistorySinkRecordsAndForwards() {
        let history = NotificationHistory(fileURL: fileURL)
        let inner = MockCallSink()
        let sink = CallHistorySink(wrapping: inner, history: history)
        sink.showCall(key: "c1", caller: "Mummy")
        sink.endCall(key: "c1")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertTrue(history.entries.first?.isCall == true)
        XCTAssertEqual(inner.calls.first?.caller, "Mummy")
        XCTAssertEqual(inner.ended, ["c1"])
    }

    func testHistorySinkRecordsAndForwards() {
        let history = NotificationHistory(fileURL: fileURL)
        let inner = MockSink()
        let sink = HistorySink(wrapping: inner, history: history)
        sink.show(payload(key: "a"), iconPath: nil)
        sink.dismiss(key: "a")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(inner.shown.count, 1)
        XCTAssertEqual(inner.dismissed, ["a"])
    }
}
