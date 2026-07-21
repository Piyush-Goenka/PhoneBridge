import XCTest
@testable import PhoneBridgeCore

final class ConnectionLimiterTests: XCTestCase {
    func testPerIPCap() {
        let limiter = ConnectionLimiter(maxTotal: 100, maxPerIP: 2)
        XCTAssertTrue(limiter.acquire("10.0.0.1"))
        XCTAssertTrue(limiter.acquire("10.0.0.1"))
        XCTAssertFalse(limiter.acquire("10.0.0.1"), "third from same IP is refused")
        XCTAssertTrue(limiter.acquire("10.0.0.2"), "a different IP is unaffected")
    }

    func testReleaseFreesASlot() {
        let limiter = ConnectionLimiter(maxTotal: 100, maxPerIP: 1)
        XCTAssertTrue(limiter.acquire("10.0.0.1"))
        XCTAssertFalse(limiter.acquire("10.0.0.1"))
        limiter.release("10.0.0.1")
        XCTAssertTrue(limiter.acquire("10.0.0.1"), "slot is reusable after release")
    }

    func testTotalCap() {
        let limiter = ConnectionLimiter(maxTotal: 2, maxPerIP: 10)
        XCTAssertTrue(limiter.acquire("10.0.0.1"))
        XCTAssertTrue(limiter.acquire("10.0.0.2"))
        XCTAssertFalse(limiter.acquire("10.0.0.3"), "total cap refuses a third IP")
    }

    func testOverReleaseDoesNotUnderflow() {
        let limiter = ConnectionLimiter(maxTotal: 1, maxPerIP: 1)
        limiter.release("10.0.0.1")   // release without acquire
        XCTAssertTrue(limiter.acquire("10.0.0.1"))
        XCTAssertFalse(limiter.acquire("10.0.0.2"), "total stays at 1, not negative")
    }
}
