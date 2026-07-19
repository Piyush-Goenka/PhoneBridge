import XCTest
@testable import PhoneBridgeCore

final class PairingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pairing-tests-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testGeneratesCertKeyAndToken() throws {
        let info = try Pairing.ensure(directory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.certPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.keyPath.path))
        XCTAssertFalse(info.token.isEmpty)
    }

    func testFingerprintIs64LowercaseHex() throws {
        let info = try Pairing.ensure(directory: dir)
        XCTAssertEqual(info.fingerprint.count, 64)
        XCTAssertTrue(info.fingerprint.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testStableAcrossCalls() throws {
        let first = try Pairing.ensure(directory: dir)
        let second = try Pairing.ensure(directory: dir)
        XCTAssertEqual(first.token, second.token)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testKeyAndTokenFilesArePrivate() throws {
        let info = try Pairing.ensure(directory: dir)
        for url in [info.keyPath, dir.appendingPathComponent("token")] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
        }
    }

    func testPrivateIPv4Recognition() {
        XCTAssertTrue(Pairing.isPrivateIPv4("192.168.1.5"))
        XCTAssertTrue(Pairing.isPrivateIPv4("10.0.0.1"))
        XCTAssertTrue(Pairing.isPrivateIPv4("172.16.9.9"))
        XCTAssertTrue(Pairing.isPrivateIPv4("172.31.255.254"))
        XCTAssertFalse(Pairing.isPrivateIPv4("172.32.0.1"))
        XCTAssertFalse(Pairing.isPrivateIPv4("8.8.8.8"))
        XCTAssertFalse(Pairing.isPrivateIPv4("169.254.1.1"))
        XCTAssertFalse(Pairing.isPrivateIPv4("not-an-ip"))
    }

    func testPrimaryIPv4LooksLikeADottedQuadWhenPresent() {
        guard let ip = Pairing.primaryIPv4() else { return }
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        XCTAssertEqual(octets.count, 4)
        XCTAssertTrue(octets.allSatisfy { (0...255).contains($0) })
    }

    func testQRPayloadIsValidJSON() throws {
        let info = try Pairing.ensure(directory: dir)
        let payload = Pairing.qrPayload(info: info, port: 52735)
        let obj = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["v"] as? Int, 1)
        XCTAssertEqual(obj?["port"] as? Int, 52735)
        XCTAssertEqual(obj?["token"] as? String, info.token)
        XCTAssertEqual(obj?["fp"] as? String, info.fingerprint)
        XCTAssertFalse((obj?["host"] as? String ?? "").isEmpty)
    }
}
