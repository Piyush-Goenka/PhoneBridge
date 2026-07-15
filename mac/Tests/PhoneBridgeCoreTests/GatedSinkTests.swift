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

    func testDropsCallWhenDisabled() {
        let inner = MockSink()
        let callInner = MockCallSink()
        let gated = GatedSink(wrapping: inner, calls: callInner)
        gated.enabled = false
        gated.showCall(key: "k", caller: "X")
        XCTAssertTrue(callInner.calls.isEmpty)
        gated.enabled = true
        gated.showCall(key: "k", caller: "X")
        XCTAssertEqual(callInner.calls.count, 1)
    }

    func testAlwaysForwardsEndCall() {
        let callInner = MockCallSink()
        let gated = GatedSink(wrapping: MockSink(), calls: callInner)
        gated.enabled = false
        gated.endCall(key: "k")
        XCTAssertEqual(callInner.ended, ["k"])
    }
}
