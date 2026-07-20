import Foundation
import NIOSSL

// Result of a phone trying to enroll its client certificate, mapped to an
// HTTP status by RequestHandler.
public enum EnrollmentOutcome: Equatable {
    case accepted   // 200: stored, server will lock
    case locked     // 403: a phone is already enrolled and pairing is closed
    case invalid    // 400: the bytes are not a usable X.509 certificate
    case failed     // 500: could not persist the certificate
}

public protocol PhoneEnroller: AnyObject {
    func enroll(certDer: Data) -> EnrollmentOutcome
}

// On-disk store for the single enrolled phone certificate. The file is the
// server's trust anchor in locked mode.
public enum PhoneCertStore {

    public static func path(directory: URL) -> URL {
        directory.appendingPathComponent("phone-cert.pem")
    }

    // A corrupt or absent file is treated as "no phone enrolled", which drops
    // the server back to open mode so the phone can re-enroll automatically.
    public static func loadTrustRoot(at url: URL) -> NIOSSLCertificate? {
        guard let certs = try? NIOSSLCertificate.fromPEMFile(url.path) else { return nil }
        return certs.first
    }

    static func isValidDER(_ der: Data) -> Bool {
        (try? NIOSSLCertificate(bytes: Array(der), format: .der)) != nil
    }

    static func writePEM(der: Data, to url: URL) throws {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
        try pem.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// Owns the open/locked decision and the certificate write. Lives off the main
// actor because enrollment arrives on a SwiftNIO thread; a lock guards the
// mode flag. AppState observes `onEnrolled` to restart the listener locked
// and close the pairing window.
public final class EnrollmentCoordinator: PhoneEnroller {
    private let certPath: URL
    private let lock = NSLock()
    private var open: Bool
    public var onEnrolled: (() -> Void)?

    public init(certPath: URL, open: Bool) {
        self.certPath = certPath
        self.open = open
    }

    public func setOpen(_ value: Bool) {
        lock.lock()
        open = value
        lock.unlock()
    }

    public func enroll(certDer: Data) -> EnrollmentOutcome {
        lock.lock()
        let isOpen = open
        lock.unlock()
        guard isOpen else { return .locked }
        guard PhoneCertStore.isValidDER(certDer) else { return .invalid }

        do {
            try PhoneCertStore.writePEM(der: certDer, to: certPath)
        } catch {
            return .failed
        }

        lock.lock()
        open = false
        lock.unlock()
        onEnrolled?()
        return .accepted
    }
}
