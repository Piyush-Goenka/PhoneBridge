import Foundation
import CryptoKit

// Encrypts the notification history blob at rest. Injected into
// NotificationHistory so the on-disk logic stays unit-testable.
public protocol HistoryCipher {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ ciphertext: Data) throws -> Data
}

// Identity cipher for tests and explicitly memory-only history instances.
public struct PlaintextHistoryCipher: HistoryCipher {
    public init() {}
    public func seal(_ plaintext: Data) throws -> Data { plaintext }
    public func open(_ ciphertext: Data) throws -> Data { ciphertext }
}

// AES-GCM with a 256-bit key stored beside the rest of PhoneBridge's private
// application-support files. The directory is 0700 and the key is 0600.
public struct FileHistoryCipher: HistoryCipher {
    public static let keyFileName = "history.key"

    private let key: SymmetricKey

    public init(directory: URL) throws {
        try PrivateFile.prepareDirectory(directory)
        let keyPath = directory.appendingPathComponent(Self.keyFileName)
        let raw: Data
        if FileManager.default.fileExists(atPath: keyPath.path) {
            raw = try Data(contentsOf: keyPath)
            try PrivateFile.protect(keyPath)
            guard raw.count == 32 else { throw FileHistoryCipherError.invalidStoredKey }
        } else {
            let generated = SymmetricKey(size: .bits256)
            raw = generated.withUnsafeBytes { Data($0) }
            try PrivateFile.write(raw, to: keyPath)
        }
        key = SymmetricKey(data: raw)
    }

    public func seal(_ plaintext: Data) throws -> Data {
        try AES.GCM.seal(plaintext, using: key).combined ?? Data()
    }

    public func open(_ ciphertext: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    enum FileHistoryCipherError: Error {
        case invalidStoredKey
    }
}
