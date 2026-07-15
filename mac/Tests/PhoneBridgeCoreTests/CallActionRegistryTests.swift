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
