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
        let info = try Pairing.ensure(directory: dir, secrets: InMemorySecretStore())
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.certPath.path))
        XCTAssertFalse(info.keyPEM.isEmpty)
        XCTAssertFalse(info.token.isEmpty)
    }

    func testFingerprintIs64LowercaseHex() throws {
        let info = try Pairing.ensure(directory: dir, secrets: InMemorySecretStore())
        XCTAssertEqual(info.fingerprint.count, 64)
        XCTAssertTrue(info.fingerprint.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testStableAcrossCalls() throws {
        let secrets = InMemorySecretStore()
        let first = try Pairing.ensure(directory: dir, secrets: secrets)
        let second = try Pairing.ensure(directory: dir, secrets: secrets)
        XCTAssertEqual(first.token, second.token)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.keyPEM, second.keyPEM)
    }

    // The key and token must live in the secret store, never as plaintext
    // files on disk.
    func testKeyAndTokenAreNotOnDisk() throws {
        let secrets = InMemorySecretStore()
        let info = try Pairing.ensure(directory: dir, secrets: secrets)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("key.pem").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("token").path))
        XCTAssertEqual(secrets.data(for: Pairing.tokenAccount), Data(info.token.utf8))
        XCTAssertEqual(secrets.data(for: Pairing.keyAccount), info.keyPEM)
    }

    // An earlier build stored the key and token as files; ensure() must pull
    // them into the secret store and delete the plaintext copies.
    func testMigratesLegacyFilesIntoSecretStore() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let certPath = dir.appendingPathComponent("cert.pem")
        let keyPath = dir.appendingPathComponent("key.pem")
        try Pairing.generateCert(certPath: certPath, keyPath: keyPath)
        let tokenPath = dir.appendingPathComponent("token")
        try "legacy-token".write(to: tokenPath, atomically: true, encoding: .utf8)

        let secrets = InMemorySecretStore()
        let info = try Pairing.ensure(directory: dir, secrets: secrets)

        XCTAssertEqual(info.token, "legacy-token")
        XCTAssertFalse(fm.fileExists(atPath: keyPath.path))
        XCTAssertFalse(fm.fileExists(atPath: tokenPath.path))
        XCTAssertNotNil(secrets.data(for: Pairing.keyAccount))
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
        let info = try Pairing.ensure(directory: dir, secrets: InMemorySecretStore())
        let payload = Pairing.qrPayload(info: info, port: 52735)
        let obj = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["v"] as? Int, 1)
        XCTAssertEqual(obj?["port"] as? Int, 52735)
        XCTAssertEqual(obj?["token"] as? String, info.token)
        XCTAssertEqual(obj?["fp"] as? String, info.fingerprint)
        XCTAssertFalse((obj?["host"] as? String ?? "").isEmpty)
    }
}
