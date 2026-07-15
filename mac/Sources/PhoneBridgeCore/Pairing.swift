import Foundation
import CryptoKit
import Security

public struct PairingInfo {
    public let certPath: URL
    public let keyPath: URL
    public let fingerprint: String
    public let token: String
}

public enum PairingError: Error {
    case opensslFailed(Int32)
    case badPEM
}

public enum Pairing {
    public static func ensure(directory: URL) throws -> PairingInfo {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let certPath = directory.appendingPathComponent("cert.pem")
        let keyPath = directory.appendingPathComponent("key.pem")
        let tokenPath = directory.appendingPathComponent("token")

        if !fm.fileExists(atPath: certPath.path) || !fm.fileExists(atPath: keyPath.path) {
            try generateCert(certPath: certPath, keyPath: keyPath)
        }

        let token: String
        if let existing = try? String(contentsOf: tokenPath, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            token = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            token = randomToken()
            try token.write(to: tokenPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath.path)
        }

        return PairingInfo(
            certPath: certPath,
            keyPath: keyPath,
            fingerprint: try fingerprint(ofCertAt: certPath),
            token: token)
    }

    public static func qrPayload(info: PairingInfo, port: Int) -> String {
        // The QR carries the Mac's current IPv4 address, not its .local
        // hostname: resolving .local needs mDNS, which some routers block
        // between Wi-Fi clients. The IP works everywhere; mDNS discovery
        // remains the phone's fallback when the cached IP goes stale.
        let dict: [String: Any] = [
            "v": 1,
            "host": primaryIPv4() ?? ProcessInfo.processInfo.hostName,
            "port": port,
            "token": info.token,
            "fp": info.fingerprint,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    public static func primaryIPv4() -> String? {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        // Connecting a UDP socket sends nothing; it just makes the kernel
        // pick the outbound interface, whose address getsockname reveals.
        var remote = sockaddr_in()
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(53).bigEndian
        remote.sin_addr.s_addr = inet_addr("8.8.8.8")
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &length)
            }
        }
        guard named == 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = local.sin_addr
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }

    static func generateCert(certPath: URL, keyPath: URL) throws {
        let host = ProcessInfo.processInfo.hostName
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyPath.path, "-out", certPath.path,
            "-days", "3650",
            "-subj", "/CN=PhoneBridge",
            "-addext", "subjectAltName=DNS:\(host),DNS:localhost,IP:127.0.0.1",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PairingError.opensslFailed(process.terminationStatus)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
    }

    static func fingerprint(ofCertAt url: URL) throws -> String {
        let pem = try String(contentsOf: url, encoding: .utf8)
        let base64 = pem
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let der = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { throw PairingError.badPEM }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
