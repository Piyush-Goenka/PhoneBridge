import XCTest
@testable import PhoneBridgeCore

final class IconStoreTests: XCTestCase {
    func testSaveHasPathRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("icons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try DiskIconStore(directory: dir)

        XCTAssertFalse(store.has("sha256:aa"))
        XCTAssertNil(store.path("sha256:aa"))

        try store.save("sha256:aa", png: Data([1, 2, 3]))
        XCTAssertTrue(store.has("sha256:aa"))
        let path = try XCTUnwrap(store.path("sha256:aa"))
        XCTAssertEqual(try Data(contentsOf: path), Data([1, 2, 3]))
    }
}
