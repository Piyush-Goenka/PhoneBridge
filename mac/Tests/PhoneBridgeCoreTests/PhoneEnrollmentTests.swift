import XCTest
import NIOSSL
@testable import PhoneBridgeCore

final class PhoneEnrollmentTests: XCTestCase {
    private var dir: URL!
    private var certPath: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enroll-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        certPath = PhoneCertStore.path(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // A self-signed DER, standing in for the phone's Keystore certificate.
    private func sampleCertDER() throws -> Data {
        let cp = dir.appendingPathComponent("client-cert.pem")
        let kp = dir.appendingPathComponent("client-key.pem")
        try Pairing.generateCert(certPath: cp, keyPath: kp)
        let pem = try String(contentsOf: cp, encoding: .utf8)
        let base64 = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }.joined()
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
    }

    func testOpenModeAcceptsAndPersistsWith0600() throws {
        let der = try sampleCertDER()
        let coordinator = EnrollmentCoordinator(certPath: certPath, open: true)
        var enrolledFired = false
        coordinator.onEnrolled = { enrolledFired = true }

        XCTAssertEqual(coordinator.enroll(certDer: der), .accepted)
        XCTAssertFalse(enrolledFired, "relock must wait for the HTTP response write")
        XCTAssertNotNil(PhoneCertStore.loadTrustRoot(at: certPath))

        coordinator.enrollmentResponseWriteCompleted()
        XCTAssertTrue(enrolledFired)

        let perms = try FileManager.default.attributesOfItem(atPath: certPath.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
    }

    func testLockedModeRejectsWith403Semantics() throws {
        let der = try sampleCertDER()
        let coordinator = EnrollmentCoordinator(certPath: certPath, open: false)
        XCTAssertEqual(coordinator.enroll(certDer: der), .locked)
        XCTAssertNil(PhoneCertStore.loadTrustRoot(at: certPath))
    }

    func testInvalidDERRejected() {
        let coordinator = EnrollmentCoordinator(certPath: certPath, open: true)
        XCTAssertEqual(coordinator.enroll(certDer: Data([0x00, 0x01, 0x02])), .invalid)
        XCTAssertNil(PhoneCertStore.loadTrustRoot(at: certPath))
    }

    func testEnrollFlipsCoordinatorToLocked() throws {
        let der = try sampleCertDER()
        let coordinator = EnrollmentCoordinator(certPath: certPath, open: true)
        XCTAssertEqual(coordinator.enroll(certDer: der), .accepted)
        // A second enroll now behaves as locked.
        XCTAssertEqual(coordinator.enroll(certDer: der), .locked)
    }

    func testConcurrentEnrollmentAcceptsExactlyOneCertificate() throws {
        let der = try sampleCertDER()
        let coordinator = EnrollmentCoordinator(certPath: certPath, open: true)
        let resultsLock = NSLock()
        var results: [EnrollmentOutcome] = []
        var callbackCount = 0
        coordinator.onEnrolled = {
            resultsLock.lock()
            callbackCount += 1
            resultsLock.unlock()
        }

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let result = coordinator.enroll(certDer: der)
            resultsLock.lock()
            results.append(result)
            resultsLock.unlock()
        }

        XCTAssertEqual(results.filter { $0 == .accepted }.count, 1)
        XCTAssertEqual(results.filter { $0 == .locked }.count, 15)
        XCTAssertEqual(callbackCount, 0, "accepting must not relock before the response write")
        coordinator.enrollmentResponseWriteCompleted()
        XCTAssertEqual(callbackCount, 1)
        coordinator.enrollmentResponseWriteCompleted()
        XCTAssertEqual(callbackCount, 1, "a completed write must trigger relock only once")
    }
}
