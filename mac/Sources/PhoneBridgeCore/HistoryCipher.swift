import Foundation
import CryptoKit
import Security

// Encrypts the notification history blob at rest. Injected into
// NotificationHistory so the on-disk logic stays unit-testable: tests use a
// plaintext cipher, the app uses the Keychain-backed one.
public protocol HistoryCipher {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ ciphertext: Data) throws -> Data
}

// Identity cipher for tests and first-run fallback.
public struct PlaintextHistoryCipher: HistoryCipher {
    public init() {}
    public func seal(_ plaintext: Data) throws -> Data { plaintext }
    public func open(_ ciphertext: Data) throws -> Data { ciphertext }
}

// AES-GCM with a 256-bit key held in the login Keychain, so a copy of
// history.json alone is useless to same-user malware that cannot reach the
// Keychain item.
public struct KeychainHistoryCipher: HistoryCipher {
    private let key: SymmetricKey

    public init(account: String = "history-encryption-key",
                service: String = "com.piyush.phonebridge") throws {
        self.key = try KeychainHistoryCipher.loadOrCreateKey(account: account, service: service)
    }

    public func seal(_ plaintext: Data) throws -> Data {
        try AES.GCM.seal(plaintext, using: key).combined ?? Data()
    }

    public func open(_ ciphertext: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    private static func loadOrCreateKey(account: String, service: String) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }

        var raw = Data(count: 32)
        let generated = raw.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard generated == errSecSuccess else { throw KeychainError.randomFailed }

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw KeychainError.storeFailed(addStatus)
        }
        return SymmetricKey(data: raw)
    }

    enum KeychainError: Error {
        case randomFailed
        case storeFailed(OSStatus)
    }
}
