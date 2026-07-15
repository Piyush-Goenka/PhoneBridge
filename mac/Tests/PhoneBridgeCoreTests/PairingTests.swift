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
