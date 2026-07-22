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

    // enabled is written from the UI thread and read on server threads for
    // every incoming notification. This pins that cross-thread use (data
    // races surface under Thread Sanitizer) and that the last write wins.
    func testEnabledToggleAcrossThreadsSettles() {
        let gated = GatedSink(wrapping: MockSink())
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            gated.enabled = index % 2 == 0
            _ = gated.enabled
        }
        gated.enabled = false
        XCTAssertFalse(gated.enabled)
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

    func testDropsCallStateWhenDisabled() {
        let callInner = MockCallSink()
        let gated = GatedSink(wrapping: MockSink(), calls: callInner)
        gated.enabled = false
        gated.setCallState(key: "k", state: .active)
        XCTAssertTrue(callInner.states.isEmpty)
        gated.enabled = true
        gated.setCallState(key: "k", state: .active)
        XCTAssertEqual(callInner.states.count, 1)
    }

    func testDropsCallUpdateWhenDisabled() {
        let callInner = MockCallSink()
        let gated = GatedSink(wrapping: MockSink(), calls: callInner)
        gated.enabled = false
        gated.updateCall(key: "k", caller: "X")
        XCTAssertTrue(callInner.updated.isEmpty)
        gated.enabled = true
        gated.updateCall(key: "k", caller: "X")
        XCTAssertEqual(callInner.updated.count, 1)
    }
}
