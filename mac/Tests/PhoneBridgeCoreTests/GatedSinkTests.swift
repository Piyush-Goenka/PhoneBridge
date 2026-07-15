import XCTest
@testable import PhoneBridgeCore

final class GatedSinkTests: XCTestCase {
    private let payload = NotifyPayload(
        v: 1, key: "k", pkg: "p", appName: "A",
        title: "t", text: "x", postedAt: 0, iconHash: "")

    func testForwardsWhenEnabled() {
        let inner = MockSink()
        let gated = GatedSink(wrapping: inner)
        gated.show(payload, iconPath: nil)
        XCTAssertEqual(inner.shown.count, 1)
    }

    func testDropsShowWhenDisabled() {
        let inner = MockSink()
        let gated = GatedSink(wrapping: inner)
        gated.enabled = false
        gated.show(payload, iconPath: nil)
        XCTAssertTrue(inner.shown.isEmpty)
    }

    func testAlwaysForwardsDismiss() {
        let inner = MockSink()
        let gated = GatedSink(wrapping: inner)
        gated.enabled = false
        gated.dismiss(key: "k")
        XCTAssertEqual(inner.dismissed, ["k"])
    }
}
