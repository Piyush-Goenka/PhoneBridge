import XCTest
@testable import PhoneBridgeCore

final class NotificationHistoryTests: XCTestCase {
    private var fileURL: URL!

    func testFileHistoryCipherPersistsOwnerOnlyKey() throws {
        let directory = fileURL.deletingLastPathComponent()
        let first = try FileHistoryCipher(directory: directory)
        let plaintext = Data("private notification".utf8)
        let ciphertext = try first.seal(plaintext)
        let keyPath = directory.appendingPathComponent(FileHistoryCipher.keyFileName)

        XCTAssertNotEqual(ciphertext, plaintext)
        XCTAssertEqual(try Data(contentsOf: keyPath).count, 32)
        let mode = try FileManager.default
            .attributesOfItem(atPath: keyPath.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        let reloaded = try FileHistoryCipher(directory: directory)
        XCTAssertEqual(try reloaded.open(ciphertext), plaintext)
    }

    func testFileHistoryCipherRejectsInvalidStoredKey() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let keyPath = directory.appendingPathComponent(FileHistoryCipher.keyFileName)
        try Data("too short".utf8).write(to: keyPath)

        XCTAssertThrowsError(try FileHistoryCipher(directory: directory))
    }

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

    // A file that fails decryption or parsing may be a plaintext leftover
    // from an older build; it must be removed, not silently kept on disk.
    func testRemovesHistoryFileItCannotDecode() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy plaintext or foreign-key ciphertext".utf8).write(to: fileURL)

        let history = NotificationHistory(fileURL: fileURL)

        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testHistoryFileIsOwnerAccessOnly() throws {
        let history = NotificationHistory(fileURL: fileURL)
        history.record(payload(key: "a"))
        let mode = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testMemoryOnlyHistoryNeverReadsOrWritesDisk() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plaintext that must be ignored".utf8).write(to: fileURL)
        let original = try Data(contentsOf: fileURL)
        let history = NotificationHistory(
            fileURL: fileURL, persistenceEnabled: false)

        XCTAssertTrue(history.entries.isEmpty)
        history.record(payload(key: "a", title: "memory only"))
        XCTAssertEqual(history.entries.map(\.title), ["memory only"])
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
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

    func testUpdateCallRewritesCallerInPlace() {
        let history = NotificationHistory(fileURL: fileURL)
        history.recordCall(key: "c1", caller: "Manoj")
        history.record(payload(key: "n1", title: "newer notification"))
        let originalId = history.entries.first { $0.isCall }?.id

        history.updateCall(key: "c1", caller: "Lattu Chacha")

        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.entries.first?.title, "newer notification")
        let call = history.entries.first { $0.isCall }
        XCTAssertEqual(call?.title, "Lattu Chacha")
        XCTAssertEqual(call?.id, originalId)
        let reloaded = NotificationHistory(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.first { $0.isCall }?.title, "Lattu Chacha")
    }

    func testUpdateCallWithoutMatchAppendsCallEntry() {
        let history = NotificationHistory(fileURL: fileURL)
        history.updateCall(key: "c9", caller: "Mummy")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertTrue(history.entries.first?.isCall == true)
        XCTAssertEqual(history.entries.first?.title, "Mummy")
    }

    func testCallHistorySinkForwardsUpdate() {
        let history = NotificationHistory(fileURL: fileURL)
        let inner = MockCallSink()
        let sink = CallHistorySink(wrapping: inner, history: history)
        sink.showCall(key: "c1", caller: "Manoj")
        sink.updateCall(key: "c1", caller: "Lattu Chacha")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.title, "Lattu Chacha")
        XCTAssertEqual(inner.updated.first?.caller, "Lattu Chacha")
    }

    func testCallHistorySinkForwardsStateAndMarksAnswered() {
        let history = NotificationHistory(fileURL: fileURL)
        let inner = MockCallSink()
        let sink = CallHistorySink(wrapping: inner, history: history)
        sink.showCall(key: "c1", caller: "Manoj")
        sink.setCallState(key: "c1", state: .active)
        XCTAssertEqual(inner.states.first?.state, .active)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.text, "Answered call")
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
