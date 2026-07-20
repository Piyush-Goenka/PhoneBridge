import XCTest
@testable import PhoneBridgeCore

final class PrivateAddressTests: XCTestCase {
    func testAllowsLoopbackAndPrivateRanges() {
        for ip in ["127.0.0.1", "10.0.0.5", "172.16.9.9", "172.31.255.1",
                   "192.168.1.7", "169.254.10.10", "100.64.0.1", "100.127.3.4"] {
            XCTAssertTrue(PrivateAddress.isAllowedIPv4(ip), "\(ip) should be allowed")
        }
    }

    func testRejectsPublicAndMalformed() {
        for ip in ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1",
                   "100.63.0.1", "100.128.0.1", "192.169.0.1", "not.an.ip", ""] {
            XCTAssertFalse(PrivateAddress.isAllowedIPv4(ip), "\(ip) should be rejected")
        }
    }
}
