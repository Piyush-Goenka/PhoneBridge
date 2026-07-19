import XCTest
@testable import PhoneBridgeCore

final class CallActionRegistryTests: XCTestCase {
    func testFulfillDeliversActionOnce() {
        let registry = CallActionRegistry(timeout: 10)
        var received: [CallAction] = []
        registry.register(key: "k") { received.append($0) }
        registry.fulfill(key: "k", action: .reject)
        registry.fulfill(key: "k", action: .silence)
        XCTAssertEqual(received, [.reject])
    }

    func testTimeoutDeliversNone() {
        let registry = CallActionRegistry(timeout: 0.1)
        let expectation = expectation(description: "timeout")
        registry.register(key: "k") { action in
            XCTAssertEqual(action, .none)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testReRegisterFulfillsPreviousWithNone() {
        let registry = CallActionRegistry(timeout: 10)
        var first: CallAction?
        registry.register(key: "k") { first = $0 }
        registry.register(key: "k") { _ in }
        XCTAssertEqual(first, CallAction.none)
    }

    func testFulfillUnknownKeyIsHarmless() {
        let registry = CallActionRegistry(timeout: 10)
        registry.fulfill(key: "missing", action: .reject)
    }

    // During a long call the phone re-polls every 45 s, so a click can land
    // in the gap between two waits. It must not be lost.
    func testActionClickedBetweenWaitsIsDeliveredToTheNextWait() {
        let registry = CallActionRegistry(timeout: 10)
        registry.fulfill(key: "k", action: .end)
        var received: [CallAction] = []
        registry.register(key: "k") { received.append($0) }
        XCTAssertEqual(received, [.end])
    }

    func testBufferedActionIsDeliveredOnlyOnce() {
        let registry = CallActionRegistry(timeout: 10)
        registry.fulfill(key: "k", action: .end)
        registry.register(key: "k") { _ in }
        var second: [CallAction] = []
        registry.register(key: "k") { second.append($0) }
        XCTAssertTrue(second.isEmpty, "buffered action was replayed to a later wait")
    }

    func testTimeoutIsNotBuffered() {
        let registry = CallActionRegistry(timeout: 10)
        registry.fulfill(key: "k", action: .none)
        var received: [CallAction] = []
        registry.register(key: "k") { received.append($0) }
        XCTAssertTrue(received.isEmpty, "a timeout should never be replayed as an action")
    }

    func testCancelClearsBufferedActionAndPendingWait() {
        let registry = CallActionRegistry(timeout: 10)
        registry.fulfill(key: "k", action: .end)
        registry.cancel(key: "k")
        var received: [CallAction] = []
        registry.register(key: "k") { received.append($0) }
        XCTAssertTrue(received.isEmpty, "stale action survived the call ending")
    }

    func testCancelFulfillsPendingWaitWithNone() {
        let registry = CallActionRegistry(timeout: 10)
        var received: [CallAction] = []
        registry.register(key: "k") { received.append($0) }
        registry.cancel(key: "k")
        XCTAssertEqual(received, [CallAction.none])
    }

    func testStaleTimerDoesNotExpireLaterRegistration() {
        let registry = CallActionRegistry(timeout: 0.5)
        registry.register(key: "k") { _ in }

        // Re-register a quarter second in; the first timer (t=0.5) is now stale.
        Thread.sleep(forTimeInterval: 0.25)
        var secondActions: [CallAction] = []
        let expectation = expectation(description: "second registration expires on its own schedule")
        registry.register(key: "k") { action in
            secondActions.append(action)
            expectation.fulfill()
        }

        // At t=0.6 the stale timer has fired; the second registration (expires t=0.75) must still be pending.
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertTrue(secondActions.isEmpty, "stale timer expired the newer registration early")

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(secondActions, [.none])
    }
}
